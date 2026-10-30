package tsmux

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/netip"
	"slices"
	"strings"
	"time"

	"github.com/tailscale/wireguard-go/tun"
	"golang.org/x/net/dns/dnsmessage"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
)

// The packet tunnel's addresses. TunnelDNS sits next to the interface's own
// address so the OS sends queries into the tunnel rather than to loopback.
var (
	TunnelAddr = netip.MustParseAddr("198.18.0.1")
	TunnelDNS  = netip.MustParseAddr("198.18.0.2")
)

// TunnelRoutes is what the packet tunnel claims: every tailnet's CGNAT range,
// plus the DNS server. Addresses no running tailnet owns get a reset.
var TunnelRoutes = []netip.Prefix{netip.MustParsePrefix("100.64.0.0/10"), netip.PrefixFrom(TunnelDNS, 32)}

const tunMTU = 1280

// TunnelSettings is what the packet tunnel hands the OS, so that any process,
// not only proxy-aware ones, reaches tailnet names and addresses.
type TunnelSettings struct {
	Address      string        `json:"address"`
	DNSServer    string        `json:"dns_server"`
	MatchDomains []string      `json:"match_domains"`
	Routes       []TunnelRoute `json:"routes"`
}

// TunnelRoute is an IPv4 route as NEIPv4Route takes it.
type TunnelRoute struct {
	Address string `json:"address"`
	Mask    string `json:"mask"`
}

// TunnelSettings sends the OS resolver only the names a tailnet's own DNS
// serves: its MagicDNS suffix and split-DNS domains. A suffix added by hand
// (dagster.example.dev) resolves publicly to a 100.x peer, which the routes
// already carry, and the tailnet's resolver would not answer it.
func (m *Manager) TunnelSettings() TunnelSettings {
	m.mu.RLock()
	var domains []string
	for _, n := range m.nodes {
		if s, _ := n.learned(); s != "" {
			domains = append(domains, strings.Trim(s, "."))
		}
	}
	m.mu.RUnlock()
	m.cfg.mu.RLock()
	for _, p := range m.cfg.sorted {
		for _, s := range p.learnedSuffixes {
			domains = append(domains, strings.Trim(s, "."))
		}
	}
	m.cfg.mu.RUnlock()
	slices.Sort(domains)
	var routes []TunnelRoute
	for _, p := range TunnelRoutes {
		routes = append(routes, TunnelRoute{p.Addr().String(), net.IP(net.CIDRMask(p.Bits(), 32)).String()})
	}
	return TunnelSettings{TunnelAddr.String(), TunnelDNS.String(), slices.Compact(domains), routes}
}

// RouteAddr names the tailnet a packet to ip belongs in: an ip_route or a
// routed IP first, else the one tailnet with that peer. One 100.x address can
// be a different machine in each tailnet, so two owners is an error.
func (c *Config) RouteAddr(ip netip.Addr) (*Profile, error) {
	ip = ip.Unmap()
	c.mu.RLock()
	defer c.mu.RUnlock()
	for _, r := range c.ipRulesLocked() {
		if r.pfx.Contains(ip) {
			return r.profile, nil
		}
	}
	var owners []string
	var owner *Profile
	for _, p := range c.sorted {
		if slices.Contains(p.peers, ip) {
			owner = p
			owners = append(owners, p.Name)
		}
	}
	switch len(owners) {
	case 0:
		return nil, fmt.Errorf("%s: no running tailnet has this address", ip)
	case 1:
		return owner, nil
	}
	return nil, fmt.Errorf("%s: ambiguous, a peer in %s; turn on routing for it in one (tsmux profile route-ip)", ip, strings.Join(owners, ", "))
}

// suffixOwner is Route's suffix match alone: a query only reaches the tunnel's
// DNS for a claimed suffix, and Route's other fallbacks would ask the system
// resolver, which is this one.
func (c *Config) suffixOwner(host string) *Profile {
	c.mu.RLock()
	defer c.mu.RUnlock()
	for _, r := range c.domainRulesLocked() {
		if strings.HasSuffix(host, r.suffix) || host == strings.TrimPrefix(r.suffix, ".") {
			return r.profile
		}
	}
	return nil
}

// TunnelHandlers is what ServeTUN needs from the running tailnets. Both look
// up the current Manager on each call, since a config edit replaces it.
type TunnelHandlers struct {
	Dial func(ctx context.Context, network string, dst netip.AddrPort) (net.Conn, error)
	DNS  func(ctx context.Context, query []byte) ([]byte, error)
}

// TunnelDial dials dst in the tailnet that owns it.
func (m *Manager) TunnelDial(ctx context.Context, network string, dst netip.AddrPort) (net.Conn, error) {
	p, err := m.cfg.RouteAddr(dst.Addr())
	if err != nil {
		return nil, err
	}
	n, err := m.Node(p.Name)
	if err != nil {
		return nil, err
	}
	return n.srv.Dial(ctx, network, dst.String())
}

