#ifndef SCHED_H
#define SCHED_H
#include "cfg.h"
#include "ft.h"
typedef struct {
    char name[BEAUT_NAME_MAX];
    char ip[IP_MAX];
    int last_seen;
    double load;
    int cores;
} peer_t;
int cores(void);
static void sort_best(peer_t *p, int n);
int peers_scan(peer_t *out, int max, const unsigned char *key);
int pick(char *best, char *next, const unsigned char *key);
#endif
