//go:build !darwin

package tsmux

func excludeFromBackup(string) error { return nil }
