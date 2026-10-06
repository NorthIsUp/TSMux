package tsmux

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"slices"
	"strings"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/types/netmap"
)

// netmapEvery bounds how often a running node re-reads its netmap. Each read
// is a full peer list, so it is not worth doing on every 5s status poll.
const netmapEvery = 30 * time.Second

// fetchNetmap reads the node's current netmap and prefs. This tsnet version
// has no LocalClient.NetMap, and the IPN bus only carries the netmap on the
// initial notify (NotifyInitialNetMap), so open a watch, take that one
// message, and close it.
func fetchNetmap(ctx context.Context, lc *local.Client) (*netmap.NetworkMap, ipn.PrefsView, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	w, err := lc.WatchIPNBus(ctx, ipn.NotifyInitialState|ipn.NotifyInitialNetMap|ipn.NotifyInitialPrefs)
	if err != nil {
		return nil, ipn.PrefsView{}, err
	}
	defer w.Close()
	n, err := w.Next()
	if err != nil {
		return nil, ipn.PrefsView{}, err
	}
	// A stopped node can still hold its last netmap; its routes are not live.
	if n.State == nil || *n.State != ipn.Running {
		return nil, ipn.PrefsView{}, errors.New("not running")
	}
	if n.NetMap == nil || n.Prefs == nil || !n.Prefs.Valid() {
		return nil, ipn.PrefsView{}, errors.New("no netmap yet")
	}
	return n.NetMap, *n.Prefs, nil
}

// learnFromNetmap extracts what the tailnet wants routed through it beyond
// its MagicDNS suffix: split-DNS domains (only resolvable by the node when it
// accepts DNS) and peers' subnet routes (only reachable when it accepts
// routes). Exit-node default routes are excluded; they would claim every IP.
func learnFromNetmap(nm *netmap.NetworkMap, acceptDNS, acceptRoutes bool) (domains []string, routes []netip.Prefix) {
	if nm == nil {
		return nil, nil
	}
	if acceptDNS {
		magic := normalizeSuffix(nm.MagicDNSSuffix())
		for k := range nm.DNS.Routes {
			d := normalizeSuffix(k)
			switch {
			case d == "" || d == ".":
			case strings.HasSuffix(d, ".arpa"):
			// The MagicDNS suffix is learned separately and persisted. A
			// parent of it ("ts.net") would swallow every other tailnet.
			case magic != "" && (d == magic || strings.HasSuffix(magic, d)):
			default:
				domains = append(domains, d)
			}
		}
		slices.Sort(domains)
		domains = slices.Compact(domains)
	}
	if acceptRoutes {
		for _, p := range nm.Peers {
			for _, r := range p.PrimaryRoutes().All() {
				if r = r.Masked(); r.IsValid() && r.Bits() > 0 {
					routes = append(routes, r)
				}
			}
		}
		slices.SortFunc(routes, comparePrefix)
		routes = slices.Compact(routes)
	}
	return domains, routes
}

func comparePrefix(a, b netip.Prefix) int {
	if c := a.Addr().Compare(b.Addr()); c != 0 {
		return c
	}
	return a.Bits() - b.Bits()
}

// setLearned replaces a profile's runtime-learned domains and routes. Nothing
// is written to config.yaml: these follow the tailnet's admin settings and
// would go stale on disk. A claim another profile already holds, statically
// or learned, stays with that profile and comes back as a conflict.
func (c *Config) setLearned(name string, domains []string, routes []netip.Prefix) (conflicts []string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	p, ok := c.Profiles[name]
	if !ok {
		return nil
	}
	p.learnedSuffixes, p.learnedRoutes = nil, nil
	for _, d := range domains {
		if slices.Contains(p.Suffixes, d) {
			continue
		}
		if owner := c.domainOwnerLocked(name, d); owner != "" {
			conflicts = append(conflicts, fmt.Sprintf("%s (%s)", strings.TrimPrefix(d, "."), owner))
			continue
		}
		p.learnedSuffixes = append(p.learnedSuffixes, d)
	}
	for _, r := range routes {
		if slices.Contains(p.routes, r) {
			continue
		}
		if owner := c.routeOwnerLocked(name, r); owner != "" {
			conflicts = append(conflicts, fmt.Sprintf("%s (%s)", r, owner))
			continue
		}
		p.learnedRoutes = append(p.learnedRoutes, r)
	}
	return conflicts
}

func (c *Config) domainOwnerLocked(self, d string) string {
	for _, o := range c.sorted {
		if o.Name != self && (slices.Contains(o.Suffixes, d) || slices.Contains(o.learnedSuffixes, d)) {
			return o.Name
		}
	}
	return ""
}

func (c *Config) routeOwnerLocked(self string, r netip.Prefix) string {
	for _, o := range c.sorted {
		if o.Name != self && (slices.Contains(o.routes, r) || slices.Contains(o.learnedRoutes, r)) {
			return o.Name
		}
	}
	return ""
}

// LearnedOf reports the split-DNS domains (no leading dot) and subnet routes
// a profile currently routes on top of its config.
func (c *Config) LearnedOf(name string) (domains, routes []string) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	p, ok := c.Profiles[name]
	if !ok {
		return nil, nil
	}
	for _, d := range p.learnedSuffixes {
		domains = append(domains, strings.TrimPrefix(d, "."))
	}
	for _, r := range p.learnedRoutes {
		routes = append(routes, r.String())
	}
	return domains, routes
}
