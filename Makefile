CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -Isrc
LDLIBS  ?= -lsodium

all: beaut-tool beaut-router

beaut-tool: src/orch.c src/crypt.c src/ft.c src/steg_hide.c src/cfg.c src/sched.c src/logstore.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

beaut-router: src/router.c src/ft.c
	$(CC) $(CFLAGS) -o $@ $^

test: beaut-tool
	@test "$(./beaut-tool encode abc)" = "nop" && echo "smoke OK"

clean:
	rm -f beaut-tool beaut-router

.PHONY: all test clean
