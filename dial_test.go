package main

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/NorthIsUp/tsmux/internal/tsmux"
)

// With the app running, its extension owns the nodes and their state, and this
// process can't create either: the connection goes through the app's proxy.
func TestWithDialUsesAppProxy(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	targets := make(chan string, 1)
	go tsmux.ServeSOCKS5(ln, func(_ context.Context, _, hostport string) (net.Conn, error) {
		targets <- hostport
		a, b := net.Pipe()
		go io.Copy(b, b)
		return a, nil
	}, nil)

	app := tsmux.Default()
	app.Paths.StateDir = "/dev/null/extension-state"
	app.Router.SOCKS5Proxy = ln.Addr().String()
	app.Profiles["work"] = &tsmux.Profile{DisplayName: "Work"}
	if err := app.Normalize(); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app.LocalHandler(nil, "secret"))
	defer srv.Close()
	endpoint, _ := json.Marshal(tsmux.AppEndpoint{URL: srv.URL, Token: "secret"})
	p := tsmux.AppEndpointPaths()[0]
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, endpoint, 0o600); err != nil {
		t.Fatal(err)
	}

	err = withDial(context.Background(), "", func(ctx context.Context, dial tsmux.DialFunc) error {
		c, err := dial(ctx, "tcp", "db.example:5432")
		if err != nil {
			return err
		}
		defer c.Close()
		if _, err := c.Write([]byte("x")); err != nil {
			return err
		}
		_, err = io.ReadFull(c, make([]byte, 1))
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := <-targets; got != "db.example:5432" {
		t.Errorf("dialed %q, want the name unresolved", got)
	}
}
