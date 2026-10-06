package tsmux

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/unix"
)

func TestExcludeFromBackupMatchesTmutil(t *testing.T) {
	dir := t.TempDir()
	if err := excludeFromBackup(dir); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 256)
	n, err := unix.Getxattr(dir, backupExcludeXattr, buf)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(buf[:n], backupExcludeValue) {
		t.Fatalf("xattr = % x", buf[:n])
	}
	if _, err := exec.LookPath("tmutil"); err != nil {
		t.Skip("tmutil not available")
	}
	out, err := exec.Command("tmutil", "isexcluded", dir).CombinedOutput()
	if err != nil {
		t.Fatalf("tmutil: %v: %s", err, out)
	}
	if !strings.Contains(string(out), "[Excluded]") {
		t.Fatalf("tmutil does not see the exclusion: %s", out)
	}
}

func TestProtectStateDirExcludesProfiles(t *testing.T) {
	profiles := filepath.Join(t.TempDir(), "profiles")
	dir := filepath.Join(profiles, "work")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := protectStateDir(profiles, dir); err != nil {
		t.Fatal(err)
	}
	if _, err := unix.Getxattr(profiles, backupExcludeXattr, make([]byte, 256)); err != nil {
		t.Fatalf("profiles dir not excluded: %v", err)
	}
}
