//go:build !darwin

package main

import (
	"errors"
	"os"
)

func utunFile() (*os.File, error) { return nil, errors.New("no utun on this platform") }
