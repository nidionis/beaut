#include "crypt.h"
#include "ft.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
void beaut_derive_key(unsigned char *key, const char *pw, int ops, int mem) {
    unsigned char salt[SALT_BYTES];
    crypto_generichash(salt, sizeof(salt),
                       (const unsigned char *)pw, strlen(pw),
                       (const unsigned char *)SALT_CTX, sizeof(SALT_CTX) - 1);
    if (crypto_pwhash(key, KEY_BYTES, pw, strlen(pw), salt, ops, mem,
                      crypto_pwhash_ALG_ARGON2ID13) != 0)
        sodium_memzero(key, KEY_BYTES);
}
void beaut_identity(char *out, const unsigned char *key) {
    sodium_bin2hex(out, IDENTITY_HEX_LEN, key, IDENTITY_BYTES);
}
void beaut_device_id(char *out, const unsigned char *pk) {
    unsigned char h[crypto_hash_sha256_BYTES];
    crypto_hash_sha256(h, pk, SIGN_PK);
    sodium_bin2hex(out, IDENTITY_HEX_LEN, h, IDENTITY_BYTES);
    sodium_memzero(h, sizeof(h));
}
static void device_path(char *out, size_t n) {
    const char *p = getenv("BEAUT_DEVICE_KEY");
    if (p && *p) { snprintf(out, n, "%s", p); return; }
    const char *etc = getenv("BEAUT_ETC_DIR");
    if (!etc || !*etc) etc = "/etc/beaut";
    snprintf(out, n, "%s/device.key", etc);
}
int beaut_device_load(unsigned char *sk, unsigned char *pk) {
    char path[512];
    device_path(path, sizeof(path));
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    unsigned char buf[SIGN_SK];
    size_t n = fread(buf, 1, sizeof(buf), f);
    fclose(f);
    if (n != sizeof(buf)) { sodium_memzero(buf, sizeof(buf)); return -1; }
    memcpy(sk, buf, SIGN_SK);
    memcpy(pk, buf + SIGN_SK - SIGN_PK, SIGN_PK);   /* libsodium sk = seed||pk */
    sodium_memzero(buf, sizeof(buf));
    return 0;
}
int beaut_device_ensure(unsigned char *sk, unsigned char *pk) {
    if (beaut_device_load(sk, pk) == 0) return 0;
    unsigned char s[SIGN_SK], p[SIGN_PK];
    crypto_sign_keypair(p, s);
    char path[512], tmp[600];
    device_path(path, sizeof(path));
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) { sodium_memzero(s, sizeof(s)); return -1; }
    ssize_t w = write(fd, s, sizeof(s));
    fsync(fd);
    close(fd);
    if (w != (ssize_t)sizeof(s) || rename(tmp, path) != 0) {
        remove(tmp);
        sodium_memzero(s, sizeof(s));
        return -1;
    }
    memcpy(sk, s, SIGN_SK);
    memcpy(pk, p, SIGN_PK);
    sodium_memzero(s, sizeof(s));
    return 0;
}
int beaut_encrypt(unsigned char **out, size_t *outlen,
                  const unsigned char *pt, size_t ptlen, const unsigned char *key) {
    *out = malloc(NONCE_BYTES + ptlen + TAG_BYTES);
    if (!*out) return -1;
    randombytes_buf(*out, NONCE_BYTES);
    unsigned long long clen;
    if (crypto_aead_xchacha20poly1305_ietf_encrypt(*out + NONCE_BYTES, &clen,
            pt, ptlen, NULL, 0, NULL, *out, key)) { free(*out); return -1; }
    *outlen = NONCE_BYTES + clen;
    return 0;
}
int beaut_decrypt(unsigned char **out, size_t *outlen,
                  const unsigned char *blob, size_t bloblen, const unsigned char *key) {
    if (bloblen < (size_t)(NONCE_BYTES + TAG_BYTES)) return -1;
    *out = malloc(bloblen - NONCE_BYTES + 1);
    if (!*out) return -1;
    unsigned long long plen;
    if (crypto_aead_xchacha20poly1305_ietf_decrypt(*out, &plen, NULL,
            blob + NONCE_BYTES, bloblen - NONCE_BYTES, NULL, 0, blob, key)) {
        free(*out); return -1;
    }
    (*out)[plen] = 0;
    *outlen = plen;
    return 0;
}
