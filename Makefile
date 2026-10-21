# beaut — C build for the beaut tool (orchestrator / watch / peers / ...)
#
#   make               build bin/beaut        <- default (driven by scripts/build.sh)
#   make beaut-router  build the legacy router binary (bin/beaut-router)
#   make install       install bin/beaut into $(BIN_DIR) (default /usr/local/bin)
#   make clean
#
# scripts/build.sh passes the architecture-appropriate CFLAGS; these defaults
# are only for a manual `make`.

CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -Isrc
LDLIBS  = -lsodium

NAME    ?= beaut
OUT      = bin/$(NAME)
BIN_DIR ?= /usr/local/bin

ORCH_SRCS   = src/orch.c src/crypt.c src/ft.c src/tsointsoin.c
ROUTER_SRCS = src/router.c src/ft.c

.PHONY: all $(NAME) beaut-router install clean

all: $(OUT)

$(NAME): $(OUT)

$(OUT): $(ORCH_SRCS:.c=.o) src/beaut_main.o
	@mkdir -p bin
	$(CC) $(CFLAGS) -o $@ $(ORCH_SRCS:.c=.o) src/beaut_main.o $(LDLIBS)

beaut-router: $(ROUTER_SRCS:.c=.o) src/router_main.o
	@mkdir -p bin
	$(CC) $(CFLAGS) -o bin/beaut-router $(ROUTER_SRCS:.c=.o) src/router_main.o

src/%.o: src/%.c
	$(CC) $(CFLAGS) -c -o $@ $<

install: $(OUT)
	install -d -m 0755 "$(BIN_DIR)"
	install -m 0755 "$(OUT)" "$(BIN_DIR)/$(NAME)"

clean:
	rm -rf bin src/*.o cluster.env
