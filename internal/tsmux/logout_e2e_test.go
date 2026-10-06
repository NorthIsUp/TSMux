package tsmux

import (
	"context"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"tailscale.com/net/netns"
	"tailscale.com/tsnet"
	"tailscale.com/tstest/integration"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/logger"
)

// signedInDir signs a node in against a local test control server, stops it,
// and returns its state dir: the state a stopped daemon leaves behind.
func signedInDir(t *testing.T) (dir string, control *testcontrol.Server) {
	t.Helper()
	netns.SetEnabled(false)
	t.Cleanup(func() { netns.SetEnabled(true) })
	control = &testcontrol.Server{DERPMap: integration.RunDERPAndSTUN(t, logger.Discard, "127.0.0.1")}
	control.HTTPTestServer = httptest.NewUnstartedServer(control)
	control.HTTPTestServer.Start()
	t.Cleanup(control.HTTPTestServer.Close)

	dir = filepath.Join(t.TempDir(), "work")
	quiet := func(string, ...any) {}
	srv := &tsnet.Server{Dir: dir, Hostname: "work", ControlURL: control.HTTPTestServer.URL, Logf: quiet, UserLogf: quiet}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := srv.Up(ctx); err != nil {
		t.Fatalf("Up: %v", err)
	}
	if err := srv.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if !HasCredentials(dir) {
		t.Fatal("signed-in node left no tailscaled.state")
	}
	return dir, control
}

func TestLogoutStoppedAgainstControl(t *testing.T) {
	if testing.Short() {
		t.Skip("starts a control server and a tsnet node")
	}
	dir, control := signedInDir(t)
	p := &Profile{Hostname: "work", ControlURL: control.HTTPTestServer.URL}

	warning, err := PurgeState(context.Background(), dir, func(ctx context.Context) error {
		return LogoutStopped(ctx, p, dir)
	})
	// Logout is a no-op without a node key, so this alone could pass vacuously;
	// the unreachable case failing on the same setup shows the key is there.
	if err != nil || warning != "" {
		t.Fatalf("PurgeState = (%q, %v), want a clean logout", warning, err)
	}
}

// An unreachable control server must cost the logout timeout, not hang the
// removal, and must surface as a warning rather than block it.
func TestLogoutStoppedControlUnreachable(t *testing.T) {
	if testing.Short() {
		t.Skip("starts a control server and a tsnet node")
	}
	dir, control := signedInDir(t)
	p := &Profile{Hostname: "work", ControlURL: control.HTTPTestServer.URL}
	control.HTTPTestServer.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	start := time.Now()
	err := LogoutStopped(ctx, p, dir)
	if err == nil {
		t.Fatal("logout against a closed control server succeeded")
	}
	if took := time.Since(start); took > 10*time.Second {
		t.Errorf("logout took %v with a 3s deadline", took)
	}
}
