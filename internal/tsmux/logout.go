package tsmux

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"tailscale.com/tsnet"
)

// LogoutTimeout bounds a logout made only so a profile can be removed: an
// offline control server must not make a profile impossible to delete.
const LogoutTimeout = 15 * time.Second

var ErrStateDirLocked = errors.New("another tsmux is already running for this profile")

// HasCredentials reports whether a state dir holds a node identity worth
// logging out. tsnet keeps it in this one file.
func HasCredentials(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, "tailscaled.state"))
	return err == nil
}

// PurgeState logs a profile's node out on the control server, then deletes its
// state dir. Deleting the keys alone leaves the device registered with keys
// that are still valid. A failed logout is a warning, not an error: the user
// asked for the profile to be gone. A dir another node holds is the exception:
// deleting it would pull the state out from under a live node.
func PurgeState(ctx context.Context, dir string, logout func(context.Context) error) (warning string, err error) {
	if HasCredentials(dir) {
		lctx, cancel := context.WithTimeout(ctx, LogoutTimeout)
		lerr := logout(lctx)
		cancel()
		if errors.Is(lerr, ErrStateDirLocked) {
			return "", lerr
		}
		if lerr != nil {
			warning = fmt.Sprintf("could not log out on the control server (%v); "+
				"the device may still be listed in the admin console", lerr)
		}
	}
	return warning, os.RemoveAll(dir)
}

// LogoutStopped logs out a profile whose node is not running by starting a
// short-lived node on its state dir. The lock keeps it off a dir a live
// daemon owns.
func LogoutStopped(ctx context.Context, p *Profile, dir string) error {
	lock, err := lockStateDir(dir)
	if err != nil {
		return err
	}
	defer lock.Close()
	quiet := func(string, ...any) {}
	// No AuthKey: an expired node would otherwise sign in again just to be
	// logged out.
	srv := &tsnet.Server{Dir: dir, Hostname: p.Hostname, ControlURL: p.ControlURL, Logf: quiet, UserLogf: quiet}
	defer srv.Close()
	if err := srv.Start(); err != nil {
		return err
	}
	lc, err := srv.LocalClient()
	if err != nil {
		return err
	}
	if err := lc.Logout(ctx); err != nil {
		if ctx.Err() != nil {
			return errors.New("control server did not answer in time")
		}
		return err
	}
	return nil
}

// LogoutRunning logs out a profile through its live node. ok is false when
// the profile has no node in this manager.
func (m *Manager) LogoutRunning(ctx context.Context, profile string) (ok bool, err error) {
	n, err := m.Node(profile)
	if err != nil {
		return false, nil
	}
	lc, err := n.srv.LocalClient()
	if err != nil {
		return true, err
	}
	return true, lc.Logout(ctx)
}

var urlPattern = regexp.MustCompile(`https?://[^\s"'<>]+`)

// RedactURL trims a URL to scheme and host. Login URLs are bearer secrets
// until used: whoever opens one first claims the node, so they stay out of
// log files.
func RedactURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return "…"
	}
	if (u.Path == "" || u.Path == "/") && u.RawQuery == "" && u.Fragment == "" && u.User == nil {
		return raw
	}
	return u.Scheme + "://" + u.Host + "/…"
}

// RedactURLs applies RedactURL to every URL in a log line.
func RedactURLs(s string) string {
	return urlPattern.ReplaceAllStringFunc(s, RedactURL)
}

// redactedLogf is a tsnet logger that keeps login URLs out of the log: tsnet
// prints the interactive login URL every few seconds while a node waits.
func redactedLogf(prefix string) func(string, ...any) {
	return func(f string, a ...any) {
		log.Print(prefix + RedactURLs(fmt.Sprintf(f, a...)))
	}
}
