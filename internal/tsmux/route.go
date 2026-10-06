package tsmux

import (
	"fmt"
	"net"
	"net/netip"
	"sort"
	"strings"
)

// Match explains a routing decision. Reason is surfaced by `tsmux test`.
type Match struct {
	Profile *Profile
	Reason  string
}

// SplitHost strips a :port and any trailing dot, lowercasing the result.
func SplitHost(hostport string) string {
	h := hostport
	if host, _, err := net.SplitHostPort(hostport); err == nil {
		h = host
	}
	return strings.ToLower(strings.TrimSuffix(strings.Trim(h, "[]"), "."))
}

// Route picks the profile that owns host. Longest suffix wins, so a profile
// claiming ".corp.example.ts.net" beats one claiming ".example.ts.net".
func (c *Config) Route(hostport string) (*Match, error) {
	host := SplitHost(hostport)
	if host == "" {
		return nil, fmt.Errorf("empty host")
	}

	// D4: Suffixes are appended by the watch goroutine when a node learns its
	// MagicDNS suffix, so every read of them is under the config lock.
	c.mu.RLock()
	defer c.mu.RUnlock()

	if ip, err := netip.ParseAddr(host); err == nil {
		for _, p := range c.sorted {
			for _, pfx := range p.routes {
				if pfx.Contains(ip) {
					return &Match{p, "ip_route " + pfx.String()}, nil
				}
			}
		}
		if exit := c.exitProfileLocked(); exit != nil && exitCarriesIP(ip, c.exit.AllowLAN) {
			return &Match{exit, "ip literal to " + exit.Name + " exit node"}, nil
		}
		if !c.Security.AllowIPLiterals {
			return nil, fmt.Errorf("%s: IP literals are not routable; add it to a profile's ip_routes or set security.allow_ip_literals", host)
		}
		return c.fallback(host, "ip literal")
	}

	var best *Profile
	var bestLen int
	var reason string
	for _, p := range c.sorted {
		for _, s := range p.Suffixes {
			// ".foo.ts.net" matches both "a.foo.ts.net" and bare "foo.ts.net".
			if strings.HasSuffix(host, s) || host == strings.TrimPrefix(s, ".") {
				if len(s) > bestLen {
					best, bestLen, reason = p, len(s), "suffix "+s
				}
			}
		}
	}
	if best != nil {
		return &Match{best, reason}, nil
	}

	if !strings.Contains(host, ".") {
		var roots []*Profile
		for _, p := range c.sorted {
			if p.MatchRoot {
				roots = append(roots, p)
			}
		}
		switch len(roots) {
		case 1:
			return &Match{roots[0], "match_root"}, nil
		case 0:
		default:
			names := make([]string, len(roots))
			for i, p := range roots {
				names[i] = p.Name
			}
			sort.Strings(names)
			return nil, fmt.Errorf("%s: ambiguous bare name, claimed by %s; qualify it with a tailnet suffix", host, strings.Join(names, ", "))
		}
	}

	if exit := c.exitProfileLocked(); exit != nil && exitCarriesName(host, c.exit.AllowLAN) {
		return &Match{exit, "fallback to " + exit.Name + " exit node"}, nil
	}
	return c.fallback(host, "fallback")
}

// Destinations an exit node never carries, so the PAC sends them DIRECT and
// the router refuses them: this host, the link, and Tailscale's own ranges,
// where one address is a different machine in each tailnet.
var exitNever = prefixes("0.0.0.0/32", "127.0.0.0/8", "169.254.0.0/16", "100.64.0.0/10",
	"::/128", "::1/128", "fe80::/10", "fd7a:115c:a1e0::/48")

// exitLAN is what "allow local network access" keeps off the exit node.
var exitLAN = prefixes("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7")

// The PAC mirrors exitCarriesIP and exitCarriesName in JavaScript;
// TestPACExitNode holds the two together.
func exitCarriesIP(ip netip.Addr, allowLAN bool) bool {
	if ip.Is4In6() {
		return false
	}
	for _, p := range exitNever {
		if p.Contains(ip) {
			return false
		}
	}
	if allowLAN {
		for _, p := range exitLAN {
			if p.Contains(ip) {
				return false
			}
		}
	}
	return true
}

func exitCarriesName(host string, allowLAN bool) bool {
	if host == "localhost" || strings.HasSuffix(host, ".local") {
		return false
	}
	return !allowLAN || strings.Contains(host, ".")
}

func prefixes(cidrs ...string) []netip.Prefix {
	out := make([]netip.Prefix, len(cidrs))
	for i, s := range cidrs {
		out[i] = netip.MustParsePrefix(s)
	}
	return out
}

func (c *Config) fallback(host, why string) (*Match, error) {
	if !c.Security.AllowCrossProfileFallback || len(c.sorted) == 0 {
		return nil, fmt.Errorf("%s: no profile claims this host", host)
	}
	return &Match{c.sorted[0], why + " to " + c.sorted[0].Name}, nil
}

// PACHosts lists every suffix a profile claims, for PAC generation.
func (c *Config) PACHosts() []*Profile { return c.sorted }
