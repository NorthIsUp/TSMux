package tsmux

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLocalHandlerRequiresToken(t *testing.T) {
	cfg := tempConfig(t, twoProfiles)
	h := cfg.LocalHandler(NewManager(cfg, false), testToken)
	for _, tc := range []struct {
		name, method, path, auth string
		want                     int
	}{
		{name: "pac without token", method: "GET", path: "/proxy.pac", want: 200},
		{name: "status without token", method: "GET", path: "/status", want: 401},
		{name: "status wrong token", method: "GET", path: "/status", auth: "Bearer nope", want: 401},
		{name: "status bare token", method: "GET", path: "/status", auth: testToken, want: 401},
		{name: "status right token", method: "GET", path: "/status", auth: "Bearer " + testToken, want: 200},
		{name: "prefs without token", method: "POST", path: "/prefs", want: 401},
		{name: "logout without token", method: "POST", path: "/logout", want: 401},
		{name: "shutdown without token", method: "POST", path: "/shutdown", want: 401},
		{name: "unknown path without token", method: "GET", path: "/", want: 401},
		{name: "unknown path with token serves pac", method: "GET", path: "/", auth: "Bearer " + testToken, want: 200},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(tc.method, "http://127.0.0.1:43180"+tc.path, strings.NewReader("{}"))
			r.Header.Set("Content-Type", "application/json")
			if tc.auth != "" {
				r.Header.Set("Authorization", tc.auth)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != tc.want {
				t.Errorf("%s %s: got %d, want %d (%s)", tc.method, tc.path, w.Code, tc.want, w.Body)
			}
		})
	}
}

// A daemon that somehow has no token must not treat an empty header as a match.
func TestLocalHandlerEmptyTokenFailsClosed(t *testing.T) {
	cfg := tempConfig(t, twoProfiles)
	h := cfg.LocalHandler(NewManager(cfg, false), "")
	for _, auth := range []string{"", "Bearer ", "Bearer x"} {
		r := httptest.NewRequest("GET", "http://127.0.0.1:43180/status", nil)
		r.Header.Set("Authorization", auth)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != http.StatusUnauthorized {
			t.Errorf("auth %q: got %d, want 401", auth, w.Code)
		}
	}
}

func TestWriteAPIToken(t *testing.T) {
	cfg := tempConfig(t, twoProfiles)
	cfg.Paths.StateDir = filepath.Join(t.TempDir(), "state")

	tok, err := NewAPIToken()
	if err != nil {
		t.Fatal(err)
	}
	if len(tok) != 64 {
		t.Errorf("token %q: want 64 hex chars", tok)
	}
	if again, _ := NewAPIToken(); again == tok {
		t.Error("two daemon runs got the same token")
	}
	if err := cfg.WriteAPIToken(tok); err != nil {
		t.Fatal(err)
	}
	if got, err := readToken(cfg.TokenPath()); err != nil || got != tok {
		t.Errorf("read back %q, %v; want %q", got, err, tok)
	}
	if fi, err := os.Stat(cfg.TokenPath()); err != nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("token file: %v; want mode 0600", err)
	}
	if fi, err := os.Stat(cfg.Paths.StateDir); err != nil || fi.Mode().Perm() != 0o700 {
		t.Errorf("state dir: %v; want mode 0700", err)
	}

	// A file someone loosened must not keep its mode when the next run rotates.
	if err := os.Chmod(cfg.TokenPath(), 0o644); err != nil {
		t.Fatal(err)
	}
	next, _ := NewAPIToken()
	if err := cfg.WriteAPIToken(next); err != nil {
		t.Fatal(err)
	}
	if got, _ := readToken(cfg.TokenPath()); got != next {
		t.Errorf("after rotation read %q, want %q", got, next)
	}
	if fi, _ := os.Stat(cfg.TokenPath()); fi.Mode().Perm() != 0o600 {
		t.Errorf("rotated file left at %v", fi.Mode().Perm())
	}
	if left, _ := filepath.Glob(filepath.Join(cfg.Paths.StateDir, ".api-token-*")); len(left) != 0 {
		t.Errorf("temp files left behind: %v", left)
	}
}

// rm and rename delete or move a profile's state dir; only a daemon that is
// plainly down may let them through.
func TestRefuseIfRunning(t *testing.T) {
	const tok = "daemon-token"
	live := requireToken(tok, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, []Status{{Profile: "work"}})
	}))
	for _, tc := range []struct {
		name, profile, clientTok string
		down, wantErr            bool
	}{
		{name: "daemon down", profile: "work", down: true},
		{name: "running profile", profile: "work", clientTok: tok, wantErr: true},
		{name: "other profile", profile: "personal", clientTok: tok},
		{name: "daemon we cannot authenticate to", profile: "work", clientTok: "stale", wantErr: true},
		{name: "no token file", profile: "work", wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := tempConfig(t, twoProfiles)
			cfg.Paths.StateDir = t.TempDir()
			if tc.clientTok != "" {
				if err := cfg.WriteAPIToken(tc.clientTok); err != nil {
					t.Fatal(err)
				}
			}
			srv := httptest.NewServer(live)
			cfg.Router.PACListen = strings.TrimPrefix(srv.URL, "http://")
			if tc.down {
				srv.Close()
			} else {
				defer srv.Close()
			}
			if err := cfg.RefuseIfRunning(tc.profile); (err != nil) != tc.wantErr {
				t.Errorf("err = %v, wantErr %v", err, tc.wantErr)
			}
		})
	}
}

// The CLI's client half: it must find the token the daemon wrote and send it.
func TestClientSendsToken(t *testing.T) {
	cfg := tempConfig(t, twoProfiles)
	cfg.Paths.StateDir = t.TempDir()
	tok, err := NewAPIToken()
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.WriteAPIToken(tok); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(cfg.LocalHandler(NewManager(cfg, false), tok))
	defer srv.Close()
	cfg.Router.PACListen = strings.TrimPrefix(srv.URL, "http://")

	if _, err := cfg.FetchStatus(); err != nil {
		t.Fatalf("with token: %v", err)
	}
	if err := cfg.Shutdown(); err == nil || !strings.Contains(err.Error(), "503") {
		t.Errorf("shutdown without a stop hook: %v, want a 503 refusal", err)
	}

	if err := os.Remove(cfg.TokenPath()); err != nil {
		t.Fatal(err)
	}
	if _, err := cfg.FetchStatus(); err == nil || !strings.Contains(err.Error(), "API token") {
		t.Errorf("without token: %v, want an API token error", err)
	}
	if _, err := cfg.PostLogout("work"); err == nil || !strings.Contains(err.Error(), "API token") {
		t.Errorf("logout without token: %v, want an API token error", err)
	}
	if _, err := cfg.FetchStatus(); errors.Is(err, ErrDaemonDown) {
		t.Error("a 401 was reported as the daemon being down")
	}
}
