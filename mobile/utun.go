package main

import (
	"errors"
	"os"

	"golang.org/x/sys/unix"
)

// utunFile finds the packet tunnel's utun socket among this process's file
// descriptors, as WireGuard's and Tailscale's Apple apps do: NetworkExtension
// opens it but has no public API that hands it over.
func utunFile() (*os.File, error) {
	info := &unix.CtlInfo{}
	copy(info.Name[:], "com.apple.net.utun_control")
	for fd := 0; fd < 1024; fd++ {
		sa, err := unix.Getpeername(fd)
		if err != nil {
			continue
		}
		ctl, ok := sa.(*unix.SockaddrCtl)
		if !ok {
			continue
		}
		if info.Id == 0 {
			if err := unix.IoctlCtlInfo(fd, info); err != nil {
				continue
			}
		}
		if ctl.ID == info.Id {
			return os.NewFile(uintptr(fd), "utun"), nil
		}
	}
	return nil, errors.New("no utun file descriptor in this process")
}
