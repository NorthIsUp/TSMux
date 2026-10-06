package tsmux

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
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

// EnsureAPIToken returns the install's API token, creating it on first use.
// It is reused rather than rotated per start: a second `tsmux up` that loses
// the port race must not lock out the CLI talking to the daemon that won.
func (c *Config) EnsureAPIToken() (string, error) {
	path := c.TokenPath()
	if tok, err := readToken(path); err == nil {
		// Tighten a file someone loosened by hand; the token is only a secret
		// while nobody else can read it.
		return tok, os.Chmod(path, 0o600)
	} else if !errors.Is(err, fs.ErrNotExist) {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	tok := hex.EncodeToString(b)
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, fs.ErrExist) {
		return readToken(path)
	}
	if err != nil {
		return "", err
	}
	_, werr := f.WriteString(tok + "\n")
	if err := errors.Join(werr, f.Close()); err != nil {
		os.Remove(path)
		return "", err
	}
	return tok, nil
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
