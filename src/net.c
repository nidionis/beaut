/* net.c — the C transport for beaut.
 *
 * A hub is the orchestrator/router front door: it verifies every signed log
 * record, appends it to its own log and rebroadcasts it to connected peers.
 * A peer mirrors the local log to the hub and appends verified records coming
 * from it.  Every record keeps the exact log format, so authentication is the
 * per-request Ed25519 signature (P2) — the socket is not trusted.
 */
#include "crypt.h"
#include "ft.h"
#include "orch.h"
#include <sodium.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <time.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

#define NET_MAX_LINE (LOG_LINE_MAX + 2)
#define NET_MAX_CLI 64
#define RING_MAX 512

typedef struct { char *line; size_t len; } rec_t;
static rec_t ring[RING_MAX];
static int ring_n = 0, ring_pos = 0;

static volatile sig_atomic_t stop = 0;
static int dbg = 0;
static void on_signal(int sig) { (void)sig; stop = 1; }

static void ring_free(void) {
    for (int i = 0; i < ring_n; i++) { free(ring[i].line); ring[i].line = NULL; }
    ring_n = ring_pos = 0;
}
/* ring_add: 1 = new, 0 = already seen */
static int ring_add(const char *line, size_t len) {
    for (int i = 0; i < ring_n; i++)
        if (ring[i].len == len && memcmp(ring[i].line, line, len) == 0) return 0;
    int idx;
    if (ring_n < RING_MAX) idx = ring_n++;
    else { idx = ring_pos; free(ring[idx].line); ring_pos = (ring_pos + 1) % RING_MAX; }
    ring[idx].line = malloc(len + 1);
    if (!ring[idx].line) return 0;
    memcpy(ring[idx].line, line, len);
    ring[idx].line[len] = 0;
    ring[idx].len = len;
    return 1;
}
static int send_all(int fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = send(fd, buf + off, len - off, MSG_NOSIGNAL);
        if (n > 0) { off += (size_t)n; continue; }
        if (n < 0 && (errno == EINTR)) continue;
        return -1;
    }
    return 0;
}
static int tcp_listen(const char *port) {
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;
    if (getaddrinfo(NULL, port, &hints, &res) != 0) return -1;
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { freeaddrinfo(res); return -1; }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (bind(fd, res->ai_addr, res->ai_addrlen) != 0 || listen(fd, 16) != 0) {
        close(fd); freeaddrinfo(res); return -1;
    }
    freeaddrinfo(res);
    return fd;
}
static int tcp_connect(const char *host, const char *port) {
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &res) != 0) return -1;
    int fd = -1;
    for (struct addrinfo *p = res; p; p = p->ai_next) {
        fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, p->ai_addr, p->ai_addrlen) == 0) break;
        close(fd); fd = -1;
    }
    freeaddrinfo(res);
    if (fd >= 0) {
        struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    }
    return fd;
}

/* ── hub ─────────────────────────────────────────────────────────────────── */

typedef struct {
    int fd;
    char buf[NET_MAX_LINE * 2];
    size_t len;
    int count;
    time_t win;
    int bad;
} cli_t;

static cli_t cli[NET_MAX_CLI];
static int ncli = 0;
static unsigned char hub_key[KEY_BYTES];

static void close_cli(int i) {
    if (cli[i].fd >= 0) close(cli[i].fd);
    cli[i].fd = -1;
}
static void broadcast(const char *line, size_t len, int except) {
    for (int i = 0; i < ncli; i++) {
        if (cli[i].fd < 0 || i == except) continue;
        send_all(cli[i].fd, line, len);   /* failures are reaped on the next poll */
    }
}
static void hub_line(const char *line, size_t len, int from) {
    char worker[BEAUT_NAME_MAX], action[ACTION_MAX], oid[IDENTITY_HEX_LEN];
    int level = 0;
    if (beaut_verify_record(line, hub_key, worker, sizeof(worker), action, sizeof(action),
                            NULL, 0, oid, sizeof(oid), &level) != 0) {
        if (from >= 0 && from < ncli) cli[from].bad++;
        return;
    }
    if (level < 1) return;
    char *l = malloc(len + 2);
    if (!l) return;
    memcpy(l, line, len);
    if (len == 0 || l[len - 1] != '\n') l[len++] = '\n';
    l[len] = 0;
    if (ring_add(l, len)) {
        beaut_append_raw(l, len);
        if (dbg) fprintf(stderr, "hub: accepted %s from %s, relay to %d\n", action, oid, ncli);
        broadcast(l, len, from);
    }
    free(l);
}

