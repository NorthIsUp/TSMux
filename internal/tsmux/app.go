package tsmux

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"gopkg.in/yaml.v3"
)

// AppEndpoint is how the CLI reaches the tailnets the TSMux Mac app runs in
// its network extension. The extension serves the local API on loopback, and
// the app, which can ask the extension for the token, writes this file.
type AppEndpoint struct {
	URL   string `json:"url"`
	Token string `json:"token"`
}

// ErrAppOwnsConfig refuses edits the CLI would make to a config file: the
// app's lives inside its extension, out of the CLI's reach.
var ErrAppOwnsConfig = errors.New("the TSMux app runs these tailnets and its config isn't a file here; make this change in the app")

// AppEndpointPaths lists where the Developer ID app and then the App Store app
// write the endpoint. The App Store app and its sandboxed copy of this CLI
// share only their app group's container.
func AppEndpointPaths() []string {
	home, _ := os.UserHomeDir()
	return []string{
		filepath.Join(home, "Library", "Application Support", "TSMux", "cli-endpoint.json"),
		filepath.Join(home, "Library", "Group Containers", "4BJBDQVY6M.dev.northisup.tsmux", "cli-endpoint.json"),
	}
}

// LoadFromApp returns the config of the first app that answers, with its
// token, or an error when none does.
func LoadFromApp() (*Config, error) {
	var errs []error
	for _, p := range AppEndpointPaths() {
		b, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		var ep AppEndpoint
		if err := json.Unmarshal(b, &ep); err != nil || ep.URL == "" {
			errs = append(errs, fmt.Errorf("%s: unreadable endpoint", p))
			continue
		}
		c, err := fetchAppConfig(ep)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		return c, nil
	}
	return nil, errors.Join(append([]error{errors.New("no TSMux app is running")}, errs...)...)
}

func fetchAppConfig(ep AppEndpoint) (*Config, error) {
	req, err := http.NewRequest(http.MethodGet, ep.URL+"/config", nil)
	if err != nil {
		return nil, err
	}
	setToken(req, ep.Token)
	resp, err := (&http.Client{Timeout: 3 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if err := apiError(resp); err != nil {
		return nil, err
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	c := Default()
	if err := yaml.Unmarshal(b, c); err != nil {
		return nil, err
	}
	c.apiToken = ep.Token
	return c, c.Normalize()
}

// FromApp reports whether this config is the app's, read over its API.
func (c *Config) FromApp() bool { return c.apiToken != "" }

// configYAML serves the running config, so the CLI uses the app's ports.
func (c *Config) configYAML(w http.ResponseWriter, _ *http.Request) {
	c.mu.RLock()
	b, err := yaml.Marshal(c)
	c.mu.RUnlock()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/yaml")
	w.Write(b)
}

// ProfileEdit is the body of the app extension's /profiles/add, /remove,
// /rename and /move (mobile/main.go).
type ProfileEdit struct {
	Name        string `json:"name"`
	DisplayName string `json:"display_name,omitempty"`
	ControlURL  string `json:"control_url,omitempty"`
	NewName     string `json:"new_name,omitempty"`
	// Index is where /move puts the profile, 0 being first.
	Index int `json:"index,omitempty"`
}

// EditInApp sends a profile edit to the app's extension, which restarts its
// tailnets to apply it. warning is set when a removed tailnet could not be
// logged out on its control server.
func (c *Config) EditInApp(path string, e ProfileEdit) (warning string, err error) {
	b, err := json.Marshal(e)
	if err != nil {
		return "", err
	}
	resp, err := c.call(http.MethodPost, path, b, 60*time.Second)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if err := apiError(resp); err != nil {
		return "", err
	}
	var r struct {
		Warning string `json:"warning"`
	}
	return r.Warning, json.NewDecoder(resp.Body).Decode(&r)
}

// TokenGuarded is a write route outside the local API, held to the same
// checks: loopback host, no cross-origin, JSON POST, and the token.
func TokenGuarded(token string, h http.HandlerFunc) http.Handler {
	return requireToken(token, guard(h, true))
}
