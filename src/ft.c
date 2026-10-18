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
