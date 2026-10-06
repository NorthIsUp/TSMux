package tsmux

import (
	"net"
	"testing"
)

// A port already in use must come back as an error, with whatever Serve had
// opened closed again, not as a panic in its cleanup.
func TestServeReportsBusyPort(t *testing.T) {
	busy, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer busy.Close()
	free, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	freeAddr := free.Addr().String()
	free.Close()

	c := Default()
	c.Router.HTTPProxy = freeAddr
	c.Router.SOCKS5Proxy = busy.Addr().String()
	if err := c.Normalize(); err != nil {
		t.Fatal(err)
	}
	if _, err := Serve(c, NewManager(c, false), nil); err == nil {
		t.Fatal("Serve succeeded on a busy port")
	}
	ln, err := net.Listen("tcp", freeAddr)
	if err != nil {
		t.Fatalf("Serve left the router http listener open: %v", err)
	}
	ln.Close()
}
