#ifndef ORCH_H
#define ORCH_H

#include <stddef.h>

/* Library entry point: the orchestrator/server tool (formerly main in orch.c).
   Returns the process exit code. */
int orch_run(int argc, char **argv);

/* Shared with the network layer (src/net.c). */
int beaut_verify_record(const char *line, const unsigned char *key,
                        char *worker, size_t wl, char *action, size_t al,
                        char *payload, size_t pl, char *oid, size_t ol,
                        int *level);
int beaut_append_raw(const char *line, size_t len);
const char *beaut_log_path(void);

#endif
