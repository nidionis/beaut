#include "crypt.h"
#include "ft.h"
#include "orch.h"
#include "net.h"
#include "pngsteg.h"
#include "tsointsoin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/file.h>
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
static int priv_find(const char *id, char *pk_out, size_t pk_sz);
typedef struct { char name[BEAUT_NAME_MAX]; char ip[IP_MAX]; char domain[BEAUT_NAME_MAX]; char id[IDENTITY_HEX_LEN]; int last_seen; double load; int cores; } peer_t;
static void cfg_init(void) {
    env_frac("SALV_COEF", 1, 3, &C.salv_num, &C.salv_den);
    C.min_cores = env_int("BEAUT_MIN_CORES", 1);
    C.max_cores = env_int("BEAUT_MAX_CORES", 0);
    C.kdf_ops = env_int("BEAUT_KDF_OPS", crypto_pwhash_OPSLIMIT_INTERACTIVE);
    C.kdf_mem = env_int("BEAUT_KDF_MEM", crypto_pwhash_MEMLIMIT_INTERACTIVE);
    C.ttl_s = env_int("BEAUT_TTL_S", 300);
    C.stale_s = env_int("BEAUT_STALE_S", 90);
    C.reserve_nodes = env_int("SCHEDULER_RESERVE_NODES", 0);
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
    unsigned char sk[SIGN_SK], pk[SIGN_PK];
    char id[IDENTITY_HEX_LEN];
    if (beaut_device_load(sk, pk) == 0) {
        beaut_device_id(id, pk);
        sodium_memzero(sk, sizeof(sk));
    } else {
        unsigned char key[KEY_BYTES];
        derive(key, pw);
        beaut_identity(id, key);
        sodium_memzero(key, sizeof(key));
    }
    return priv_find(id, NULL, 0);
}
static int split_raw(char *s, char d, char **f, int max) {
    int n = 0;
    if (max < 1) return 0;
    f[n++] = s;
    while (*s && n < max) {
        if (*s == d) { *s = 0; f[n++] = s + 1; }
        s++;
    }
    return n;
}
static int priv_find(const char *id, char *pk_out, size_t pk_sz) {
    int best = 0, got = 0;
    for (int i = 0; i < PTn; i++) {
        if (strcmp(PT[i].id, id) != 0) continue;
        if (PT[i].level > best) best = PT[i].level;
        if (pk_out && pk_sz && !got) {
            strncpy(pk_out, PT[i].pk, pk_sz - 1);
            pk_out[pk_sz - 1] = 0;
            got = 1;
        }
    }
    return best;
}
static int log_post(const char *w, const char *act, const char *pl, const unsigned char *key) {
    unsigned char sk[SIGN_SK], pk[SIGN_PK];
    if (beaut_device_load(sk, pk) != 0) return -1;
    char oid[IDENTITY_HEX_LEN];
    beaut_device_id(oid, pk);

    unsigned char nraw[REC_NONCE_BYTES];
    randombytes_buf(nraw, sizeof(nraw));
    char nonce[REC_NONCE_HEX];
    hex_encode(nonce, nraw, sizeof(nraw));

    int ts = (int)time(NULL);
    size_t cap = MAX_MSG_LEN + 1024;
    char *msg = malloc(cap);
    char *pt = malloc(cap);
    if (!msg || !pt) { free(msg); free(pt); sodium_memzero(sk, sizeof(sk)); return -1; }

    snprintf(msg, cap, "beaut1\n%d\n%s\n%s\n%s\n%s\n%s",
             ts, oid, nonce, w, act, pl);
    unsigned char sig[crypto_sign_BYTES];
    unsigned long long siglen = 0;
    crypto_sign_detached(sig, &siglen, (unsigned char *)msg, strlen(msg), sk);
    char sighex[HEXBUF(crypto_sign_BYTES)];
    hex_encode(sighex, sig, sizeof(sig));

    snprintf(pt, cap, "v2\t%d\t%s\t%s\t%s\t%s\t%s\t%s",
             ts, oid, nonce, sighex, w, act, pl);

    unsigned char *enc; size_t el;
    int rc = beaut_encrypt(&enc, &el, (unsigned char *)pt, strlen(pt), key);
    if (rc == 0) {
        FILE *f = fopen(LOGP, "a");
        if (!f) { free(enc); rc = -1; }
        else {
            fprintf(f, "%d ", ts);
            for (size_t i = 0; i < el; i++) fprintf(f, "%02x", enc[i]);
            fputc('\n', f);
            fclose(f);
            free(enc);
        }
    }
    free(msg); free(pt);
    sodium_memzero(sk, sizeof(sk));
    sodium_memzero(sig, sizeof(sig));
    return rc;
}
/* Verify one encrypted log line.  Returns 0 on success and fills the fields
   (payload last, so it may contain tabs).  Used by log_read and the network. */
