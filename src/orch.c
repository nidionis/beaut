#include "cfg.h"
#include "crypt.h"
#include "ft.h"
#include "sched.h"
#include "logstore.h"
#include "steg_hide.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sodium.h>
#define P_HEARTBEAT "heartbeat"
typedef struct { char id[IDENTITY_HEX_LEN]; char pk[SIGN_PK_HEX]; int level; } priv_entry;
static priv_entry PT[256];
static int PTn = 0;
/* orchestrator CLI and identity administration */
static int priv_load(void) {
    FILE *f = fopen(PRIVP, "r");
    if (!f) return 0;
    char line[PRIV_LINE_MAX + 8], dec[PRIV_LINE_MAX + 8];
    PTn = 0;
    while (fgets(line, sizeof(line), f) && PTn < 256) {
        line[strcspn(line, "\n")] = 0;
        steg_hide_decode(dec, line);
        char *fld[3];
        if (split_fields(dec, SEP_FIELD, fld, 3) < 3) continue;
        strncpy(PT[PTn].id, fld[0], sizeof(PT[PTn].id) - 1);
        strncpy(PT[PTn].pk, fld[1], sizeof(PT[PTn].pk) - 1);
        PT[PTn].level = atoi(fld[2]);
        PTn++;
    }
    fclose(f);
    return PTn;
}
static int auth(const char *pw) {
    unsigned char key[KEY_BYTES];
    derive_key(key, pw);
    char id[IDENTITY_HEX_LEN];
    beaut_identity(id, key);
    int lvl = 0;
    for (int i = 0; i < PTn; i++) if (strcmp(PT[i].id, id) == 0) { lvl = PT[i].level; break; }
    sodium_memzero(key, sizeof(key));
    return lvl;
}
static void c_join(char **a) {
    unsigned char key[KEY_BYTES];
    derive_key(key, a[0]);
    char id[IDENTITY_HEX_LEN];
    beaut_identity(id, key);
    unsigned char pk[SIGN_PK];
    crypto_generichash(pk, sizeof(pk), key, KEY_BYTES, (const unsigned char *)"pk", 2);
    char pkhex[SIGN_PK_HEX];
    hex_encode(pkhex, pk, sizeof(pk));
    sodium_memzero(key, sizeof(key));
    char line[PRIV_LINE_MAX], enc[PRIV_LINE_MAX];
    snprintf(line, sizeof(line), "%s%c%s%c%d", id, SEP_FIELD, pkhex, SEP_FIELD, (int)time(NULL));
    steg_hide_encode(enc, line);
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
        steg_hide_decode(dec, line);
        char *fld[3];
        if (split_fields(dec, SEP_FIELD, fld, 3) < 3) continue;
        if (strcmp(fld[0], a[2]) != 0) continue;
        char out[PRIV_LINE_MAX], enc[PRIV_LINE_MAX];
        snprintf(out, sizeof(out), "%s%c%s%c%s", fld[0], SEP_FIELD, fld[1], SEP_FIELD, a[3]);
        steg_hide_encode(enc, out);
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
static void c_encode(char **a) { char o[PRIV_LINE_MAX + 8]; steg_hide_encode(o, a[0]); printf("%s\n", o); }
static void c_decode(char **a) { char o[PRIV_LINE_MAX + 8]; steg_hide_decode(o, a[0]); printf("%s\n", o); }
static void c_post(char **a) { unsigned char k[KEY_BYTES]; derive_key(k, a[4]); int rc = log_post(a[1], a[2], a[3], k); sodium_memzero(k, sizeof(k)); if (rc) exit(1); }
static void c_read(char **a) { unsigned char k[KEY_BYTES]; derive_key(k, a[2]); static char buf[65536]; int n = log_read(atoi(a[1]), buf, sizeof(buf), k); sodium_memzero(k, sizeof(k)); if (n > 0) fputs(buf, stdout); fprintf(stderr, "%d\n", n); }
static void c_peers(char **a) { static peer_t p[256]; unsigned char k[KEY_BYTES]; derive_key(k, a[1]); int n = peers_scan(p, 256, k); sodium_memzero(k, sizeof(k)); for (int i = 0; i < n; i++) printf("%s\t%s\t%.1f\t%d\n", p[i].name, p[i].ip, p[i].load, p[i].cores); }
static void c_pick(char **a) { unsigned char k[KEY_BYTES]; derive_key(k, a[1]); char best[IP_MAX], next[IP_MAX]; int rc = pick(best, next, k); sodium_memzero(k, sizeof(k)); if (rc) exit(1); printf("%s\n%s\n", best, next); }
static void c_heartbeat(char **a) {
    double load = 0;
    FILE *f = fopen("/proc/loadavg", "r");
    if (f) { if (fscanf(f, "%lf", &load) != 1) load = 0; fclose(f); }
    char pl[LOAD_STR_MAX + IP_MAX];
    snprintf(pl, sizeof(pl), "%s%c%.1f", a[2], SEP_LOAD, load);
    unsigned char k[KEY_BYTES];
    derive_key(k, a[3]);
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
