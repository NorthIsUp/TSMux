package tsmux

import (
	"fmt"
	"testing"
)

func cfg(t *testing.T) *Config {
	t.Helper()
	c := Default()
	c.Profiles = map[string]*Profile{
		"work": {Suffixes: []string{"work.ts.net"}, MatchRoot: true, IPRoutes: []string{"100.64.0.0/16"}},
		"corp": {Suffixes: []string{".eng.work.ts.net"}},
		"home": {Suffixes: []string{"home.ts.net"}},
	}
	if err := c.Normalize(); err != nil {
		t.Fatal(err)
	}
	return c
}

func TestRoute(t *testing.T) {
	c := cfg(t)
	for _, tc := range []struct{ host, want string }{
		{"box.work.ts.net", "work"},
		{"work.ts.net", "work"},      // bare apex of a claimed suffix
		{"BOX.Work.TS.Net.", "work"}, // case + trailing dot
		{"box.work.ts.net:8080", "work"},
		{"db.eng.work.ts.net", "corp"}, // longest suffix wins over "work"
		{"nas.home.ts.net", "home"},
		{"laptop", "work"},     // single match_root profile
		{"100.64.1.5", "work"}, // ip_route
	} {
		m, err := c.Route(tc.host)
		if err != nil {
			t.Fatalf("%s: %v", tc.host, err)
		}
		if m.Profile.Name != tc.want {
			t.Errorf("%s: got %s (%s), want %s", tc.host, m.Profile.Name, m.Reason, tc.want)
		}
	}
}

func TestRouteRejects(t *testing.T) {
	c := cfg(t)
	for _, host := range []string{"example.com", "1.1.1.1", ""} {
		if m, err := c.Route(host); err == nil {
			t.Errorf("%s: expected refusal, got %s", host, m.Profile.Name)
		}
	}
}

func TestRouteAmbiguousBareName(t *testing.T) {
	c := cfg(t)
	c.Profiles["home"].MatchRoot = true
	if err := c.Normalize(); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Route("laptop"); err == nil {
		t.Fatal("expected ambiguity error when two profiles claim bare names")
	}
}

func TestStablePorts(t *testing.T) {
	c := cfg(t)
	// corp, home, work sorted -> 43110/43112/43114
	if got := c.Profiles["corp"].HTTPPort; got != 43110 {
		t.Errorf("corp http port = %d, want 43110", got)
	}
	if got := c.Profiles["work"].HTTPPort; got != 43114 {
		t.Errorf("work http port = %d, want 43114", got)
	}
	if got := c.Profiles["work"].SOCKSPort; got != 43115 {
		t.Errorf("work socks port = %d, want 43115", got)
	}
}

// D4: Route ranges over Suffixes while the watch goroutine appends to them.
func TestRouteConcurrentSuffixLearn(t *testing.T) {
	c := cfg(t)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := range 200 {
			c.addSuffix("home", fmt.Sprintf(".learned%d.ts.net", i))
		}
	}()
	for range 200 {
		if _, err := c.Route("box.work.ts.net"); err != nil {
			t.Fatal(err)
		}
	}
	<-done
}

func TestRouteExitNodeFallback(t *testing.T) {
	for _, tc := range []struct {
		name      string
		exit      ExitRoute
		host      string
		want      string // "" means refused
		wantMatch string
	}{
		{"public name, no exit node", ExitRoute{}, "example.com", "", ""},
		{"public ip, no exit node", ExitRoute{}, "1.1.1.1", "", ""},
		{"public name via exit", ExitRoute{Profile: "home"}, "example.com", "home", "fallback to home exit node"},
		{"public ip via exit", ExitRoute{Profile: "home"}, "1.1.1.1:443", "home", "ip literal to home exit node"},
		{"claimed suffix beats exit", ExitRoute{Profile: "home"}, "box.work.ts.net", "work", "suffix .work.ts.net"},
		{"ip_route beats exit", ExitRoute{Profile: "home"}, "100.64.1.5", "work", "ip_route 100.64.0.0/16"},
		{"exit profile gone", ExitRoute{Profile: "gone"}, "example.com", "", ""},
		{"loopback stays off the exit node", ExitRoute{Profile: "home"}, "127.0.0.1:8080", "", ""},
		{"ipv6 loopback stays off the exit node", ExitRoute{Profile: "home"}, "[::1]:3000", "", ""},
		{"localhost stays off the exit node", ExitRoute{Profile: "home"}, "localhost:3000", "work", "match_root"},
		{"localhost.local stays off the exit node", ExitRoute{Profile: "home"}, "localhost.local", "", ""},
		{"mdns stays off the exit node", ExitRoute{Profile: "home"}, "printer.local", "", ""},
		{"unclaimed tailscale ip stays off", ExitRoute{Profile: "home"}, "100.100.1.1", "", ""},
		{"mapped v4 stays off", ExitRoute{Profile: "home"}, "::ffff:127.0.0.1", "", ""},
		{"lan via exit", ExitRoute{Profile: "home"}, "192.168.1.1", "home", "ip literal to home exit node"},
		{"lan kept off with allow LAN", ExitRoute{Profile: "home", AllowLAN: true}, "192.168.1.1", "", ""},
		{"public v6 via exit", ExitRoute{Profile: "home"}, "[2606:4700::1111]:443", "home", "ip literal to home exit node"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := cfg(t)
			c.SetExitRoute(tc.exit)
			m, err := c.Route(tc.host)
			if tc.want == "" {
				if err == nil {
					t.Fatalf("expected refusal, got %s (%s)", m.Profile.Name, m.Reason)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if m.Profile.Name != tc.want || m.Reason != tc.wantMatch {
				t.Errorf("got %s (%s), want %s (%s)", m.Profile.Name, m.Reason, tc.want, tc.wantMatch)
			}
		})
	}
}