// TunnelDNS answers one query for a claimed suffix from the owning tailnet's
// resolver. Names outside every suffix get REFUSED, so the OS moves on.
func (m *Manager) TunnelDNS(ctx context.Context, query []byte) ([]byte, error) {
	var p dnsmessage.Parser
	h, err := p.Start(query)
	if err != nil {
		return nil, err
	}
	q, err := p.Question()
	if err != nil {
		return nil, err
	}
	reply := func(rcode dnsmessage.RCode) ([]byte, error) {
		h.Response, h.RCode, h.RecursionAvailable = true, rcode, true
		b := dnsmessage.NewBuilder(nil, h)
		b.StartQuestions()
		b.Question(q)
		return b.Finish()
	}
	host := strings.ToLower(strings.TrimSuffix(q.Name.String(), "."))
	prof := m.cfg.suffixOwner(host)
	if prof == nil {
		return reply(dnsmessage.RCodeRefused)
	}
	// shortcut: the tunnel carries IPv4 only, so AAAA answers would send
	// clients to addresses it can't reach; add an IPv6 route to lift this.
	if q.Type == dnsmessage.TypeAAAA {
		return reply(dnsmessage.RCodeSuccess)
	}
	n, err := m.Node(prof.Name)
	if err != nil {
		return reply(dnsmessage.RCodeServerFailure)
	}
	lc, err := n.srv.LocalClient()
	if err != nil {
		return reply(dnsmessage.RCodeServerFailure)
	}
	raw, _, err := lc.QueryDNS(ctx, host, q.Type.String()[len("Type"):])
	if err != nil || len(raw) < 2 {
		return reply(dnsmessage.RCodeServerFailure)
	}
	raw[0], raw[1] = query[0], query[1]
	return raw, nil
}

// ServeTUN terminates every TCP connection and DNS query the OS routes into
// the tunnel, in a userspace stack, and redials it through h. It returns when
// ctx ends or the device fails.
func ServeTUN(ctx context.Context, dev tun.Device, h TunnelHandlers) error {
	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol, ipv6.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})
	defer s.Destroy()
	ep := channel.New(512, tunMTU, "")
	if err := s.CreateNIC(1, ep); err != nil {
		return fmt.Errorf("netstack NIC: %v", err)
	}
	// Accept packets for any destination: each one is a remote peer's address.
	s.SetPromiscuousMode(1, true)
	s.SetSpoofing(1, true)
	s.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: 1}, {Destination: header.IPv6EmptySubnet, NIC: 1}})

	tcpFwd := tcp.NewForwarder(s, 0, 1024, func(r *tcp.ForwarderRequest) {
		id := r.ID()
		dst := netip.AddrPortFrom(addrOf(id.LocalAddress), id.LocalPort)
		dctx, cancel := context.WithTimeout(ctx, 15*time.Second)
		out, err := h.Dial(dctx, "tcp", dst)
		cancel()
		if err != nil {
			log.Printf("tun: tcp %s: %v", dst, err)
			r.Complete(true)
			return
		}
		var wq waiter.Queue
		tep, terr := r.CreateEndpoint(&wq)
		if terr != nil {
			out.Close()
			r.Complete(true)
			return
		}
		r.Complete(false)
		go pipe(gonet.NewTCPConn(&wq, tep), out)
	})
	s.SetTransportProtocolHandler(tcp.ProtocolNumber, tcpFwd.HandlePacket)

	udpFwd := udp.NewForwarder(s, func(r *udp.ForwarderRequest) bool {
		id := r.ID()
		// shortcut: only DNS rides UDP; other tailnet UDP needs a relay per flow.
		if addrOf(id.LocalAddress) != TunnelDNS || id.LocalPort != 53 {
			return false
		}
		var wq waiter.Queue
		uep, err := r.CreateEndpoint(&wq)
		if err != nil {
			return true
		}
		go serveDNS(ctx, gonet.NewUDPConn(&wq, uep), h.DNS)
		return true
	})
	s.SetTransportProtocolHandler(udp.ProtocolNumber, udpFwd.HandlePacket)

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		defer cancel()
		const off = 4 // the utun header wireguard-go's darwin Device writes
		bufs := [][]byte{make([]byte, off+tunMTU+64)}
		for {
			pkt := ep.ReadContext(ctx)
			if pkt == nil {
				return
			}
			view := pkt.ToView()
			n := copy(bufs[0][off:], view.AsSlice())
			view.Release()
			pkt.DecRef()
			if _, err := dev.Write([][]byte{bufs[0][:off+n]}, off); err != nil && ctx.Err() == nil {
				log.Printf("tun: write: %v", err)
			}
		}
	}()

	const off = 4
	bufs := [][]byte{make([]byte, off+65535)}
	sizes := []int{0}
	for ctx.Err() == nil {
		n, err := dev.Read(bufs, sizes, off)
		if err != nil {
			if errors.Is(err, tun.ErrTooManySegments) {
				continue
			}
			return err
		}
		if n == 0 || sizes[0] == 0 {
			continue
		}
		b := bufs[0][off : off+sizes[0]]
		proto := ipv4.ProtocolNumber
		if b[0]>>4 == 6 {
			proto = ipv6.ProtocolNumber
		}
		pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(slices.Clone(b))})
		ep.InjectInbound(proto, pkt)
		pkt.DecRef()
	}
	return ctx.Err()
}

// serveDNS answers queries on one UDP flow until it goes quiet.
func serveDNS(ctx context.Context, c *gonet.UDPConn, answer func(context.Context, []byte) ([]byte, error)) {
	defer c.Close()
	buf := make([]byte, 1500)
	for {
		c.SetReadDeadline(time.Now().Add(30 * time.Second))
		n, err := c.Read(buf)
		if err != nil {
			return
		}
		qctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		resp, err := answer(qctx, buf[:n])
		cancel()
		if err != nil {
			continue
		}
		if _, err := c.Write(resp); err != nil {
			return
		}
	}
}

func addrOf(a tcpip.Address) netip.Addr {
	ip, _ := netip.AddrFromSlice(a.AsSlice())
	return ip
}
