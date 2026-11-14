package main

// Self-test for the app's --self-test: two WireGuard peers on loopback. One
// plays the VPN provider and runs an echo service inside its tunnel; the other
// is a Raven Tunnel built from a wg-quick config. A connection through the
// Raven Tunnel's SOCKS5 endpoint must reach the echo service.

import "C"

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"time"

	"golang.org/x/crypto/curve25519"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

func keypair() (priv, pub []byte) {
	priv = make([]byte, 32)
	rand.Read(priv)
	priv[0] &= 248
	priv[31] = (priv[31] & 127) | 64
	pub, _ = curve25519.X25519(priv, curve25519.Basepoint)
	return
}

func freeUDPPort() int {
	c, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		return 51820
	}
	defer c.Close()
	return c.LocalAddr().(*net.UDPAddr).Port
}

func selfTest() error {
	serverPriv, serverPub := keypair()
	clientPriv, clientPub := keypair()
	serverPort := freeUDPPort()

	// The provider side.
	stun, snet, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.66.0.1")}, nil, 1420)
	if err != nil {
		return err
	}
	sdev := device.NewDevice(stun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""))
	defer sdev.Close()
	if err := sdev.IpcSet(fmt.Sprintf("private_key=%s\nlisten_port=%d\npublic_key=%s\nallowed_ip=10.66.0.2/32\n",
		hex.EncodeToString(serverPriv), serverPort, hex.EncodeToString(clientPub))); err != nil {
		return err
	}
	if err := sdev.Up(); err != nil {
		return err
	}
	ln, err := snet.ListenTCP(&net.TCPAddr{IP: net.IPv4(10, 66, 0, 1), Port: 7000})
	if err != nil {
		return err
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()

	// The Raven side, from a config file as a provider would issue it.
	conf := fmt.Sprintf(`[Interface]
PrivateKey = %s
Address = 10.66.0.2/32
DNS = 10.66.0.1

[Peer]
PublicKey = %s
Endpoint = 127.0.0.1:%d
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
`, base64.StdEncoding.EncodeToString(clientPriv), base64.StdEncoding.EncodeToString(serverPub), serverPort)
	cfg, err := ParseConfig(conf)
	if err != nil {
		return fmt.Errorf("parse: %v", err)
	}
	t, err := startTunnel(cfg, "raven", "secret")
	if err != nil {
		return fmt.Errorf("start: %v", err)
	}
	defer t.stop()

	// Wrong credentials are refused by the local endpoint.
	if c, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", t.port())); err == nil {
		c.Write([]byte{5, 1, 2})
		r := make([]byte, 2)
		io.ReadFull(c, r)
		c.Write(append(append([]byte{1, 5}, "raven"...), append([]byte{5}, "wrong"...)...))
		io.ReadFull(c, r)
		c.Close()
		if r[1] == 0 {
			return errors.New("local endpoint accepted a wrong password")
		}
	}

	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", t.port()), 5*time.Second)
	if err != nil {
		return err
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(10 * time.Second))
	c.Write([]byte{5, 1, 2})
	r := make([]byte, 2)
	if _, err := io.ReadFull(c, r); err != nil || r[1] != 2 {
		return errors.New("socks greeting")
	}
	c.Write(append(append([]byte{1, 5}, "raven"...), append([]byte{6}, "secret"...)...))
	if _, err := io.ReadFull(c, r); err != nil || r[1] != 0 {
		return errors.New("socks auth")
	}
	c.Write([]byte{5, 1, 0, 1, 10, 66, 0, 1, 0x1B, 0x58}) // 10.66.0.1:7000
	reply := make([]byte, 10)
	if _, err := io.ReadFull(c, reply); err != nil || reply[1] != 0 {
		return fmt.Errorf("connect through tunnel failed (%v)", reply[1])
	}
	c.Write([]byte("raven"))
	echo := make([]byte, 5)
	if _, err := io.ReadFull(c, echo); err != nil || string(echo) != "raven" {
		return errors.New("echo through tunnel")
	}
	if t.lastHandshake() == 0 {
		return errors.New("no handshake recorded")
	}
	return nil
}

//export RavenTunnelSelfTest
func RavenTunnelSelfTest() *C.char {
	if err := selfTest(); err != nil {
		return C.CString(err.Error())
	}
	return nil
}
