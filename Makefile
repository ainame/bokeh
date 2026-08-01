.PHONY: all release install linux profile benchmark terminal-smoke

all: release install

release:
	swift build --traits MmapBuffer -c release
install:
	cp ./.build/release/fltr ~/.local/bin/

# Linux static build with mimalloc and increased stack size (aarch64 by default)
# Usage: make linux (override via env: ARCH=x86_64 MIMALLOC_VERSION=3.0.10 make linux)

linux:
	scripts/build_linux.sh

# Usage: make profile INPUT=./input.txt ARGS="--query foo"
profile: release
	@if [ -n "$(INPUT)" ]; then \
		INPUT_ARG="--input $(INPUT)"; \
	else \
		INPUT_ARG=""; \
	fi; \
	scripts/profile_xctrace.sh $$INPUT_ARG -- $(ARGS)

# Usage: make benchmark COUNT=500000 MODE=all RUNS=5 WARMUP=2 SEED=1337
benchmark: release
	swift build -c release --package-path Benchmarks --target matcher-benchmark
	Benchmarks/.build/release/matcher-benchmark \
		--count $(COUNT) \
		--mode $(MODE) \
		--runs $(RUNS) \
		--warmup $(WARMUP) \
		--seed $(SEED)

# macOS PTY integration smoke test for input/render/teardown ownership.
terminal-smoke: release
	expect scripts/terminal_smoke_test.expect ./.build/release/fltr

COUNT ?= 500000
MODE ?= all
RUNS ?= 5
WARMUP ?= 2
SEED ?= 1337
