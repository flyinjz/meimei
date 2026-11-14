// Raven Tunnel: a WireGuard tunnel for i2s's Soulseek engine only.
//
// It runs wireguard-go on a userspace network stack (gVisor netstack), so it
// needs no system VPN, no admin rights and no network extension, and nothing
// else on the Mac is routed through it. Raven reaches it through a SOCKS5
// endpoint on loopback, protected by a username and password generated for
// each session. Names are resolved inside the tunnel.
//
// Built as a C archive and linked into the app.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

// Config is a parsed wg-quick style configuration.
type Config struct {
	PrivateKey string
	Addresses  []netip.Addr
	DNS        []netip.Addr
	MTU        int
	ListenPort int
	Peers      []Peer
}

type Peer struct {
	PublicKey    string
	PresharedKey string
	Endpoint     string
	AllowedIPs   []string
	Keepalive    int
}

func keyHex(b64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil || len(raw) != 32 {
		return "", errors.New("invalid key")
	}
	return hex.EncodeToString(raw), nil
}

// ParseConfig reads the [Interface] and [Peer] sections of a WireGuard config.
func ParseConfig(text string) (*Config, error) {
	cfg := &Config{MTU: 1420}
	var section string
	var peer *Peer
	sc := bufio.NewScanner(strings.NewReader(text))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if i := strings.IndexAny(line, "#;"); i >= 0 {
			line = strings.TrimSpace(line[:i])
		}
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") {
			section = strings.ToLower(strings.Trim(line, "[] "))
			if section == "peer" {
				cfg.Peers = append(cfg.Peers, Peer{})
				peer = &cfg.Peers[len(cfg.Peers)-1]
			}
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(k))
		val := strings.TrimSpace(v)
		list := func() []string {
			var out []string
			for _, p := range strings.Split(val, ",") {
				if p = strings.TrimSpace(p); p != "" {
					out = append(out, p)
				}
			}
			return out
		}
		switch section {
		case "interface":
			switch key {
			case "privatekey":
				cfg.PrivateKey = val
			case "address":
				for _, a := range list() {
					p, err := netip.ParsePrefix(a)
					if err != nil {
						addr, err2 := netip.ParseAddr(a)
						if err2 != nil {
							return nil, fmt.Errorf("invalid address %q", a)
						}
						cfg.Addresses = append(cfg.Addresses, addr)
						continue
					}
					cfg.Addresses = append(cfg.Addresses, p.Addr())
				}
			case "dns":
				for _, a := range list() {
					if addr, err := netip.ParseAddr(a); err == nil {
						cfg.DNS = append(cfg.DNS, addr)
					}
				}
			case "mtu":
				if n, err := strconv.Atoi(val); err == nil && n >= 1280 {
					cfg.MTU = n
				}
			case "listenport":
				cfg.ListenPort, _ = strconv.Atoi(val)
			}
		case "peer":
			if peer == nil {
				continue
			}
			switch key {
			case "publickey":
				peer.PublicKey = val
			case "presharedkey":
				peer.PresharedKey = val
			case "endpoint":
				peer.Endpoint = val
			case "allowedips":
				peer.AllowedIPs = list()
			case "persistentkeepalive":
				peer.Keepalive, _ = strconv.Atoi(val)
			}
		}
	}
	if cfg.PrivateKey == "" {
		return nil, errors.New("missing PrivateKey in [Interface]")
	}
	if len(cfg.Addresses) == 0 {
		return nil, errors.New("missing Address in [Interface]")
	}
	if len(cfg.Peers) == 0 || cfg.Peers[0].PublicKey == "" {
		return nil, errors.New("missing [Peer] with a PublicKey")
	}
	if len(cfg.DNS) == 0 {
		// Resolve inside the tunnel even when the config names no resolver.
		cfg.DNS = []netip.Addr{netip.MustParseAddr("1.1.1.1")}
	}
	return cfg, nil
}