static void hub_tail(int logfd, char *tail, size_t *taillen, size_t cap) {
    char tmp[16384];
    ssize_t n;
    while ((n = read(logfd, tmp, sizeof(tmp))) > 0) {
        if (*taillen + (size_t)n >= cap) *taillen = 0;
        memcpy(tail + *taillen, tmp, (size_t)n);
        *taillen += (size_t)n;
        size_t start = 0;
        for (size_t i = 0; i < *taillen; i++) {
            if (tail[i] != '\n') continue;
            size_t len = i - start + 1;
            int isnew = ring_add(tail + start, len);
            if (dbg) fprintf(stderr, "hub: tail line %zu new=%d clients=%d\n", len, isnew, ncli);
            if (isnew) broadcast(tail + start, len, -1);
            start = i + 1;
        }
        if (start > 0) {
            memmove(tail, tail + start, *taillen - start);
            *taillen -= start;
        }
    }
}

int net_hub(const char *port, const char *pw) {
    unsigned char key[KEY_BYTES];
    beaut_derive_key(key, pw, crypto_pwhash_OPSLIMIT_INTERACTIVE, crypto_pwhash_MEMLIMIT_INTERACTIVE);
    memcpy(hub_key, key, sizeof(key));
    sodium_memzero(key, sizeof(key));

    int ls = tcp_listen(port);
    if (ls < 0) { fprintf(stderr, "hub: cannot listen on %s: %s\n", port, strerror(errno)); return 1; }
    printf("beaut hub listening on :%s\n", port);
    fflush(stdout);

    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGPIPE, SIG_IGN);

    int logfd = open(beaut_log_path(), O_RDONLY);
    if (logfd >= 0) lseek(logfd, 0, SEEK_END);
    static char tail[NET_MAX_LINE * 4];
    size_t taillen = 0;
    int rate = env_int("BEAUT_HUB_RATE", 240);
    dbg = env_int("BEAUT_NET_DEBUG", 0);

    while (!stop) {
        struct pollfd pfd[NET_MAX_CLI + 1];
        int map[NET_MAX_CLI + 1];
        int np = 1;
        pfd[0].fd = ls; pfd[0].events = POLLIN; pfd[0].revents = 0; map[0] = -1;
        for (int i = 0; i < ncli; i++) {
            if (cli[i].fd < 0) continue;
            pfd[np].fd = cli[i].fd;
            pfd[np].events = POLLIN;
            pfd[np].revents = 0;
            map[np++] = i;
        }
        int pr = poll(pfd, (nfds_t)np, 500);
        if (pr < 0 && errno != EINTR) break;
        if (pr > 0 && (pfd[0].revents & POLLIN)) {
            int fd = accept(ls, NULL, NULL);
            int slot = -1;
            for (int i = 0; i < ncli; i++) if (cli[i].fd < 0) { slot = i; break; }
            if (slot < 0 && ncli < NET_MAX_CLI) slot = ncli++;
            if (fd >= 0 && slot >= 0) {
                cli[slot].fd = fd; cli[slot].len = 0;
                cli[slot].count = 0; cli[slot].win = time(NULL); cli[slot].bad = 0;
                /* replay recent verified history to a late joiner */
                int start = ring_n < RING_MAX ? 0 : ring_pos;
                for (int k = 0; k < ring_n; k++) {
                    int idx = ring_n < RING_MAX ? k : (start + k) % RING_MAX;
                    if (send_all(fd, ring[idx].line, ring[idx].len) != 0) break;
                }
            } else if (fd >= 0) close(fd);
        }
        for (int p = 1; p < np; p++) {
            int i = map[p];
            if (i < 0 || i >= ncli || cli[i].fd < 0) continue;
            short rev = pfd[p].revents;
            if (rev & (POLLHUP | POLLERR | POLLNVAL)) { close_cli(i); continue; }
            if (!(rev & POLLIN)) continue;
            ssize_t n = recv(cli[i].fd, cli[i].buf + cli[i].len,
                             sizeof(cli[i].buf) - cli[i].len - 1, 0);
            if (n <= 0) { close_cli(i); continue; }
            cli[i].len += (size_t)n;
            cli[i].buf[cli[i].len] = 0;
            size_t start = 0;
            int drop = 0;
            for (size_t k = 0; k < cli[i].len; k++) {
                if (cli[i].buf[k] != '\n') continue;
                size_t len = k - start;
                cli[i].buf[k] = 0;
                time_t now = time(NULL);
                if (now - cli[i].win >= 60) { cli[i].win = now; cli[i].count = 0; }
                if (++cli[i].count > rate) {
                    fprintf(stderr, "hub: rate limit, dropping client\n");
                    drop = 1;
                    break;
                }
                hub_line(cli[i].buf + start, len, i);
                start = k + 1;
            }
            if (drop) { close_cli(i); continue; }
            if (start > 0) {
                memmove(cli[i].buf, cli[i].buf + start, cli[i].len - start);
                cli[i].len -= start;
            }
            if (cli[i].bad > 5) close_cli(i);
        }
        if (logfd >= 0) hub_tail(logfd, tail, &taillen, sizeof(tail));
    }
    for (int i = ncli - 1; i >= 0; i--) close_cli(i);
    close(ls);
    if (logfd >= 0) close(logfd);
    ring_free();
    return 0;
}

