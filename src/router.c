#include "ft.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
static void pump(int from, int to) {
    char buf[8192]; ssize_t r;
    while ((r = read(from, buf, sizeof(buf))) > 0) {
        ssize_t o = 0;
        while (o < r) { ssize_t w = write(to, buf + o, (size_t)(r - o)); if (w <= 0) break; o += w; }
    }
}
int main(int argc, char **argv) {
    const char *bind_addr = env_str("ROUTER_LISTEN", "0.0.0.0");  /* never name it "listen" */
    int lport = env_int("ROUTER_PORT", 443);
    const char *orch = env_str("ORCHESTRATOR_IP", "127.0.0.1");
    int oport = env_int("ORCHESTRATOR_PORT", 7700);
    if (argc > 1) oport = atoi(argv[1]);
    signal(SIGCHLD, SIG_IGN);                       /* no zombies */
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { perror("socket"); return 1; }
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET;
    sa.sin_port = htons((unsigned short)lport);
    inet_pton(AF_INET, bind_addr, &sa.sin_addr);
    if (bind(srv, (struct sockaddr *)&sa, sizeof(sa)) < 0) { perror("bind"); return 1; }
    if (listen(srv, 128) < 0) { perror("listen"); return 1; }
    fprintf(stderr, "router %s:%d -> %s:%d\n", bind_addr, lport, orch, oport);
    for (;;) {
        int c = accept(srv, NULL, NULL);
        if (c < 0) continue;
        int up = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in ua = {0};
        ua.sin_family = AF_INET;
        ua.sin_port = htons((unsigned short)oport);
        inet_pton(AF_INET, orch, &ua.sin_addr);
        if (connect(up, (struct sockaddr *)&ua, sizeof(ua)) < 0) { close(c); close(up); continue; }
        pid_t pid = fork();
        if (pid < 0) { close(c); close(up); continue; }
        if (pid == 0) { pump(c, up); close(up); close(c); _exit(0); }
        pump(up, c);
        close(c); close(up);
    }
}
