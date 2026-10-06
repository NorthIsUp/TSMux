package tsmux

import (
	"encoding/json"
	"net/netip"
	"slices"
	"testing"

	"tailscale.com/tailcfg"
	"tailscale.com/types/dnstype"
	"tailscale.com/types/netmap"
)

func testNetmap(t *testing.T) *netmap.NetworkMap {
	t.Helper()
	nm := &netmap.NetworkMap{
		SelfNode: (&tailcfg.Node{Name: "me.tail-ab.ts.net."}).View(),
		DNS: tailcfg.DNSConfig{Routes: map[string][]*dnstype.Resolver{
			"corp.example.com.":    {{Addr: "10.0.0.53"}},
			"Lab.Example.Org":      nil, // empty resolvers: still handled by the node
			"tail-ab.ts.net.":      nil, // MagicDNS suffix, learned elsewhere
			"ts.net":               nil, // parent of it would swallow other tailnets
			"0.10.in-addr.arpa.":   {{Addr: "10.0.0.53"}},
			"corp.example.com":     {{Addr: "10.0.0.54"}}, // duplicate after normalising
			"":                     nil,
			"100.100.in-addr.arpa": nil,
			// Control-supplied keys are written into the PAC's JavaScript.
			`x"); alert(1); ("`: nil,
			"a..b.example":      nil,
			"sp ace.example":    nil,
		}},
		Peers: []tailcfg.NodeView{
			(&tailcfg.Node{ID: 1, PrimaryRoutes: []netip.Prefix{
				netip.MustParsePrefix("10.1.0.0/16"),
				netip.MustParsePrefix("0.0.0.0/0"),
				netip.MustParsePrefix("::/0"),
			}}).View(),
			(&tailcfg.Node{ID: 2, PrimaryRoutes: []netip.Prefix{
				netip.MustParsePrefix("192.168.7.9/24"), // unmasked
				netip.MustParsePrefix("10.1.0.0/16"),
				netip.MustParsePrefix("fd7a:1::/48"),
			}}).View(),
			(&tailcfg.Node{ID: 3}).View(),
		},
	}
	// The daemon receives the netmap as JSON over the IPN bus; make sure the
	// views survive that trip.
	b, err := json.Marshal(nm)
	if err != nil {
		t.Fatal(err)
	}
	var out netmap.NetworkMap
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	return &out
}

func TestLearnFromNetmap(t *testing.T) {
	nm := testNetmap(t)
	allDomains := []string{".corp.example.com", ".lab.example.org"}
	allRoutes := []netip.Prefix{
		netip.MustParsePrefix("10.1.0.0/16"),
		netip.MustParsePrefix("192.168.7.0/24"),
		netip.MustParsePrefix("fd7a:1::/48"),
	}
	for _, tc := range []struct {
		name                    string
		nm                      *netmap.NetworkMap
		acceptDNS, acceptRoutes bool
		domains                 []string
		routes                  []netip.Prefix
	}{
		{name: "both", nm: nm, acceptDNS: true, acceptRoutes: true, domains: allDomains, routes: allRoutes},
		{name: "dns only", nm: nm, acceptDNS: true, domains: allDomains},
		{name: "routes only", nm: nm, acceptRoutes: true, routes: allRoutes},
		{name: "neither", nm: nm},
		{name: "no netmap", acceptDNS: true, acceptRoutes: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d, r := learnFromNetmap(tc.nm, tc.acceptDNS, tc.acceptRoutes)
			if !slices.Equal(d, tc.domains) {
				t.Errorf("domains = %v, want %v", d, tc.domains)
			}
			if !slices.Equal(r, tc.routes) {
				t.Errorf("routes = %v, want %v", r, tc.routes)
			}
		})
	}
}

