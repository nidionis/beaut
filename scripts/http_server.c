/* http_server.c — minimal TCP listener: listen + accept loop, fork per
 * connection, per connection stdin/stdout = socket. Low-level socat-enough
 * replacement for the HTTP server front-end. One connection = one bash handler.
 *
 * usage: http_server <port> <handler>
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <port> <handler>\n", argv[0]);
    return 2;
  }
  signal(SIGCHLD, SIG_IGN);
  int port = atoi(argv[1]);
  const char *handler = argv[2];

  int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
  if (listen_fd < 0) { perror("beaut: socket"); return 1; }
  int one = 1;
  setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  addr.sin_port = htons((uint16_t)port);
  if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { perror("beaut: bind"); return 1; }
  if (listen(listen_fd, 16) != 0) { perror("beaut: listen"); return 1; }

  for (;;) {
    int conn = accept(listen_fd, NULL, NULL);
    if (conn < 0) { break; }
    pid_t pid = fork();
    if (pid == 0) {
      close(listen_fd);
      dup2(conn, STDIN_FILENO);
      dup2(conn, STDOUT_FILENO);
      close(conn);
      execl("/bin/bash", "bash", handler, (char *)NULL);
      _exit(127);
    }
    close(conn);
  }
  return 0;
}
