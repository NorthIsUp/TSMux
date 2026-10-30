package tsmux

import (
	"context"
	"io"
	"net"
	"net/netip"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/tailscale/wireguard-go/tun"
	"golang.org/x/net/dns/dnsmessage"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
)

func TestRouteAddr(t *testing.T) {
	cfg := tempConfig(t, twoProfiles)
	a, shared := netip.MustParseAddr("100.64.0.1"), netip.MustParseAddr("100.64.0.9")
	cfg.setPeers("work", []netip.Addr{a, shared})
	cfg.setPeers("personal", []netip.Addr{shared})

	if p, err := cfg.RouteAddr(a); err != nil || p.Name != "work" {
		t.Errorf("RouteAddr(%s) = %v, %v; want work", a, p, err)
	}
	if _, err := cfg.RouteAddr(shared); err == nil || !strings.Contains(err.Error(), "ambiguous") {
		t.Errorf("shared address: err = %v, want ambiguous", err)
	}
	if _, err := cfg.RouteAddr(netip.MustParseAddr("100.64.0.77")); err == nil {
		t.Error("unknown address routed")
	}
	// A hand-added suffix stays out of the OS resolver; learned split DNS goes in.
	cfg.setLearned("work", []string{".corp.example"}, nil)
	got := NewManager(cfg, false).TunnelSettings()
	if strings.Join(got.MatchDomains, ",") != "corp.example" || got.Routes[0] != (TunnelRoute{"100.64.0.0", "255.192.0.0"}) {
		t.Errorf("TunnelSettings = %+v", got)
	}
}

// A process on the OS side of the utun reaches a tailnet peer over TCP and
// resolves through the tunnel's DNS, with only packets crossing between them.
func TestServeTUN(t *testing.T) {
	osStack, dev := clientStack(t)
	peer := netip.MustParseAddrPort("100.64.0.1:80")
	h := TunnelHandlers{
		Dial: func(_ context.Context, network string, dst netip.AddrPort) (net.Conn, error) {
			if network != "tcp" || dst != peer {
				t.Errorf("dial %s %s", network, dst)
			}
			a, b := net.Pipe()
			go func() { io.Copy(b, b) }()
			return a, nil
		},
		DNS: func(_ context.Context, q []byte) ([]byte, error) { return append([]byte("answer:"), q...), nil },
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go ServeTUN(ctx, dev, h)

	dctx, dcancel := context.WithTimeout(ctx, 5*time.Second)
	defer dcancel()
	c, err := gonet.DialContextTCP(dctx, osStack, fullAddr(peer), ipv4.ProtocolNumber)
	if err != nil {
		t.Fatalf("dial through tunnel: %v", err)
	}
	c.Write([]byte("ping"))
	buf := make([]byte, 4)
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(c, buf); err != nil || string(buf) != "ping" {
		t.Fatalf("echo = %q, %v", buf, err)
	}
	c.Close()

	dns := netip.AddrPortFrom(TunnelDNS, 53)
	u, err := gonet.DialUDP(osStack, nil, &tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFromSlice(dns.Addr().AsSlice()), Port: 53}, ipv4.ProtocolNumber)
	if err != nil {
		t.Fatal(err)
	}
	u.Write([]byte("q"))
	u.SetReadDeadline(time.Now().Add(5 * time.Second))
	got := make([]byte, 64)
	n, err := u.Read(got)
	if err != nil || string(got[:n]) != "answer:q" {
		t.Fatalf("dns reply = %q, %v", got[:n], err)
	}
}

func TestTunnelDNSRefusesUnclaimed(t *testing.T) {
	m := NewManager(tempConfig(t, twoProfiles), false)
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: 7})
	b.StartQuestions()
	b.Question(dnsmessage.Question{Name: dnsmessage.MustNewName("example.com."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET})
	q, _ := b.Finish()
	raw, err := m.TunnelDNS(context.Background(), q)
	if err != nil {
		t.Fatal(err)
	}
	var msg dnsmessage.Message
	if err := msg.Unpack(raw); err != nil || msg.ID != 7 || msg.RCode != dnsmessage.RCodeRefused {
		t.Fatalf("reply = %+v, %v; want REFUSED with ID 7", msg.Header, err)
	}
}

func fullAddr(ap netip.AddrPort) tcpip.FullAddress {
	return tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFromSlice(ap.Addr().AsSlice()), Port: ap.Port()}
}

// clientStack is the OS side: a stack whose only route is the fake utun.
func clientStack(t *testing.T) (*stack.Stack, tun.Device) {
	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})
	t.Cleanup(s.Destroy)
	ep := channel.New(512, tunMTU, "")
	s.CreateNIC(1, ep)
	s.AddProtocolAddress(1, tcpip.ProtocolAddress{
		Protocol:          ipv4.ProtocolNumber,
		AddressWithPrefix: tcpip.AddrFromSlice(TunnelAddr.AsSlice()).WithPrefix(),
	}, stack.AddressProperties{})
	s.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: 1}})
	return s, &fakeTUN{ep: ep}
}

// fakeTUN is a utun whose far end is a channel endpoint.
type fakeTUN struct{ ep *channel.Endpoint }

func (f *fakeTUN) Read(bufs [][]byte, sizes []int, off int) (int, error) {
	pkt := f.ep.ReadContext(context.Background())
	if pkt == nil {
		return 0, os.ErrClosed
	}
	defer pkt.DecRef()
	v := pkt.ToView()
	defer v.Release()
	sizes[0] = copy(bufs[0][off:], v.AsSlice())
	return 1, nil
}

func (f *fakeTUN) Write(bufs [][]byte, off int) (int, error) {
	pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(append([]byte(nil), bufs[0][off:]...))})
	f.ep.InjectInbound(ipv4.ProtocolNumber, pkt)
	pkt.DecRef()
	return 1, nil
}

func (f *fakeTUN) File() *os.File           { return nil }
func (f *fakeTUN) MTU() (int, error)        { return tunMTU, nil }
func (f *fakeTUN) Name() (string, error)    { return "utun-test", nil }
func (f *fakeTUN) Events() <-chan tun.Event { return nil }
func (f *fakeTUN) Close() error             { f.ep.Close(); return nil }
func (f *fakeTUN) BatchSize() int           { return 1 }
