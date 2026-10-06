package main

import (
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Ports below the ephemeral range (49152+ on macOS, 32768+ on Linux): one the
// kernel hands out for :0 can be taken again as the source port of any
// outgoing connection, tsnet's included, between this check and the daemon
// binding it.
func testConfig(t *testing.T) string {
	t.Helper()
	var held []net.Listener
	defer func() {
		for _, ln := range held {
			ln.Close()
		}
	}()
	bind := func(port int) bool {
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			return false
		}
		held = append(held, ln)
		return true
	}
	// Five ports in a row: the router's three, then the one profile's pair.
	for range 200 {
		base := 20000 + rand.IntN(12000)
		ok := true
		for i := range 5 {
			if !bind(base + i) {
				ok = false
				break
			}
		}
		if !ok {
			continue
		}
		return fmt.Sprintf(`version: 1
router:
  http_proxy: 127.0.0.1:%d
  socks5_proxy: 127.0.0.1:%d
  pac_listen: 127.0.0.1:%d
  profile_http_proxy_base: %d
  profile_socks5_proxy_base: %d
  profile_hostname_base: tsmux
profiles: {}
`, base, base+1, base+2, base+3, base+4)
	}
	t.Fatal("no five free ports in a row below the ephemeral range")
	return ""
}

func mustCall(t *testing.T, method, path string, body any) response {
	t.Helper()
	b, _ := json.Marshal(body)
	raw, _ := json.Marshal(request{Method: method, Path: path, Body: string(b)})
	return call(raw)
}

func TestCallLifecycle(t *testing.T) {
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "config.yaml"), []byte(testConfig(t)), 0o600); err != nil {
		t.Fatal(err)
	}
	if r := mustCall(t, "GET", "/status", nil); r.Code != 503 {
		t.Fatalf("before start: %+v", r)
	}
	if err := start(d); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { mu.Lock(); down(); mu.Unlock() })

	if r := mustCall(t, "GET", "/status", nil); r.Code != 200 || strings.TrimSpace(r.Body) != "[]" {
		t.Fatalf("empty status: %+v", r)
	}

	// A dead control URL keeps the node off the network.
	add := profileRequest{Name: "work", DisplayName: "Work", ControlURL: "http://127.0.0.1:1"}
	if r := mustCall(t, "POST", "/profiles/add", add); r.Code != 200 {
		t.Fatalf("add: %+v", r)
	}
	if r := mustCall(t, "POST", "/profiles/add", add); r.Code != 400 {
		t.Fatalf("duplicate add should fail: %+v", r)
	}
	r := mustCall(t, "GET", "/status", nil)
	var st []struct{ Profile string }
	if err := json.Unmarshal([]byte(r.Body), &st); err != nil || len(st) != 1 || st[0].Profile != "work" {
		t.Fatalf("status after add: %+v %v", r, err)
	}
	if _, err := os.Stat(filepath.Join(d, "state", "profiles", "work")); err != nil {
		t.Fatalf("state dir should live in the container: %v", err)
	}

	ren := profileRequest{Name: "work", NewName: "acme", DisplayName: "Acme"}
	if r := mustCall(t, "POST", "/profiles/rename", ren); r.Code != 200 {
		t.Fatalf("rename: %+v", r)
	}
	r = mustCall(t, "GET", "/status", nil)
	var renamed []struct {
		Profile     string
		DisplayName string `json:"display_name"`
	}
	if err := json.Unmarshal([]byte(r.Body), &renamed); err != nil || len(renamed) != 1 ||
		renamed[0].Profile != "acme" || renamed[0].DisplayName != "Acme" {
		t.Fatalf("status after rename: %+v %v", r, err)
	}
	if _, err := os.Stat(filepath.Join(d, "state", "profiles", "acme")); err != nil {
		t.Fatalf("rename should move the state dir: %v", err)
	}

	if r := mustCall(t, "POST", "/profiles/remove", profileRequest{Name: "acme"}); r.Code != 200 {
		t.Fatalf("remove: %+v", r)
	}
	if _, err := os.Stat(filepath.Join(d, "state", "profiles", "acme")); !os.IsNotExist(err) {
		t.Fatalf("remove should purge credentials: %v", err)
	}
	if r := mustCall(t, "GET", "/proxy.pac", nil); r.Code != 200 || !strings.Contains(r.Body, "FindProxyForURL") {
		t.Fatalf("pac: %+v", r)
	}
}
