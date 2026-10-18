#ifndef CRYPT_H
#define CRYPT_H
#include <stddef.h>
#include <sodium.h>
#define KEY_BYTES crypto_aead_xchacha20poly1305_ietf_KEYBYTES
#define NONCE_BYTES crypto_aead_xchacha20poly1305_ietf_NPUBBYTES
#define TAG_BYTES crypto_aead_xchacha20poly1305_ietf_ABYTES
#define SALT_BYTES crypto_pwhash_SALTBYTES
#define SIGN_PK crypto_sign_PUBLICKEYBYTES
#define SIGN_PK_HEX HEXBUF(SIGN_PK)
#define IDENTITY_BYTES 8
#define IDENTITY_HEX_LEN HEXBUF(IDENTITY_BYTES)
#define KEY_HEX_LEN HEXBUF(KEY_BYTES)
#define SALT_CTX "beaut-salt"
#define LOG_HEX_MAX HEXBUF(NONCE_BYTES + MAX_MSG_LEN + TAG_BYTES)
#define LOG_LINE_MAX (TS_STR_MAX + 1 + LOG_HEX_MAX + 1)
#define PRIV_LINE_MAX (IDENTITY_HEX_LEN + 1 + SIGN_PK_HEX + 1 + LEVEL_STR_MAX + 1)
#define MSG_BUF_MAX (BEAUT_NAME_MAX + ACTION_MAX + MAX_MSG_LEN + 4)
void beaut_derive_key(unsigned char *key, const char *pw, int ops, int mem);
void beaut_identity(char *out, const unsigned char *key);
int beaut_encrypt(unsigned char **out, size_t *outlen,
                  const unsigned char *pt, size_t ptlen, const unsigned char *key);
int beaut_decrypt(unsigned char **out, size_t *outlen,
                  const unsigned char *blob, size_t bloblen, const unsigned char *key);
#endif
