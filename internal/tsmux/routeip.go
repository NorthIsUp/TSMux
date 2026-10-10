package tsmux

import (
	"context"
	"fmt"
	"net/netip"
	"slices"
	"strings"
)

// RouteIPRequest is the POST /route-ip body. Target is a device or service
// name, or one of its addresses.
type RouteIPRequest struct {
	Profile string `json:"profile"`
	Target  string `json:"target"`
	On      bool   `json:"on"`
}

func hostPrefixes(rs []RoutedIP) ([]netip.Prefix, error) {
	var out []netip.Prefix
	for _, r := range rs {
		for _, s := range r.IPs {
			a, err := netip.ParseAddr(strings.TrimSpace(s))
			if err != nil {
				return nil, fmt.Errorf("bad routed_ips address %q for %s: %w", s, r.Name, err)
			}
			out = append(out, netip.PrefixFrom(a, a.BitLen()))
		}
	}
	return out, nil
}

// SetRoutedIP turns routing r's addresses to profile on or off. Turning one on
// that another profile already routes is refused, as an ambiguous bare name
// is: the address would mean two different machines.
func (c *Config) SetRoutedIP(profile string, r RoutedIP, on bool) error {
	add, err := hostPrefixes([]RoutedIP{r})
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	p, ok := c.Profiles[profile]
	if !ok {
		return fmt.Errorf("no profile %q", profile)
	}
	if on {
		for _, pfx := range add {
			if owner := c.ipOwnerLocked(profile, pfx.Addr()); owner != "" {
				return fmt.Errorf("%s (%s) is already routed to %s, so it can't also route to %s; turn it off in %s first",
					pfx.Addr(), r.Name, owner, profile, owner)
			}
		}
	}
	kept := []RoutedIP{}
	for _, e := range p.RoutedIPs {
		if e.Name != r.Name && !slices.ContainsFunc(e.IPs, func(ip string) bool { return slices.Contains(r.IPs, ip) }) {
			kept = append(kept, e)
		}
	}
	if on {
		kept = append(kept, r)
		slices.SortFunc(kept, func(a, b RoutedIP) int { return strings.Compare(a.Name, b.Name) })
	}
	routed, err := hostPrefixes(kept)
	if err != nil {
		return err
	}
	p.RoutedIPs, p.routed = kept, routed
	return nil
}

// ipOwnerLocked is the other profile that routes a, by routed_ips or
// ip_routes, if any.
func (c *Config) ipOwnerLocked(self string, a netip.Addr) string {
	for _, o := range c.sorted {
		if o.Name == self {
			continue
		}
		in := func(p netip.Prefix) bool { return p.Contains(a) }
		if slices.ContainsFunc(o.routed, in) || slices.ContainsFunc(o.routes, in) {
			return o.Name
		}
	}
	return ""
}

// RoutedIPsOf is a copy of a profile's routed peers and services.
func (c *Config) RoutedIPsOf(profile string) []RoutedIP {
	c.mu.RLock()
	defer c.mu.RUnlock()
	p, ok := c.Profiles[profile]
	if !ok {
		return nil
	}
	return slices.Clone(p.RoutedIPs)
}

// routeState reports whether profile routes any of ips, and which other
// profile routes one of them instead, for the UI to say why it can't.
func (c *Config) routeState(profile string, ips []string) (routed bool, by string) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	p, ok := c.Profiles[profile]
	if !ok {
		return false, ""
	}
	for _, s := range ips {
		a, err := netip.ParseAddr(s)
		if err != nil {
			continue
		}
		if slices.Contains(p.routed, netip.PrefixFrom(a, a.BitLen())) {
			routed = true
		}
		if by == "" {
			by = c.ipOwnerLocked(profile, a)
		}
	}
	return routed, by
}

// routeTarget finds what target names among a profile's live devices and
// services, then among what it already routes, so a peer that has left can
// still be turned off.
func routeTarget(st Status, stored []RoutedIP, target string) (RoutedIP, error) {
	t := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(target), "."))
	type cand struct {
		r    RoutedIP
		keys []string
	}
	var live []cand
	for _, d := range st.Devices {
		short, _, _ := strings.Cut(d.Name, ".")
		live = append(live, cand{RoutedIP{d.Name, d.IPs}, append([]string{d.Name, short, d.Hostname}, d.IPs...)})
	}
	for _, s := range st.Services {
		live = append(live, cand{RoutedIP{s.Name, s.IPs},
			append([]string{s.Name, strings.TrimPrefix(s.Name, "svc:"), s.DNSName}, s.IPs...)})
	}
	var gone []cand
	for _, r := range stored {
		gone = append(gone, cand{r, append([]string{r.Name}, r.IPs...)})
	}
	for _, cands := range [][]cand{live, gone} {
		var hits []RoutedIP
		for _, c := range cands {
			if slices.ContainsFunc(c.keys, func(k string) bool { return strings.EqualFold(k, t) }) &&
				!slices.ContainsFunc(hits, func(h RoutedIP) bool { return h.Name == c.r.Name }) {
				hits = append(hits, c.r)
			}
		}
		switch len(hits) {
		case 0:
			continue
		case 1:
			if len(hits[0].IPs) == 0 {
				return RoutedIP{}, fmt.Errorf("%s has no addresses yet", hits[0].Name)
			}
			return hits[0], nil
		default:
			names := make([]string, len(hits))
			for i, h := range hits {
				names[i] = h.Name
			}
			return RoutedIP{}, fmt.Errorf("%s: ambiguous, matches %s; use the full name", target, strings.Join(names, ", "))
		}
	}
	return RoutedIP{}, fmt.Errorf("no device or service %q in profile %q", target, st.Profile)
}

// SetRoutedIP turns routing a device's or service's addresses to profile on
// or off, live and in config.yaml.
func (m *Manager) SetRoutedIP(ctx context.Context, profile, target string, on bool) (Status, error) {
	st, err := m.StatusOf(ctx, profile)
	if err != nil {
		return Status{}, err
	}
	r, err := routeTarget(st, m.cfg.RoutedIPsOf(profile), target)
	if err != nil {
		return Status{}, err
	}
	// Checked against the live config first, so a refusal leaves the file alone.
	if err := m.cfg.SetRoutedIP(profile, r, on); err != nil {
		return Status{}, err
	}
	if err := m.persistRoutedIP(profile, r, on); err != nil {
		return Status{}, fmt.Errorf("routing changed until restart, but not saved: %w", err)
	}
	return m.StatusOf(ctx, profile)
}

// persistRoutedIP is persistSuffix for routed IPs: re-read config.yaml so an
// edit made since startup survives.
func (m *Manager) persistRoutedIP(profile string, r RoutedIP, on bool) error {
	if m.cfg.Path() == "" {
		return nil
	}
	disk, err := Load(m.cfg.Path())
	if err != nil {
		return err
	}
	if err := disk.SetRoutedIP(profile, r, on); err != nil {
		return err
	}
	return disk.Save(disk.Path())
}

// PostRouteIP is the CLI's side of POST /route-ip.
func (c *Config) PostRouteIP(req RouteIPRequest) (Status, error) { return c.post("/route-ip", req) }
