package tsmux

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestProtectStateDirSurvivesUnsupportedXattr(t *testing.T) {
	orig := backupExcluder
	t.Cleanup(func() { backupExcluder = orig })
	backupExcluder = func(string) error { return syscall.ENOTSUP }

	profiles := filepath.Join(t.TempDir(), "profiles")
	dir := filepath.Join(profiles, "work")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := protectStateDir(profiles, dir); err != nil {
		t.Fatalf("a volume without xattrs must not block the profile: %v", err)
	}
	if fi, err := os.Stat(dir); err != nil || fi.Mode().Perm() != 0o700 {
		t.Fatalf("modes not tightened: %v %v", fi.Mode(), err)
	}
}

// A second instance must report the held lock, and must not touch the live
// node's files on the way.
func TestStartOneLeavesLockedStateDirAlone(t *testing.T) {
	cfg := tempConfig(t, twoProfiles)
	cfg.Paths.StateDir = t.TempDir()
	dir := cfg.StateDir("work")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	held, err := lockStateDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	live := filepath.Join(dir, "tailscaled.state")
	if err := os.WriteFile(live, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(live, 0o644); err != nil {
		t.Fatal(err)
	}

	err = NewManager(cfg, false).startOne(context.Background(), cfg.Profiles["work"])
	if err == nil || !strings.Contains(err.Error(), "already running") {
		t.Fatalf("err = %v, want the held-lock error", err)
	}
	fi, err := os.Stat(live)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o644 {
		t.Fatalf("second instance chmodded the live node's state to %o", fi.Mode().Perm())
	}
}

func TestProtectStateDirTightensModes(t *testing.T) {
	profiles := filepath.Join(t.TempDir(), "profiles")
	dir := filepath.Join(profiles, "work")
	logs := filepath.Join(dir, "logs")
	if err := os.MkdirAll(logs, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{profiles, dir, logs} {
		if err := os.Chmod(p, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	state := filepath.Join(dir, "tailscaled.state")
	logf := filepath.Join(logs, "tailscaled.log1.txt")
	for _, p := range []string{state, logf} {
		if err := os.WriteFile(p, []byte("{}"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := protectStateDir(profiles, dir); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		path string
		want fs.FileMode
	}{
		{profiles, 0o700},
		{dir, 0o700},
		{logs, 0o700},
		{state, 0o600},
		{logf, 0o600},
	} {
		fi, err := os.Stat(tc.path)
		if err != nil {
			t.Fatal(err)
		}
		if got := fi.Mode().Perm(); got != tc.want {
			t.Errorf("%s: mode %o, want %o", tc.path, got, tc.want)
		}
	}
}
