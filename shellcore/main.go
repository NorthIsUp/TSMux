// Command shellcore is internal/sshclient as a C library for the apps
// (TSMuxSSH.xcframework). It is separate from the iOS tunnel core so the app
// process carries an SSH client and not a second copy of tsnet.
//
// Opening is asynchronous: authentication can wait on a check-mode login, so
// TSMuxSSHOpen returns a handle at once and TSMuxSSHState reports progress,
// including the banner that carries the login URL.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"sync"
	"unsafe"

	"github.com/NorthIsUp/tsmux/internal/sshclient"
)

func main() {}

type openRequest struct {
	SOCKSAddr  string   `json:"socks_addr"`
	Host       string   `json:"host"`
	Port       int      `json:"port,omitempty"`
	User       string   `json:"user"`
	Users      []string `json:"users,omitempty"`
	HostKeys   []string `json:"host_keys,omitempty"`
	TrustedKey string   `json:"trusted_key,omitempty"`
	Password   string   `json:"password,omitempty"`
	PrivateKey string   `json:"private_key,omitempty"`
	Cols       int      `json:"cols"`
	Rows       int      `json:"rows"`
}

// state is what TSMuxSSHState returns. ErrorKind lets the UI tell "ask the
// user to trust this key" and "this key changed" apart from plain failure.
type state struct {
	Phase       string   `json:"phase"`          // connecting, open, failed, closed
	User        string   `json:"user,omitempty"` // who was let in, once open
	Error       string   `json:"error,omitempty"`
	ErrorKind   string   `json:"error_kind,omitempty"` // unknown_host_key, host_key_mismatch, denied
	HostKey     string   `json:"host_key,omitempty"`
	Fingerprint string   `json:"fingerprint,omitempty"`
	Banners     []string `json:"banners,omitempty"`
	URLs        []string `json:"urls,omitempty"`
}

type conn struct {
	mu     sync.Mutex
	st     state
	sess   *sshclient.Session
	cancel context.CancelFunc
	ready  chan struct{} // closed once open or failed
}

var (
	connsMu sync.Mutex
	conns   = map[int64]*conn{}
	nextID  int64
)

func lookup(h C.longlong) *conn {
	connsMu.Lock()
	defer connsMu.Unlock()
	return conns[int64(h)]
}

// TSMuxSSHOpen starts connecting and returns a handle (> 0), or 0 when the
// request itself is unreadable.
//
//export TSMuxSSHOpen
func TSMuxSSHOpen(creq *C.char) C.longlong {
	var req openRequest
	if err := json.Unmarshal([]byte(C.GoString(creq)), &req); err != nil {
		return 0
	}
	ctx, cancel := context.WithCancel(context.Background())
	c := &conn{st: state{Phase: "connecting"}, cancel: cancel, ready: make(chan struct{})}
	connsMu.Lock()
	nextID++
	id := nextID
	conns[id] = c
	connsMu.Unlock()

	go func() {
		sess, err := sshclient.Dial(ctx, sshclient.Config{
			SOCKSAddr: req.SOCKSAddr, Host: req.Host, Port: req.Port, User: req.User, Users: req.Users,
			HostKeys: req.HostKeys, TrustedKey: req.TrustedKey,
			Password: req.Password, PrivateKey: []byte(req.PrivateKey),
			Cols: req.Cols, Rows: req.Rows,
			Banner: func(b string) {
				c.mu.Lock()
				c.st.Banners = append(c.st.Banners, b)
				c.st.URLs = append(c.st.URLs, sshclient.URLs(b)...)
				c.mu.Unlock()
			},
		})
		c.mu.Lock()
		defer c.mu.Unlock()
		defer close(c.ready)
		if err != nil {
			c.st.Phase, c.st.Error = "failed", err.Error()
			var unknown *sshclient.UnknownHostKeyError
			var mismatch *sshclient.HostKeyMismatchError
			switch {
			case errors.As(err, &unknown):
				c.st.ErrorKind, c.st.HostKey, c.st.Fingerprint = "unknown_host_key", unknown.Key, unknown.Fingerprint
			case errors.As(err, &mismatch):
				c.st.ErrorKind, c.st.Fingerprint = "host_key_mismatch", mismatch.Fingerprint
			case errors.Is(err, sshclient.ErrDenied):
				c.st.ErrorKind = "denied"
			}
			return
		}
		if ctx.Err() != nil { // closed while the handshake finished
			sess.Close()
			c.st.Phase = "closed"
			return
		}
		c.sess, c.st.Phase, c.st.User = sess, "open", sess.User
		go func() {
			sess.Wait()
			c.mu.Lock()
			c.st.Phase = "closed"
			c.mu.Unlock()
		}()
	}()
	return C.longlong(id)
}

// TSMuxSSHState returns the connection's state as JSON; free it with
// TSMuxSSHFree.
//
//export TSMuxSSHState
func TSMuxSSHState(h C.longlong) *C.char {
	c := lookup(h)
	st := state{Phase: "closed"}
	if c != nil {
		c.mu.Lock()
		st = c.st
		c.mu.Unlock()
	}
	b, _ := json.Marshal(st)
	return C.CString(string(b))
}

// TSMuxSSHRead blocks until output arrives and copies up to n bytes into buf.
// It returns the count, or -1 once the session is over (or never opened).
//
//export TSMuxSSHRead
func TSMuxSSHRead(h C.longlong, buf *C.char, n C.int) C.int {
	c := lookup(h)
	if c == nil || n <= 0 {
		return -1
	}
	<-c.ready
	c.mu.Lock()
	sess := c.sess
	c.mu.Unlock()
	if sess == nil {
		return -1
	}
	p := unsafe.Slice((*byte)(unsafe.Pointer(buf)), int(n))
	got, err := sess.Read(p)
	if got > 0 {
		return C.int(got)
	}
	if err != nil && !errors.Is(err, io.EOF) {
		c.mu.Lock()
		if c.st.Error == "" {
			c.st.Error = err.Error()
		}
		c.mu.Unlock()
	}
	return -1
}

// TSMuxSSHWrite sends n bytes of keyboard input. Returns n, or -1.
//
//export TSMuxSSHWrite
func TSMuxSSHWrite(h C.longlong, buf *C.char, n C.int) C.int {
	c := lookup(h)
	if c == nil {
		return -1
	}
	c.mu.Lock()
	sess := c.sess
	c.mu.Unlock()
	if sess == nil {
		return -1
	}
	if _, err := sess.Write(C.GoBytes(unsafe.Pointer(buf), n)); err != nil {
		return -1
	}
	return n
}

//export TSMuxSSHResize
func TSMuxSSHResize(h C.longlong, cols, rows C.int) {
	if c := lookup(h); c != nil {
		c.mu.Lock()
		sess := c.sess
		c.mu.Unlock()
		if sess != nil {
			sess.Resize(int(cols), int(rows))
		}
	}
}

// TSMuxSSHClose cancels a pending connect or ends the session, and forgets
// the handle. A Read blocked on it returns -1.
//
//export TSMuxSSHClose
func TSMuxSSHClose(h C.longlong) {
	connsMu.Lock()
	c := conns[int64(h)]
	delete(conns, int64(h))
	connsMu.Unlock()
	if c == nil {
		return
	}
	c.cancel()
	c.mu.Lock()
	sess := c.sess
	c.mu.Unlock()
	if sess != nil {
		sess.Close()
	}
}

//export TSMuxSSHFree
func TSMuxSSHFree(p *C.char) { C.free(unsafe.Pointer(p)) }