/* ── one-shot push ───────────────────────────────────────────────────────── */

static void ring_load_tail(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return; }
    long sz = ftell(f);
    long start = sz > (2L << 20) ? sz - (2L << 20) : 0;
    if (fseek(f, start, SEEK_SET) != 0) { fclose(f); return; }
    char *buf = malloc((size_t)(sz - start) + 1);
    if (!buf) { fclose(f); return; }
    size_t n = fread(buf, 1, (size_t)(sz - start), f);
    fclose(f);
    buf[n] = 0;
    char *p = buf;
    while (p && *p) {
        char *nl = strchr(p, '\n');
        if (!nl) break;
        size_t len = (size_t)(nl - p) + 1;
        if (len > 3) ring_add(p, len);
        p = nl + 1;
    }
    free(buf);
}
static int last_log_line(const char *path, char *out, size_t cap) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -1; }
    long sz = ftell(f);
    if (sz <= 0) { fclose(f); return -1; }
    long start = sz > (long)cap - 2 ? sz - ((long)cap - 2) : 0;
    if (fseek(f, start, SEEK_SET) != 0) { fclose(f); return -1; }
    size_t n = fread(out, 1, cap - 2, f);
    fclose(f);
    out[n] = 0;
    char *e = out + n;
    while (e > out && (e[-1] == '\n' || e[-1] == '\r')) e--;
    char *b = e;
    while (b > out && b[-1] != '\n') b--;
    size_t len = (size_t)(e - b);
    if (len == 0) return -1;
    memmove(out, b, len);
    out[len] = 0;
    return 0;
}
/* Send this node's last record to a hub and pull the hub's recent ring. */
int net_push(const char *host, const char *port, const char *pw) {
    unsigned char key[KEY_BYTES];
    beaut_derive_key(key, pw, crypto_pwhash_OPSLIMIT_INTERACTIVE, crypto_pwhash_MEMLIMIT_INTERACTIVE);
    dbg = env_int("BEAUT_NET_DEBUG", 0);
    int fd = tcp_connect(host, port);
    if (fd < 0) { sodium_memzero(key, sizeof(key)); return 1; }

    ring_load_tail(beaut_log_path());
    char line[NET_MAX_LINE];
    if (last_log_line(beaut_log_path(), line, sizeof(line)) == 0) {
        size_t len = strlen(line);
        char *sendbuf = malloc(len + 2);
        if (sendbuf) {
            memcpy(sendbuf, line, len);
            sendbuf[len] = '\n';
            send_all(fd, sendbuf, len + 1);
            ring_add(sendbuf, len + 1);
            free(sendbuf);
        }
    }

    char buf[NET_MAX_LINE * 2];
    size_t blen = 0;
    time_t until = time(NULL) + 2;
    while (!stop && time(NULL) <= until) {
        struct pollfd p = { .fd = fd, .events = POLLIN };
        int pr = poll(&p, 1, 200);
        if (pr < 0 && errno != EINTR) break;
        if (pr > 0 && (p.revents & (POLLHUP | POLLERR | POLLNVAL))) break;
        if (!(pr > 0 && (p.revents & POLLIN))) continue;
        ssize_t n = recv(fd, buf + blen, sizeof(buf) - blen - 1, 0);
        if (n <= 0) break;
        blen += (size_t)n;
        buf[blen] = 0;
        size_t start = 0;
        for (size_t i = 0; i < blen; i++) {
            if (buf[i] != '\n') continue;
            size_t len = i - start + 1;
            char worker[BEAUT_NAME_MAX], action[ACTION_MAX], oid[IDENTITY_HEX_LEN];
            int level = 0;
            if (beaut_verify_record(buf + start, key, worker, sizeof(worker),
                                    action, sizeof(action), NULL, 0, oid, sizeof(oid),
                                    &level) == 0 && level >= 1) {
                if (ring_add(buf + start, len)) beaut_append_raw(buf + start, len);
            }
            start = i + 1;
        }
        if (start > 0) { memmove(buf, buf + start, blen - start); blen -= start; }
    }
    close(fd);
    sodium_memzero(key, sizeof(key));
    ring_free();
    return 0;
}


