package sshclient

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

// testServer is a stand-in for a Tailscale SSH server: "none" auth, a banner,
// and a PTY shell that echoes its input back.
type testServer struct {
	addr    string
	hostKey ssh.PublicKey
	resized chan [2]uint32
}

func newHostSigner(t *testing.T) ssh.Signer {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	s, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func startServer(t *testing.T, banner string) *testServer {
	t.Helper()
	signer := newHostSigner(t)
	cfg := &ssh.ServerConfig{
		NoClientAuth:   true,
		BannerCallback: func(ssh.ConnMetadata) string { return banner },
	}
	cfg.AddHostKey(signer)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	ts := &testServer{addr: ln.Addr().String(), hostKey: signer.PublicKey(), resized: make(chan [2]uint32, 4)}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go ts.serve(c, cfg)
		}
	}()
	return ts
}

func (ts *testServer) serve(c net.Conn, cfg *ssh.ServerConfig) {
	_, chans, reqs, err := ssh.NewServerConn(c, cfg)
	if err != nil {
		return
	}
	go ssh.DiscardRequests(reqs)
	for nc := range chans {
		ch, creqs, err := nc.Accept()
		if err != nil {
			return
		}
		go func() {
			for r := range creqs {
				switch r.Type {
				case "pty-req", "shell":
					r.Reply(true, nil)
					if r.Type == "shell" {
						go func() {
							io.Copy(ch, ch) // echo
							ch.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{0}))
							ch.Close()
						}()
					}
				case "window-change":
					var wc struct{ Cols, Rows, W, H uint32 }
					ssh.Unmarshal(r.Payload, &wc)
					ts.resized <- [2]uint32{wc.Cols, wc.Rows}
				default:
					r.Reply(false, nil)
				}
			}
		}()
	}
}

func (ts *testServer) host(t *testing.T) (string, int) {
	h, p, _ := net.SplitHostPort(ts.addr)
	port, err := strconv.Atoi(p)
	if err != nil {
		t.Fatal(err)
	}
	return h, port
}

func authorized(k ssh.PublicKey) string {
	return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(k)))
}

// startSOCKS is the smallest SOCKS5 CONNECT proxy that x/net/proxy talks to,
// standing in for a tailnet's loopback SOCKS port.
func startSOCKS(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				r := bufio.NewReader(c)
				hdr := make([]byte, 2)
				io.ReadFull(r, hdr)
				io.ReadFull(r, make([]byte, hdr[1]))
				c.Write([]byte{5, 0})
				req := make([]byte, 4)
				io.ReadFull(r, req)
				var host string
				switch req[3] {
				case 1:
					ip := make([]byte, 4)
					io.ReadFull(r, ip)
					host = net.IP(ip).String()
				case 3:
					n, _ := r.ReadByte()
					name := make([]byte, n)
					io.ReadFull(r, name)
					host = string(name)
				}
				pb := make([]byte, 2)
				io.ReadFull(r, pb)
				up, err := net.Dial("tcp", net.JoinHostPort(host, strconv.Itoa(int(binary.BigEndian.Uint16(pb)))))
				if err != nil {
					c.Write([]byte{5, 5, 0, 1, 0, 0, 0, 0, 0, 0})
					return
				}
				defer up.Close()
				c.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0})
				go io.Copy(up, r)
				io.Copy(c, up)
			}()
		}
	}()
	return ln.Addr().String()
}

func readUntil(t *testing.T, s *Session, want string) {
	t.Helper()
	var got strings.Builder
	buf := make([]byte, 256)
	deadline := time.Now().Add(5 * time.Second)
	for !strings.Contains(got.String(), want) {
		if time.Now().After(deadline) {
			t.Fatalf("never read %q, got %q", want, got.String())
		}
		n, err := s.Read(buf)
		got.Write(buf[:n])
		if err != nil {
			t.Fatalf("read: %v (got %q)", err, got.String())
		}
	}
}

