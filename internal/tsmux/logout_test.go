package tsmux

import (
	"bytes"
	"context"
	"errors"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRedactURL(t *testing.T) {
	for _, tc := range []struct{ name, in, want string }{
		{"tailscale login", "https://login.tailscale.com/a/1a2b3c4d", "https://login.tailscale.com/…"},
		{"headscale register", "http://hs.example:8080/register/nodekey:abc", "http://hs.example:8080/…"},
		{"query secret", "https://login.example.com/?code=secret", "https://login.example.com/…"},
		{"bare host kept", "https://controlplane.tailscale.com", "https://controlplane.tailscale.com"},
		{"root path kept", "https://controlplane.tailscale.com/", "https://controlplane.tailscale.com/"},
		{"userinfo dropped", "https://u:pw@hs.example/", "https://hs.example/…"},
		{"not a url", "nonsense", "…"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := RedactURL(tc.in); got != tc.want {
				t.Errorf("RedactURL(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestRedactURLs(t *testing.T) {
	for _, tc := range []struct{ name, in, want string }{
		{
			"tsnet auth loop line",
			"To start this tsnet server, restart with TS_AUTHKEY set, or go to: https://login.tailscale.com/a/abc123",
			"To start this tsnet server, restart with TS_AUTHKEY set, or go to: https://login.tailscale.com/…",
		},
		{"two urls", `a "https://x.io/a/1" b https://y.io/z`, `a "https://x.io/…" b https://y.io/…`},
		{"no urls", "state is Running; done", "state is Running; done"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := RedactURLs(tc.in); got != tc.want {
				t.Errorf("RedactURLs(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestRedactedLogf(t *testing.T) {
	var buf bytes.Buffer
	prevOut, prevFlags := log.Writer(), log.Flags()
	log.SetOutput(&buf)
	log.SetFlags(0)
	t.Cleanup(func() { log.SetOutput(prevOut); log.SetFlags(prevFlags) })

	redactedLogf("[work] ")("go to: %s", "https://login.tailscale.com/a/secret")
	if got, want := buf.String(), "[work] go to: https://login.tailscale.com/…\n"; got != want {
		t.Errorf("logged %q, want %q", got, want)
	}
}

func TestPurgeState(t *testing.T) {
	offline := errors.New("dial tcp: no route to host")
	for _, tc := range []struct {
		name        string
		creds       bool
		logoutErr   error
		wantCalled  bool
		wantWarning bool
	}{
		// A profile that never signed in has nothing registered to log out,
		// and starting a node for it would mint a fresh login URL.
		{name: "never signed in", creds: false},
		{name: "logged out cleanly", creds: true, wantCalled: true},
		{name: "control unreachable", creds: true, logoutErr: offline, wantCalled: true, wantWarning: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "profiles", "work")
			if err := os.MkdirAll(dir, 0o700); err != nil {
				t.Fatal(err)
			}
			if tc.creds {
				if err := os.WriteFile(filepath.Join(dir, "tailscaled.state"), []byte("{}"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			called := false
			warning, err := PurgeState(context.Background(), dir, func(ctx context.Context) error {
				called = true
				if _, ok := ctx.Deadline(); !ok {
					t.Error("logout ran without a deadline")
				}
				return tc.logoutErr
			})
			if err != nil {
				t.Fatalf("PurgeState: %v", err)
			}
			if called != tc.wantCalled {
				t.Errorf("logout called = %v, want %v", called, tc.wantCalled)
			}
			if got := warning != ""; got != tc.wantWarning {
				t.Errorf("warning = %q, want one: %v", warning, tc.wantWarning)
			}
			if tc.wantWarning && !strings.Contains(warning, "admin console") {
				t.Errorf("warning %q does not say the device may still be listed", warning)
			}
			if _, err := os.Stat(dir); !os.IsNotExist(err) {
				t.Errorf("state dir still exists (stat err %v)", err)
			}
		})
	}
}

// A live daemon holds the state dir's lock; the offline logout must not start
// a second node on it and clobber the first one's credentials.
func TestLogoutStoppedRefusesLockedDir(t *testing.T) {
	dir := t.TempDir()
	lock, err := lockStateDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := LogoutStopped(context.Background(), &Profile{Hostname: "x"}, dir); err == nil {
		t.Fatal("LogoutStopped started a node on a locked state dir")
	}
}

// A daemon that has not let go of the dir yet (still exiting, or a second
// tsmux) must not have its state deleted underneath it.
func TestPurgeStateKeepsLockedDir(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "tailscaled.state"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	lock, err := lockStateDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	_, err = PurgeState(context.Background(), dir, func(ctx context.Context) error {
		return LogoutStopped(ctx, &Profile{Hostname: "x"}, dir)
	})
	if !errors.Is(err, ErrStateDirLocked) {
		t.Errorf("PurgeState err = %v, want ErrStateDirLocked", err)
	}
	if !HasCredentials(dir) {
		t.Error("PurgeState deleted a locked state dir")
	}
}
