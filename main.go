// kindle-wireguard (kwg): a minimal wg-quick for Kindle e-readers — userspace WireGuard
// (wireguard-go) on the kernel TUN device; address, routes (split or full tunnel) and DNS
// set via netlink and /etc/resolv.conf.
package main

import (
	"bufio"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/vishvananda/netlink"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/ipc"
	"golang.zx2c4.com/wireguard/tun"
)

const (
	iface      = "wg0"
	resolvConf = "/etc/resolv.conf"
	sockPath   = "/var/run/wireguard/" + iface + ".sock"
)

const usage = `usage:
  kwg up <wg.conf>       bring the tunnel up; runs until SIGINT/SIGTERM (also: kwg <wg.conf>)
  kwg status             tunnel state, last handshake, traffic
  kwg check <wg.conf>    validate a config
  kwg genkey             print a new private key
  kwg pubkey [wg.conf]   print the public key (of the config's PrivateKey, or a private key on stdin)`

func die(f string, a ...any)  { fmt.Fprintf(os.Stderr, "kwg: "+f+"\n", a...); os.Exit(1) }
func warn(f string, a ...any) { fmt.Fprintf(os.Stderr, "kwg: warning: "+f+"\n", a...) }

type config struct {
	priv, pub, psk []byte
	endpoint       string
	keepalive      string
	addrs, allowed []string
	dns            []string
}

func decodeKey(name, b64 string) ([]byte, error) {
	b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil || len(b) != 32 {
		return nil, fmt.Errorf("%s is not a valid key (expected 44 base64 characters)", name)
	}
	return b, nil
}

// list splits a comma list, keeping IPv4 entries only.
func list(v string) []string {
	var out []string
	for _, a := range strings.Split(v, ",") {
		if a = strings.TrimSpace(a); a != "" && !strings.Contains(a, ":") {
			out = append(out, a)
		}
	}
	return out
}

func parseConfig(path string) (*config, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	c := &config{}
	sec := ""
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		l := strings.TrimSpace(strings.SplitN(sc.Text(), "#", 2)[0])
		if l == "" {
			continue
		}
		if strings.HasPrefix(l, "[") {
			sec = strings.ToLower(l)
			continue
		}
		kv := strings.SplitN(l, "=", 2)
		if len(kv) != 2 {
			continue
		}
		k, v := strings.ToLower(strings.TrimSpace(kv[0])), strings.TrimSpace(kv[1])
		if v == "" {
			continue // "Key =" with no value counts as missing
		}
		switch sec + k {
		case "[interface]privatekey":
			if c.priv, err = decodeKey("PrivateKey", v); err != nil {
				return nil, err
			}
		case "[interface]address":
			c.addrs = list(v)
		case "[interface]dns":
			for _, d := range list(v) {
				if net.ParseIP(d) == nil {
					return nil, fmt.Errorf("DNS %q is not an IPv4 address", d)
				}
				c.dns = append(c.dns, d)
			}
		case "[peer]publickey":
			if c.pub, err = decodeKey("PublicKey", v); err != nil {
				return nil, err
			}
		case "[peer]presharedkey":
			if c.psk, err = decodeKey("PresharedKey", v); err != nil {
				return nil, err
			}
		case "[peer]endpoint":
			c.endpoint = v
		case "[peer]allowedips":
			c.allowed = list(v)
		case "[peer]persistentkeepalive":
			if n, err := strconv.Atoi(v); err != nil || n < 0 || n > 65535 {
				return nil, fmt.Errorf("PersistentKeepalive %q is not a number of seconds", v)
			}
			c.keepalive = v
		}
	}
	if err := sc.Err(); err != nil {
		return nil, errors.New("not a WireGuard config (unreadable line)")
	}
	switch {
	case c.priv == nil:
		return nil, errors.New("config needs [Interface] PrivateKey")
	case c.pub == nil:
		return nil, errors.New("config needs [Peer] PublicKey")
	case c.endpoint == "":
		return nil, errors.New("config needs [Peer] Endpoint")
	case len(c.addrs) == 0:
		return nil, errors.New("config needs an IPv4 [Interface] Address")
	case len(c.allowed) == 0:
		return nil, errors.New("config needs [Peer] AllowedIPs")
	}
	if _, _, err := net.SplitHostPort(c.endpoint); err != nil {
		return nil, fmt.Errorf("Endpoint %q must be host:port", c.endpoint)
	}
	for _, a := range c.addrs {
		if _, err := netlink.ParseAddr(a); err != nil {
			return nil, fmt.Errorf("Address %q is not an IPv4 address/prefix", a)
		}
	}
	for _, a := range c.allowed {
		if _, _, err := net.ParseCIDR(a); err != nil {
			return nil, fmt.Errorf("AllowedIPs entry %q is not a network (e.g. 10.0.0.0/24)", a)
		}
	}
	return c, nil
}

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		die("%s", usage)
	}
	switch args[0] {
	case "up":
		if len(args) != 2 {
			die("%s", usage)
		}
		up(args[1])
	case "status":
		os.Exit(status())
	case "check":
		if len(args) != 2 {
			die("%s", usage)
		}
		if _, err := parseConfig(args[1]); err != nil {
			die("%v", err)
		}
		fmt.Println("ok")
	case "genkey":
		k, err := ecdh.X25519().GenerateKey(rand.Reader)
		if err != nil {
			die("%v", err)
		}
		fmt.Println(base64.StdEncoding.EncodeToString(k.Bytes()))
	case "pubkey":
		pubkey(args[1:])
	case "-h", "--help", "help":
		fmt.Println(usage)
	default:
		if len(args) == 1 && !strings.HasPrefix(args[0], "-") {
			up(args[0]) // kwg <wg.conf>, as in v0.1
			return
		}
		die("%s", usage)
	}
}

