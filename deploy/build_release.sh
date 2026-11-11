#!/usr/bin/env bash
# Builds release artifacts into dist/:
#   diz-bridge-<version>-linux-arm64.tar.gz   Raspberry Pi 3/4/5 (64-bit OS) and other ARM64 machines
#   diz-bridge-<version>-linux-x64.tar.gz     regular PCs and servers
#   diz-<version>.apk                          Android app
#
# Usage: bash deploy/build_release.sh [--arch arm64|x64]... [--no-apk]
#
# Works on Linux, macOS and Windows (Git Bash): the bridge is cross-compiled
# with `dart compile exe --target-os=linux`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
PKG_SRC="$ROOT/deploy/pkg"
ARCHES=()
BUILD_APK=1

while (( $# )); do
  case "$1" in
    --arch)    ARCHES+=("${2:?--arch needs a value}"); shift ;;
    --no-apk)  BUILD_APK=0 ;;
    -h|--help) sed -n '2,10s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *)         echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done
(( ${#ARCHES[@]} )) || ARCHES=(arm64 x64)

version_of() { sed -n 's/^version: *//p' "$1" | head -n1 | tr -d '\r'; }
VERSION="$(version_of "$ROOT/bridge/pubspec.yaml")"
APP_VERSION="$(version_of "$ROOT/app/pubspec.yaml")"
APP_VERSION="${APP_VERSION%%+*}"

# Scripts with Windows line endings break on Linux; refuse to package them.
if grep -l $'\r' "$PKG_SRC"/* >/dev/null 2>&1; then
  echo "error: CRLF line endings in deploy/pkg/ ($(grep -l $'\r' "$PKG_SRC"/* | xargs -n1 basename | tr '\n' ' '))." >&2
  echo "       Re-checkout with the repo's .gitattributes or convert them to LF." >&2
  exit 1
fi

mkdir -p "$DIST"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

for arch in "${ARCHES[@]}"; do
  case "$arch" in arm64|x64) ;; *) echo "unsupported arch: $arch (use arm64 or x64)" >&2; exit 1 ;; esac
  work="$STAGE/$arch"
  pkg="$work/diz-bridge"
  mkdir -p "$pkg"

  echo "==> Compiling diz-bridge $VERSION for linux-$arch"
  (cd "$ROOT/bridge" && dart compile exe bin/diz_bridge.dart \
      --target-os=linux --target-arch="$arch" \
      -DDIZ_VERSION="$VERSION" -o "$pkg/diz-bridge")

  cp "$PKG_SRC/install.sh" "$PKG_SRC/uninstall.sh" "$PKG_SRC/diz-bridge.service" \
     "$PKG_SRC/diz.env.example" "$PKG_SRC/README.md" "$pkg/"
  printf '%s\n' "$arch" > "$pkg/ARCH"
  printf '%s\n' "$VERSION" > "$pkg/VERSION"

  # Set ownership and permissions explicitly: the build host's filesystem
  # (e.g. NTFS) may not have Unix permission bits.
  tarball="$work/diz-bridge-$VERSION-linux-$arch.tar"
  (
    cd "$work"
    tar --owner=0 --group=0 --numeric-owner --mode=0755 -cf "$tarball" --no-recursion diz-bridge
    tar --owner=0 --group=0 --numeric-owner --mode=0644 -rf "$tarball" \
        diz-bridge/diz-bridge.service diz-bridge/diz.env.example diz-bridge/README.md \
        diz-bridge/ARCH diz-bridge/VERSION
    tar --owner=0 --group=0 --numeric-owner --mode=0755 -rf "$tarball" \
        diz-bridge/diz-bridge diz-bridge/install.sh diz-bridge/uninstall.sh
  )
  gzip -9 -n -f "$tarball"
  mv -f "$tarball.gz" "$DIST/"
  echo "    dist/$(basename "$tarball").gz"
done

if (( BUILD_APK )); then
  echo "==> Building the Android app $APP_VERSION"
  (cd "$ROOT/app" && flutter build apk --release)
  cp "$ROOT/app/build/app/outputs/flutter-apk/app-release.apk" "$DIST/diz-$APP_VERSION.apk"
  echo "    dist/diz-$APP_VERSION.apk"
fi

echo "==> Done"
(cd "$DIST" && sha256sum -- *.tar.gz *.apk 2>/dev/null | tee SHA256SUMS) || true
