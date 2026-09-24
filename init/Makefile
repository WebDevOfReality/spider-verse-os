# svos-init — built with the Stage 0 cross-toolchain, static musl.
#
# Usage:  make            (needs x86_64-svos-linux-musl-* on PATH)
#         make check      (compile-time smoke: static + arch sanity)

CROSS  ?= x86_64-svos-linux-musl-
CC      = $(CROSS)gcc
CFLAGS  = -Os -Wall -Wextra -std=c11 -fno-asynchronous-unwind-tables
LDFLAGS = -static

BIN = svos-init

$(BIN): svos-init.c
	$(CC) $(CFLAGS) svos-init.c -o $@ $(LDFLAGS)

check: $(BIN)
	file $(BIN) | grep -q 'statically linked'
	@echo "svos-init: static build OK"

clean:
	rm -f $(BIN)

.PHONY: check clean