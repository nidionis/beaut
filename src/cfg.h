#ifndef CFG_H
#define CFG_H
#include "crypt.h"
#include "ft.h"
#define CFG_PATH_MAX 512
extern char LOGP[CFG_PATH_MAX];
extern char PENDP[CFG_PATH_MAX];
extern char PRIVP[CFG_PATH_MAX];
extern char ARCHP[CFG_PATH_MAX];
typedef struct {
    int salv_num, salv_den, min_cores, max_cores;
    int kdf_ops, kdf_mem, ttl_s, stale_s, reserve_nodes;
    int retain_active_s, retain_archive_s;
    const char *state_dir, *etc_dir, *domain;
} cfg_t;
extern cfg_t C;
void cfg_init(void);
void derive_key(unsigned char *k, const char *pw);
int is_router(void);
#endif
