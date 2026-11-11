#!/usr/bin/env bash
# Installs or upgrades the Diz bridge as a systemd service.
#
#   sudo bash install.sh [--tailscale-https[=PORT]] [--no-firewall]
#
#   --tailscale-https[=PORT]  also publish the bridge over HTTPS on your tailnet
#                             with `tailscale serve` (default port 443)
#   --no-firewall             don't add ufw rules, even if ufw is active
#
# Safe to run again: upgrades the program and keeps your configuration.
# (For Docker, see deploy/docker/ in the repository instead.)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX=/opt/diz
CONF_DIR=/etc/diz
CONF_FILE=$CONF_DIR/diz.env
UNIT_FILE=/etc/systemd/system/diz-bridge.service
SERVICE=diz-bridge.service
PUSH_PORT=38900   # fixed in WiZ firmware

TS_HTTPS_PORT=""
CONFIGURE_FIREWALL=1

say()  { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;31mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --tailscale-https)   TS_HTTPS_PORT=443 ;;
    --tailscale-https=*) TS_HTTPS_PORT="${arg#*=}" ;;
    --no-firewall)       CONFIGURE_FIREWALL=0 ;;
    -h|--help)           sed -n '2,11s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *)                   die "unknown option: $arg (see --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "please run as root: sudo bash $0 $*"
command -v systemctl >/dev/null || die "systemd is required"
[[ -f $HERE/diz-bridge ]] || die "the diz-bridge program was not found next to this script"
if [[ -n $TS_HTTPS_PORT && ! $TS_HTTPS_PORT =~ ^[0-9]+$ ]]; then
  die "--tailscale-https port must be a number"
fi

# ---------------------------------------------------------------- arch check
pkg_arch="$(cat "$HERE/ARCH" 2>/dev/null || echo unknown)"
case "$(uname -m)" in
  aarch64|arm64) host_arch=arm64 ;;
  x86_64|amd64)  host_arch=x64 ;;
  *)             host_arch="$(uname -m)" ;;
esac
if [[ $pkg_arch != "$host_arch" ]]; then
  die "this package is for linux-$pkg_arch, but this machine is $(uname -m); use the linux-$host_arch package"
fi

version="$(cat "$HERE/VERSION" 2>/dev/null || echo unknown)"
say "Installing diz-bridge $version"

# ---------------------------------------------------------------- network facts
lan_iface="$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
lan_subnet=""
lan_ip=""
if [[ -n $lan_iface ]]; then
  lan_subnet="$(ip -4 route show dev "$lan_iface" scope link 2>/dev/null | awk '$1 ~ /\// { print $1; exit }')"
  lan_ip="$(ip -4 -o addr show dev "$lan_iface" 2>/dev/null | awk '{ print $4; exit }' | cut -d/ -f1)"
fi
has_tailscale=0
command -v tailscale >/dev/null && has_tailscale=1

# ---------------------------------------------------------------- files
install -d -m 0755 "$PREFIX"
install -m 0755 "$HERE/diz-bridge" "$PREFIX/diz-bridge.new"
mv -f "$PREFIX/diz-bridge.new" "$PREFIX/diz-bridge"
install -m 0755 "$HERE/uninstall.sh" "$PREFIX/uninstall.sh"

install -d -m 0755 "$CONF_DIR"
if [[ -f $CONF_FILE ]]; then
  say "Keeping your configuration in $CONF_FILE"
else
  install -m 0600 "$HERE/diz.env.example" "$CONF_FILE"
  token="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  sed -i "s/^DIZ_API_TOKEN=.*/DIZ_API_TOKEN=$token/" "$CONF_FILE"
  if [[ -n $lan_ip ]]; then
    sed -i "s/^#\{0,1\}DIZ_ADVERTISE_IP=.*/DIZ_ADVERTISE_IP=$lan_ip/" "$CONF_FILE"
  fi
  say "Created $CONF_FILE with a new access token"
fi
# The file holds the access token; systemd reads it as root.
chmod 0600 "$CONF_FILE"

