#include "logstore.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
/* encrypted log: append entries, read them back, prune them */
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
int log_read(int offset, char *buf, size_t bufsz, const unsigned char *key) {
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
void retain(void) {
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
