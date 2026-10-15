#include "crypt.h"
#include "ft.h"
#include <stdlib.h>
#include <string.h>
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
