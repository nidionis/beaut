#!/usr/bin/env bash
# 01-build.sh — layer 1: arch + env + C library. Writes src/, Makefile, builds binaries.
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
NATIVE="${BEAUT_NATIVE:-0}"
CFLAGS_EXTRA="-O2"
[ -n "$BEAUT_MARCH" ] && CFLAGS_EXTRA="$CFLAGS_EXTRA -march=$BEAUT_MARCH"
[ "$NATIVE" = 1 ] && CFLAGS_EXTRA="-O2 -march=native"
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
SODIUM_VER="$(pkg-config --modversion libsodium 2>/dev/null || echo header-only)"
log "libsodium $SODIUM_VER"

# ── 3. C library (regenerated only if missing or --force) ──
FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1
write() { # write <path> <<'MARK' … MARK
  local p="$1"; if [ -f "$p" ] && [ "$FORCE" = 0 ]; then return 0; fi
  mkdir -p "$(dirname "$p")"; cat > "$p"
}

write src/ft.h <<'EOF'
#ifndef FT_H
#define FT_H
#include <stdbool.h>
#include <stddef.h>
#define BLANK_CHARS " \t\r\n-_-"
#define HEXBUF(n) ((n) * 2 + 1)
#define BEAUT_NAME_MAX 128
#define IP_MAX 64
#define ACTION_MAX 64
#define TS_STR_MAX 16
#define LOAD_STR_MAX 16
#define LEVEL_STR_MAX 4
#define MAX_MSG_LEN 65536
bool is_blank(char c);
size_t trim_blanks(char *s);
int split_fields(char *line, char delim, char **f, int max);
void hex_encode(char *out, const unsigned char *in, size_t n);
int hex_decode(unsigned char *out, size_t outsz, const char *hex);
int env_int(const char *k, int d);
const char *env_str(const char *k, const char *d);
void env_frac(const char *k, int nd, int dd, int *n, int *dn);
#endif
EOF

write src/ft.c <<'EOF'
#include "ft.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
bool is_blank(char c) {
    for (const char *b = BLANK_CHARS; *b; b++) if (c == *b) return true;
    return false;
}
size_t trim_blanks(char *s) {
    char *r = s, *w = s;
    while (*r) { if (!is_blank(*r)) *w++ = *r; r++; }
    *w = 0;
    return (size_t)(w - s);
}
int split_fields(char *line, char delim, char **f, int max) {
    int n = 0; char *p = line;
    if (max < 1) return 0;
    f[n++] = p;
    while (*p && n < max) {
        if (*p == delim) { *p++ = 0; trim_blanks(f[n - 1]); f[n++] = p; }
        else p++;
    }
    if (n > 0) trim_blanks(f[n - 1]);
    return n;
}
void hex_encode(char *out, const unsigned char *in, size_t n) {
    static const char *d = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        out[i * 2] = d[in[i] >> 4];
        out[i * 2 + 1] = d[in[i] & 0xF];
    }
    out[n * 2] = 0;
}
int hex_decode(unsigned char *out, size_t outsz, const char *hex) {
    size_t hl = strlen(hex);
    if (hl % 2 || hl / 2 > outsz) return -1;
    for (size_t i = 0; i < hl / 2; i++) {
        char b[3] = { hex[i * 2], hex[i * 2 + 1], 0 };
        out[i] = (unsigned char)strtol(b, NULL, 16);
    }
    return (int)(hl / 2);
}
int env_int(const char *k, int d) { const char *v = getenv(k); return v ? atoi(v) : d; }
const char *env_str(const char *k, const char *d) { const char *v = getenv(k); return (v && *v) ? v : d; }
void env_frac(const char *k, int nd, int dd, int *n, int *dn) {
    const char *v = getenv(k);
    if (!v) { *n = nd; *dn = dd; return; }
    const char *s = strchr(v, '/');
    if (s) {
        char b[32]; int l = (int)(s - v); if (l > 31) l = 31;
        memcpy(b, v, l); b[l] = 0; *n = atoi(b); *dn = atoi(s + 1);
    } else { *n = atoi(v); *dn = 1; }
    if (*dn < 1) *dn = 1;
    if (*n < 0) *n = 0;
}
EOF

