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