// uapi renders the config in wireguard-go's configuration protocol.
func (c *Config) uapi() (string, error) {
	var b strings.Builder
	k, err := keyHex(c.PrivateKey)
	if err != nil {
		return "", errors.New("invalid PrivateKey")
	}
	fmt.Fprintf(&b, "private_key=%s\n", k)
	if c.ListenPort > 0 {
		fmt.Fprintf(&b, "listen_port=%d\n", c.ListenPort)
	}
	for _, p := range c.Peers {
		pk, err := keyHex(p.PublicKey)
		if err != nil {
			return "", errors.New("invalid peer PublicKey")
		}
		fmt.Fprintf(&b, "public_key=%s\n", pk)
		if p.PresharedKey != "" {
			psk, err := keyHex(p.PresharedKey)
			if err != nil {
				return "", errors.New("invalid PresharedKey")
			}
			fmt.Fprintf(&b, "preshared_key=%s\n", psk)
		}
		if p.Endpoint != "" {
			addr, err := net.ResolveUDPAddr("udp", p.Endpoint)
			if err != nil {
				return "", fmt.Errorf("cannot resolve endpoint %q", p.Endpoint)
			}
			fmt.Fprintf(&b, "endpoint=%s\n", addr.String())
		}
		if p.Keepalive > 0 {
			fmt.Fprintf(&b, "persistent_keepalive_interval=%d\n", p.Keepalive)
		}
		allowed := p.AllowedIPs
		if len(allowed) == 0 {
			allowed = []string{"0.0.0.0/0", "::/0"}
		}
		for _, a := range allowed {
			fmt.Fprintf(&b, "allowed_ip=%s\n", a)
		}
	}
	return b.String(), nil
}

// Tunnel is one running WireGuard device plus its SOCKS5 front door.
type Tunnel struct {
	dev      *device.Device
	net      *netstack.Net
	listener net.Listener
	user     string
	pass     string
	wg       sync.WaitGroup
}

func startTunnel(cfg *Config, user, pass string) (*Tunnel, error) {
	conf, err := cfg.uapi()
	if err != nil {
		return nil, err
	}
	tun, tnet, err := netstack.CreateNetTUN(cfg.Addresses, cfg.DNS, cfg.MTU)
	if err != nil {
		return nil, fmt.Errorf("network stack: %v", err)
	}
	dev := device.NewDevice(tun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""))
	if err := dev.IpcSet(conf); err != nil {
		dev.Close()
		return nil, fmt.Errorf("configuration: %v", err)
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return nil, fmt.Errorf("device: %v", err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		dev.Close()
		return nil, fmt.Errorf("local endpoint: %v", err)
	}
	t := &Tunnel{dev: dev, net: tnet, listener: ln, user: user, pass: pass}
	t.wg.Add(1)
	go t.serve()
	return t, nil
}

func (t *Tunnel) port() int { return t.listener.Addr().(*net.TCPAddr).Port }

func (t *Tunnel) stop() {
	t.listener.Close()
	t.dev.Close()
	t.wg.Wait()
}

// lastHandshake reports the most recent handshake with any peer, as Unix seconds.
func (t *Tunnel) lastHandshake() int64 {
	state, err := t.dev.IpcGet()
	if err != nil {
		return 0
	}
	var latest int64
	for _, line := range strings.Split(state, "\n") {
		if v, ok := strings.CutPrefix(line, "last_handshake_time_sec="); ok {
			if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > latest {
				latest = n
			}
		}
	}
	return latest
}

func (t *Tunnel) serve() {
	defer t.wg.Done()
	for {
		c, err := t.listener.Accept()
		if err != nil {
			return
		}
		go t.handle(c)
	}
}

