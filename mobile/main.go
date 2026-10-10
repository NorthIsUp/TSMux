// Command mobile is the iOS core, built with -buildmode=c-archive and linked
// into the packet tunnel extension. The extension hands the app's messages to
// TSMuxCall unchanged, so the daemon's own HTTP API is the iOS API too.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"unsafe"

	"github.com/NorthIsUp/tsmux/internal/tsmux"
)

// memoryLimit keeps the Go heap well under the ~50 MB jetsam cap iOS puts on
// a network extension; the runtime and binary need the rest.
const memoryLimit = 30 << 20

var (
	mu       sync.RWMutex
	dir      string
	cfg      *tsmux.Config
	mgr      *tsmux.Manager
	closeAll func()
	cancel   context.CancelFunc
	// apiToken guards the loopback API the Mac extension serves for the CLI.
	apiToken string
)

func main() {}

// TSMuxStart brings up every profile under dir (the App Group container) and
// its loopback listeners. It returns NULL or an error the caller frees.
//
//export TSMuxStart
func TSMuxStart(cdir *C.char) *C.char {
	return cerr(start(C.GoString(cdir)))
}

func start(d string) error {
	mu.Lock()
	defer mu.Unlock()
	debug.SetMemoryLimit(memoryLimit)
	dir = d
	// Library/Caches is the one part of the container devicectl can read back.
	logDir := filepath.Join(dir, "Library", "Caches")
	_ = os.MkdirAll(logDir, 0o700)
	if f, err := os.Create(filepath.Join(logDir, "tsmux.log")); err == nil {
		log.SetOutput(f)
	}
	return up()
}

//export TSMuxStop
func TSMuxStop() {
	mu.Lock()
	defer mu.Unlock()
	down()
}

// TSMuxCall runs one request against the API and returns a JSON
// {"code": int, "body": string} the caller frees with TSMuxFree.
//
//export TSMuxCall
func TSMuxCall(creq *C.char) *C.char {
	b, _ := json.Marshal(call([]byte(C.GoString(creq))))
	return C.CString(string(b))
}

//export TSMuxFree
func TSMuxFree(p *C.char) { C.free(unsafe.Pointer(p)) }

type request struct {
	Method string `json:"method"`
	Path   string `json:"path"`
	Body   string `json:"body,omitempty"` // JSON, as a string
}

type response struct {
	Code int    `json:"code"`
	Body string `json:"body"`
}

type editResult struct {
	OK      bool   `json:"ok"`
	Warning string `json:"warning,omitempty"`
}

type profileRequest struct {
	Name        string `json:"name"`
	DisplayName string `json:"display_name,omitempty"`
	ControlURL  string `json:"control_url,omitempty"`
	NewName     string `json:"new_name,omitempty"`
	Index       int    `json:"index,omitempty"`
}

func call(raw []byte) response {
	var req request
	if err := json.Unmarshal(raw, &req); err != nil {
		return errResponse(http.StatusBadRequest, err)
	}
	switch req.Path {
	case "/profiles/add", "/profiles/remove", "/profiles/rename", "/profiles/move":
		var p profileRequest
		if err := json.Unmarshal([]byte(req.Body), &p); err != nil {
			return errResponse(http.StatusBadRequest, err)
		}
		var warning string
		var err error
		switch req.Path {
		case "/profiles/add":
			err = addProfile(p)
		case "/profiles/remove":
			warning, err = removeProfile(p)
		case "/profiles/rename":
			err = renameProfile(p)
		case "/profiles/move":
			err = editConfig(func(c *tsmux.Config) error { return c.MoveProfile(p.Name, p.Index) })
		}
		if err != nil {
			return errResponse(http.StatusBadRequest, err)
		}
		b, _ := json.Marshal(editResult{OK: true, Warning: warning})
		return response{Code: http.StatusOK, Body: string(b)}
	}

	mu.RLock()
	defer mu.RUnlock()
	if mgr == nil {
		return errResponse(http.StatusServiceUnavailable, errors.New("tsmux is not running"))
	}
	if req.Path == "/cli" {
		if apiToken == "" {
			return errResponse(http.StatusNotFound, errors.New("no loopback API on this platform"))
		}
		b, _ := json.Marshal(tsmux.AppEndpoint{URL: "http://" + cfg.Router.PACListen, Token: apiToken})
		return response{Code: http.StatusOK, Body: string(b)}
	}
	// guard() only admits loopback JSON requests with no Origin, which is
	// exactly what this is; the extension is the only caller.
	r := httptest.NewRequest(req.Method, "http://127.0.0.1"+req.Path, strings.NewReader(req.Body))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	cfg.InProcessHandler(mgr).ServeHTTP(w, r)
	return response{Code: w.Code, Body: w.Body.String()}
}

// addProfile and removeProfile restart every node, as the macOS app does:
// a node's ports and state dir are fixed for its lifetime.
func addProfile(p profileRequest) error {
	return editConfig(func(c *tsmux.Config) error {
		if p.Name == "" {
			return errors.New("name is required")
		}
		if _, ok := c.Profiles[p.Name]; ok {
			return fmt.Errorf("profile %q already exists", p.Name)
		}
		c.Profiles[p.Name] = &tsmux.Profile{DisplayName: p.DisplayName, ControlURL: p.ControlURL}
		return nil
	})
}

