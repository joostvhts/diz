# Diz bridge (systemd package)

The Diz bridge controls your WiZ lights over your home network and gives the
Diz app a small HTTP API. This package installs it as a systemd service on any
always-on Linux machine on the same network as the lights, for example a
Raspberry Pi. (Prefer containers? Use `deploy/docker/` from the repository.)

## Install / upgrade

Requirements: a Linux machine with systemd, 64-bit ARM (`arm64`, e.g. a
Raspberry Pi 3/4/5 running a 64-bit OS) or `x64`.

```sh
tar xzf diz-bridge-*-linux-arm64.tar.gz
sudo bash diz-bridge/install.sh --tailscale-https
```

On first install, the installer creates `/etc/diz/diz.env` with a random
**access token** and this machine's LAN address. Show the token with
`sudo grep DIZ_API_TOKEN /etc/diz/diz.env`. Running the installer again
upgrades the bridge and keeps your settings and light names.

**The Android app only talks HTTPS.** Either put a TLS reverse proxy (Caddy,
nginx, ...) in front of port 8787, or use `--tailscale-https`, which publishes
the bridge on your tailnet at `https://<machine>.<tailnet>.ts.net`.

Options:

| Option | Effect |
|---|---|
| `--tailscale-https[=PORT]` | Publish the bridge over HTTPS on your tailnet with `tailscale serve` (default port 443). |
| `--no-firewall` | Don't add ufw rules, even if ufw is active. |

## Before you start

- In the WiZ app, **Settings → Security → Allow local communication** must be on.
  Without it, the bulbs ignore local control.
- The bridge must be on the same network (subnet) as the bulbs. Discovery uses
  UDP broadcast, which doesn't cross routers or VPNs.

## Settings

Edit `/etc/diz/diz.env`, then run `sudo systemctl restart diz-bridge`.

| Variable | Default | Meaning |
|---|---|---|
| `DIZ_API_TOKEN` | (generated) | Bearer token the app must send; at least 16 characters. |
| `DIZ_API_TOKEN_FILE` | - | Read the token from this file instead. |
| `DIZ_ADVERTISE_IP` | (detected) | This machine's LAN IP; lights push status changes to it on UDP 38900. Unset = no push. |
| `DIZ_HOST` | `0.0.0.0` | Address to listen on. |
| `DIZ_PORT` | `8787` | HTTP port. |
| `DIZ_BROADCAST` | `255.255.255.255` | Where discovery probes go; `off` disables discovery. |
| `DIZ_BULBS` | - | Extra bulb IPs, comma-separated (`ip` or `ip:port`). |
| `DIZ_DISCOVERY_INTERVAL` | `300` | Seconds between automatic discovery runs. |
| `DIZ_WEB_ROOT` | - | Serve a web UI from this directory at `/`. |

Light names and the list of known bulbs are kept in `/var/lib/diz/lights.json`.

## Troubleshooting

- **Logs:** `journalctl -u diz-bridge -f`
- **Is it running?** `curl http://localhost:8787/healthz`
- **List lights:** `curl -H "Authorization: Bearer $TOKEN" http://localhost:8787/api/lights`
- **No lights found:**
  - Check that "Allow local communication" is on.
  - Set `DIZ_BROADCAST` to your subnet's broadcast address (e.g. `192.168.1.255`), or list the bulbs in `DIZ_BULBS`.
  - With a firewall other than ufw, allow incoming UDP *from source port* 38899 and *to port* 38900 on the LAN.
- **"is pushing status updates" never appears in the log:** check `DIZ_ADVERTISE_IP`
  and that UDP 38900 is open from the LAN. Everything still works without push, by polling.

## Uninstall

```sh
sudo bash /opt/diz/uninstall.sh          # keeps settings and light names
sudo bash /opt/diz/uninstall.sh --purge  # removes everything
```
