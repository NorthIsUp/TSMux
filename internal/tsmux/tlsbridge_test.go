package tsmux

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

// sniServer is Tailscale Serve as far as SNI goes: a hello without one is
// refused. Its certificate is httptest's, which covers example.com.
func sniServer(t *testing.T) (*httptest.Server, *x509.CertPool) {
	t.Helper()
	s := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "%s %s", r.Proto, r.TLS.ServerName)
	}))
	s.EnableHTTP2 = true
	s.StartTLS()
	t.Cleanup(s.Close)
	s.TLS.GetConfigForClient = func(h *tls.ClientHelloInfo) (*tls.Config, error) {
		if h.ServerName == "" {
			return nil, errors.New("no SNI ServerName")
		}
		return nil, nil
	}
	pool := x509.NewCertPool()
	pool.AddCert(s.Certificate())
	return s, pool
}

// bridgeProxy is an HTTP proxy whose every CONNECT goes to backend, bridged
// to name.
func bridgeProxy(t *testing.T, backend, name string, roots *x509.CertPool) *url.URL {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	dial := (&fakeTailnet{backend: backend}).Dial
	join := func(down, up net.Conn, hostport string) { joinTLS(down, up, hostport, name, roots) }
	go (&http.Server{Handler: &HTTPProxy{Dial: dial, Join: join}}).Serve(ln)
	u, _ := url.Parse("http://" + ln.Addr().String())
	return u
}

func TestTLSBridgeAddsSNI(t *testing.T) {
	s, roots := sniServer(t)
	proxy := bridgeProxy(t, s.Listener.Addr().String(), "example.com", roots)
	for _, tc := range []struct {
		name  string
		h2    bool
		proto string
	}{{"h2", true, "HTTP/2.0"}, {"http/1.1", false, "HTTP/1.1"}} {
		t.Run(tc.name, func(t *testing.T) {
			tr := &http.Transport{
				Proxy: http.ProxyURL(proxy),
				// The bridge's own certificate is self-signed: the one warning a
				// browser shows.
				TLSClientConfig:   &tls.Config{InsecureSkipVerify: true},
				ForceAttemptHTTP2: tc.h2,
			}
			if !tc.h2 {
				tr.TLSNextProto = map[string]func(string, *tls.Conn) http.RoundTripper{}
			}
			// Go sends no SNI for an IP literal, as a browser doesn't.
			resp, err := (&http.Client{Transport: tr}).Get("https://100.90.45.67/")
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			body, _ := io.ReadAll(resp.Body)
			if want := tc.proto + " example.com"; string(body) != want || resp.Proto != tc.proto {
				t.Errorf("got %q over %s, want %q", body, resp.Proto, want)
			}
			if ips := resp.TLS.PeerCertificates[0].IPAddresses; len(ips) != 1 || ips[0].String() != "100.90.45.67" {
				t.Errorf("bridge certificate IPs = %v", ips)
			}
		})
	}
}

func TestTLSBridgeLeavesSNIAlone(t *testing.T) {
	s, roots := sniServer(t)
	proxy := bridgeProxy(t, s.Listener.Addr().String(), "example.com", nil)
	tr := &http.Transport{
		Proxy:           http.ProxyURL(proxy),
		TLSClientConfig: &tls.Config{ServerName: "example.com", RootCAs: roots},
	}
	resp, err := (&http.Client{Transport: tr}).Get("https://100.90.45.67/")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	// Verified against the backend's own certificate: spliced end to end.
	if !resp.TLS.PeerCertificates[0].Equal(s.Certificate()) {
		t.Error("an SNI-carrying hello was terminated by the bridge")
	}
}

func TestTLSBridgeRefusesUnverifiedUpstream(t *testing.T) {
	s, _ := sniServer(t)
	proxy := bridgeProxy(t, s.Listener.Addr().String(), "example.com", x509.NewCertPool())
	tr := &http.Transport{Proxy: http.ProxyURL(proxy), TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}
	if resp, err := (&http.Client{Transport: tr}).Get("https://100.90.45.67/"); err == nil {
		resp.Body.Close()
		t.Fatal("bridged to an upstream whose certificate didn't verify")
	}
}

func TestBridgeName(t *testing.T) {
	c := tempConfig(t, twoProfiles)
	if err := c.SetRoutedIP("work", RoutedIP{Name: "nas.tail.ts.net", IPs: []string{"100.64.0.2"}}, true); err != nil {
		t.Fatal(err)
	}
	m := NewManager(c, false)
	for _, tc := range []struct{ profile, hostport, want string }{
		{"", "100.64.0.2:443", "nas.tail.ts.net"},
		{"work", "100.64.0.2:443", "nas.tail.ts.net"},
		{"personal", "100.64.0.2:443", ""}, // another profile's port
		{"", "100.64.0.2:8443", ""},
		{"", "100.64.0.3:443", ""},
		{"", "nas.tail.ts.net:443", ""},
	} {
		if got := m.bridgeName(tc.profile, tc.hostport); got != tc.want {
			t.Errorf("%q %s = %q, want %q", tc.profile, tc.hostport, got, tc.want)
		}
	}
}