// removeProfile also logs the node out and deletes the saved credentials: on
// iOS nothing else can reach the state dir to clean it up later.
func removeProfile(p profileRequest) (warning string, err error) {
	live, liveErr := logoutLive(p.Name)
	err = editConfig(func(c *tsmux.Config) error {
		prof, ok := c.Profiles[p.Name]
		if !ok {
			return fmt.Errorf("no profile %q", p.Name)
		}
		delete(c.Profiles, p.Name)
		dir := c.StateDir(p.Name)
		var rmErr error
		warning, rmErr = tsmux.PurgeState(context.Background(), dir, func(ctx context.Context) error {
			if live {
				return liveErr
			}
			return tsmux.LogoutStopped(ctx, prof, dir)
		})
		return rmErr
	})
	if warning != "" {
		log.Printf("[%s] %s", p.Name, warning)
	}
	return warning, err
}

// logoutLive logs a profile out through its running node, which editConfig is
// about to stop. live is false when it has none and the logout is still owed.
func logoutLive(name string) (live bool, err error) {
	mu.Lock()
	defer mu.Unlock()
	if mgr == nil {
		return false, nil
	}
	ctx, cancelCtx := context.WithTimeout(context.Background(), tsmux.LogoutTimeout)
	defer cancelCtx()
	return mgr.LogoutRunning(ctx, name)
}

// renameProfile renames a tailnet after sign-in, when its real name is known.
func renameProfile(p profileRequest) error {
	return editConfig(func(c *tsmux.Config) error {
		return c.RenameProfile(p.Name, p.NewName, p.DisplayName)
	})
}

func editConfig(edit func(*tsmux.Config) error) error {
	mu.Lock()
	defer mu.Unlock()
	if dir == "" {
		return errors.New("tsmux is not running")
	}
	down()
	c, err := load()
	if err == nil {
		err = edit(c)
	}
	if err == nil {
		err = c.Normalize()
	}
	if err == nil {
		err = c.Save(configPath())
	}
	// Restart even when the edit failed, so a bad request never leaves the
	// existing tailnets down.
	return errors.Join(err, up())
}

func configPath() string { return filepath.Join(dir, "config.yaml") }

// load reads the config, writing a default one on first run. The state dir
// always follows the container, whose path is not the one HOME implies.
func load() (*tsmux.Config, error) {
	if _, err := os.Stat(configPath()); errors.Is(err, fs.ErrNotExist) {
		d := tsmux.Default()
		if err := d.Normalize(); err != nil {
			return nil, err
		}
		if err := d.Save(configPath()); err != nil {
			return nil, err
		}
	}
	c, err := tsmux.Load(configPath())
	if err != nil {
		return nil, err
	}
	c.Paths.StateDir = filepath.Join(dir, "state")
	return c, nil
}

// up starts the manager and listeners. Callers hold mu.
func up() error {
	c, err := load()
	if err != nil {
		return err
	}
	ctx, cancelCtx := context.WithCancel(context.Background())
	m := tsmux.NewManager(c, false)
	if len(c.Ordered()) > 0 {
		if err := m.Start(ctx); err != nil {
			cancelCtx()
			m.Close()
			return err
		}
	}
	// The app reaches the API through TSMuxCall, and the tunnel hands the OS
	// the PAC as script. Only the Mac serves it on loopback too, for the CLI
	// bundled in the app; the token keeps other users and apps out.
	var local http.Handler
	if runtime.GOOS == "darwin" {
		// One token for the extension's lifetime: every profile edit restarts
		// the core, and a new token each time would leave the CLI holding a
		// stale one until the app next republishes it.
		if apiToken == "" {
			tok, err := tsmux.NewAPIToken()
			if err != nil {
				cancelCtx()
				m.Close()
				return err
			}
			apiToken = tok
		}
		local = localAPI(c, m)
	}
	closer, err := tsmux.Serve(c, m, local)
	if err != nil {
		cancelCtx()
		m.Close()
		return err
	}
	cfg, mgr, closeAll, cancel = c, m, closer, cancelCtx
	return nil
}

// localAPI is the daemon's local API plus the profile edits only this core
// has. An edit restarts the core and closes this listener, but not the
// connection the request came in on, so the reply still arrives.
func localAPI(c *tsmux.Config, m *tsmux.Manager) http.Handler {
	mux := http.NewServeMux()
	edit := func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		req, _ := json.Marshal(request{Method: http.MethodPost, Path: r.URL.Path, Body: string(body)})
		resp := call(req)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(resp.Code)
		io.WriteString(w, resp.Body)
	}
	for _, p := range []string{"/profiles/add", "/profiles/remove", "/profiles/rename", "/profiles/move"} {
		mux.Handle(p, tsmux.TokenGuarded(apiToken, edit))
	}
	mux.Handle("/", c.LocalHandler(m, apiToken))
	return mux
}

// down stops whatever up started. Callers hold mu.
func down() {
	if mgr == nil {
		return
	}
	cancel()
	closeAll()
	mgr.Close()
	cfg, mgr, closeAll, cancel = nil, nil, nil, nil
}

func errResponse(code int, err error) response {
	b, _ := json.Marshal(map[string]string{"error": err.Error()})
	return response{Code: code, Body: string(b)}
}

func cerr(err error) *C.char {
	if err == nil {
		return nil
	}
	return C.CString(err.Error())
}
