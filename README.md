# kindle-wireguard (`kwg`)

WireGuard for Kindle e-readers — a single static binary that brings up a WireGuard tunnel
from a standard `wg-quick` config, without the WireGuard kernel module, `wg` or `ip`.

Kindle kernels don't ship WireGuard, but they do have TUN. `kwg` runs
[`wireguard-go`](https://git.zx2c4.com/wireguard-go) (the userspace implementation) on the
TUN device and sets the interface address, routes and DNS itself via netlink — so it works
with nothing but what's already on the device.

Use it to reach your self-hosted services from the Kindle — an OPDS catalog (Calibre-Web,
Kavita, …) for KOReader, a KOReader sync server, or your whole home network — from anywhere.

## Requirements

- A **rooted/jailbroken Kindle** with a root shell (e.g. KOReader's SSH server or USBNetwork).
  This project does not cover how to get there.
- Kernel with TUN support. Check on the device:
  ```
  ls -l /dev/net/tun; zcat /proc/config.gz | grep CONFIG_TUN
  ```
- An ARMv7 Kindle (`uname -m` → `armv7l`).

Running on a **Kindle Paperwhite (12th generation, 2024)**: firmware 5.19.5, kernel
5.15.41-lab126, armv7l — full tunnel home, autostarted at boot.

## KOReader plugin (easiest)

`kwg.koplugin.zip` from the [releases](../../releases) contains the plugin, the `kwg` binary
and the watchdog.

1. Unzip it into KOReader's plugin folder, so you get `koreader/plugins/kwg.koplugin/`
   (over USB that's `koreader/plugins/` on the Kindle drive; over SSH `/mnt/us/koreader/plugins/`).
2. Put your WireGuard client config (any `*.conf`, a normal `wg-quick` file — see
   [`example.conf`](example.conf)) into that `kwg.koplugin/` folder.
3. Restart KOReader. The config is imported to `/var/local/kwg/wg.conf` — internal storage,
   **not** visible over USB — and removed from the plugin folder.

Then, in KOReader: **Settings (⚙) → Network → WireGuard**:

- **Status line** — tunnel up/off, tunnel address, last handshake; tap for traffic details.
- **Tunnel on** — start/stop. The tunnel keeps running when you leave KOReader.
- **Start at boot** — installs the upstart job and starts the tunnel at every boot.
- **Settings** — edit single values: tunnel address, DNS, server endpoint, server public key,
  routed networks (`AllowedIPs`), keepalive, preshared key; enter or generate the private key;
  show this Kindle's public key.
- **Edit config as text** — the whole config in an editor, or type one from scratch. The
  private key is shown as `<unchanged>`; leave it to keep the current key.
- **Import config file** — pick a `.conf` anywhere on the Kindle (offers to delete it from the
  USB storage afterwards).
- **Show log**

Every save is checked (`kwg check`); a running tunnel is restarted with the new config. The
previous config is kept as `/var/local/kwg/wg.conf.bak`.

No SSH needed after the install — KOReader on a rooted Kindle runs as root, so the plugin can
manage the tunnel and the upstart job itself. To remove it: turn the tunnel and *Start at boot* off, delete `kwg.koplugin/`, then
`mntroot rw; rm /etc/upstart/kwg.conf; mntroot ro` (or leave the job — without the plugin
folder it does nothing).

## Command line

```
kwg up <wg.conf>       bring the tunnel up; runs until SIGINT/SIGTERM (also: kwg <wg.conf>)
kwg status             tunnel state, last handshake, traffic
kwg check <wg.conf>    validate a config
kwg genkey             print a new private key
kwg pubkey [wg.conf]   public key of the config's PrivateKey (or of a private key on stdin)
```

## Build

Needs Go (any OS):

```
make            # kwg — CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build …
make plugin     # dist/kwg.koplugin.zip
```

Or grab `kwg` / `kwg.koplugin.zip` from the [releases](../../releases). Releases are built by
GitHub Actions from the tagged source (`.github/workflows/release.yml`).

## Manual install (without the plugin)

Copy `kwg` and your WireGuard client config to the Kindle (KOReader's SSH server listens on
port 2222):

```
ssh -p 2222 root@<kindle-ip> mkdir -p /mnt/us/kwg
scp -P 2222 kwg wg.conf root@<kindle-ip>:/mnt/us/kwg/
```

The config is a normal `wg-quick` file — see [`example.conf`](example.conf).

## Run

```
# start (detached from the shell / KOReader, so it keeps running in the stock UI too)
setsid nohup /mnt/us/kwg/kwg up /mnt/us/kwg/wg.conf > /mnt/us/kwg/kwg.log 2>&1 < /dev/null &

# check
cat /mnt/us/kwg/kwg.log      # kwg: wg0 up (full tunnel: true, dns: [...])
ip route

# stop — removes wg0 and restores routes and /etc/resolv.conf
killall kwg
```

## Autostart + watchdog (manual install)

[`kwg-loop.sh`](kwg-loop.sh) waits for Wi-Fi, starts `kwg`, and restarts it when it exits,
when Wi-Fi drops, or when the default gateway changes (another network).
[`kwg.upstart`](kwg.upstart) is an upstart job that runs the loop at boot
(`start on framework_ready`) and respawns it if it dies.

```
scp -P 2222 kwg-loop.sh kwg.upstart root@<kindle-ip>:/mnt/us/kwg/
# on the Kindle:
mntroot rw
cp /mnt/us/kwg/kwg.upstart /etc/upstart/kwg.conf
mntroot ro
start kwg
```

Control it with upstart (a plain `killall kwg` just gets restarted by the loop):

```
status kwg     # kwg start/running
stop kwg       # tunnel off — routes and /etc/resolv.conf restored
start kwg      # tunnel on
```

`stop kwg` lasts until the next reboot. To remove the autostart:
`mntroot rw; rm /etc/upstart/kwg.conf; mntroot ro`.

The loop logs to `/mnt/us/kwg/kwg.log` and trims it to the last 200 lines when it passes 200 KB.

## What it does

From `[Interface]` it uses `PrivateKey`, `Address` and `DNS`; from `[Peer]` it uses
`PublicKey`, `PresharedKey`, `Endpoint`, `AllowedIPs` and `PersistentKeepalive`.

- **Split tunnel** (`AllowedIPs = 192.168.1.0/24, …`): a route per entry via `wg0`.
- **Full tunnel** (`AllowedIPs = 0.0.0.0/0`): routes `0.0.0.0/1` and `128.0.0.0/1` via `wg0`
  (they beat the default route without replacing it), plus a host route to the endpoint via
  the current gateway so the WireGuard packets themselves still leave over Wi-Fi.
- **DNS**: the `DNS =` servers are written to `/etc/resolv.conf` while the tunnel runs; the
  original file is restored on exit.

## Limits

- **IPv4 only.** IPv6 entries are ignored; on a network with IPv6, IPv6 traffic bypasses the tunnel.
- **Changing Wi-Fi networks:** the endpoint route points at the gateway that was current at
  start. The watchdog restarts `kwg` when the gateway changes; without it, restart by hand.
- **DNS overwrite:** a DHCP renewal may rewrite `/etc/resolv.conf`. Restart `kwg` if names stop
  resolving through the tunnel (`stop kwg; start kwg`).
- **Private key on USB storage (manual install):** `/mnt/us` is what a computer sees when the
  Kindle is plugged in, so a config kept there is readable. The plugin keeps it in `/var/local/kwg/`.
- One tunnel (`wg0`), one peer.

## License

MIT — see [LICENSE](LICENSE). Uses [wireguard-go](https://git.zx2c4.com/wireguard-go) (MIT)
and [vishvananda/netlink](https://github.com/vishvananda/netlink) (Apache-2.0).
WireGuard is a registered trademark of Jason A. Donenfeld; this project is not affiliated
with the WireGuard project or with Amazon.
