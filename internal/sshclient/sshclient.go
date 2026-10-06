// Package sshclient is the SSH client both apps embed: one interactive shell,
// reached through the owning tailnet's SOCKS5 proxy. Tailscale SSH servers
// authorize by tailnet identity, so "none" auth is enough for them; plain
// OpenSSH servers get a password or key.
package sshclient

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/net/proxy"
)

// Config describes one session. HostKeys and TrustedKey decide which host
// key is accepted; with neither, the first connection fails with
// *UnknownHostKeyError so the caller can ask the user.
type Config struct {
	SOCKSAddr string // the tailnet's SOCKS5 proxy; empty dials directly
	Host      string
	Port      int
	User      string

	// HostKeys are the keys control advertises for the host (authorized_keys
	// form). When set, they are the only keys accepted.
	HostKeys []string
	// TrustedKey is a key the user accepted earlier (authorized_keys form),
	// used only when HostKeys is empty.
	TrustedKey string

	Password   string
	PrivateKey []byte // PEM or OpenSSH format, unencrypted

	Term       string
	Cols, Rows int

	// Banner receives server banners, which is where Tailscale SSH's
	// check-mode login URL arrives while authentication waits on it.
	Banner func(string)
}

// UnknownHostKeyError reports a host key nothing vouches for yet.
type UnknownHostKeyError struct {
	Key         string // authorized_keys form
	Fingerprint string // SHA256:…
}

func (e *UnknownHostKeyError) Error() string {
	return "unknown host key " + e.Fingerprint
}

// HostKeyMismatchError reports a key that differs from the pinned ones: the
// host was reinstalled, or something is impersonating it.
type HostKeyMismatchError struct {
	Fingerprint string
}

func (e *HostKeyMismatchError) Error() string {
	return "host key " + e.Fingerprint + " does not match the key this host is known by"
}

// Session is one interactive shell. Read returns the terminal's output
// (stdout and stderr together, as a terminal shows them); Write is its input.
type Session struct {
	client *ssh.Client
	sess   *ssh.Session
	stdin  io.WriteCloser
	out    *io.PipeReader
	outW   *io.PipeWriter

	closeOnce sync.Once
	done      chan struct{}
	exitErr   error
}

const dialTimeout = 20 * time.Second

// Dial connects, authenticates and starts a login shell on a PTY.
// Authentication can block for as long as a check-mode login takes; cancel
// ctx to give up.
func Dial(ctx context.Context, cfg Config) (*Session, error) {
	if cfg.Port == 0 {
		cfg.Port = 22
	}
	if cfg.Term == "" {
		cfg.Term = "xterm-256color"
	}
	addr := net.JoinHostPort(cfg.Host, strconv.Itoa(cfg.Port))

	conn, err := dialTCP(ctx, cfg.SOCKSAddr, addr)
	if err != nil {
		return nil, err
	}
	// Closing the conn is how ctx cancellation reaches a handshake that is
	// waiting on the user.
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()

	hostKeyCB, err := hostKeyCallback(cfg)
	if err != nil {
		conn.Close()
		return nil, err
	}
	clientCfg := &ssh.ClientConfig{
		User:            cfg.User,
		Auth:            authMethods(cfg),
		HostKeyCallback: hostKeyCB,
		BannerCallback: func(msg string) error {
			if cfg.Banner != nil {
				cfg.Banner(msg)
			}
			return nil
		},
	}
	c, chans, reqs, err := ssh.NewClientConn(conn, addr, clientCfg)
	if err != nil {
		conn.Close()
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, unwrapHostKeyError(err)
	}
	client := ssh.NewClient(c, chans, reqs)

	s, err := startShell(client, cfg)
	if err != nil {
		client.Close()
		return nil, err
	}
	return s, nil
}

func dialTCP(ctx context.Context, socksAddr, addr string) (net.Conn, error) {
	ctx, cancel := context.WithTimeout(ctx, dialTimeout)
	defer cancel()
	if socksAddr == "" {
		var d net.Dialer
		return d.DialContext(ctx, "tcp", addr)
	}
	d, err := proxy.SOCKS5("tcp", socksAddr, nil, &net.Dialer{Timeout: dialTimeout})
	if err != nil {
		return nil, err
	}
	cd, ok := d.(proxy.ContextDialer)
	if !ok {
		return nil, errors.New("SOCKS5 dialer cannot take a context")
	}
	conn, err := cd.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("reach %s through the tailnet: %w", addr, err)
	}
	return conn, nil
}