func TestSetLearnedConflicts(t *testing.T) {
	c := cfg(t) // work: work.ts.net + 100.64.0.0/16; corp: .eng.work.ts.net; home: home.ts.net
	pfx := netip.MustParsePrefix

	if got := c.setLearned("home", []string{".corp.example.com"}, []netip.Prefix{pfx("10.1.0.0/16")}); len(got) != 0 {
		t.Fatalf("first claimant got conflicts %v", got)
	}
	got := c.setLearned("corp",
		[]string{".corp.example.com", ".home.ts.net", ".eng.work.ts.net", ".only-corp.example"},
		[]netip.Prefix{pfx("10.1.0.0/16"), pfx("100.64.0.0/16"), pfx("10.1.2.0/24")})
	want := []string{
		"corp.example.com (home)", // learned by another node first
		"home.ts.net (home)",      // another profile's configured suffix
		"10.1.0.0/16 (home)",
		"100.64.0.0/16 (work)", // another profile's ip_routes
	}
	if !slices.Equal(got, want) {
		t.Errorf("conflicts = %v, want %v", got, want)
	}
	d, r := c.LearnedOf("corp")
	if !slices.Equal(d, []string{"only-corp.example"}) || !slices.Equal(r, []string{"10.1.2.0/24"}) {
		t.Errorf("corp learned %v %v", d, r)
	}

	// A tailnet cannot take a name or a range nested in another profile's
	// configured claim, which longest match would otherwise hand it.
	got = c.setLearned("corp",
		[]string{".db.home.ts.net", ".only-corp.example"},
		[]netip.Prefix{pfx("100.64.3.0/24"), pfx("10.1.2.0/24")})
	want = []string{"db.home.ts.net (home)", "100.64.3.0/24 (work)"}
	if !slices.Equal(got, want) {
		t.Errorf("nested conflicts = %v, want %v", got, want)
	}
	if m, err := c.Route("x.db.home.ts.net"); err != nil || m.Profile.Name != "home" {
		t.Errorf("nested name routed to %v (%v), want home", m, err)
	}

	// Learning replaces; once home lets go, corp can take the domain.
	c.setLearned("home", nil, nil)
	if got := c.setLearned("corp", []string{".corp.example.com"}, nil); len(got) != 0 {
		t.Errorf("conflicts after release = %v", got)
	}
	if d, r := c.LearnedOf("corp"); !slices.Equal(d, []string{"corp.example.com"}) || r != nil {
		t.Errorf("corp learned %v %v", d, r)
	}
	if got := c.setLearned("gone", []string{".x.example"}, nil); got != nil {
		t.Errorf("unknown profile = %v", got)
	}
}

func TestRouteLearned(t *testing.T) {
	c := cfg(t)
	pfx := netip.MustParsePrefix
	c.setLearned("home", []string{".example.com"}, []netip.Prefix{pfx("10.0.0.0/8"), pfx("fd7a:1::/48")})
	c.setLearned("corp", []string{".corp.example.com"}, []netip.Prefix{pfx("10.1.0.0/16")})
	for _, tc := range []struct{ host, want, reason string }{
		{"wiki.example.com", "home", "split_dns .example.com"},
		{"example.com", "home", "split_dns .example.com"},
		{"git.corp.example.com", "corp", "split_dns .corp.example.com"}, // longest wins across profiles
		{"10.9.9.9", "home", "subnet_route 10.0.0.0/8"},
		{"10.1.2.3", "corp", "subnet_route 10.1.0.0/16"}, // most specific prefix wins
		{"[fd7a:1::5]:443", "home", "subnet_route fd7a:1::/48"},
		{"100.64.1.5", "work", "ip_route 100.64.0.0/16"},
		{"box.work.ts.net", "work", "suffix .work.ts.net"},
	} {
		m, err := c.Route(tc.host)
		if err != nil {
			t.Errorf("%s: %v", tc.host, err)
			continue
		}
		if m.Profile.Name != tc.want || m.Reason != tc.reason {
			t.Errorf("%s: got %s (%s), want %s (%s)", tc.host, m.Profile.Name, m.Reason, tc.want, tc.reason)
		}
	}
	c.setLearned("home", nil, nil)
	if m, err := c.Route("wiki.example.com"); err == nil {
		t.Errorf("forgotten domain still routes to %s", m.Profile.Name)
	}
}

func TestIsSplitDNSName(t *testing.T) {
	c := cfg(t)
	c.setLearned("corp", []string{".corp.example.com"}, nil)
	for _, tc := range []struct {
		profile, host string
		want          bool
	}{
		{"corp", "git.corp.example.com", true},
		{"corp", "corp.example.com", true},
		{"corp", "xcorp.example.com", false},
		{"corp", "db.eng.work.ts.net", false}, // configured suffix: MagicDNS, not split DNS
		{"home", "git.corp.example.com", false},
		{"gone", "git.corp.example.com", false},
	} {
		if got := c.isSplitDNSName(tc.profile, tc.host); got != tc.want {
			t.Errorf("isSplitDNSName(%s, %s) = %v, want %v", tc.profile, tc.host, got, tc.want)
		}
	}
}
