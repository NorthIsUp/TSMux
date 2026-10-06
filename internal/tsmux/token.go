package tsmux

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// The local API listens on TCP loopback, which every user and app on the
// machine can reach. This token, readable only by the user who runs the
// daemon, is what separates that user's CLI from everyone else.
const tokenHeader = "Authorization"

func (c *Config) TokenPath() string { return filepath.Join(c.Paths.StateDir, "api-token") }

// NewAPIToken returns a fresh token for one daemon run. Reusing one across
// runs would leak it: while no daemon holds the port, anyone can listen there
// and collect the token that the CLI and the menu bar's status polls send.
func NewAPIToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// WriteAPIToken publishes tok for the CLI. Call it only once the API listener
// is bound, so an `up` that loses the port race never replaces the token of
// the daemon that won. The rename means readers never see a partial file and
// a pre-existing file's looser mode is not inherited.
func (c *Config) WriteAPIToken(tok string) error {
	dir := filepath.Dir(c.TokenPath())
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".api-token-*")
	if err != nil {
		return err
	}
	_, werr := f.WriteString(tok + "\n")
	if err := errors.Join(werr, f.Close()); err != nil {
		os.Remove(f.Name())
		return err
	}
	if err := os.Rename(f.Name(), c.TokenPath()); err != nil {
		os.Remove(f.Name())
		return err
	}
	return nil
}

func readToken(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	tok := strings.TrimSpace(string(b))
	if tok == "" {
		return "", fmt.Errorf("%s is empty", path)
	}
	return tok, nil
}

func setToken(r *http.Request, tok string) {
	if tok != "" {
		r.Header.Set(tokenHeader, "Bearer "+tok)
	}
}

// requireToken fails closed: an empty want never matches, even an empty header.
func requireToken(want string, h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got, ok := strings.CutPrefix(r.Header.Get(tokenHeader), "Bearer ")
		if !ok || want == "" || subtle.ConstantTimeCompare([]byte(got), []byte(want)) != 1 {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "missing or wrong API token"})
			return
		}
		h.ServeHTTP(w, r)
	})
}
