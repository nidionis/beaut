#ifndef NET_H
#define NET_H

int net_hub(const char *port, const char *pw);
int net_peer(const char *host, const char *port, const char *pw);
int net_push(const char *host, const char *port, const char *pw);

#endif
