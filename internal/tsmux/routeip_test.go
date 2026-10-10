package tsmux

import (
	"encoding/json"
	"net/netip"
	"strings"
	"testing"

	"tailscale.com/tailcfg"
	"tailscale.com/types/netmap"
)

var romm = RoutedIP{Name: "svc:romm", IPs: []string{"100.90.45.67", "fd7a:115c:a1e0::4501:2d43"}}

func TestRoutedIPRoutes(t *testing.T) {
	c := tempConfig(t, twoProfiles)
	if _, err := c.Route("100.90.45.67"); err == nil {
		t.Fatal("routed before it was turned on")
	}
	if err := c.SetRoutedIP("personal", romm, true); err != nil {
		t.Fatal(err)
	}
	for _, host := range []string{"100.90.45.67", "[fd7a:115c:a1e0::4501:2d43]:443"} {
		m, err := c.Route(host)
		if err != nil || m.Profile.Name != "personal" || !strings.HasPrefix(m.Reason, "routed_ip ") {
			t.Errorf("%s: %+v %v", host, m, err)
		}
	}
	if pac := c.PAC(); !strings.Contains(pac, `if (tsmuxIsIP && isInNet(host, "100.90.45.67", "255.255.255.255")) return "PROXY 127.0.0.1:`) {
		t.Errorf("PAC has no guarded rule for the routed IP:\n%s", pac)
	}
	// A peer can come back with the same name; its entry is replaced, not doubled.
	if err := c.SetRoutedIP("personal", romm, true); err != nil {
		t.Fatal(err)
	}
	if got := c.RoutedIPsOf("personal"); len(got) != 1 {
		t.Errorf("entries = %+v", got)
	}
	if err := c.SetRoutedIP("personal", romm, false); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Route("100.90.45.67"); err == nil {
		t.Error("still routed after turning it off")
	}
}

func TestRoutedIPCollision(t *testing.T) {
	c := tempConfig(t, `version: 1
profiles:
  work:
    ip_routes: ["100.100.0.0/16"]
  personal: {}
`)
	if err := c.SetRoutedIP("personal", romm, true); err != nil {
		t.Fatal(err)
	}
	err := c.SetRoutedIP("work", romm, true)
	if err == nil || !strings.Contains(err.Error(), "personal") || !strings.Contains(err.Error(), "work") {
		t.Errorf("collision with another routed IP: %v", err)
	}
	inRoute := RoutedIP{Name: "nas", IPs: []string{"100.100.1.2"}}
	if err := c.SetRoutedIP("personal", inRoute, true); err == nil || !strings.Contains(err.Error(), "work") {
		t.Errorf("collision with ip_routes: %v", err)
	}
	if routed, by := c.routeState("work", romm.IPs); routed || by != "personal" {
		t.Errorf("routeState = %v, %q", routed, by)
	}
	if err := c.SetRoutedIP("personal", RoutedIP{Name: "x", IPs: []string{"nope"}}, true); err == nil {
		t.Error("accepted a bad address")
	}
}

func TestRoutedIPPersists(t *testing.T) {
	c := tempConfig(t, twoProfiles)
	m := NewManager(c, false)
	if err := m.persistRoutedIP("work", romm, true); err != nil {
		t.Fatal(err)
	}
	disk, err := Load(c.Path())
	if err != nil {
		t.Fatal(err)
	}
	if got, err := disk.Route("100.90.45.67"); err != nil || got.Profile.Name != "work" {
		t.Errorf("reloaded: %+v %v", got, err)
	}
	if err := m.persistRoutedIP("work", romm, false); err != nil {
		t.Fatal(err)
	}
	disk, _ = Load(c.Path())
	if got := disk.RoutedIPsOf("work"); len(got) != 0 {
		t.Errorf("after off: %+v", got)
	}
}

func TestRouteTarget(t *testing.T) {
	st := Status{
		Profile: "home",
		Devices: []Device{
			{Name: "nas.tail.ts.net", Hostname: "NAS", IPs: []string{"100.64.0.2"}},
			{Name: "nas-2.tail.ts.net", Hostname: "nas", IPs: []string{"100.64.0.3"}},
			{Name: "pi.tail.ts.net", Hostname: "raspberrypi", IPs: []string{"100.64.0.4"}},
		},
		Services: []Service{{Name: "svc:romm", DNSName: "romm.tail.ts.net", IPs: romm.IPs}},
	}
	gone := []RoutedIP{{Name: "old.tail.ts.net", IPs: []string{"100.64.0.9"}}}
	for _, tc := range []struct{ target, want, err string }{
		{target: "romm", want: "svc:romm"},
		{target: "svc:romm", want: "svc:romm"},
		{target: "romm.tail.ts.net.", want: "svc:romm"},
		{target: "100.90.45.67", want: "svc:romm"},
		{target: "pi", want: "pi.tail.ts.net"},
		{target: "raspberrypi", want: "pi.tail.ts.net"},
		{target: "nas-2", want: "nas-2.tail.ts.net"},
		{target: "nas", err: "ambiguous"},
		{target: "100.64.0.9", want: "old.tail.ts.net"},
		{target: "ghost", err: "no device or service"},
	} {
		r, err := routeTarget(st, gone, tc.target)
		switch {
		case tc.err != "" && (err == nil || !strings.Contains(err.Error(), tc.err)):
			t.Errorf("%s: err = %v, want %q", tc.target, err, tc.err)
		case tc.err == "" && (err != nil || r.Name != tc.want):
			t.Errorf("%s: got %+v %v, want %s", tc.target, r, err, tc.want)
		}
	}
}

func TestServicesFromNetmap(t *testing.T) {
	raw, _ := json.Marshal(tailcfg.ServiceDetails{Name: "svc:romm", Addrs: []netip.Addr{netip.MustParseAddr("100.90.45.67")}})
	nm := &netmap.NetworkMap{SelfNode: (&tailcfg.Node{
		Name:   "me.tail-ab.ts.net.",
		CapMap: tailcfg.NodeCapMap{"services/opaque-1": {tailcfg.RawMessage(raw)}},
	}).View()}
	got := servicesFromNetmap(nm)
	if len(got) != 1 || got[0].Name != "svc:romm" || got[0].DNSName != "romm.tail-ab.ts.net" ||
		len(got[0].IPs) != 1 || got[0].IPs[0] != "100.90.45.67" {
		t.Errorf("services = %+v", got)
	}
}
