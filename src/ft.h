#ifndef FT_H
#define FT_H
#include <stdbool.h>
#include <stddef.h>
#define BLANK_CHARS " \t\r\n"
#define HEXBUF(n) ((n) * 2 + 1)
#define BEAUT_NAME_MAX 128
#define IP_MAX 64
#define ACTION_MAX 64
#define P_HEARTBEAT "heartbeat"
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