func TestPinnedHostThroughSOCKS(t *testing.T) {
	ts := startServer(t, "Tailscale SSH requires an additional check.\nTo authenticate, visit: https://login.tailscale.com/a/abc123\n")
	host, port := ts.host(t)
	var banners []string
	s, err := Dial(context.Background(), Config{
		SOCKSAddr: startSOCKS(t), Host: host, Port: port, User: "adam",
		HostKeys: []string{"not a key", authorized(ts.hostKey)},
		Cols:     80, Rows: 24,
		Banner: func(b string) { banners = append(banners, b) },
	})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	if len(banners) != 1 || len(URLs(banners[0])) != 1 || URLs(banners[0])[0] != "https://login.tailscale.com/a/abc123" {
		t.Errorf("banner URLs = %v from %q", banners, banners)
	}
	if _, err := s.Write([]byte("hello\n")); err != nil {
		t.Fatal(err)
	}
	readUntil(t, s, "hello")

	if err := s.Resize(120, 40); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-ts.resized:
		if got != [2]uint32{120, 40} {
			t.Errorf("resize = %v, want 120x40", got)
		}
	case <-time.After(5 * time.Second):
		t.Error("server never saw the resize")
	}
}

func TestHostKeyPolicy(t *testing.T) {
	ts := startServer(t, "")
	host, port := ts.host(t)
	other := authorized(newHostSigner(t).PublicKey())
	dial := func(cfg Config) error {
		cfg.Host, cfg.Port, cfg.User = host, port, "adam"
		s, err := Dial(context.Background(), cfg)
		if err == nil {
			s.Close()
		}
		return err
	}

	err := dial(Config{})
	var unknown *UnknownHostKeyError
	if !errors.As(err, &unknown) || unknown.Key != authorized(ts.hostKey) || !strings.HasPrefix(unknown.Fingerprint, "SHA256:") {
		t.Fatalf("no keys: want UnknownHostKeyError for the server's key, got %v", err)
	}
	if err := dial(Config{TrustedKey: unknown.Key}); err != nil {
		t.Errorf("trusted key the user accepted: %v", err)
	}

	var mismatch *HostKeyMismatchError
	if err := dial(Config{HostKeys: []string{other}}); !errors.As(err, &mismatch) {
		t.Errorf("advertised key differs: want HostKeyMismatchError, got %v", err)
	}
	// Advertised keys win over a remembered one: control is the authority.
	if err := dial(Config{HostKeys: []string{other}, TrustedKey: authorized(ts.hostKey)}); !errors.As(err, &mismatch) {
		t.Errorf("trusted key must not override advertised keys, got %v", err)
	}
	if err := dial(Config{TrustedKey: other}); !errors.As(err, &mismatch) {
		t.Errorf("remembered key changed: want HostKeyMismatchError, got %v", err)
	}
}

func TestCloseUnblocksRead(t *testing.T) {
	ts := startServer(t, "")
	host, port := ts.host(t)
	s, err := Dial(context.Background(), Config{Host: host, Port: port, User: "adam", HostKeys: []string{authorized(ts.hostKey)}})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := s.Read(make([]byte, 16))
		done <- err
	}()
	time.Sleep(50 * time.Millisecond)
	s.Close()
	s.Close()
	select {
	case err := <-done:
		if err != io.EOF {
			t.Errorf("read after close = %v, want EOF", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Close did not unblock Read")
	}
}

func TestDialCancel(t *testing.T) {
	// A listener that accepts and never speaks SSH: the handshake hangs the
	// way it does while check mode waits on the user.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			defer c.Close()
		}
	}()
	h, p, _ := net.SplitHostPort(ln.Addr().String())
	port, _ := strconv.Atoi(p)
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := Dial(ctx, Config{Host: h, Port: port, User: "adam"}); !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("err = %v, want DeadlineExceeded", err)
	}
	if time.Since(start) > 3*time.Second {
		t.Error("cancel did not interrupt the handshake")
	}
}

func TestURLs(t *testing.T) {
	got := URLs("visit: https://login.tailscale.com/a/x1. or (http://h/y), not ftp://z")
	if strings.Join(got, " ") != "https://login.tailscale.com/a/x1 http://h/y" {
		t.Errorf("URLs = %v", got)
	}
}
