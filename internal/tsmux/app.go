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
var ErrAppOwnsConfig = errors.New("the TSMux app runs these tailnets; add, remove and rename them in the app")

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
