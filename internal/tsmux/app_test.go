package tsmux

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/net/dns/dnsmessage"
	"tailscale.com/client/tailscale/apitype"
)

func writeEndpoint(t *testing.T, ep AppEndpoint) {
	t.Helper()
	p := AppEndpointPaths()[0]
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(ep)
	if err := os.WriteFile(p, b, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestLoadFromApp(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if _, err := LoadFromApp(); err == nil {
		t.Fatal("LoadFromApp with no endpoint file: want an error")
	}

	app := Default()
	app.Profiles["work"] = &Profile{DisplayName: "Work"}
	if err := app.Normalize(); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.LocalHandler(nil, "secret"))
	defer srv.Close()

	writeEndpoint(t, AppEndpoint{URL: srv.URL, Token: "wrong"})
	if _, err := LoadFromApp(); err == nil {
		t.Fatal("LoadFromApp with a wrong token: want an error")
	}

	writeEndpoint(t, AppEndpoint{URL: srv.URL, Token: "secret"})
	got, err := LoadFromApp()
	if err != nil {
		t.Fatal(err)
	}
	if !got.FromApp() || got.Profiles["work"] == nil || got.Profiles["work"].HTTPPort != app.Profiles["work"].HTTPPort {
		t.Fatalf("got %+v, want the app's work profile on its ports", got.Profiles["work"])
	}
	if err := got.Save(filepath.Join(home, "config.yaml")); !errors.Is(err, ErrAppOwnsConfig) {
		t.Fatalf("Save of the app's config = %v, want ErrAppOwnsConfig", err)
	}
}

func TestEditInApp(t *testing.T) {
	var got ProfileEdit
	var path string
	mux := http.NewServeMux()
	mux.Handle("/profiles/", TokenGuarded("secret", func(w http.ResponseWriter, r *http.Request) {
		path = r.URL.Path
		b, _ := io.ReadAll(r.Body)
		json.Unmarshal(b, &got)
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "warning": "control unreachable"})
	}))
	srv := httptest.NewServer(mux)
	defer srv.Close()

	c := Default()
	c.Router.PACListen = srv.Listener.Addr().String()
	c.apiToken = "secret"
	warning, err := c.EditInApp("/profiles/rename", ProfileEdit{Name: "a", NewName: "b"})
	if err != nil {
		t.Fatal(err)
	}
	if path != "/profiles/rename" || got.Name != "a" || got.NewName != "b" || warning != "control unreachable" {
		t.Fatalf("path %q, body %+v, warning %q", path, got, warning)
	}

	c.apiToken = "wrong"
	if _, err := c.EditInApp("/profiles/remove", ProfileEdit{Name: "a"}); err == nil {
		t.Fatal("EditInApp with a wrong token: want an error")
	}
}

// AppDial goes through the router's proxy, or a pinned tailnet's own.
func TestAppDial(t *testing.T) {
	serve := func(name string, seen chan<- string) *net.TCPAddr {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { ln.Close() })
		go ServeSOCKS5(ln, func(_ context.Context, _, hostport string) (net.Conn, error) {
			seen <- name + " " + hostport
			a, b := net.Pipe()
			go io.Copy(b, b)
			return a, nil
		}, nil)
		return ln.Addr().(*net.TCPAddr)
	}
	seen := make(chan string, 1)
	c := Default()
	c.Router.SOCKS5Proxy = serve("router", seen).String()
	c.Profiles["work"] = &Profile{SOCKSPort: serve("work", seen).Port}

	for _, tt := range []struct{ profile, want string }{
		{"", "router db.example:5432"},
		{"work", "work db.example:5432"},
	} {
		dial, err := c.AppDial(tt.profile)
		if err != nil {
			t.Fatalf("AppDial(%q): %v", tt.profile, err)
		}
		conn, err := dial(context.Background(), "tcp", "db.example:5432")
		if err != nil {
			t.Fatalf("dial through %q: %v", tt.profile, err)
		}
		conn.Close()
		if got := <-seen; got != tt.want {
			t.Errorf("AppDial(%q) reached %q, want %q", tt.profile, got, tt.want)
		}
	}
	if _, err := c.AppDial("nope"); err == nil {
		t.Error("AppDial of an unknown profile: want an error")
	}
}

// AppResolve asks the tailnet's resolver in the app, with the app's token.
func TestAppResolve(t *testing.T) {
	mux := http.NewServeMux()
	mux.Handle("/tailscale/work/localapi/v0/dns-query", requireToken("secret", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		msg := dnsmessage.Message{Header: dnsmessage.Header{Response: true}}
		if r.URL.Query().Get("type") == "A" && r.URL.Query().Get("name") == "db.corp.example" {
			msg.Answers = []dnsmessage.Resource{{
				Header: dnsmessage.ResourceHeader{
					Name: dnsmessage.MustNewName("db.corp.example."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET,
				},
				Body: &dnsmessage.AResource{A: [4]byte{10, 0, 15, 7}},
			}}
		}
		b, err := msg.Pack()
		if err != nil {
			t.Error(err)
		}
		writeJSON(w, http.StatusOK, apitype.DNSQueryResponse{Bytes: b})
	})))
	srv := httptest.NewServer(mux)
	defer srv.Close()

	c := Default()
	c.Router.PACListen = srv.Listener.Addr().String()
	c.apiToken = "secret"
	ips, err := c.AppResolve(context.Background(), "work", "db.corp.example")
	if err != nil {
		t.Fatal(err)
	}
	if len(ips) != 1 || ips[0].String() != "10.0.15.7" {
		t.Errorf("AppResolve = %v, want 10.0.15.7", ips)
	}
	if _, err := c.AppResolve(context.Background(), "work", "missing.corp.example"); err == nil {
		t.Error("AppResolve with no answer: want an error")
	}
}