int beaut_verify_record(const char *line, const unsigned char *key,
                        char *worker, size_t wl, char *action, size_t al,
                        char *payload, size_t pl, char *oid, size_t ol,
                        int *level) {
    char *copy = strdup(line);
    if (!copy) return -1;
    copy[strcspn(copy, "\r\n")] = 0;
    char *sp = strchr(copy, ' ');
    if (!sp) { free(copy); return -1; }
    *sp = 0;
    int ots = atoi(copy);
    if (ots <= 0) { free(copy); return -1; }
    int now = (int)time(NULL);
    if (now - ots > C.ttl_s || ots - now > 60) { free(copy); return -1; }
    char *hex = sp + 1;
    size_t hlen = strlen(hex);
    if (hlen % 2) { free(copy); return -1; }
    size_t rl = hlen / 2;
    unsigned char *raw = malloc(rl ? rl : 1);
    if (!raw) { free(copy); return -1; }
    if (hex_decode(raw, rl, hex) < 0) { free(raw); free(copy); return -1; }
    unsigned char *pt;
    size_t ptlen;
    if (beaut_decrypt(&pt, &ptlen, raw, rl, key) != 0) { free(raw); free(copy); return -1; }
    free(raw);

    int ok = -1;
    char *f[8];
    if (split_raw((char *)pt, '\t', f, 8) == 8 && strcmp(f[0], "v2") == 0) {
        int its = atoi(f[1]);
        if (its == ots) {
            char pkhex[SIGN_PK_HEX];
            int lvl = priv_find(f[2], pkhex, sizeof(pkhex));
            if (lvl >= 1) {
                unsigned char pkraw[SIGN_PK];
                int pklen = hex_decode(pkraw, sizeof(pkraw), pkhex);
                char *msg = malloc(MAX_MSG_LEN + 512);
                if (msg && pklen == (int)sizeof(pkraw)) {
                    snprintf(msg, MAX_MSG_LEN + 512, "beaut1\n%s\n%s\n%s\n%s\n%s\n%s",
                             f[1], f[2], f[3], f[5], f[6], f[7]);
                    unsigned char sig[crypto_sign_BYTES];
                    int sl = hex_decode(sig, sizeof(sig), f[4]);
                    if (sl == (int)sizeof(sig) &&
                        crypto_sign_verify_detached(sig, (unsigned char *)msg, strlen(msg),
                                                    pkraw) == 0) {
                        if (worker && wl) { strncpy(worker, f[5], wl - 1); worker[wl - 1] = 0; }
                        if (action && al) { strncpy(action, f[6], al - 1); action[al - 1] = 0; }
                        if (payload && pl) { strncpy(payload, f[7], pl - 1); payload[pl - 1] = 0; }
                        if (oid && ol) { strncpy(oid, f[2], ol - 1); oid[ol - 1] = 0; }
                        if (level) *level = lvl;
                        ok = 0;
                    }
                }
                free(msg);
            }
        }
    }
    free(pt);
    free(copy);
    return ok;
}
/* Append an already-verified encrypted line to the local log (used by net.c).
   Validates the shape to prevent log injection. */
