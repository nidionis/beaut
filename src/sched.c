#include "sched.h"
#include "logstore.h"
#include <time.h>
/* scheduling policy: how many cores to use, and which peer is best */
static double free_cap(const peer_t *p) { double f = p->cores - p->load; return f > 0 ? f : 0; }
static void sort_best(peer_t *p, int n) {
    for (int i = 1; i < n; i++) {
        peer_t t = p[i]; int j = i - 1;
        while (j >= 0 && free_cap(&p[j]) < free_cap(&t)) { p[j + 1] = p[j]; j--; }
        p[j + 1] = t;
    }
}
int cores(void) {
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
int peers_scan(peer_t *out, int max, const unsigned char *key) {
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
int pick(char *best, char *next, const unsigned char *key) {
    static peer_t p[256];
    int n = peers_scan(p, 256, key);
    if (n < C.reserve_nodes + 1) return -1;
    sort_best(p, n);
    strncpy(best, p[0].ip, IP_MAX - 1); best[IP_MAX - 1] = 0;
    if (n >= C.reserve_nodes + 2) { strncpy(next, p[1].ip, IP_MAX - 1); next[IP_MAX - 1] = 0; }
    else next[0] = 0;
    return 0;
}
