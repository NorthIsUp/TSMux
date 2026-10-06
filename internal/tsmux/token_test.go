package tsmux

import (
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

func TestEnsureAPIToken(t *testing.T) {
	cfg := tempConfig(t, twoProfiles)
	cfg.Paths.StateDir = filepath.Join(t.TempDir(), "state")

	tok, err := cfg.EnsureAPIToken()
	if err != nil {
		t.Fatal(err)
	}
	if len(tok) != 64 {
		t.Errorf("token %q: want 64 hex chars", tok)
	}
	fi, err := os.Stat(cfg.TokenPath())
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Errorf("mode = %v, want 0600", fi.Mode().Perm())
	}

	if err := os.Chmod(cfg.TokenPath(), 0o644); err != nil {
		t.Fatal(err)
	}
	again, err := cfg.EnsureAPIToken()
	if err != nil {
		t.Fatal(err)
	}
	if again != tok {
		t.Errorf("token rotated: %q then %q", tok, again)
	}
	if fi, _ := os.Stat(cfg.TokenPath()); fi.Mode().Perm() != 0o600 {
		t.Errorf("loosened file left at %v", fi.Mode().Perm())
	}
}

// The CLI's client half: it must find the token the daemon wrote and send it.
func TestClientSendsToken(t *testing.T) {
	cfg := tempConfig(t, twoProfiles)
	cfg.Paths.StateDir = t.TempDir()
	tok, err := cfg.EnsureAPIToken()
	if err != nil {
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
}
