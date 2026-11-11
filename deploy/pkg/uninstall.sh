#!/usr/bin/env bash
# Removes the Diz bridge service.
#
#   sudo bash uninstall.sh [--purge]
#
#   --purge   also delete the configuration (/etc/diz) and light names (/var/lib/diz)
set -euo pipefail

PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge)   PURGE=1 ;;
    -h|--help) sed -n '2,6s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *)         echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "please run as root: sudo bash $0 $*" >&2; exit 1; }

PORT="$(sed -n 's/^[[:space:]]*DIZ_PORT=//p' /etc/diz/diz.env 2>/dev/null | tail -n1 | tr -d "\"'[:space:]")"
PORT="${PORT:-8787}"

systemctl disable --now diz-bridge.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/diz-bridge.service
systemctl daemon-reload
rm -rf /opt/diz

# Firewall rules added by install.sh are tagged with a "diz-bridge" comment.
if command -v ufw >/dev/null; then
  while num="$(ufw status numbered 2>/dev/null | grep 'diz-bridge' | head -n1 | sed -n 's/^\[ *\([0-9][0-9]*\)\].*/\1/p')" && [[ -n $num ]]; do
    ufw --force delete "$num" >/dev/null
  done
fi

if command -v tailscale >/dev/null && tailscale serve status 2>/dev/null | grep -q "127.0.0.1:$PORT"; then
  echo "Note: if you used --tailscale-https, turn it off with: sudo tailscale serve --https=<port> off"
fi

if (( PURGE )); then
  rm -rf /etc/diz /var/lib/diz /var/lib/private/diz
  echo "Removed configuration and light names."
else
  echo "Kept /etc/diz and /var/lib/diz (run with --purge to remove them)."
fi
echo "diz-bridge removed."
