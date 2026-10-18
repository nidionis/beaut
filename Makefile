CC      = gcc
CFLAGS  = -O2 -march=armv8-a+crypto -Wall -Wextra -Isrc
LDLIBS  = -lsodium

all: beaut-tool beaut-router

beaut-tool: src/orch.c src/crypt.c src/ft.c src/tsointsoin.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

beaut-router: src/router.c src/ft.c
	$(CC) $(CFLAGS) -o $@ $^

test: beaut-tool
	@test "$(./beaut-tool encode abc)" = "nop" && echo "smoke OK"

clean:
	rm -f beaut-tool beaut-router

.PHONY: all test clean