write src/crypt.h <<'EOF'
#ifndef CRYPT_H
#define CRYPT_H
#include <stddef.h>
#include <sodium.h>
#define KEY_BYTES crypto_aead_xchacha20poly1305_ietf_KEYBYTES
#define NONCE_BYTES crypto_aead_xchacha20poly1305_ietf_NPUBBYTES
#define TAG_BYTES crypto_aead_xchacha20poly1305_ietf_ABYTES
#define SALT_BYTES crypto_pwhash_SALTBYTES
#define SIGN_PK crypto_sign_PUBLICKEYBYTES
#define SIGN_PK_HEX HEXBUF(SIGN_PK)
#define IDENTITY_BYTES 8
#define IDENTITY_HEX_LEN HEXBUF(IDENTITY_BYTES)
#define KEY_HEX_LEN HEXBUF(KEY_BYTES)
#define SALT_CTX "beaut-salt"
#define LOG_HEX_MAX HEXBUF(NONCE_BYTES + MAX_MSG_LEN + TAG_BYTES)
#define LOG_LINE_MAX (TS_STR_MAX + 1 + LOG_HEX_MAX + 1)
#define PRIV_LINE_MAX (IDENTITY_HEX_LEN + 1 + SIGN_PK_HEX + 1 + LEVEL_STR_MAX + 1)
#define MSG_BUF_MAX (BEAUT_NAME_MAX + ACTION_MAX + MAX_MSG_LEN + 4)
void beaut_derive_key(unsigned char *key, const char *pw, int ops, int mem);
void beaut_identity(char *out, const unsigned char *key);
int beaut_encrypt(unsigned char **out, size_t *outlen,
                  const unsigned char *pt, size_t ptlen, const unsigned char *key);
int beaut_decrypt(unsigned char **out, size_t *outlen,
                  const unsigned char *blob, size_t bloblen, const unsigned char *key);
#endif
EOF

write src/crypt.c <<'EOF'
#include "crypt.h"
#include "ft.h"
#include <stdlib.h>
#include <string.h>
void beaut_derive_key(unsigned char *key, const char *pw, int ops, int mem) {
    unsigned char salt[SALT_BYTES];
    crypto_generichash(salt, sizeof(salt),
                       (const unsigned char *)pw, strlen(pw),
                       (const unsigned char *)SALT_CTX, sizeof(SALT_CTX) - 1);
    if (crypto_pwhash(key, KEY_BYTES, pw, strlen(pw), salt, ops, mem,
                      crypto_pwhash_ALG_ARGON2ID13) != 0)
        sodium_memzero(key, KEY_BYTES);
}
void beaut_identity(char *out, const unsigned char *key) {
    sodium_bin2hex(out, IDENTITY_HEX_LEN, key, IDENTITY_BYTES);
}
int beaut_encrypt(unsigned char **out, size_t *outlen,
                  const unsigned char *pt, size_t ptlen, const unsigned char *key) {
    *out = malloc(NONCE_BYTES + ptlen + TAG_BYTES);
    if (!*out) return -1;
    randombytes_buf(*out, NONCE_BYTES);
    unsigned long long clen;
    if (crypto_aead_xchacha20poly1305_ietf_encrypt(*out + NONCE_BYTES, &clen,
            pt, ptlen, NULL, 0, NULL, *out, key)) { free(*out); return -1; }
    *outlen = NONCE_BYTES + clen;
    return 0;
}
int beaut_decrypt(unsigned char **out, size_t *outlen,
                  const unsigned char *blob, size_t bloblen, const unsigned char *key) {
    if (bloblen < (size_t)(NONCE_BYTES + TAG_BYTES)) return -1;
    *out = malloc(bloblen - NONCE_BYTES + 1);
    if (!*out) return -1;
    unsigned long long plen;
    if (crypto_aead_xchacha20poly1305_ietf_decrypt(*out, &plen, NULL,
            blob + NONCE_BYTES, bloblen - NONCE_BYTES, NULL, 0, blob, key)) {
        free(*out); return -1;
    }
    (*out)[plen] = 0;
    *outlen = plen;
    return 0;
}
EOF

