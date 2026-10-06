package tsmux

import (
	"fmt"
	"log"
	"net"
	"net/http"
)

// Serve opens every loopback listener a running daemon owns: the router
// proxies, one proxy pair per running profile, the PAC/API listener and the
// configured tunnels. A nil local skips the PAC/API listener, for hosts that
// reach the API in process. The returned func closes them all; on error,
// whatever was already opened is closed before returning.
func Serve(cfg *Config, m *Manager, local http.Handler) (closeAll func(), err error) {
	var closers []func()
	closeAll = func() {
		for _, f := range closers {
			f()
		}
	}
	defer func() {
		if err != nil {
			closeAll()
		}
	}()

	serveProxies := func(label, httpAddr, socksAddr string, dial DialFunc) error {
		hl, err := net.Listen("tcp", httpAddr)
		if err != nil {
			return fmt.Errorf("%s http proxy: %w", label, err)
		}
		sl, err := net.Listen("tcp", socksAddr)
		if err != nil {
			hl.Close()
			return fmt.Errorf("%s socks proxy: %w", label, err)
		}
		closers = append(closers, func() { hl.Close(); sl.Close() })
		go (&http.Server{Handler: &HTTPProxy{Dial: dial, Label: label}}).Serve(hl)
		go ServeSOCKS5(sl, dial)
		log.Printf("%-12s http %s  socks5 %s", label, httpAddr, socksAddr)
		return nil
	}

	if err := serveProxies("router", cfg.Router.HTTPProxy, cfg.Router.SOCKS5Proxy, m.Dial); err != nil {
		return nil, err
	}
	for _, p := range cfg.Ordered() {
		n, err := m.Node(p.Name)
		if err != nil {
			return nil, err
		}
		if err := serveProxies(p.Name,
			fmt.Sprintf("127.0.0.1:%d", p.HTTPPort),
			fmt.Sprintf("127.0.0.1:%d", p.SOCKSPort), n.Dial); err != nil {
			return nil, err
		}
	}

	if local != nil {
		pl, err := net.Listen("tcp", cfg.Router.PACListen)
		if err != nil {
			return nil, fmt.Errorf("pac server: %w", err)
		}
		closers = append(closers, func() { pl.Close() })
		go (&http.Server{Handler: local}).Serve(pl)
		log.Printf("%-12s %s", "pac", cfg.PACURL())
		log.Printf("%-12s %s", "status", cfg.StatusURL())
	}

	for _, t := range cfg.OrderedTunnels() {
		dial := m.Dial
		if t.Profile != "" {
			n, err := m.Node(t.Profile)
			if err != nil {
				return nil, err
			}
			dial = n.Dial
		}
		tl, err := net.Listen("tcp", t.Listen)
		if err != nil {
			return nil, fmt.Errorf("tunnel %s: %w", t.Name, err)
		}
		closers = append(closers, func() { tl.Close() })
		go ServeTunnel(tl, t.Target, dial)
		log.Printf("%-12s %s -> %s", "tunnel:"+t.Name, t.Listen, t.Target)
	}
	return closeAll, nil
}
