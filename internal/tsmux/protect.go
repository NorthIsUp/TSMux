package tsmux

import (
	"io/fs"
	"log"
	"os"
	"path/filepath"
)

// protectStateDir keeps node private keys readable only by this user and out
// of backups. tsnet creates its files 0600 under a 0700 dir, but a state dir
// from an older build or restored from elsewhere keeps whatever modes it had.
// The exclusion goes on the profiles dir rather than Paths.StateDir, which a
// user may point at a directory shared with other apps.
func protectStateDir(profiles, dir string) error {
	if err := os.Chmod(profiles, 0o700); err != nil {
		return err
	}
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		switch {
		case err != nil:
			return err
		case d.IsDir():
			return os.Chmod(path, 0o700)
		case d.Type().IsRegular():
			return os.Chmod(path, 0o600)
		}
		return nil
	})
	if err != nil {
		return err
	}
	// A state dir on a volume without xattrs (SMB, exFAT) or a sandbox that
	// refuses the xattr cannot be excluded; that costs less than a profile
	// that never starts.
	if err := backupExcluder(profiles); err != nil {
		log.Printf("state dir %s is not excluded from backups: %v", profiles, err)
	}
	return nil
}

// backupExcluder is swapped in tests to simulate a volume without xattrs.
var backupExcluder = excludeFromBackup
