package tsmux

import (
	"testing"

	"tailscale.com/ipn"
)

func TestEffectiveExit(t *testing.T) {
	for _, tc := range []struct {
		name    string
		prefs   ipn.Prefs
		wantID  string
		wantLAN bool
	}{
		{"none", ipn.Prefs{WantRunning: true}, "", false},
		{"selected", ipn.Prefs{WantRunning: true, ExitNodeID: "n1"}, "n1", false},
		{"selected with LAN", ipn.Prefs{WantRunning: true, ExitNodeID: "n1", ExitNodeAllowLANAccess: true}, "n1", true},
		{"disconnected", ipn.Prefs{ExitNodeID: "n1", ExitNodeAllowLANAccess: true}, "", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			id, lan := effectiveExit(&tc.prefs)
			if id != tc.wantID || lan != tc.wantLAN {
				t.Errorf("got (%q, %v), want (%q, %v)", id, lan, tc.wantID, tc.wantLAN)
			}
		})
	}
}

// Several tailnets can each have an exit node picked; only one can carry
// public traffic, and which one must not depend on map order.
func TestRefreshExitPicksFirstInConfigOrder(t *testing.T) {
	c := cfg(t) // corp, home, work
	m := NewManager(c, false)
	for _, p := range c.Ordered() {
		m.nodes[p.Name] = &Node{Profile: p}
	}
	steps := []struct {
		name string
		set  map[string]string
		lan  bool
		want ExitRoute
	}{
		{"nobody", nil, false, ExitRoute{}},
		{"work only", map[string]string{"work": "w1"}, true, ExitRoute{Profile: "work", AllowLAN: true}},
		{"home and work", map[string]string{"home": "h1", "work": "w1"}, false, ExitRoute{Profile: "home"}},
		{"home cleared", map[string]string{"home": "", "work": "w1"}, false, ExitRoute{Profile: "work"}},
		{"all cleared", map[string]string{"work": ""}, false, ExitRoute{}},
	}
	for _, s := range steps {
		for name, id := range s.set {
			m.nodes[name].setExit(id, s.lan)
		}
		for range 20 {
			m.refreshExit()
			if got := c.ExitRoute(); got != s.want {
				t.Fatalf("%s: got %+v, want %+v", s.name, got, s.want)
			}
		}
	}
}

func TestExitCarriesName(t *testing.T) {
	for _, tc := range []struct {
		host     string
		allowLAN bool
		want     bool
	}{
		{"example.com", false, true},
		{"example.com", true, true},
		{"localhost", false, false},
		{"printer.local", false, false},
		{"nas", false, true},
		{"nas", true, false},
	} {
		if got := exitCarriesName(tc.host, tc.allowLAN); got != tc.want {
			t.Errorf("exitCarriesName(%q, %v) = %v, want %v", tc.host, tc.allowLAN, got, tc.want)
		}
	}
}
