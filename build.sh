#!/usr/bin/env bash
# build.sh — arch detection, dependencies, compile, smoke test.
# The C sources in src/ are the single source of truth; this script only
# decides how to compile them and then builds.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# ── 1. arch ────────────────────────────────────────────────
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)        BEAUT_MARCH="x86-64-v2" ;;
  aarch64|arm64) BEAUT_MARCH="armv8-a+crypto" ;;
  armv7l)        BEAUT_MARCH="armv7-a" ;;
  armv6l)        BEAUT_MARCH="armv6" ;;
  riscv64)       BEAUT_MARCH="rv64gc" ;;
  *)             BEAUT_MARCH="" ;;
esac
CFLAGS_EXTRA="-O2"
[ -n "$BEAUT_MARCH" ] && CFLAGS_EXTRA="$CFLAGS_EXTRA -march=$BEAUT_MARCH"
log "arch=$ARCH  cflags='$CFLAGS_EXTRA'"

# ── 2. deps ────────────────────────────────────────────────
have_sodium() {
  pkg-config --exists libsodium 2>/dev/null && return 0
  [ -f /usr/include/sodium.h ] || [ -f /usr/include/sodium/sodium.h ]
}
install_deps() {
  log "installing deps"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      gcc make pkg-config libssl-dev libsodium-dev tar
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q gcc make pkgconf-pkg-config openssl-devel libsodium-devel tar
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache gcc musl-dev make pkgconf openssl-dev libsodium-dev tar
  else
    die "unsupported package manager"
  fi
}
if ! command -v gcc >/dev/null || ! command -v make >/dev/null || ! have_sodium; then
  [ "$(id -u)" = 0 ] || die "deps missing — run as root"
  install_deps
fi
have_sodium || die "libsodium headers still missing"
log "libsodium ready"

# ── 3. build + smoke ───────────────────────────────────────
export CFLAGS="$CFLAGS_EXTRA -Wall -Wextra -Isrc"
log "compiling with CFLAGS='$CFLAGS'"
make -s clean >/dev/null 2>&1 || true
make -s all
[ -x beaut-tool ] && [ -x beaut-router ] || die "build produced no binaries"
[ "$(./beaut-tool encode abc)" = "nop" ] || die "smoke test failed"
log "built: beaut-tool beaut-router  (arch=$ARCH)"
