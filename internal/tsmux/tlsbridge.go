package tsmux

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/pem"
	"errors"
	"io"
	"log"
	"math/big"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// TLSJoin joins proxied connections, bridging TLS to profile's routed IPs, or
// to any profile's when profile is "" (the router). See joinTLS.
func (m *Manager) TLSJoin(profile string) JoinFunc {
	return func(down, up net.Conn, hostport string) {
		joinTLS(down, up, hostport, m.bridgeName(profile, hostport), m.cfg.Paths.StateDir, nil)
	}
}

// bridgeName is the name a routed IP's peer serves TLS under, for hostport on
// port 443, or "" when hostport is anything else.
func (m *Manager) bridgeName(profile, hostport string) string {
	host, port, err := net.SplitHostPort(hostport)
	if err != nil || port != "443" {
		return ""
	}
	a, err := netip.ParseAddr(host)
	if err != nil {
		return ""
	}
	owner, e := m.cfg.routedEntry(profile, a)
	if owner == "" {
		return ""
	}
	if !strings.HasPrefix(e.Name, "svc:") {
		return e.Name
	}
	n, err := m.Node(owner)
	if err != nil {
		return ""
	}
	for _, s := range n.Services() {
		if s.Name == e.Name {
			return s.DNSName
		}
	}
	return ""
}

// routedEntry finds the routed_ips entry holding a, in profile or, when
// profile is "", in whichever profile has it.
func (c *Config) routedEntry(profile string, a netip.Addr) (string, RoutedIP) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	for _, p := range c.sorted {
		if profile != "" && p.Name != profile {
			continue
		}
		for _, e := range p.RoutedIPs {
			for _, ip := range e.IPs {
				if b, err := netip.ParseAddr(ip); err == nil && b == a {
					return p.Name, e
				}
			}
		}
	}
	return "", RoutedIP{}
}

// joinTLS is pipe, except for a TLS ClientHello with no SNI to a peer that
// needs one: Tailscale Serve refuses those, and a browser sends none for
// https://100.x.y.z. SNI can't be added in transit without breaking the
// handshake transcript, so the connection is terminated here with a
// self-signed certificate for the IP, and re-originated to name with the
// upstream certificate verified as usual. roots nil means the system's.
func joinTLS(down, up net.Conn, hostport, name, certDir string, roots *x509.CertPool) {
	if name == "" {
		pipe(down, up)
		return
	}
	br := bufio.NewReaderSize(down, 5+1<<14)
	down.SetReadDeadline(time.Now().Add(10 * time.Second))
	hello, err := peekClientHello(br)
	down.SetReadDeadline(time.Time{})
	down = &readConn{down, br}
	// An IP is no server name (RFC 6066), but Safari sends one through a proxy.
	if err != nil || hello.ServerName != "" && net.ParseIP(hello.ServerName) == nil {
		pipe(down, up)
		return
	}
	defer down.Close()
	defer up.Close()

	host, _, _ := net.SplitHostPort(hostport)
	var upTLS *tls.Conn
	srv := tls.Server(down, &tls.Config{
		GetConfigForClient: func(h *tls.ClientHelloInfo) (*tls.Config, error) {
			upTLS = tls.Client(up, &tls.Config{ServerName: name, NextProtos: h.SupportedProtos, RootCAs: roots})
			ctx, cancel := context.WithTimeout(h.Context(), 15*time.Second)
			defer cancel()
			if err := upTLS.HandshakeContext(ctx); err != nil {
				log.Printf("tls bridge %s as %s: %v", hostport, name, err)
				return nil, err
			}
			cert, err := bridgeCert(certDir, host)
			if err != nil {
				return nil, err
			}
			cfg := &tls.Config{Certificates: []tls.Certificate{*cert}}
			if p := upTLS.ConnectionState().NegotiatedProtocol; p != "" {
				cfg.NextProtos = []string{p}
			}
			return cfg, nil
		},
	})
	if err := srv.Handshake(); err != nil {
		return
	}
	pipe(srv, upTLS)
}

var errStopHello = errors.New("stop after hello")

// peekClientHello parses the ClientHello in br's first record without
// consuming it. crypto/tls does the parsing, on a copy that discards writes.
func peekClientHello(br *bufio.Reader) (*tls.ClientHelloInfo, error) {
	hdr, err := br.Peek(5)
	if err != nil {
		return nil, err
	}
	if hdr[0] != 0x16 { // handshake record
		return nil, errors.New("not TLS")
	}
	rec, err := br.Peek(5 + int(binary.BigEndian.Uint16(hdr[3:5])))
	if err != nil {
		return nil, err
	}
	var hello *tls.ClientHelloInfo
	tls.Server(&replayConn{r: bytes.NewReader(rec)}, &tls.Config{
		GetConfigForClient: func(h *tls.ClientHelloInfo) (*tls.Config, error) {
			hello = h
			return nil, errStopHello
		},
	}).Handshake()
	if hello == nil {
		return nil, errors.New("no ClientHello in the first record")
	}
	return hello, nil
}

// replayConn reads r and swallows writes. Only Read and Write are ever called.
type replayConn struct {
	net.Conn
	r io.Reader
}

func (c *replayConn) Read(b []byte) (int, error)  { return c.r.Read(b) }
func (c *replayConn) Write(b []byte) (int, error) { return len(b), nil }

// bridgeCerts caches the certificates loaded from or written to disk, by path.
var bridgeCerts struct {
	sync.Mutex
	byPath map[string]*tls.Certificate
}

// bridgeCertDays stays inside Apple's 825-day limit on TLS server certificates.
const bridgeCertDays = 800

// bridgeCert is the self-signed certificate for ip, kept in dir so a browser's
// click-through survives a restart. One key and file per IP, mode 0600. An
// empty dir keeps it in memory only.
func bridgeCert(dir, ip string) (*tls.Certificate, error) {
	path := ""
	if dir != "" {
		path = filepath.Join(dir, "bridge-certs", ip+".pem")
	}
	bridgeCerts.Lock()
	defer bridgeCerts.Unlock()
	if c, ok := bridgeCerts.byPath[path+"|"+ip]; ok && time.Until(c.Leaf.NotAfter) > 30*24*time.Hour {
		return c, nil
	}
	if bridgeCerts.byPath == nil {
		bridgeCerts.byPath = map[string]*tls.Certificate{}
	}
	if path != "" {
		if b, err := os.ReadFile(path); err == nil {
			if c, err := tls.X509KeyPair(b, b); err == nil && time.Until(c.Leaf.NotAfter) > 30*24*time.Hour {
				bridgeCerts.byPath[path+"|"+ip] = &c
				return &c, nil
			}
		}
	}
	pemBytes, err := newBridgeCert(ip)
	if err != nil {
		return nil, err
	}
	c, err := tls.X509KeyPair(pemBytes, pemBytes)
	if err != nil {
		return nil, err
	}
	if path != "" {
		if err := writePrivate(path, pemBytes); err != nil {
			log.Printf("tls bridge: can't save the certificate for %s: %v", ip, err)
		}
	}
	bridgeCerts.byPath[path+"|"+ip] = &c
	return &c, nil
}

func newBridgeCert(ip string) ([]byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 64))
	if err != nil {
		return nil, err
	}
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: ip, Organization: []string{"tsmux"}},
		IPAddresses:  []net.IP{net.ParseIP(ip)},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(bridgeCertDays * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	kder, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}
	out := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	return append(out, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: kder})...), nil
}

// writePrivate writes b to path atomically, readable by its owner only.
func writePrivate(path string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".cert-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err := f.Write(b); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}
