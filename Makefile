# beaut — server-oriented C build (orchestrator / router / side tooling)
#
#   make            build bin/$(NAME)  (= bin/beaut)   <- default entry point
#   make beaut      same as above (separate command, NAME target)
#   make beaut-router  build the standalone router binary (bin/beaut-router)
#   make deploy     link beaut/config.env as cluster.env
#   make install    install bin/$(NAME) into $(BIN_DIR)
#   make clean

CC      = gcc
CFLAGS  = -O2 -march=armv8-a+crypto -Wall -Wextra -Isrc
LDLIBS  = -lsodium

NAME    ?= beaut
OUT     = bin/$(NAME)                 # artifact path (root dir has a `beaut/` submodule)
BIN_DIR ?= /usr/local/bin

# ── sources ──
ORCH_SRCS  = src/orch.c src/crypt.c src/ft.c src/tsointsoin.c
ROUTER_SRCS = src/router.c src/ft.c
BEAUT_MAIN = src/beaut_main.c
ROUTER_MAIN = src/router_main.c

.PHONY: all $(NAME) deploy install clean

all: $(OUT)

# `make beaut` alias -> builds bin/beaut
$(NAME): $(OUT)

# ── $NAME (separate compile command) ──
# server-oriented binary: orchestrator/watch/encode/decode/role/join/peers/heartbeat
# main lives in src/beaut_main.c (separated from the orch.c library).
$(OUT): $(ORCH_SRCS:.c=.o) $(BEAUT_MAIN:.c=.o)
	@mkdir -p bin
	$(CC) $(CFLAGS) -o $@ src/orch.o src/crypt.o src/ft.o src/tsointsoin.o src/beaut_main.o $(LDLIBS)

# ── router (separate main(), kept as its own target) ──
# main lives in src/router_main.c (separated from the router.c library).
beaut-router: $(ROUTER_SRCS:.c=.o) $(ROUTER_MAIN:.c=.o)
	@mkdir -p bin
	$(CC) $(CFLAGS) -o bin/beaut-router src/router.o src/ft.o src/router_main.o

# ── pattern compile ──
src/%.o: src/%.c
	$(CC) $(CFLAGS) -c -o $@ $<

# ── deployment: beaut/config.env linked as cluster.env ──
deploy:
	@[ -f beaut/config.env ] || { \
		echo "error: beaut/config.env not found — create it first"; \
		exit 1; \
	}
	ln -sf "$$(pwd)/beaut/config.env" cluster.env
	@echo "cluster.env -> beaut/config.env"

# ── install ──
install: $(OUT)
	install -d -m 0755 "$(BIN_DIR)"
	install -m 0755 "$(OUT)" "$(BIN_DIR)/$(NAME)"
	@echo "installed $(NAME) -> $(BIN_DIR)/$(NAME)"

clean:
	rm -rf bin src/*.o cluster.env