func pubkey(args []string) {
	var priv []byte
	var err error
	switch len(args) {
	case 0:
		b, rerr := io.ReadAll(io.LimitReader(os.Stdin, 1024))
		if rerr != nil {
			die("%v", rerr)
		}
		priv, err = decodeKey("private key", string(b))
	case 1:
		// only the PrivateKey is needed, so this also works on an incomplete config
		priv, err = privFromFile(args[0])
	default:
		die("%s", usage)
	}
	if err != nil {
		die("%v", err)
	}
	k, err := ecdh.X25519().NewPrivateKey(priv)
	if err != nil {
		die("%v", err)
	}
	fmt.Println(base64.StdEncoding.EncodeToString(k.PublicKey().Bytes()))
}

func privFromFile(path string) ([]byte, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	for _, l := range strings.Split(string(b), "\n") {
		kv := strings.SplitN(strings.SplitN(l, "#", 2)[0], "=", 2)
		if len(kv) == 2 && strings.EqualFold(strings.TrimSpace(kv[0]), "PrivateKey") {
			return decodeKey("PrivateKey", kv[1])
		}
	}
	return nil, errors.New("no PrivateKey in " + path)
}

// status prints "key: value" lines (parsed by the KOReader plugin). Exit code 0 = up, 3 = down.
func status() int {
	c, err := net.DialTimeout("unix", sockPath, 2*time.Second)
	if err != nil {
		fmt.Println("state: down")
		return 3
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := io.WriteString(c, "get=1\n\n"); err != nil {
		die("status: %v", err)
	}
	v := map[string]string{}
	sc := bufio.NewScanner(c)
	for sc.Scan() {
		l := sc.Text()
		if l == "" {
			break
		}
		if kv := strings.SplitN(l, "=", 2); len(kv) == 2 {
			v[kv[0]] = kv[1] // single peer: no key collisions that matter here
		}
	}
	fmt.Println("state: up")
	if link, err := netlink.LinkByName(iface); err == nil {
		if addrs, err := netlink.AddrList(link, netlink.FAMILY_V4); err == nil && len(addrs) > 0 {
			fmt.Println("address:", addrs[0].IPNet)
		}
	}
	if e := v["endpoint"]; e != "" {
		fmt.Println("endpoint:", e)
	}
	if hs, _ := strconv.ParseInt(v["last_handshake_time_sec"], 10, 64); hs == 0 {
		fmt.Println("handshake: never")
	} else {
		fmt.Println("handshake:", time.Since(time.Unix(hs, 0)).Round(time.Second), "ago")
	}
	rx, _ := strconv.ParseUint(v["rx_bytes"], 10, 64)
	tx, _ := strconv.ParseUint(v["tx_bytes"], 10, 64)
	fmt.Println("received:", human(rx))
	fmt.Println("sent:", human(tx))
	return 0
}

func human(b uint64) string {
	const u = 1024
	if b < u {
		return fmt.Sprintf("%d B", b)
	}
	d, e := uint64(u), 0
	for n := b / u; n >= u; n /= u {
		d *= u
		e++
	}
	return fmt.Sprintf("%.1f %ciB", float64(b)/float64(d), "KMGTPE"[e])
}

func up(path string) {
	c, err := parseConfig(path)
	if err != nil {
		die("%v", err)
	}
	ep, err := net.ResolveUDPAddr("udp4", c.endpoint) // before DNS is switched
	if err != nil {
		die("endpoint: %v", err)
	}
	var u strings.Builder
	fmt.Fprintf(&u, "private_key=%s\npublic_key=%s\nendpoint=%s\n", hex.EncodeToString(c.priv), hex.EncodeToString(c.pub), ep)
	if c.psk != nil {
		fmt.Fprintf(&u, "preshared_key=%s\n", hex.EncodeToString(c.psk))
	}
	if c.keepalive != "" {
		fmt.Fprintf(&u, "persistent_keepalive_interval=%s\n", c.keepalive)
	}
	full := false
	for _, a := range c.allowed {
		fmt.Fprintf(&u, "allowed_ip=%s\n", a)
		if a == "0.0.0.0/0" {
			full = true
		}
	}

	// Full tunnel: keep the WireGuard packets themselves on Wi-Fi.
	if full {
		routes, err := netlink.RouteList(nil, netlink.FAMILY_V4)
		if err != nil {
			die("route list: %v", err)
		}
		var def *netlink.Route
		for i := range routes {
			r := &routes[i]
			if r.Gw != nil && (r.Dst == nil || r.Dst.String() == "0.0.0.0/0") {
				def = r
				break
			}
		}
		if def == nil {
			die("no default route — is Wi-Fi connected?")
		}
		epRoute := &netlink.Route{Dst: &net.IPNet{IP: ep.IP, Mask: net.CIDRMask(32, 32)}, Gw: def.Gw, LinkIndex: def.LinkIndex}
		if err := netlink.RouteReplace(epRoute); err != nil {
			die("endpoint route: %v", err)
		}
		defer netlink.RouteDel(epRoute)
	}

	t, err := tun.CreateTUN(iface, 1420)
	if err != nil {
		die("tun: %v", err)
	}
	dev := device.NewDevice(t, conn.NewDefaultBind(), device.NewLogger(device.LogLevelError, "kwg: "))
	defer dev.Close()
	if err := dev.IpcSet(u.String()); err != nil {
		die("config: %v", err)
	}
	if err := dev.Up(); err != nil {
		die("up: %v", err)
	}

	// Status socket, same path as wireguard-go/wg (/var/run/wireguard/wg0.sock), for `kwg status`.
	if f, err := ipc.UAPIOpen(iface); err != nil {
		warn("status socket: %v", err)
	} else if l, err := ipc.UAPIListen(iface, f); err != nil {
		warn("status socket: %v", err)
	} else {
		defer l.Close()
		go func() {
			for {
				c, err := l.Accept()
				if err != nil {
					return
				}
				go dev.IpcHandle(c)
			}
		}()
	}

	link, err := netlink.LinkByName(iface)
	if err != nil {
		die("%v", err)
	}
	for _, a := range c.addrs {
		ad, _ := netlink.ParseAddr(a) // validated in parseConfig
		if err := netlink.AddrAdd(link, ad); err != nil {
			die("address %s: %v", a, err)
		}
	}
	if err := netlink.LinkSetUp(link); err != nil {
		die("link up: %v", err)
	}
	for _, a := range c.allowed {
		dsts := []string{a}
		if a == "0.0.0.0/0" {
			dsts = []string{"0.0.0.0/1", "128.0.0.0/1"} // beats the default route without touching it
		}
		for _, d := range dsts {
			_, dst, _ := net.ParseCIDR(d)
			if err := netlink.RouteReplace(&netlink.Route{LinkIndex: link.Attrs().Index, Dst: dst}); err != nil {
				die("route %s: %v", d, err)
			}
		}
	}

	if len(c.dns) > 0 {
		if old, err := os.ReadFile(resolvConf); err != nil {
			warn("can't read %s (%v) — DNS unchanged", resolvConf, err)
		} else {
			var b strings.Builder
			for _, d := range c.dns {
				fmt.Fprintf(&b, "nameserver %s\n", d)
			}
			if err := os.WriteFile(resolvConf, []byte(b.String()), 0644); err != nil {
				warn("can't write %s (%v) — DNS unchanged", resolvConf, err)
			} else {
				defer os.WriteFile(resolvConf, old, 0644)
			}
		}
	}

	fmt.Printf("kwg: %s up (full tunnel: %v, dns: %v)\n", iface, full, c.dns)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	fmt.Println("kwg: shutting down")
}