// authMethods lists what to offer after "none", which x/crypto/ssh always
// tries first and which is all a Tailscale SSH server needs.
func authMethods(cfg Config) []ssh.AuthMethod {
	var m []ssh.AuthMethod
	if len(cfg.PrivateKey) > 0 {
		if signer, err := ssh.ParsePrivateKey(cfg.PrivateKey); err == nil {
			m = append(m, ssh.PublicKeys(signer))
		}
	}
	if cfg.Password != "" {
		pw := cfg.Password
		m = append(m, ssh.Password(pw), ssh.KeyboardInteractive(
			func(_, _ string, questions []string, _ []bool) ([]string, error) {
				answers := make([]string, len(questions))
				for i := range answers {
					answers[i] = pw
				}
				return answers, nil
			}))
	}
	return m
}

func hostKeyCallback(cfg Config) (ssh.HostKeyCallback, error) {
	var pinned []ssh.PublicKey
	for _, k := range cfg.HostKeys {
		pk, _, _, _, err := ssh.ParseAuthorizedKey([]byte(k))
		if err != nil {
			continue // one malformed advertisement shouldn't block the others
		}
		pinned = append(pinned, pk)
	}
	if len(pinned) == 0 && cfg.TrustedKey != "" {
		pk, _, _, _, err := ssh.ParseAuthorizedKey([]byte(cfg.TrustedKey))
		if err != nil {
			return nil, fmt.Errorf("saved host key is unreadable: %w", err)
		}
		pinned = append(pinned, pk)
	}
	return func(_ string, _ net.Addr, key ssh.PublicKey) error {
		if len(pinned) == 0 {
			return &UnknownHostKeyError{
				Key:         strings.TrimSpace(string(ssh.MarshalAuthorizedKey(key))),
				Fingerprint: ssh.FingerprintSHA256(key),
			}
		}
		got := key.Marshal()
		for _, p := range pinned {
			if subtle.ConstantTimeCompare(got, p.Marshal()) == 1 {
				return nil
			}
		}
		return &HostKeyMismatchError{Fingerprint: ssh.FingerprintSHA256(key)}
	}, nil
}

// x/crypto/ssh wraps callback errors in its own; callers want ours back.
func unwrapHostKeyError(err error) error {
	var unknown *UnknownHostKeyError
	if errors.As(err, &unknown) {
		return unknown
	}
	var mismatch *HostKeyMismatchError
	if errors.As(err, &mismatch) {
		return mismatch
	}
	return err
}

func startShell(client *ssh.Client, cfg Config) (*Session, error) {
	sess, err := client.NewSession()
	if err != nil {
		return nil, err
	}
	modes := ssh.TerminalModes{ssh.ECHO: 1, ssh.TTY_OP_ISPEED: 115200, ssh.TTY_OP_OSPEED: 115200}
	if err := sess.RequestPty(cfg.Term, max(cfg.Rows, 1), max(cfg.Cols, 1), modes); err != nil {
		sess.Close()
		return nil, err
	}
	stdin, err := sess.StdinPipe()
	if err != nil {
		sess.Close()
		return nil, err
	}
	pr, pw := io.Pipe()
	sess.Stdout = pw
	sess.Stderr = pw
	if err := sess.Shell(); err != nil {
		sess.Close()
		return nil, err
	}
	s := &Session{client: client, sess: sess, stdin: stdin, out: pr, outW: pw, done: make(chan struct{})}
	go func() {
		s.exitErr = sess.Wait()
		pw.CloseWithError(io.EOF)
		close(s.done)
	}()
	return s, nil
}

func (s *Session) Read(p []byte) (int, error)  { return s.out.Read(p) }
func (s *Session) Write(p []byte) (int, error) { return s.stdin.Write(p) }

// Resize tells the remote PTY the terminal's new size.
func (s *Session) Resize(cols, rows int) error {
	return s.sess.WindowChange(max(rows, 1), max(cols, 1))
}

// Close ends the shell and the connection. Safe to call more than once and
// alongside a blocked Read, which then returns io.EOF.
func (s *Session) Close() error {
	s.closeOnce.Do(func() {
		s.sess.Close()
		s.client.Close()
		// The writer side, so a blocked Read sees a clean EOF.
		s.outW.CloseWithError(io.EOF)
	})
	return nil
}

// Wait blocks until the remote shell exits and reports how.
func (s *Session) Wait() error {
	<-s.done
	return s.exitErr
}

// URLs pulls http(s) links out of a banner, for a tappable check-mode login.
func URLs(banner string) []string {
	var out []string
	for _, f := range strings.Fields(banner) {
		f = strings.TrimLeft(strings.TrimRight(f, ".,;)>\"'"), "(<\"'")
		if strings.HasPrefix(f, "https://") || strings.HasPrefix(f, "http://") {
			out = append(out, f)
		}
	}
	return out
}
