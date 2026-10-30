package tsmux

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"tailscale.com/client/local"
)

// The bridge must swap whatever Authorization the CLI sent (the Tailscale
// app's own token, when it is installed) for ours, and scope the path to the
// profile.
func TestTailscaleSocket(t *testing.T) {
	var gotPath, gotAuth string
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotAuth = r.URL.RequestURI(), r.Header.Get(tokenHeader)
		io.WriteString(w, "ok")
	}))
	defer api.Close()
	cfg := Default()
	cfg.Router.PACListen = strings.TrimPrefix(api.URL, "http://")
	cfg.apiToken = testToken

	sock, stop, err := cfg.TailscaleSocket("work")
	if err != nil {
		t.Fatal(err)
	}
	c := &http.Client{Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", sock)
	}}}
	req, _ := http.NewRequest(http.MethodGet, "http://local-tailscaled.sock/localapi/v0/status?peers=false", nil)
	req.SetBasicAuth("", "tailscale-app-token")
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if gotPath != "/tailscale/work/localapi/v0/status?peers=false" {
		t.Errorf("path = %q", gotPath)
	}
	if gotAuth != "Bearer "+testToken {
		t.Errorf("authorization = %q, want the tsmux token only", gotAuth)
	}
	stop()
	if _, err := net.Dial("unix", sock); err == nil {
		t.Error("socket still answers after stop")
	}
}

// Without the token the proxy is closed, and paths outside the LocalAPI or for
// unknown profiles go nowhere.
func TestLocalAPIProxyGuards(t *testing.T) {
	cfg := tempConfig(t, twoProfiles)
	h := cfg.LocalHandler(NewManager(cfg, false), testToken)

	r := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:43180/tailscale/work/localapi/v0/status", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("no token: %d, want 401", w.Code)
	}
	for _, p := range []string{"/tailscale/work/debug", "/tailscale/nope/localapi/v0/status"} {
		if w := get(t, h, p); w.Code != http.StatusNotFound {
			t.Errorf("%s: %d, want 404", p, w.Code)
		}
	}
}

// `tailscale nc` dials through the LocalAPI's ts-dial upgrade, which must
// survive both proxy hops and the LocalAPI's lowercase-only Connection check.
func TestTailscaleSocketDialUpgrade(t *testing.T) {
	localAPI := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.Header.Get("Connection"), "upgrade") || r.Header.Get("Upgrade") != "ts-dial" {
			http.Error(w, "bad ts-dial upgrade", http.StatusBadRequest)
			return
		}
		w.Header().Set("Upgrade", "ts-dial")
		w.Header().Set("Connection", "upgrade")
		w.WriteHeader(http.StatusSwitchingProtocols)
		conn, brw, _ := w.(http.Hijacker).Hijack()
		defer conn.Close()
		brw.Flush()
		io.Copy(conn, brw)
	}))
	defer localAPI.Close()
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		localAPIReverseProxy("localapi/v0/dial", func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "tcp", localAPI.Listener.Addr().String())
		}).ServeHTTP(w, r)
	}))
	defer api.Close()
	cfg := Default()
	cfg.Router.PACListen = strings.TrimPrefix(api.URL, "http://")
	cfg.apiToken = testToken
	sock, stop, err := cfg.TailscaleSocket("work")
	if err != nil {
		t.Fatal(err)
	}
	defer stop()

	conn, err := (&local.Client{Socket: sock, UseSocketOnly: true}).UserDial(context.Background(), "tcp", "peer", 443)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	io.WriteString(conn, "ping")
	buf := make([]byte, 4)
	if _, err := io.ReadFull(conn, buf); err != nil || string(buf) != "ping" {
		t.Fatalf("echo = %q, %v", buf, err)
	}
}