int net_peer(const char *host, const char *port, const char *pw) {
    unsigned char key[KEY_BYTES];
    beaut_derive_key(key, pw, crypto_pwhash_OPSLIMIT_INTERACTIVE, crypto_pwhash_MEMLIMIT_INTERACTIVE);
    dbg = env_int("BEAUT_NET_DEBUG", 0);

    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGPIPE, SIG_IGN);

    static char rbuf[NET_MAX_LINE * 4];
    size_t rlen = 0;
    static char tbuf[NET_MAX_LINE * 4];
    size_t tlen = 0;

    while (!stop) {
        int fd = tcp_connect(host, port);
        if (fd < 0) {
            fprintf(stderr, "peer: %s:%s unreachable, retrying\n", host, port);
            for (int i = 0; i < 50 && !stop; i++) usleep(100000);
            continue;
        }
        printf("beaut peer connected to %s:%s\n", host, port);
        fflush(stdout);
        int logfd = open(beaut_log_path(), O_RDONLY);
        if (logfd >= 0) lseek(logfd, 0, SEEK_END);
        else fprintf(stderr, "peer: cannot open log %s: %s\n", beaut_log_path(), strerror(errno));
        rlen = tlen = 0;

        while (!stop && fd >= 0) {
            struct pollfd p = { .fd = fd, .events = POLLIN };
            int pr = poll(&p, 1, 500);
            if (pr < 0 && errno != EINTR) break;
            if (pr > 0 && (p.revents & (POLLHUP | POLLERR | POLLNVAL))) break;
            if (pr > 0 && (p.revents & POLLIN)) {
                ssize_t n = recv(fd, rbuf + rlen, sizeof(rbuf) - rlen - 1, 0);
                if (n <= 0) break;
                rlen += (size_t)n;
                rbuf[rlen] = 0;
                size_t start = 0;
                for (size_t i = 0; i < rlen; i++) {
                    if (rbuf[i] != '\n') continue;
                    char worker[BEAUT_NAME_MAX], action[ACTION_MAX], oid[IDENTITY_HEX_LEN];
                    int level = 0;
                    int vr = beaut_verify_record(rbuf + start, key, worker, sizeof(worker),
                                            action, sizeof(action), NULL, 0, oid, sizeof(oid),
                                            &level);
                    if (dbg) fprintf(stderr, "peer: recv verify=%d level=%d action=%s\n", vr, level, vr == 0 ? action : "?");
                    if (vr == 0 && level >= 1) {
                        size_t len = i - start + 1;
                        int isnew = ring_add(rbuf + start, len);
                        if (isnew) beaut_append_raw(rbuf + start, len);
                        if (dbg) fprintf(stderr, "peer: append new=%d len=%zu\n", isnew, len);
                    }
                    start = i + 1;
                }
                if (start > 0) { memmove(rbuf, rbuf + start, rlen - start); rlen -= start; }
                if (rlen >= sizeof(rbuf) - 1) rlen = 0;
            }

            if (logfd >= 0) {
                char tmp[16384];
                ssize_t n;
                while ((n = read(logfd, tmp, sizeof(tmp))) > 0) {
                    if (tlen + (size_t)n >= sizeof(tbuf)) tlen = 0;
                    memcpy(tbuf + tlen, tmp, (size_t)n);
                    tlen += (size_t)n;
                    size_t start = 0;
                    for (size_t i = 0; i < tlen; i++) {
                        if (tbuf[i] != '\n') continue;
                        size_t len = i - start + 1;
                        if (ring_add(tbuf + start, len)) {
                            if (send_all(fd, tbuf + start, len) != 0) { fd = -1; break; }
                        }
                        start = i + 1;
                    }
                    if (start > 0) { memmove(tbuf, tbuf + start, tlen - start); tlen -= start; }
                    if (fd < 0) break;
                }
            }
        }
        if (logfd >= 0) close(logfd);
        if (fd >= 0) close(fd);
        if (!stop) {
            fprintf(stderr, "peer: disconnected, retrying\n");
            for (int i = 0; i < 30 && !stop; i++) usleep(100000);
        }
    }
    sodium_memzero(key, sizeof(key));
    ring_free();
    return 0;
}
