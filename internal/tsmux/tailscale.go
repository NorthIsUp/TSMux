package tsmux

import (
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"tailscale.com/client/tailscale/apitype"
)

// localAPIProxy hands /tailscale/<profile>/localapi/... to that profile's
// tsnet LocalAPI, so the real tailscale CLI can drive a node that lives in
// another process. Write access is the node's whole LocalAPI: the API token is
// what guards it, as it guards /prefs and /logout.
func (m *Manager) localAPIProxy(w http.ResponseWriter, r *http.Request) {
	profile, rest, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/tailscale/"), "/")
	if !strings.HasPrefix(rest, "localapi/") {
		http.NotFound(w, r)
		return
	}
	lc, err := m.client(profile)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": err.Error()})
		return
	}
	(&httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.Out.URL.Scheme, pr.Out.URL.Host = "http", apitype.LocalAPIHost
			pr.Out.URL.Path, pr.Out.URL.RawPath = "/"+rest, ""
			pr.Out.Host = apitype.LocalAPIHost
			pr.Out.Header.Del(tokenHeader)
		},
		Transport:     &http.Transport{DialContext: lc.Dial, DisableKeepAlives: true},
		FlushInterval: -1,
	}).ServeHTTP(w, r)
}

// TailscaleSocket serves a unix socket for the tailscale CLI's --socket that
// forwards each LocalAPI request to profile's node in the app or daemon. stop
// closes it and removes it.
func (c *Config) TailscaleSocket(profile string) (path string, stop func(), err error) {
	tok, err := c.token()
	if err != nil {
		return "", nil, err
	}
	sweepTailscaleSockets()
	// Short: a unix socket path has to fit in 104 bytes, and a sandboxed
	// CLI's temp dir is already deep inside its container.
	dir, err := os.MkdirTemp("", fmt.Sprintf("tsx%d-", os.Getpid()))
	if err != nil {
		return "", nil, err
	}
	path = filepath.Join(dir, "s")
	l, err := net.Listen("unix", path)
	if err != nil {
		os.RemoveAll(dir)
		return "", nil, err
	}
	srv := &http.Server{Handler: &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.Out.URL.Scheme, pr.Out.URL.Host = "http", c.Router.PACListen
			pr.Out.URL.Path, pr.Out.URL.RawPath = "/tailscale/"+profile+pr.In.URL.Path, ""
			pr.Out.Host = ""
			// The CLI adds the Tailscale app's own token when that app is
			// installed; it must never leave this process.
			pr.Out.Header.Del(tokenHeader)
			setToken(pr.Out, tok)
		},
		FlushInterval: -1,
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, _ error) {
			http.Error(w, ErrDaemonDown.Error(), http.StatusBadGateway)
		},
	}}
	go srv.Serve(l)
	return path, func() { srv.Close(); os.RemoveAll(dir) }, nil
}

// sweepTailscaleSockets removes the socket dirs of runs that are gone: the
// tailscale CLI calls os.Exit on some failures (status of a stopped node, a
// ping that gets no answer), which skips TailscaleSocket's stop.
func sweepTailscaleSockets() {
	dirs, _ := filepath.Glob(filepath.Join(os.TempDir(), "tsx*-*"))
	for _, d := range dirs {
		pid, err := strconv.Atoi(strings.TrimPrefix(strings.Split(filepath.Base(d), "-")[0], "tsx"))
		if err == nil && syscall.Kill(pid, 0) == syscall.ESRCH {
			os.RemoveAll(d)
		}
	}
}
