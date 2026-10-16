#include "steg_hide.h"
#include <string.h>
void steg_hide_encode(char *out, const char *in) {
    size_t i;
    for (i = 0; in[i]; i++) {
        char c = in[i];
        if (c >= 'a' && c <= 'z') out[i] = (char)('a' + (c - 'a' + 13) % 26);
        else if (c >= 'A' && c <= 'Z') out[i] = (char)('A' + (c - 'A' + 13) % 26);
        else out[i] = c;
    }
    out[i] = 0;
}
void steg_hide_decode(char *out, const char *in) { steg_hide_encode(out, in); }
