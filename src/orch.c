#include "crypt.h"
#include "ft.h"
#include "orch.h"
#include "tsointsoin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
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
typedef struct { char name[BEAUT_NAME_MAX]; char ip[IP_MAX]; char domain[BEAUT_NAME_MAX]; int last_seen; double load; int cores; } peer_t;
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
    unsigned char key[KEY_BYTES];
    derive(key, pw);
    char id[IDENTITY_HEX_LEN];
    beaut_identity(id, key);
    int lvl = 0;
    for (int i = 0; i < PTn; i++)
        if (strcmp(PT[i].id, id) == 0 && PT[i].level > lvl) lvl = PT[i].level;
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
    int i = 0; size_t used = 0;
    while (fgets(line, sizeof(line), f)) {
        i++;
        if (i <= offset) continue;
        char *sp = strchr(line, ' ');
        if (!sp) continue;
        *sp = 0;
        int ts = atoi(line);
        if ((int)time(NULL) - ts > C.ttl_s) continue;
        char *hex = sp + 1;
        hex[strcspn(hex, "\r\n")] = 0;
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
                memcpy(buf + used, entry, (size_t)el); used += (size_t)el; buf[used] = 0;
            }
            free(pt);
        }
        free(raw);
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
        char *f[4];
        if (split_fields(line, SEP_FIELD, f, 4) == 4 && strcmp(f[2], P_HEARTBEAT) == 0
            && now - atoi(f[0]) < C.stale_s) {
            char *sub[4];
            int ns = split_fields(f[3], SEP_LOAD, sub, 4);
            if (ns < 2) { line = nl + 1; continue; }
            int found = 0;
            for (int i = 0; i < count; i++)
                if (strcmp(out[i].name, f[1]) == 0) { out[i].last_seen = atoi(f[0]); found = 1; break; }
            if (!found) {
                strncpy(out[count].name, f[1], BEAUT_NAME_MAX - 1);
                strncpy(out[count].ip, sub[0], IP_MAX - 1);
                out[count].load = atof(sub[1]);
                out[count].last_seen = atoi(f[0]);
                out[count].cores = ns >= 3 ? atoi(sub[2]) : env_int("BEAUT_PEER_CORES", 4);
                if (out[count].cores < 0) out[count].cores = 0;
                out[count].domain[0] = 0;
                if (ns >= 4) strncpy(out[count].domain, sub[3], BEAUT_NAME_MAX - 1);
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
    unsigned char key[KEY_BYTES];
    derive(key, a[1]);
    char id[IDENTITY_HEX_LEN];
    beaut_identity(id, key);
    for (int i = 0; i < PTn; i++)
        if (strcmp(PT[i].id, id) == 0) {
            fprintf(stderr, "id %s already approved\n", id);
            sodium_memzero(key, sizeof(key));
            exit(1);
        }
    if (pending_has(id)) {
        fprintf(stderr, "id %s already pending\n", id);
        sodium_memzero(key, sizeof(key));
        exit(1);
    }
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
    if (!a[2] || !a[3]) { fputs("usage: approve <pending> <priv> <id> <level>\n", stderr); return 1; }
    const char *id = a[2];
    int lvl = atoi(a[3]);
    if (lvl < 1 || lvl > 3) { fputs("level must be 1..3\n", stderr); return 1; }

    char pk[SIGN_PK_HEX] = "";
    int found = 0;

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
static void c_myid(char **a) { unsigned char k[KEY_BYTES]; derive(k, a[0]); char id[IDENTITY_HEX_LEN]; beaut_identity(id, k); sodium_memzero(k, sizeof(k)); printf("%s\n", id); }
static void c_decode(char **a) { char o[PRIV_LINE_MAX + 8]; tsointsoin_decode(o, a[0]); printf("%s\n", o); }
static void c_post(char **a) { unsigned char k[KEY_BYTES]; derive(k, a[4]); int rc = log_post(a[1], a[2], a[3], k); sodium_memzero(k, sizeof(k)); if (rc) exit(1); }
static void c_read(char **a) { unsigned char k[KEY_BYTES]; derive(k, a[2]); static char buf[65536]; int off = atoi(a[1]); int n = log_read(off, buf, sizeof(buf), k); sodium_memzero(k, sizeof(k)); if (n > off) fputs(buf, stdout); fprintf(stderr, "%d\n", n > off ? n - off : 0); }
static void c_peers(char **a) { static peer_t p[256]; unsigned char k[KEY_BYTES]; derive(k, a[1]); int n = peers_scan(p, 256, k); sodium_memzero(k, sizeof(k)); for (int i = 0; i < n; i++) printf("%s\t%s\t%.1f\t%d\t%s\n", p[i].name, p[i].ip, p[i].load, p[i].cores, p[i].domain); }
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
      "  join <pending> <pw>        approve <pending> <priv> <id> <lvl>\n"
      "  auth <pw>                  cores                    role\n"
      "  post <log> <w> <act> <payload> <pw>\n"
      "  read <log> <offset> <pw>   peers <log> <pw>         pick <log> <pw>\n"
      "  heartbeat <log> <w> <ip> <pw>                       retain\n"
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
    else if (!strcmp(cmd, "myid")) c_myid(a);
    else if (!strcmp(cmd, "decode")) c_decode(a);
    else { help(); return 1; }
    return 0;
}