write src/tsointsoin.h <<'EOF'
#ifndef TSOINTSOIN_H
#define TSOINTSOIN_H
void tsointsoin_encode(char *out, const char *in);
void tsointsoin_decode(char *out, const char *in);
#endif
EOF

write src/tsointsoin.c <<'EOF'
#include "tsointsoin.h"
#include <string.h>
void tsointsoin_encode(char *out, const char *in) {
    size_t i;
    for (i = 0; in[i]; i++) {
        char c = in[i];
        if (c >= 'a' && c <= 'z') out[i] = (char)('a' + (c - 'a' + 13) % 26);
        else if (c >= 'A' && c <= 'Z') out[i] = (char)('A' + (c - 'A' + 13) % 26);
        else out[i] = c;
    }
    out[i] = 0;
}
void tsointsoin_decode(char *out, const char *in) { tsointsoin_encode(out, in); }
EOF

write src/orch.c <<'EOF'
#include "crypt.h"
#include "ft.h"
#include "tsointsoin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sodium.h>
#define F_LOG "log.enc"
#define F_PENDING "pending.tsv"
#define F_PRIV "priv.tsv"
#define F_ARCHIVE "archive"
#define P_HEARTBEAT "heartbeat"
#define P_TASK "task"
#define SEP_FIELD '\t'
#define SEP_LOAD ':'
#define DOMAIN_VM "vm"
typedef struct {
    int salv_num, salv_den, min_cores, max_cores;
    int kdf_ops, kdf_mem, ttl_s, stale_s, reserve_nodes;
    int retain_active_s, retain_archive_s;
    const char *state_dir, *etc_dir, *domain;
} cfg_t;
static cfg_t C;
static char LOGP[512], PENDP[512], PRIVP[512], ARCHP[512];
typedef struct { char id[IDENTITY_HEX_LEN]; char pk[SIGN_PK_HEX]; int level; } priv_entry;
static priv_entry PT[256];
static int PTn = 0;
typedef struct { char name[BEAUT_NAME_MAX]; char ip[IP_MAX]; int last_seen; double load; int cores; } peer_t;
static void cfg_init(void) {
    env_frac("SALV_COEF", 1, 3, &C.salv_num, &C.salv_den);
    C.min_cores = env_int("BEAUT_MIN_CORES", 1);
    C.max_cores = env_int("BEAUT_MAX_CORES", 0);
    C.kdf_ops = env_int("BEAUT_KDF_OPS", crypto_pwhash_OPSLIMIT_INTERACTIVE);
    C.kdf_mem = env_int("BEAUT_KDF_MEM", crypto_pwhash_MEMLIMIT_INTERACTIVE);
    C.ttl_s = env_int("BEAUT_TTL_S", 300);
    C.stale_s = env_int("BEAUT_STALE_S", 90);
    C.reserve_nodes = env_int("SCHEDULER_RESERVE_NODES", 1);
    C.retain_active_s = env_int("BEAUT_RETAIN_ACTIVE_S", 86400);
    C.retain_archive_s = env_int("BEAUT_RETAIN_ARCHIVE_S", 2592000);
    C.state_dir = env_str("BEAUT_STATE_DIR", "/var/lib/beaut");
    C.etc_dir = env_str("BEAUT_ETC_DIR", "/etc/beaut");
    C.domain = env_str("BEAUT_DOMAIN", "");
    snprintf(LOGP, sizeof(LOGP), "%s/%s", C.state_dir, F_LOG);
    snprintf(PENDP, sizeof(PENDP), "%s/%s", C.etc_dir, F_PENDING);
    snprintf(PRIVP, sizeof(PRIVP), "%s/%s", C.etc_dir, F_PRIV);
    snprintf(ARCHP, sizeof(ARCHP), "%s/%s", C.state_dir, F_ARCHIVE);
}
static void derive(unsigned char *k, const char *pw) { beaut_derive_key(k, pw, C.kdf_ops, C.kdf_mem); }
static int is_router(void) { return strstr(C.domain, DOMAIN_VM) != NULL; }
static int cores(void) {
    if (is_router()) return 0;
    int total = (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (total < 1) total = 1;
    if (total == 1) return 0;
    int c = (total * C.salv_num + C.salv_den - 1) / C.salv_den;   /* ceil(2/3) */
    if (c > total - 1) c = total - 1;                             /* always keep 1 free */
    if (c < C.min_cores) c = C.min_cores;
    if (C.max_cores > 0 && c > C.max_cores) c = C.max_cores;
    if (c > total - 1) c = total - 1;
    if (c < 0) c = 0;
    return c;
}
static int priv_load(void) {
    FILE *f = fopen(PRIVP, "r");
    if (!f) return 0;
    char line[PRIV_LINE_MAX + 8], dec[PRIV_LINE_MAX + 8];
    PTn = 0;
    while (fgets(line, sizeof(line), f) && PTn < 256) {
        line[strcspn(line, "\n")] = 0;
        tsointsoin_decode(dec, line);
        char *fld[3];
        if (split_fields(dec, SEP_FIELD, fld, 3) < 3) continue;
        strncpy(PT[PTn].id, fld[0], sizeof(PT[0].id) - 1);
        strncpy(PT[PTn].pk, fld[1], sizeof(PT[0].pk) - 1);
        PT[PTn].level = atoi(fld[2]);
        PTn++;
    }
    fclose(f);
    return PTn;
}
static int auth(const char *pw) {
    unsigned char key[KEY_BYTES];
    derive(key, pw);
    char id[IDENTITY_HEX_LEN];
    beaut_identity(id, key);
    int lvl = 0;
    for (int i = 0; i < PTn; i++) if (strcmp(PT[i].id, id) == 0) { lvl = PT[i].level; break; }
    sodium_memzero(key, sizeof(key));
    return lvl;
}
static int log_post(const char *w, const char *act, const char *pl, const unsigned char *key) {
    char pt[MSG_BUF_MAX];
    snprintf(pt, sizeof(pt), "%s%c%s%c%s", w, SEP_FIELD, act, SEP_FIELD, pl);
    unsigned char *enc; size_t el;
    if (beaut_encrypt(&enc, &el, (unsigned char *)pt, strlen(pt), key)) return -1;
    FILE *f = fopen(LOGP, "a");
    if (!f) { free(enc); return -1; }
    fprintf(f, "%lld ", (long long)time(NULL));
    for (size_t i = 0; i < el; i++) fprintf(f, "%02x", enc[i]);
    fputc('\n', f);
    fclose(f); free(enc);
    return 0;
}
static int log_read(int offset, char *buf, size_t bufsz, const unsigned char *key) {
    FILE *f = fopen(LOGP, "r");
    if (!f) return 0;
    static char line[LOG_LINE_MAX];
    int n = 0, i = 0; size_t used = 0;
    while (fgets(line, sizeof(line), f)) {
        i++;
        if (i <= offset) continue;
        char *sp = strchr(line, ' ');
        if (!sp) continue;
        *sp = 0;
        int ts = atoi(line);
        if ((int)time(NULL) - ts > C.ttl_s) continue;
        char *hex = sp + 1;
        size_t hlen = strlen(hex);
        if (hlen % 2) continue;
        size_t rl = hlen / 2;
        unsigned char *raw = malloc(rl);
        if (!raw) continue;
        if (hex_decode(raw, rl, hex) < 0) { free(raw); continue; }
        unsigned char *pt; size_t pl;
        if (beaut_decrypt(&pt, &pl, raw, rl, key) == 0) {
            char entry[MSG_BUF_MAX + TS_STR_MAX];
            int el = snprintf(entry, sizeof(entry), "%d%c%s\n", ts, SEP_FIELD, (char *)pt);
            if (el > 0 && used + (size_t)el + 1 < bufsz) {
                memcpy(buf + used, entry, (size_t)el); used += (size_t)el; buf[used] = 0; n++;
            }
            free(pt);
        }
        free(raw);
    }
    fclose(f);
    return n;
}
static double free_cap(const peer_t *p) { double f = p->cores - p->load; return f > 0 ? f : 0; }
static void sort_best(peer_t *p, int n) {
    for (int i = 1; i < n; i++) {
        peer_t t = p[i]; int j = i - 1;
        while (j >= 0 && free_cap(&p[j]) < free_cap(&t)) { p[j + 1] = p[j]; j--; }
        p[j + 1] = t;
    }
}
static int peers_scan(peer_t *out, int max, const unsigned char *key) {
    static char buf[65536];
    log_read(0, buf, sizeof(buf), key);
    int count = 0, now = (int)time(NULL);
    char *line = buf;
    while (*line && count < max) {
        char *nl = strchr(line, '\n');
        if (!nl) break;
        *nl = 0;
        char *f[4];
        if (split_fields(line, SEP_FIELD, f, 4) == 4 && strcmp(f[2], P_HEARTBEAT) == 0
            && now - atoi(f[0]) < C.stale_s) {
            char *lp = strchr(f[3], SEP_LOAD);
            if (!lp) { line = nl + 1; continue; }
            *lp = 0;
            int found = 0;
            for (int i = 0; i < count; i++)
                if (strcmp(out[i].name, f[1]) == 0) { out[i].last_seen = atoi(f[0]); found = 1; break; }
            if (!found) {
                strncpy(out[count].name, f[1], BEAUT_NAME_MAX - 1);
                strncpy(out[count].ip, f[3], IP_MAX - 1);
                out[count].load = atof(lp + 1);
                out[count].last_seen = atoi(f[0]);
                out[count].cores = env_int("BEAUT_PEER_CORES", 4);
                count++;
            }
        }
        line = nl + 1;
    }
    return count;
}
static int pick(char *best, char *next, const unsigned char *key) {
    static peer_t p[256];
    int n = peers_scan(p, 256, key);
    if (n < C.reserve_nodes + 1) return -1;
    sort_best(p, n);
    strncpy(best, p[0].ip, IP_MAX - 1); best[IP_MAX - 1] = 0;
    if (n >= C.reserve_nodes + 2) { strncpy(next, p[1].ip, IP_MAX - 1); next[IP_MAX - 1] = 0; }
    else next[0] = 0;
    return 0;
}
static void retain(void) {
    FILE *in = fopen(LOGP, "r");
    if (!in) return;
    int now = (int)time(NULL);
    char line[LOG_LINE_MAX], tmp[600], ap[600];
    snprintf(tmp, sizeof(tmp), "%s.tmp", LOGP);
    snprintf(ap, sizeof(ap), "%s/%lld.log", ARCHP, (long long)now);
    FILE *act = fopen(tmp, "w");
    if (!act) { fclose(in); return; }
    FILE *arc = NULL;
    while (fgets(line, sizeof(line), in)) {
        int ts = atoi(line);
        if (now - ts < C.retain_active_s) fputs(line, act);
        else if (now - ts < C.retain_archive_s) {
            if (!arc) arc = fopen(ap, "a");
            if (arc) fputs(line, arc); else fputs(line, act);
        }
    }
    if (arc) fclose(arc);
    fclose(in); fclose(act);
    if (rename(tmp, LOGP) != 0) remove(tmp);
}
static void c_join(char **a) {
    unsigned char key[KEY_BYTES];
    derive(key, a[0]);
    char id[IDENTITY_HEX_LEN];
    beaut_identity(id, key);
    unsigned char pk[SIGN_PK];
    crypto_generichash(pk, sizeof(pk), key, KEY_BYTES, (const unsigned char *)"pk", 2);
    char pkhex[SIGN_PK_HEX];
    hex_encode(pkhex, pk, sizeof(pk));
    sodium_memzero(key, sizeof(key));
    char line[PRIV_LINE_MAX], enc[PRIV_LINE_MAX];
    snprintf(line, sizeof(line), "%s%c%s%c%d", id, SEP_FIELD, pkhex, SEP_FIELD, (int)time(NULL));
    tsointsoin_encode(enc, line);
    FILE *f = fopen(PENDP, "a");
    if (!f) { fprintf(stderr, "cannot open %s\n", PENDP); exit(1); }
    fprintf(f, "%s\n", enc); fclose(f);
    printf("pending id=%s pk=%s\n", id, pkhex);
}
static int c_approve(char **a) {
    FILE *p = fopen(PENDP, "r");
    if (!p) return 1;
    char line[PRIV_LINE_MAX + 8], dec[PRIV_LINE_MAX + 8];
    int found = 0;
    while (fgets(line, sizeof(line), p)) {
        line[strcspn(line, "\n")] = 0;
        tsointsoin_decode(dec, line);
        char *fld[3];
        if (split_fields(dec, SEP_FIELD, fld, 3) < 3) continue;
        if (strcmp(fld[0], a[2]) != 0) continue;
        char out[PRIV_LINE_MAX], enc[PRIV_LINE_MAX];
        snprintf(out, sizeof(out), "%s%c%s%c%s", fld[0], SEP_FIELD, fld[1], SEP_FIELD, a[3]);
        tsointsoin_encode(enc, out);
        FILE *ap = fopen(PRIVP, "a");
        if (!ap) { fclose(p); return 1; }
        fprintf(ap, "%s\n", enc); fclose(ap);
        found = 1; break;
    }
    fclose(p);
    return found ? 0 : 1;
}
static void c_auth(char **a) { int l = auth(a[0]); printf("%d\n", l); exit(l > 0 ? 0 : 1); }
static void c_cores(char **a) { (void)a; printf("%d\n", cores()); }
static void c_role(char **a) { (void)a; printf("%s cores=%d\n", is_router() ? "router" : "worker", cores()); }
static void c_encode(char **a) { char o[PRIV_LINE_MAX + 8]; tsointsoin_encode(o, a[0]); printf("%s\n", o); }
static void c_decode(char **a) { char o[PRIV_LINE_MAX + 8]; tsointsoin_decode(o, a[0]); printf("%s\n", o); }
static void c_post(char **a) { unsigned char k[KEY_BYTES]; derive(k, a[4]); int rc = log_post(a[1], a[2], a[3], k); sodium_memzero(k, sizeof(k)); if (rc) exit(1); }
static void c_read(char **a) { unsigned char k[KEY_BYTES]; derive(k, a[2]); static char buf[65536]; int n = log_read(atoi(a[1]), buf, sizeof(buf), k); sodium_memzero(k, sizeof(k)); if (n > 0) fputs(buf, stdout); fprintf(stderr, "%d\n", n); }
static void c_peers(char **a) { static peer_t p[256]; unsigned char k[KEY_BYTES]; derive(k, a[1]); int n = peers_scan(p, 256, k); sodium_memzero(k, sizeof(k)); for (int i = 0; i < n; i++) printf("%s\t%s\t%.1f\t%d\n", p[i].name, p[i].ip, p[i].load, p[i].cores); }
static void c_pick(char **a) { unsigned char k[KEY_BYTES]; derive(k, a[1]); char best[IP_MAX], next[IP_MAX]; int rc = pick(best, next, k); sodium_memzero(k, sizeof(k)); if (rc) exit(1); printf("%s\n%s\n", best, next); }
static void c_heartbeat(char **a) {
    double load = 0;
    FILE *f = fopen("/proc/loadavg", "r");
    if (f) { if (fscanf(f, "%lf", &load) != 1) load = 0; fclose(f); }
    char pl[LOAD_STR_MAX + IP_MAX];
    snprintf(pl, sizeof(pl), "%s%c%.1f", a[2], SEP_LOAD, load);
    unsigned char k[KEY_BYTES];
    derive(k, a[3]);
    log_post(a[1], P_HEARTBEAT, pl, k);
    sodium_memzero(k, sizeof(k));
}
static void c_retain(char **a) { (void)a; retain(); }
static void help(void) {
    fprintf(stderr,
      "usage: beaut-tool <cmd> [args]\n"
      "  join <pending> <pw>        approve <pending> <priv> <id> <lvl>\n"
      "  auth <pw>                  cores                    role\n"
      "  post <log> <w> <act> <payload> <pw>\n"
      "  read <log> <offset> <pw>   peers <log> <pw>         pick <log> <pw>\n"
      "  heartbeat <log> <w> <ip> <pw>                       retain\n"
      "  encode <text>              decode <text>\n");
}
int main(int argc, char **argv) {
    if (sodium_init() < 0) { fputs("sodium_init failed\n", stderr); return 1; }
    cfg_init();
    priv_load();
    if (argc < 2) { help(); return 1; }
    const char *cmd = argv[1];
    char **a = argv + 2;
    if      (!strcmp(cmd, "join")) c_join(a);
    else if (!strcmp(cmd, "approve")) return c_approve(a);
    else if (!strcmp(cmd, "auth")) c_auth(a);
    else if (!strcmp(cmd, "cores")) c_cores(a);
else if (!strcmp(cmd, "role")) c_role(a);
    else if (!strcmp(cmd, "post")) c_post(a);
    else if (!strcmp(cmd, "read")) c_read(a);
    else if (!strcmp(cmd, "peers")) c_peers(a);
    else if (!strcmp(cmd, "pick")) c_pick(a);
    else if (!strcmp(cmd, "heartbeat")) c_heartbeat(a);
    else if (!strcmp(cmd, "retain")) c_retain(a);
    else if (!strcmp(cmd, "encode")) c_encode(a);
    else if (!strcmp(cmd, "decode")) c_decode(a);
    else { help(); return 1; }
    return 0;
}
EOF

write src/router.c <<'EOF'
#include "ft.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
static void pump(int from, int to) {
    char buf[8192]; ssize_t r;
    while ((r = read(from, buf, sizeof(buf))) > 0) {
        ssize_t o = 0;
        while (o < r) { ssize_t w = write(to, buf + o, (size_t)(r - o)); if (w <= 0) break; o += w; }
    }
}
int main(int argc, char **argv) {
    const char *bind_addr = env_str("ROUTER_LISTEN", "0.0.0.0");  /* never name it "listen" */
    int lport = env_int("ROUTER_PORT", 443);
    const char *orch = env_str("ORCHESTRATOR_IP", "127.0.0.1");
    int oport = env_int("ORCHESTRATOR_PORT", 7700);
    if (argc > 1) oport = atoi(argv[1]);
    signal(SIGCHLD, SIG_IGN);                       /* no zombies */
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { perror("socket"); return 1; }
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET;
    sa.sin_port = htons((unsigned short)lport);
    inet_pton(AF_INET, bind_addr, &sa.sin_addr);
    if (bind(srv, (struct sockaddr *)&sa, sizeof(sa)) < 0) { perror("bind"); return 1; }
    if (listen(srv, 128) < 0) { perror("listen"); return 1; }
    fprintf(stderr, "router %s:%d -> %s:%d\n", bind_addr, lport, orch, oport);
    for (;;) {
        int c = accept(srv, NULL, NULL);
        if (c < 0) continue;
        int up = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in ua = {0};
        ua.sin_family = AF_INET;
        ua.sin_port = htons((unsigned short)oport);
        inet_pton(AF_INET, orch, &ua.sin_addr);
        if (connect(up, (struct sockaddr *)&ua, sizeof(ua)) < 0) { close(c); close(up); continue; }
        pid_t pid = fork();
        if (pid < 0) { close(c); close(up); continue; }
        if (pid == 0) { pump(c, up); close(up); close(c); _exit(0); }
        pump(up, c);
        close(c); close(up);
    }
}
EOF

# ── 4. Makefile ────────────────────────────────────────────
if [ ! -f Makefile ] || [ "$FORCE" = 1 ]; then
cat > Makefile <<EOF
CC      = gcc
CFLAGS  = $CFLAGS_EXTRA -Wall -Wextra -Isrc
LDLIBS  = -lsodium

all: beaut-tool beaut-router

beaut-tool: src/orch.c src/crypt.c src/ft.c src/tsointsoin.c
	\$(CC) \$(CFLAGS) -o \$@ \$^ \$(LDLIBS)

beaut-router: src/router.c src/ft.c
	\$(CC) \$(CFLAGS) -o \$@ \$^

test: beaut-tool
	@test "\$(./beaut-tool encode abc)" = "nop" && echo "smoke OK"

clean:
	rm -f beaut-tool beaut-router

.PHONY: all test clean
EOF
fi

# ── 5. build + smoke ───────────────────────────────────────
log "compiling"
make -s clean >/dev/null 2>&1 || true
make -s all
[ -x beaut-tool ] && [ -x beaut-router ] || die "build produced no binaries"
[ "$(./beaut-tool encode abc)" = "nop" ] || die "smoke test failed"
log "built: beaut-tool beaut-router  (arch=$ARCH)"
printf 'BEAUT_ARCH=%s\nBEAUT_CFLAGS=%s\n' "$ARCH" "$CFLAGS_EXTRA" > .build-info
