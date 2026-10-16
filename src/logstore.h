#ifndef LOGSTORE_H
#define LOGSTORE_H
#include "cfg.h"
#include "crypt.h"
#include "ft.h"
int log_post(const char *w, const char *act, const char *pl, const unsigned char *key);
int log_read(int offset, char *buf, size_t bufsz, const unsigned char *key);
void retain(void);
#endif
