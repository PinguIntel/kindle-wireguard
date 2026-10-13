// kindle-wireguard (kwg): a minimal wg-quick for Kindle e-readers — userspace WireGuard
// (wireguard-go) on the kernel TUN device; address, routes (split or full tunnel) and DNS
// set via netlink and /etc/resolv.conf. Usage: kwg <wg.conf>; runs until SIGINT/SIGTERM.
package main

import (
	"bufio"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/vishvananda/netlink"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

const resolvConf = "/etc/resolv.conf"

func die(f string, a ...any) { fmt.Fprintf(os.Stderr, "kwg: "+f+"\n", a...); os.Exit(1) }
func warn(f string, a ...any) { fmt.Fprintf(os.Stderr, "kwg: warning: "+f+"\n", a...) }

func key(b64 string) string {
	b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil || len(b) != 32 {
		die("invalid key in config")
	}
	return hex.EncodeToString(b)
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

func main() {
	if len(os.Args) != 2 {
		die("usage: kwg <wg0.conf>")
	}
	f, err := os.Open(os.Args[1])
	if err != nil {
		die("%v", err)
	}
	var priv string
	var addrs, allowed, dns []string
	peer := map[string]string{}
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
		switch sec + k {
		case "[interface]privatekey":
			priv = key(v)
		case "[interface]address":
			addrs = list(v)
		case "[interface]dns":
			for _, d := range list(v) {
				if net.ParseIP(d) != nil {
					dns = append(dns, d)
				}
			}
		case "[peer]allowedips":
			allowed = list(v)
		case "[peer]publickey", "[peer]presharedkey", "[peer]endpoint", "[peer]persistentkeepalive":
			peer[k] = v
		}
	}
	f.Close()
	if priv == "" || peer["publickey"] == "" || peer["endpoint"] == "" {
		die("config needs PrivateKey, PublicKey and Endpoint")
	}
	ep, err := net.ResolveUDPAddr("udp4", peer["endpoint"]) // before DNS is switched
	if err != nil {
		die("endpoint: %v", err)
	}
	var u strings.Builder
	fmt.Fprintf(&u, "private_key=%s\npublic_key=%s\nendpoint=%s\n", priv, key(peer["publickey"]), ep)
	if p := peer["presharedkey"]; p != "" {
		fmt.Fprintf(&u, "preshared_key=%s\n", key(p))
	}
	if p := peer["persistentkeepalive"]; p != "" {
		fmt.Fprintf(&u, "persistent_keepalive_interval=%s\n", p)
	}
	full := false
	for _, a := range allowed {
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

	t, err := tun.CreateTUN("wg0", 1420)
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
	link, err := netlink.LinkByName("wg0")
	if err != nil {
		die("%v", err)
	}
	for _, a := range addrs {
		ad, err := netlink.ParseAddr(a)
		if err != nil {
			die("address %s: %v", a, err)
		}
		if err := netlink.AddrAdd(link, ad); err != nil {
			die("address %s: %v", a, err)
		}
	}
	if err := netlink.LinkSetUp(link); err != nil {
		die("link up: %v", err)
	}
	for _, a := range allowed {
		dsts := []string{a}
		if a == "0.0.0.0/0" {
			dsts = []string{"0.0.0.0/1", "128.0.0.0/1"} // beats the default route without touching it
		}
		for _, d := range dsts {
			_, dst, err := net.ParseCIDR(d)
			if err != nil {
				die("allowed ip %s: %v", d, err)
			}
			if err := netlink.RouteReplace(&netlink.Route{LinkIndex: link.Attrs().Index, Dst: dst}); err != nil {
				die("route %s: %v", d, err)
			}
		}
	}

	if len(dns) > 0 {
		if old, err := os.ReadFile(resolvConf); err != nil {
			warn("can't read %s (%v) — DNS unchanged", resolvConf, err)
		} else {
			var b strings.Builder
			for _, d := range dns {
				fmt.Fprintf(&b, "nameserver %s\n", d)
			}
			if err := os.WriteFile(resolvConf, []byte(b.String()), 0644); err != nil {
				warn("can't write %s (%v) — DNS unchanged", resolvConf, err)
			} else {
				defer os.WriteFile(resolvConf, old, 0644)
			}
		}
	}

	fmt.Printf("kwg: wg0 up (full tunnel: %v, dns: %v)\n", full, dns)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	fmt.Println("kwg: shutting down")
}