int beaut_append_raw(const char *line, size_t len) {
    if (!line || len < 3) return -1;
    size_t i = 0;
    while (i < len && line[i] >= '0' && line[i] <= '9') i++;
    if (i == 0 || i >= len || line[i] != ' ') return -1;
    for (size_t j = i + 1; j < len; j++) {
        char c = line[j];
        if (c == '\n') {
            if (j + 1 != len) return -1;   /* only the terminating newline */
            break;
        }
        if (c == '\r') return -1;
        int hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        if (!hex) return -1;
    }
    int fd = open(LOGP, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return -1;
    if (line[len - 1] != '\n') {
        /* caller is expected to pass the newline; copy to a temporary line */
        char *tmp = malloc(len + 1);
        if (!tmp) { close(fd); return -1; }
        memcpy(tmp, line, len);
        tmp[len] = '\n';
        flock(fd, LOCK_EX);
        ssize_t w = write(fd, tmp, len + 1);
        flock(fd, LOCK_UN);
        close(fd);
        free(tmp);
        return w == (ssize_t)(len + 1) ? 0 : -1;
    }
    flock(fd, LOCK_EX);
    ssize_t w = write(fd, line, len);
    flock(fd, LOCK_UN);
    close(fd);
    return w == (ssize_t)len ? 0 : -1;
}
const char *beaut_log_path(void) { return LOGP; }
static int log_read(int offset, char *buf, size_t bufsz, const unsigned char *key) {
    FILE *f = fopen(LOGP, "r");
    if (!f) return 0;
    static char line[LOG_LINE_MAX];
    int i = 0; size_t used = 0;
    while (fgets(line, sizeof(line), f)) {
        i++;
        if (i <= offset) continue;
        char worker[BEAUT_NAME_MAX], action[ACTION_MAX], payload[MAX_MSG_LEN + 1], oid[IDENTITY_HEX_LEN];
        int level = 0;
        if (beaut_verify_record(line, key, worker, sizeof(worker), action, sizeof(action),
                                payload, sizeof(payload), oid, sizeof(oid), &level) != 0)
            continue;
        char *entry = malloc(strlen(payload) + BEAUT_NAME_MAX + ACTION_MAX + 64);
        if (!entry) continue;
        int el = snprintf(entry, strlen(payload) + BEAUT_NAME_MAX + ACTION_MAX + 64,
                          "%d\t%s\t%s\t%s\t%d\t%s\n", atoi(line), worker, action, oid, level, payload);
        if (el > 0 && used + (size_t)el + 1 < bufsz) {
            memcpy(buf + used, entry, (size_t)el); used += (size_t)el; buf[used] = 0;
        }
        free(entry);
    }
    fclose(f);
    return i;   /* physical lines consumed */
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
        char *f[6];
        if (split_fields(line, SEP_FIELD, f, 6) == 6 && strcmp(f[2], P_HEARTBEAT) == 0
            && atoi(f[4]) >= 1 && now - atoi(f[0]) < C.stale_s) {
            char *sub[4];
            int ns = split_fields(f[5], SEP_LOAD, sub, 4);
            if (ns < 2) { line = nl + 1; continue; }
            int found = 0;
            for (int i = 0; i < count; i++)
                if (strcmp(out[i].name, f[1]) == 0) { out[i].last_seen = atoi(f[0]); found = 1; break; }
            if (!found) {
                snprintf(out[count].name, sizeof(out[count].name), "%s", f[1]);
                snprintf(out[count].ip, sizeof(out[count].ip), "%s", sub[0]);
                out[count].load = atof(sub[1]);
                out[count].last_seen = atoi(f[0]);
                out[count].cores = ns >= 3 ? atoi(sub[2]) : env_int("BEAUT_PEER_CORES", 4);
                if (out[count].cores < 0) out[count].cores = 0;
                out[count].domain[0] = 0;
                if (ns >= 4) snprintf(out[count].domain, sizeof(out[count].domain), "%s", sub[3]);
                snprintf(out[count].id, sizeof(out[count].id), "%s", f[3]);
                count++;
            }
        }
        line = nl + 1;
    }
    return count;
}
static int pick(char *best, char *next, const char *want, const unsigned char *key) {
    static peer_t p[256];
    int n = peers_scan(p, 256, key);
    if (want && *want && strcmp(want, "*") != 0) {
        int k = 0;
        for (int i = 0; i < n; i++)
            if (!p[i].domain[0] || strcmp(p[i].domain, want) == 0) p[k++] = p[i];
        n = k;
    }
    if (n < C.reserve_nodes + 1) return -1;
    sort_best(p, n);
    snprintf(best, IP_MAX, "%s", p[0].ip);
    if (n >= C.reserve_nodes + 2) snprintf(next, IP_MAX, "%s", p[1].ip);
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
static int pending_has(const char *id) {
    FILE *f = fopen(PENDP, "r");
    if (!f) return 0;
    char line[PRIV_LINE_MAX + 8], dec[PRIV_LINE_MAX + 8];
    int found = 0;
    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\n")] = 0;
        if (!line[0]) continue;
        tsointsoin_decode(dec, line);
        char *fld[3];
        if (split_fields(dec, SEP_FIELD, fld, 3) < 3) continue;
        if (strcmp(fld[0], id) == 0) { found = 1; break; }
    }
    fclose(f);
    return found;
}
static void c_join(char **a) {
    if (!a[0] || !a[1]) { fputs("usage: join <pending> <pw>\n", stderr); return; }
    unsigned char sk[SIGN_SK], pk[SIGN_PK];
    if (beaut_device_ensure(sk, pk) != 0) { fputs("cannot create device key\n", stderr); exit(1); }
    char id[IDENTITY_HEX_LEN];
    beaut_device_id(id, pk);
    for (int i = 0; i < PTn; i++)
        if (strcmp(PT[i].id, id) == 0) {
            fprintf(stderr, "id %s already approved\n", id);
            sodium_memzero(sk, sizeof(sk));
            exit(1);
        }
    if (pending_has(id)) {
        fprintf(stderr, "id %s already pending\n", id);
        sodium_memzero(sk, sizeof(sk));
        exit(1);
    }
    char pkhex[SIGN_PK_HEX];
    hex_encode(pkhex, pk, sizeof(pk));
    sodium_memzero(sk, sizeof(sk));
    char line[PRIV_LINE_MAX], enc[PRIV_LINE_MAX];
    snprintf(line, sizeof(line), "%s%c%s%c%d", id, SEP_FIELD, pkhex, SEP_FIELD, (int)time(NULL));
    tsointsoin_encode(enc, line);
    FILE *f = fopen(PENDP, "a");
    if (!f) { fprintf(stderr, "cannot open %s\n", PENDP); exit(1); }
    fprintf(f, "%s\n", enc); fclose(f);
    printf("pending id=%s pk=%s\n", id, pkhex);
}
static int c_approve(char **a) {
    if (!a[2] || !a[3]) { fputs("usage: approve <pending> <priv> <id> <level>\n", stderr); return 1; }
    const char *id = a[2];
    int lvl = atoi(a[3]);
    if (lvl < 1 || lvl > 3) { fputs("level must be 1..3\n", stderr); return 1; }

    char pk[SIGN_PK_HEX] = "";
    int found = 0;
    if (a[4] && strlen(a[4]) == SIGN_PK_HEX - 1) {
        snprintf(pk, sizeof(pk), "%s", a[4]);
        found = 1;
    }

    /* already approved: keep its pk; the new level is authoritative */
    for (int i = 0; i < PTn; i++) {
        if (strcmp(PT[i].id, id) != 0) continue;
        if (!pk[0]) strncpy(pk, PT[i].pk, sizeof(pk) - 1);
        found = 1;
    }

    /* never lock the cluster out: keep at least one admin */
    if (lvl < 3) {
        int admins = 0;
        for (int i = 0; i < PTn; i++)
            if (strcmp(PT[i].id, id) != 0 && PT[i].level >= 3) admins++;
        if (admins == 0) {
            fputs("refusing to demote the last admin\n", stderr);
            return 1;
        }
    }

    /* first approval: the pending record supplies the public key */
    FILE *pend = fopen(PENDP, "r");
    if (pend) {
        char line[PRIV_LINE_MAX + 8], dec[PRIV_LINE_MAX + 8];
        while (fgets(line, sizeof(line), pend)) {
            line[strcspn(line, "\n")] = 0;
            if (!line[0]) continue;
            tsointsoin_decode(dec, line);
            char *fld[3];
            if (split_fields(dec, SEP_FIELD, fld, 3) < 3) continue;
            if (strcmp(fld[0], id) != 0) continue;
            if (!pk[0]) strncpy(pk, fld[1], sizeof(pk) - 1);
            found = 1;
            break;
        }
        fclose(pend);
    }
    if (!found) { fprintf(stderr, "id %s is not pending\n", id); return 1; }

    /* rewrite priv.tsv: exactly one line per id */
    char tmp[600];
    snprintf(tmp, sizeof(tmp), "%s.tmp", PRIVP);
    FILE *in = fopen(PRIVP, "r");
    FILE *out = fopen(tmp, "w");
    if (!out) { if (in) fclose(in); return 1; }
    int wrote = 0;
    if (in) {
        char line[PRIV_LINE_MAX + 8], dec[PRIV_LINE_MAX + 8];
        while (fgets(line, sizeof(line), in)) {
            line[strcspn(line, "\n")] = 0;
            if (!line[0]) continue;
            tsointsoin_decode(dec, line);
            char *fld[3];
            if (split_fields(dec, SEP_FIELD, fld, 3) < 3) continue;
            if (strcmp(fld[0], id) != 0) {
                fprintf(out, "%s\n", line);
                continue;
            }
            if (wrote) continue;                 /* collapse duplicates */
            char rec[PRIV_LINE_MAX], enc[PRIV_LINE_MAX];
            snprintf(rec, sizeof(rec), "%s%c%s%c%d",
                     fld[0], SEP_FIELD, fld[1], SEP_FIELD, lvl);
            tsointsoin_encode(enc, rec);
            fprintf(out, "%s\n", enc);
            wrote = 1;
        }
        fclose(in);
    }
    if (!wrote) {
        char rec[PRIV_LINE_MAX], enc[PRIV_LINE_MAX];
        snprintf(rec, sizeof(rec), "%s%c%s%c%d", id, SEP_FIELD, pk, SEP_FIELD, lvl);
        tsointsoin_encode(enc, rec);
        fprintf(out, "%s\n", enc);
    }
    fclose(out);
    chmod(tmp, 0600);
    if (rename(tmp, PRIVP) != 0) { remove(tmp); return 1; }

    /* clear the id from pending.tsv (all duplicates) */
    FILE *pin = fopen(PENDP, "r");
    if (pin) {
        char ptmp[600];
        snprintf(ptmp, sizeof(ptmp), "%s.tmp", PENDP);
        FILE *pout = fopen(ptmp, "w");
        if (pout) {
            char line[PRIV_LINE_MAX + 8], dec[PRIV_LINE_MAX + 8];
            while (fgets(line, sizeof(line), pin)) {
                line[strcspn(line, "\n")] = 0;
                if (!line[0]) continue;
                tsointsoin_decode(dec, line);
                char *fld[3];
                if (split_fields(dec, SEP_FIELD, fld, 3) >= 3 && strcmp(fld[0], id) == 0) continue;
                fprintf(pout, "%s\n", line);
            }
            fclose(pout);
            chmod(ptmp, 0600);
            rename(ptmp, PENDP);
        }
        fclose(pin);
    }

    printf("approved id=%s level=%d\n", id, lvl);
    return 0;
}
static void c_pending(char **a) {
    (void)a;
    FILE *f = fopen(PENDP, "r");
    if (!f) { printf("pending.tsv: 0 identity(ies)\n"); return; }
    int n = 0;
    char line[PRIV_LINE_MAX + 8], dec[PRIV_LINE_MAX + 8];
    int now = (int)time(NULL);
    printf("id\tpk\tage_s\n");
    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\n")] = 0;
        if (!line[0]) continue;
        tsointsoin_decode(dec, line);
        char *fld[3];
        if (split_fields(dec, SEP_FIELD, fld, 3) < 3) continue;
        int ts = atoi(fld[2]);
        printf("%s\t%s\t%d\n", fld[0], fld[1], now - ts);
        n++;
    }
    fclose(f);
    fprintf(stderr, "pending.tsv: %d identity(ies)\n", n);
}
static void c_privdedupe(char **a) {
    (void)a;
    priv_entry u[256]; int n = 0;
    for (int i = 0; i < PTn; i++) {
        int j = 0;
        while (j < n && strcmp(u[j].id, PT[i].id) != 0) j++;
        if (j == n) { u[n] = PT[i]; n++; }
        else if (PT[i].level > u[j].level) u[j].level = PT[i].level;
    }
    char tmp[600];
    snprintf(tmp, sizeof(tmp), "%s.tmp", PRIVP);
    FILE *out = fopen(tmp, "w");
    if (out) {
        for (int i = 0; i < n; i++) {
            char rec[PRIV_LINE_MAX], enc[PRIV_LINE_MAX];
            snprintf(rec, sizeof(rec), "%.16s%c%.64s%c%d",
                     u[i].id, SEP_FIELD, u[i].pk, SEP_FIELD, u[i].level);
            tsointsoin_encode(enc, rec);
            fprintf(out, "%s\n", enc);
        }
        fclose(out);
        chmod(tmp, 0600);
        rename(tmp, PRIVP);
    }

    static char keep[256][PRIV_LINE_MAX + 8];
    static char kid[256][IDENTITY_HEX_LEN];
    int kn = 0;
    FILE *pin = fopen(PENDP, "r");
    if (pin) {
        char line[PRIV_LINE_MAX + 8], dec[PRIV_LINE_MAX + 8];
        while (fgets(line, sizeof(line), pin) && kn < 256) {
            line[strcspn(line, "\n")] = 0;
            if (!line[0]) continue;
            tsointsoin_decode(dec, line);
            char *fld[3];
            if (split_fields(dec, SEP_FIELD, fld, 3) < 3) continue;
            int approved = 0;
            for (int q = 0; q < n; q++)
                if (strcmp(u[q].id, fld[0]) == 0) { approved = 1; break; }
            if (approved) continue;
            int j = 0;
            while (j < kn && strcmp(kid[j], fld[0]) != 0) j++;
            if (j < kn) continue;
            strncpy(kid[kn], fld[0], IDENTITY_HEX_LEN - 1);
            snprintf(keep[kn], sizeof(keep[kn]), "%s", line);
            kn++;
        }
        fclose(pin);
        snprintf(tmp, sizeof(tmp), "%s.tmp", PENDP);
        out = fopen(tmp, "w");
        if (out) {
            for (int i = 0; i < kn; i++) fprintf(out, "%s\n", keep[i]);
            fclose(out);
            chmod(tmp, 0600);
            rename(tmp, PENDP);
        }
    }
    printf("priv.tsv: %d identity(ies) | pending.tsv: %d\n", n, kn);
}
static void c_auth(char **a) { int l = auth(a[0]); printf("%d\n", l); exit(l > 0 ? 0 : 1); }
static void c_cores(char **a) { (void)a; printf("%d\n", cores()); }
static void c_role(char **a) { (void)a; printf("%s cores=%d\n", is_router() ? "router" : "worker", cores()); }
static void c_encode(char **a) { char o[PRIV_LINE_MAX + 8]; tsointsoin_encode(o, a[0]); printf("%s\n", o); }
static void c_myid(char **a) {
    unsigned char sk[SIGN_SK], pk[SIGN_PK];
    char id[IDENTITY_HEX_LEN];
    if (beaut_device_load(sk, pk) == 0) {
        beaut_device_id(id, pk);
        sodium_memzero(sk, sizeof(sk));
    } else if (a[0]) {
        unsigned char key[KEY_BYTES];
        derive(key, a[0]);
        beaut_identity(id, key);
        sodium_memzero(key, sizeof(key));
    } else {
        fputs("no device key\n", stderr);
        exit(1);
    }
    printf("%s\n", id);
}
static void c_migrate(char **a) {
    if (!a[0]) { fputs("usage: migrate <pw>\n", stderr); exit(1); }
    unsigned char sk[SIGN_SK], pk[SIGN_PK];
    if (beaut_device_ensure(sk, pk) != 0) { fputs("cannot create device key\n", stderr); exit(1); }
    sodium_memzero(sk, sizeof(sk));
    char nid[IDENTITY_HEX_LEN], npk[SIGN_PK_HEX];
    beaut_device_id(nid, pk);
    hex_encode(npk, pk, sizeof(pk));

    unsigned char key[KEY_BYTES];
    derive(key, a[0]);
    char lid[IDENTITY_HEX_LEN];
    beaut_identity(lid, key);
    sodium_memzero(key, sizeof(key));

    if (strcmp(lid, nid) == 0) { printf("device id=%s\n", nid); return; }

    priv_entry u[256]; int un = 0, migrated = 0, got_level = 0;
    for (int i = 0; i < PTn; i++) {
        const char *id = PT[i].id;
        if (strcmp(id, lid) == 0) { id = nid; if (!got_level) { got_level = PT[i].level; migrated = 1; } }
        int j = 0;
        while (j < un && strcmp(u[j].id, id) != 0) j++;
        if (j == un) {
            snprintf(u[un].id, sizeof(u[un].id), "%.16s", id);
            snprintf(u[un].pk, sizeof(u[un].pk), "%.64s",
                     strcmp(id, nid) == 0 ? npk : PT[i].pk);
            u[un].level = PT[i].level;
            un++;
        } else if (PT[i].level > u[j].level) {
            u[j].level = PT[i].level;
        }
    }

    if (access(PRIVP, R_OK) == 0) {
        char tmp[600];
        snprintf(tmp, sizeof(tmp), "%s.tmp", PRIVP);
        FILE *out = fopen(tmp, "w");
        if (out) {
            for (int i = 0; i < un; i++) {
                char rec[PRIV_LINE_MAX], enc[PRIV_LINE_MAX];
                snprintf(rec, sizeof(rec), "%.16s%c%.64s%c%d",
                         u[i].id, SEP_FIELD, u[i].pk, SEP_FIELD, u[i].level);
                tsointsoin_encode(enc, rec);
                fprintf(out, "%s\n", enc);
            }
            fclose(out);
            chmod(tmp, 0600);
            rename(tmp, PRIVP);
        }
    }

    /* pending: replace our legacy record and drop duplicates */
    FILE *pin = fopen(PENDP, "r");
    if (pin) {
        char tmp[600];
        snprintf(tmp, sizeof(tmp), "%s.tmp", PENDP);
        FILE *out = fopen(tmp, "w");
        if (out) {
            char line[PRIV_LINE_MAX + 8], dec[PRIV_LINE_MAX + 8];
            char seen[256][IDENTITY_HEX_LEN]; int sn = 0;
            while (fgets(line, sizeof(line), pin)) {
                line[strcspn(line, "\n")] = 0;
                if (!line[0]) continue;
                tsointsoin_decode(dec, line);
                char *fld[3];
                if (split_fields(dec, SEP_FIELD, fld, 3) < 3) continue;
                const char *id = fld[0];
                const char *pkx = fld[1];
                if (strcmp(id, lid) == 0) { id = nid; pkx = npk; migrated = 1; }
                int j = 0;
                while (j < sn && strcmp(seen[j], id) != 0) j++;
                if (j < sn) continue;
                snprintf(seen[sn], IDENTITY_HEX_LEN, "%.16s", id);
                sn++;
                char rec[PRIV_LINE_MAX], enc[PRIV_LINE_MAX];
                snprintf(rec, sizeof(rec), "%s%c%s%c%s", id, SEP_FIELD, pkx, SEP_FIELD, fld[2]);
                tsointsoin_encode(enc, rec);
                fprintf(out, "%s\n", enc);
            }
            fclose(out);
            chmod(tmp, 0600);
            rename(tmp, PENDP);
        }
        fclose(pin);
    }

    if (migrated) printf("migrated %s -> %s level=%d\n", lid, nid, got_level);
    else printf("device id=%s\n", nid);
}
static void c_decode(char **a) { char o[PRIV_LINE_MAX + 8]; tsointsoin_decode(o, a[0]); printf("%s\n", o); }
static int c_steg(char **a) {
    if (!a[0]) {
        fputs("usage: steg pack <src> <outdir> [addr] [stamp]\n"
              "       steg unpack <dir> <stamp> <out>\n"
              "       steg missing <dir> <stamp>\n"
              "       steg resend <src> <outdir> <stamp> [package...]\n"
              "       steg inspect <file>\n", stderr);
        return 1;
    }
    if (!strcmp(a[0], "pack")) {
        if (!a[1] || !a[2]) { fputs("usage: steg pack <src> <outdir> [addr] [stamp]\n", stderr); return 1; }
        return steg_pack(a[1], a[2], a[3], a[4]);
    }
    if (!strcmp(a[0], "unpack")) {
        if (!a[1] || !a[2] || !a[3]) { fputs("usage: steg unpack <dir> <stamp> <out>\n", stderr); return 1; }
        return steg_unpack(a[1], a[2], a[3]);
    }
    if (!strcmp(a[0], "missing")) {
        if (!a[1] || !a[2]) { fputs("usage: steg missing <dir> <stamp>\n", stderr); return 1; }
        return steg_missing(a[1], a[2]);
    }
    if (!strcmp(a[0], "resend")) {
        if (!a[1] || !a[2] || !a[3]) {
            fputs("usage: steg resend <src> <outdir> <stamp> [package...]\n", stderr);
            return 1;
        }
        int n = 0, cap = 16;
        int *v = malloc((size_t)cap * sizeof(int));
        if (!v) return 1;
        for (int i = 4; a[i]; i++) {
            if (n == cap) {
                cap *= 2;
                int *nv = realloc(v, (size_t)cap * sizeof(int));
                if (!nv) { free(v); return 1; }
                v = nv;
            }
            v[n++] = atoi(a[i]);
        }
        int rc = steg_resend(a[1], a[2], a[3], v, n);
        free(v);
        return rc;
    }
    if (!strcmp(a[0], "inspect")) {
        if (!a[1]) { fputs("usage: steg inspect <file>\n", stderr); return 1; }
        return steg_inspect(a[1]);
    }
    fputs("steg: unknown subcommand\n", stderr);
    return 1;
}
static void c_post(char **a) { unsigned char k[KEY_BYTES]; derive(k, a[4]); int rc = log_post(a[1], a[2], a[3], k); sodium_memzero(k, sizeof(k)); if (rc) exit(1); }
static void c_read(char **a) { unsigned char k[KEY_BYTES]; derive(k, a[2]); static char buf[65536]; int off = atoi(a[1]); int n = log_read(off, buf, sizeof(buf), k); sodium_memzero(k, sizeof(k)); if (n > off) fputs(buf, stdout); fprintf(stderr, "%d\n", n > off ? n - off : 0); }
static void c_peers(char **a) { static peer_t p[256]; unsigned char k[KEY_BYTES]; derive(k, a[1]); int n = peers_scan(p, 256, k); sodium_memzero(k, sizeof(k)); for (int i = 0; i < n; i++) printf("%s\t%s\t%.1f\t%d\t%s\t%s\n", p[i].name, p[i].ip, p[i].load, p[i].cores, p[i].domain, p[i].id); }
static void c_pick(char **a) { unsigned char k[KEY_BYTES]; derive(k, a[1]); char best[IP_MAX], next[IP_MAX]; int rc = pick(best, next, a[2], k); sodium_memzero(k, sizeof(k)); if (rc) exit(1); printf("%s\n%s\n", best, next); }
static void c_heartbeat(char **a) {
    double load = 0;
    FILE *f = fopen("/proc/loadavg", "r");
    if (f) { if (fscanf(f, "%lf", &load) != 1) load = 0; fclose(f); }
    char pl[IP_MAX + LOAD_STR_MAX + BEAUT_NAME_MAX + 16];
    snprintf(pl, sizeof(pl), "%s%c%.1f%c%d%c%s",
             a[2], SEP_LOAD, load, SEP_LOAD, cores(), SEP_LOAD, C.domain);
    unsigned char k[KEY_BYTES];
    derive(k, a[3]);
    log_post(a[1], P_HEARTBEAT, pl, k);
    sodium_memzero(k, sizeof(k));
}
static void c_retain(char **a) { (void)a; retain(); }
static void help(void) {
    fprintf(stderr,
      "usage: beaut-tool <cmd> [args]\n"
      "  join <pending> <pw>        approve <pending> <priv> <id> <lvl> [pk]\n"
      "  pending                    list pending identities\n"
      "  auth <pw>                  cores                    role\n"
      "  post <log> <w> <act> <payload> <pw>\n"
      "  read <log> <offset> <pw>   peers <log> <pw>         pick <log> <pw>\n"
      "  heartbeat <log> <w> <ip> <pw>                       retain\n"
      "  hub <port> <pw>            peer <host> <port> <pw>\n"
      "  push <host> <port> <pw>\n"
      "  steg pack <src> <outdir> [addr] [stamp]\n"
      "  steg unpack <dir> <stamp> <out>   steg missing <dir> <stamp>\n"
      "  steg resend <src> <outdir> <stamp> [package...]\n"
      "  encode <text>              decode <text>\n");
}
int orch_run(int argc, char **argv) {
    if (sodium_init() < 0) { fputs("sodium_init failed\n", stderr); return 1; }
    cfg_init();
    priv_load();
    if (argc < 2) { help(); return 1; }
    const char *cmd = argv[1];
    char **a = argv + 2;
    if      (!strcmp(cmd, "join")) c_join(a);
    else if (!strcmp(cmd, "approve")) return c_approve(a);
    else if (!strcmp(cmd, "privdedupe")) c_privdedupe(a);
    else if (!strcmp(cmd, "pending")) c_pending(a);
    else if (!strcmp(cmd, "auth")) c_auth(a);
    else if (!strcmp(cmd, "cores")) c_cores(a);
    else if (!strcmp(cmd, "role")) c_role(a);
    else if (!strcmp(cmd, "post")) c_post(a);
    else if (!strcmp(cmd, "read")) c_read(a);
    else if (!strcmp(cmd, "peers")) c_peers(a);
    else if (!strcmp(cmd, "pick")) c_pick(a);
    else if (!strcmp(cmd, "heartbeat")) c_heartbeat(a);
    else if (!strcmp(cmd, "hub") || !strcmp(cmd, "router") || !strcmp(cmd, "orchestrator") || !strcmp(cmd, "listen")) {
        int i = (a[0] && !strcmp(a[0], "--listen")) ? 1 : 0;
        if (!a[i] || !a[i + 1]) { help(); return 1; }
        const char *port = strrchr(a[i], ':');
        return net_hub(port ? port + 1 : a[i], a[i + 1]);
    }
    else if (!strcmp(cmd, "peer")) { if (!a[0] || !a[1] || !a[2]) { help(); return 1; } return net_peer(a[0], a[1], a[2]); }
    else if (!strcmp(cmd, "push")) { if (!a[0] || !a[1] || !a[2]) { help(); return 1; } return net_push(a[0], a[1], a[2]); }
    else if (!strcmp(cmd, "steg")) return c_steg(a);
    else if (!strcmp(cmd, "retain")) c_retain(a);
    else if (!strcmp(cmd, "encode")) c_encode(a);
    else if (!strcmp(cmd, "myid")) c_myid(a);
    else if (!strcmp(cmd, "migrate")) c_migrate(a);
    else if (!strcmp(cmd, "decode")) c_decode(a);
    else { help(); return 1; }
    return 0;
}
