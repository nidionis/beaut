#ifndef PNGSTEG_H
#define PNGSTEG_H

#include <stdint.h>

#define PNG_W 64
#define PNG_H 64
#define PNG_CHANNELS 4
#define PNG_PIXELS (PNG_W * PNG_H * PNG_CHANNELS)
#define PNG_OFFSET 64
#define PNG_CAPACITY (PNG_PIXELS - PNG_OFFSET)

#define STEG_MAGIC "BSTG"
#define STEG_VERSION 1
#define STEG_STAMP_LEN 16
#define STEG_HDR_LEN 66
#define STEG_CHUNK_MAX (PNG_CAPACITY - STEG_HDR_LEN - 24 - 16)

#define STEGANO_MAX_SIZE_DEFAULT (512LL * 1024 * 1024)

int steg_pack(const char *src, const char *outdir, const char *addr, const char *stamp);
int steg_unpack(const char *dir, const char *stamp, const char *out);
int steg_missing(const char *dir, const char *stamp);
int steg_resend(const char *src, const char *outdir, const char *stamp, int *counters, int n);
int steg_inspect(const char *path);

#endif
