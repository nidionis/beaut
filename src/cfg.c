#include "cfg.h"
#include <stdio.h>
#include <string.h>
/* orchestrator configuration: derived parameters, identity domains, paths */
void cfg_init(void) {
    env_frac("SALV_COEF", 1, 3, &C.salv_num, &C.salv_den);
    C.min_cores = env_int("BEAUT_MIN_CORES", 1);
    C.max_cores = env_int("BEAUT_MAX_CORES", 0);
    C.kdf_ops = env_int("BEAUT_KDF_OPS", crypto_pwhash_OPSLIMIT_INTERACTIVE);
    C.kdf_mem = env_int("BEAUT_KDF_MEM", crypto_pwhash_MEMLIMIT_INTERACTIVE);
    C.ttl_s = env_int("BEAUT_TTL_S", 300);
    C.stale_s = env_int("BEAUT_STALE_S", 90);
    C.reserve_nodes = env_int("SCHEDULER_RESERVE_NODES", 1);
    C.retain_active_s = env_int("BEAUT_RETAIN_ACTIVE_S", 86400);
    C.retain_archive_s = env_int("BEAUT_RETAIN_ARCHIVE_S", 2592000);
    C.state_dir = env_str("BEAUT_STATE_DIR", "/var/lib/beaut");
    C.etc_dir = env_str("BEAUT_ETC_DIR", "/etc/beaut");
    C.domain = env_str("BEAUT_DOMAIN", "");
    snprintf(LOGP, sizeof(LOGP), "%s/%s", C.state_dir, F_LOG);
    snprintf(PENDP, sizeof(PENDP), "%s/%s", C.etc_dir, F_PENDING);
    snprintf(PRIVP, sizeof(PRIVP), "%s/%s", C.etc_dir, F_PRIV);
    snprintf(ARCHP, sizeof(ARCHP), "%s/%s", C.state_dir, F_ARCHIVE);
}
void derive_key(unsigned char *k, const char *pw) {
    unsigned char salt[SALT_BYTES];
    crypto_generichash(salt, sizeof(salt),
                    (const unsigned char *)pw, strlen(pw),
                    (const unsigned char *)SALT_CTX, sizeof(SALT_CTX) - 1);
    if (crypto_pwhash(key, KEY_BYTES, pw, strlen(pw), salt, C.kdf_ops, C.kdf_mem,
                      crypto_pwhash_ALG_ARGON2ID13) != 0)
        sodium_memzero(key, KEY_BYTES);
}
int is_router(void) { return strstr(C.domain, DOMAIN_VM) != NULL; }