conf_get() { sed -n "s/^[[:space:]]*$1=//p" "$CONF_FILE" | tail -n1 | tr -d "\"'[:space:]"; }
PORT="$(conf_get DIZ_PORT)";  PORT="${PORT:-8787}"
HOST="$(conf_get DIZ_HOST)";  HOST="${HOST:-0.0.0.0}"
[[ -n "$(conf_get DIZ_API_TOKEN)" ]] || warn "DIZ_API_TOKEN is empty in $CONF_FILE: anyone who can reach the bridge can control your lights"
[[ -n "$(conf_get DIZ_ADVERTISE_IP)" ]] || warn "DIZ_ADVERTISE_IP is not set in $CONF_FILE: push updates are off (polling still works)"

install -m 0644 "$HERE/diz-bridge.service" "$UNIT_FILE"
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1
systemctl restart "$SERVICE"

# ---------------------------------------------------------------- firewall (ufw)
if (( CONFIGURE_FIREWALL )) && command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  if [[ -z $lan_subnet ]]; then
    warn "ufw is active but the home network could not be detected; see README.md for the rules to add"
  else
    say "ufw is active: allowing the bridge port and WiZ traffic from $lan_subnet"
    ufw allow proto tcp from "$lan_subnet" to any port "$PORT" comment 'diz-bridge API (LAN)' >/dev/null
    # WiZ bulbs answer discovery broadcasts from port 38899. A stateful firewall
    # does not link those answers to the broadcast, so allow them explicitly.
    ufw allow proto udp from "$lan_subnet" port 38899 comment 'diz-bridge WiZ replies' >/dev/null
    ufw allow proto udp from "$lan_subnet" to any port "$PUSH_PORT" comment 'diz-bridge WiZ status pushes' >/dev/null
    if (( has_tailscale )); then
      ufw allow in on tailscale0 to any port "$PORT" proto tcp comment 'diz-bridge API (tailnet)' >/dev/null
    fi
  fi
fi

# ---------------------------------------------------------------- tailscale https
ts_name=""
if (( has_tailscale )); then
  ts_name="$(tailscale status --json 2>/dev/null | sed -n 's/.*"DNSName": *"\([^"]*\)\.".*/\1/p' | head -n1)"
fi
if [[ -n $TS_HTTPS_PORT ]]; then
  (( has_tailscale )) || die "--tailscale-https needs Tailscale to be installed"
  serve_status="$(tailscale serve status --json 2>/dev/null || true)"
  if grep -q "127.0.0.1:$PORT" <<<"$serve_status"; then
    say "tailscale serve already publishes the bridge"
  elif grep -q "\"$TS_HTTPS_PORT\":" <<<"$serve_status"; then
    warn "tailscale serve already uses HTTPS port $TS_HTTPS_PORT for something else; skipped. Pick another port with --tailscale-https=PORT"
  else
    say "Publishing the bridge on your tailnet over HTTPS (port $TS_HTTPS_PORT)"
    tailscale serve --bg --https="$TS_HTTPS_PORT" "http://127.0.0.1:$PORT" >/dev/null
  fi
fi

# ---------------------------------------------------------------- health check
check_host=127.0.0.1
[[ $HOST != 0.0.0.0 && $HOST != "::" ]] && check_host=$HOST
say "Waiting for the bridge to start"
ok=0
for _ in $(seq 1 20); do
  if command -v curl >/dev/null; then
    if curl -fsS "http://$check_host:$PORT/healthz" >/dev/null 2>&1; then ok=1; break; fi
  elif systemctl is-active --quiet "$SERVICE"; then
    ok=1; break
  fi
  sleep 0.5
done
if (( ok )); then
  say "diz-bridge $version is running"
else
  warn "diz-bridge did not answer yet. Check the log: journalctl -u diz-bridge -n 50"
fi

# ---------------------------------------------------------------- next steps
echo
if [[ -n $TS_HTTPS_PORT && -n $ts_name ]]; then
  suffix=""; [[ $TS_HTTPS_PORT != 443 ]] && suffix=":$TS_HTTPS_PORT"
  echo "Bridge address for the app:  https://$ts_name$suffix"
else
  echo "The bridge listens on http://${lan_ip:-<this machine>}:$PORT. The Android app needs HTTPS:"
  echo "put a TLS reverse proxy in front, or re-run with --tailscale-https."
fi
echo "Access token for the app:    sudo grep DIZ_API_TOKEN $CONF_FILE"
echo
echo "Logs:       journalctl -u diz-bridge -f"
echo "Settings:   $CONF_FILE   (then: sudo systemctl restart diz-bridge)"
echo "Uninstall:  sudo bash $PREFIX/uninstall.sh"
