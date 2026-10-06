package tsmux

import (
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

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
