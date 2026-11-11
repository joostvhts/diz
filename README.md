# Diz

Local control for WiZ smart lights, without the cloud and without an account.

Diz is two small pieces:

- **diz-bridge**, a service on an always-on machine (e.g. a Raspberry Pi) on the
  same network as your lights. It talks to the bulbs with WiZ's local UDP
  protocol and receives the status changes they push.
- **the Diz app** (Android; the same code also runs as a web UI). It talks to
  the bridge over HTTPS, at home or from anywhere through a VPN such as Tailscale.

```
Phone / browser ──HTTPS──▶ reverse proxy ──HTTP──▶ diz-bridge :8787 ──UDP 38899──▶ WiZ bulbs
                                                   diz-bridge :38900 ◀──UDP push── WiZ bulbs
```

## Features

- Control all lights at once, or one at a time
- On/off and brightness (10-100%)
- White color temperature (e.g. 2200-6500 K, per bulb) with presets
- RGB color wheel and color swatches
- Status pushed by the bulbs, so changes from wall switches or remotes show up
- Bearer-token authentication
- Adapts to each bulb: full color, tunable white, dimmable-only, smart plugs
- Lost UDP packets are retried; slider drags are coalesced so bulbs aren't flooded

Not yet: scenes, schedules/wake-up, live updates to the app (see [Roadmap](#roadmap)).

## Requirements

- WiZ lights with **Allow local communication** enabled (WiZ app → Settings → Security).
- An always-on Linux machine on the **same network (subnet)** as the lights:
  64-bit ARM (e.g. Raspberry Pi 3/4/5 with a 64-bit OS) or x64.
- HTTPS in front of the bridge (a reverse proxy such as Caddy, or `tailscale serve`).
  The Android app doesn't accept plain HTTP.
- An Android phone.

## Install the bridge with Docker (recommended)

The image is built from this repository (multi-arch: `linux/arm64`, `linux/amd64`).
It runs as a non-root user on a read-only file system and needs about 15 MB of RAM.

1. Copy [deploy/docker/compose.yaml](deploy/docker/compose.yaml) and
   [deploy/docker/.env.example](deploy/docker/.env.example) (as `.env`) next to
   each other and fill in the `CHANGEME` values: the host's LAN IP, the lamps'
   IP addresses, and an access token (`openssl rand -hex 32`).
2. Point your reverse proxy at the container, e.g. in a Caddyfile:
   ```
   lights.example.com {
       reverse_proxy diz-bridge:8787
   }
   ```
3. `docker compose up -d`, then check `docker logs diz-bridge`.

| | |
|---|---|
| Container | `diz-bridge` |
| HTTP | `8787/tcp`, plain HTTP inside the container. Don't publish it; let the proxy reach it over a shared Docker network. |
| Push | `38900/udp`. Publish it on the host's LAN IP: `"${LAN_IP}:38900:38900/udp"`. The bulbs always send to 38900. |
| State | `/data` (`lights.json`: light names, known bulbs). Use a volume. |
| Health | `GET /healthz` (no auth), plus a built-in `HEALTHCHECK`. |

In a container on a bridge network, broadcast discovery can't reach the LAN, so
list the bulbs in `DIZ_BULBS` (give them fixed IPs). The bridge tells the bulbs
to push to `DIZ_ADVERTISE_IP`, which must be the host's LAN IP, not the
container's.

## Install the bridge without Docker

A systemd package for Raspberry Pi OS / Debian / Ubuntu: see
[deploy/pkg/README.md](deploy/pkg/README.md). Build it with
`bash deploy/build_release.sh`.

## Install the app

Install `diz-<version>.apk` on your phone (allow installs from unknown sources),
open it, and enter the bridge's HTTPS address (e.g. `lights.example.com`) and
the access token. Both can be changed later under Settings → Change.

To pre-fill the address for your own builds:
`flutter build apk --dart-define=DIZ_BRIDGE_URL=https://lights.example.com`
(never put the token in a build).

## Configuration

All settings are environment variables (flags with the same names also work,
except the token, which is environment-only):

| Variable | Default | Meaning |
|---|---|---|
| `DIZ_API_TOKEN` | - | Bearer token required on `/api`; at least 16 characters. Unset = no auth (a warning is logged). |
| `DIZ_API_TOKEN_FILE` | - | Read the token from a file (e.g. a Docker secret). |
| `DIZ_ADVERTISE_IP` | - | The host's LAN IPv4; bulbs push status changes to it on UDP 38900. Unset = no push, polling only. |
| `DIZ_BULBS` | - | Bulb IPs, comma-separated (`ip` or `ip:port`). |
| `DIZ_BROADCAST` | `255.255.255.255` (image: `off`) | Discovery broadcast address, or `off`. |
| `DIZ_HOST` / `DIZ_PORT` | `0.0.0.0` / `8787` | HTTP listen address and port. |
| `DIZ_STATE_DIR` | `diz-state` (image: `/data`) | Where `lights.json` is kept. |
| `DIZ_DISCOVERY_INTERVAL` | `300` | Seconds between discovery runs. |
| `DIZ_WEB_ROOT` | - | Serve a web UI from this directory at `/`. |

## HTTP API

JSON under `/api`, with `Authorization: Bearer <token>` when a token is configured.

| Method | Path | Purpose |
|---|---|---|
| GET | `/healthz` | liveness, no auth: `{"status":"ok"}` |
| GET | `/api/health` | name, version, `apiVersion`, number of lights |
| GET | `/api/lights` | all lights with capabilities and live state |
| POST | `/api/lights/{id}/state` | change one light |
| POST | `/api/group/state` | change all online lights (optional `"ids": [...]`) |
| PATCH | `/api/lights/{id}` | rename: `{"name": "Desk"}` |
| POST | `/api/discover` | search for new lights now |

A state change contains any of `on`, `brightness` (10-100), `kelvin`, or
`rgb` (`{"r":255,"g":0,"b":128}`; not together with `kelvin`). Changing
brightness or color also turns the light on. Light ids are the bulbs' MAC addresses.

```sh
curl -X POST https://lights.example.com/api/group/state \
     -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
     -d '{"kelvin": 2700, "brightness": 40}'
```

The app polls `/api/lights` every 5 seconds while it is open; there are no
WebSockets or server-sent events (yet).

## Development

A Dart [pub workspace](https://dart.dev/tools/pub/workspaces):

```
packages/diz_core/   shared models and API types (pure Dart, web-safe)
bridge/              the bridge (Dart, shelf); tool/fake_bulb.dart simulates bulbs
app/                 the Flutter app (Android + web)
deploy/docker/       example compose.yaml and .env.example
deploy/pkg/          systemd install package; deploy/build_release.sh builds it
Dockerfile           the bridge image
```

Requires the Flutter SDK (3.41+, which includes Dart 3.11+).

```sh
flutter pub get                                   # once, at the repo root

# Tests
(cd packages/diz_core && dart test)
(cd bridge && dart test)
(cd app && flutter test)

# Run without real lights: start fake bulbs, then the bridge with the printed command
(cd bridge && dart run tool/fake_bulb.dart --count 3)
(cd bridge && dart run bin/diz_bridge.dart --broadcast off --dev-cors \
              --bulbs 127.0.0.1:38901,127.0.0.1:38902,127.0.0.1:38903)

# Run the app against it. Debug builds accept plain http://, release builds don't.
# (Android emulator: the bridge address is http://10.0.2.2:8787)
(cd app && flutter run)

# Or as a web UI (enter http://localhost:8787 on the setup screen)
(cd app && flutter run -d web-server --web-port 8080)

# Docker image
docker build -t diz-bridge:dev .
docker buildx build --platform linux/arm64 -t diz-bridge:dev-arm64 .
```

**Web UI served by the bridge:** `flutter build web --no-web-resources-cdn` in
`app/`, make `app/build/web` available to the bridge and set `DIZ_WEB_ROOT` to
it. The app then opens at the bridge's own address and connects to it automatically.

## Roadmap

- WiZ scenes and dynamic modes
- Live updates to the app (server-sent events), now that bulbs push their status
- Schedules and wake-up light, run by the bridge
- Android quick-settings tile / home-screen widget for "all on/off"
- CI-built images and releases

## License

Public domain, under [The Unlicense](LICENSE).

## Disclaimer

Diz is an independent project, not affiliated with or endorsed by WiZ or
Signify. WiZ is a trademark of Signify Holding. Diz uses the bulbs' local
network protocol; a future firmware update could change or restrict it.