// handle speaks SOCKS5 with username/password authentication and CONNECT only.
func (t *Tunnel) handle(c net.Conn) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(20 * time.Second))
	head := make([]byte, 2)
	if _, err := io.ReadFull(c, head); err != nil || head[0] != 5 {
		return
	}
	methods := make([]byte, head[1])
	if _, err := io.ReadFull(c, methods); err != nil {
		return
	}
	hasAuth := false
	for _, m := range methods {
		if m == 2 {
			hasAuth = true
		}
	}
	if !hasAuth {
		c.Write([]byte{5, 0xFF})
		return
	}
	c.Write([]byte{5, 2})
	ver := make([]byte, 2)
	if _, err := io.ReadFull(c, ver); err != nil {
		return
	}
	u := make([]byte, ver[1])
	io.ReadFull(c, u)
	pl := make([]byte, 1)
	io.ReadFull(c, pl)
	p := make([]byte, pl[0])
	io.ReadFull(c, p)
	if string(u) != t.user || string(p) != t.pass {
		c.Write([]byte{1, 1})
		return
	}
	c.Write([]byte{1, 0})

	req := make([]byte, 4)
	if _, err := io.ReadFull(c, req); err != nil || req[1] != 1 {
		c.Write([]byte{5, 7, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	var host string
	switch req[3] {
	case 1:
		a := make([]byte, 4)
		io.ReadFull(c, a)
		host = net.IP(a).String()
	case 3:
		l := make([]byte, 1)
		io.ReadFull(c, l)
		n := make([]byte, l[0])
		io.ReadFull(c, n)
		host = string(n)
	case 4:
		a := make([]byte, 16)
		io.ReadFull(c, a)
		host = net.IP(a).String()
	default:
		c.Write([]byte{5, 8, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	pb := make([]byte, 2)
	io.ReadFull(c, pb)
	port := binary.BigEndian.Uint16(pb)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	// Names resolve through the tunnel's own resolver, never this Mac's.
	upstream, err := t.net.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(int(port))))
	if err != nil {
		c.Write([]byte{5, 5, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	defer upstream.Close()
	c.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0})
	c.SetDeadline(time.Time{})
	done := make(chan struct{}, 2)
	go func() { io.Copy(upstream, c); done <- struct{}{} }()
	go func() { io.Copy(c, upstream); done <- struct{}{} }()
	<-done
}

// MARK: - C interface

var (
	mu      sync.Mutex
	current *Tunnel
)

func cstr(s string) *C.char { return C.CString(s) }

//export RavenTunnelStart
func RavenTunnelStart(config, user, pass *C.char, errOut **C.char) C.int {
	mu.Lock()
	defer mu.Unlock()
	if current != nil {
		current.stop()
		current = nil
	}
	cfg, err := ParseConfig(C.GoString(config))
	if err != nil {
		*errOut = cstr(err.Error())
		return 0
	}
	t, err := startTunnel(cfg, C.GoString(user), C.GoString(pass))
	if err != nil {
		*errOut = cstr(err.Error())
		return 0
	}
	current = t
	return C.int(t.port())
}

//export RavenTunnelStop
func RavenTunnelStop() {
	mu.Lock()
	defer mu.Unlock()
	if current != nil {
		current.stop()
		current = nil
	}
}

//export RavenTunnelLastHandshake
func RavenTunnelLastHandshake() C.longlong {
	mu.Lock()
	defer mu.Unlock()
	if current == nil {
		return 0
	}
	return C.longlong(current.lastHandshake())
}

// RavenTunnelDescribe validates a config and returns "endpoint|address" or an error.
//
//export RavenTunnelDescribe
func RavenTunnelDescribe(config *C.char, errOut **C.char) *C.char {
	cfg, err := ParseConfig(C.GoString(config))
	if err != nil {
		*errOut = cstr(err.Error())
		return nil
	}
	return cstr(cfg.Peers[0].Endpoint + "|" + cfg.Addresses[0].String())
}

//export RavenTunnelFree
func RavenTunnelFree(p *C.char) { C.free(unsafe.Pointer(p)) }

func main() {}
