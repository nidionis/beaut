#!/usr/bin/env bash
# scripts/build.sh — compile src/ into bin/beaut (the C tool).
#   ./scripts/build.sh           cached
#   ./scripts/build.sh --force   clean rebuild
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/lib.sh"
cd "$ROOT"

FORCE=0
if [ "${1:-}" = "--force" ] || [ "${BEAUT_FORCE_BUILD:-0}" = 1 ]; then FORCE=1; fi

# ── arch ───────────────────────────────────────────────────────────────────
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)        MARCH="x86-64-v2" ;;
  aarch64|arm64) MARCH="armv8-a+crypto" ;;
  armv7l)        MARCH="armv7-a" ;;
  armv6l)        MARCH="armv6" ;;
  riscv64)       MARCH="rv64gc" ;;
  *)             MARCH="" ;;
esac
if [ "${BEAUT_NATIVE:-0}" = 1 ]; then MARCH="native"; fi
CFLAGS="-O2 -Wall -Wextra -Isrc"
if [ -n "$MARCH" ]; then CFLAGS="$CFLAGS -march=$MARCH"; fi
log "arch=$ARCH  cflags='$CFLAGS'"

# ── deps ───────────────────────────────────────────────────────────────────
have_sodium() {
  pkg-config --exists libsodium 2>/dev/null && return 0
  [ -f /usr/include/sodium.h ] || [ -f /usr/include/sodium/sodium.h ]
}
have_zlib() {
  pkg-config --exists zlib 2>/dev/null && return 0
  [ -f /usr/include/zlib.h ]
}
if ! command -v gcc >/dev/null || ! command -v make >/dev/null || ! have_sodium || ! have_zlib; then
  [ "$(id -u)" = 0 ] || die "missing gcc/make/libsodium-dev/zlib1g-dev — install them (needs root)"
  log "installing deps"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      gcc make pkg-config libssl-dev libsodium-dev zlib1g-dev tar
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q gcc make pkgconf-pkg-config openssl-devel libsodium-devel zlib-devel tar
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache gcc musl-dev make pkgconf openssl-dev libsodium-dev zlib-dev tar
  else
    die "unsupported package manager"
  fi
fi
have_sodium || die "libsodium headers still missing"
have_zlib || die "zlib headers still missing"

# ── build ──────────────────────────────────────────────────────────────────
if [ "$FORCE" = 1 ]; then
  log "compiling (clean)"
  make -s clean >/dev/null 2>&1 || true
else
  log "compiling"
fi
make -s CFLAGS="$CFLAGS" all
[ -x bin/beaut ] || die "build produced no binary"
[ "$(./bin/beaut encode abc)" = "nop" ] || die "smoke test failed"
log "built: bin/beaut  (arch=$ARCH)"
printf 'BEAUT_ARCH=%s\nBEAUT_CFLAGS=%s\n' "$ARCH" "$CFLAGS" > .build-info
