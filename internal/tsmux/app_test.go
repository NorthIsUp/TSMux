package tsmux

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
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
