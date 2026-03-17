# Torrent — Tmux Arc Orchestrator
# TUI for managing batch Claude Code arc sessions

BINARY     := torrent
CARGO      := cargo
TORRENT    := torrent
TARGET     := $(TORRENT)/target/release/$(BINARY)
PLUGIN_DIR := ./plugins/rune

# ─── Build ──────────────────────────────────────

.PHONY: build dev install clean

## Build release binary
build:
	cd $(TORRENT) && $(CARGO) build --release

## Build debug binary (faster compile, slower runtime)
dev:
	cd $(TORRENT) && $(CARGO) build

## Install to /usr/local/bin/
install: build
	cp $(TARGET) /usr/local/bin/$(BINARY)
	@echo "Installed $(BINARY) to /usr/local/bin/"

## Remove build artifacts
clean:
	cd $(TORRENT) && $(CARGO) clean

# ─── Test ───────────────────────────────────────

.PHONY: test test-verbose

## Run all tests
test:
	cd $(TORRENT) && $(CARGO) test

## Run tests with output visible
test-verbose:
	cd $(TORRENT) && $(CARGO) test -- --nocapture

# ─── Lint ───────────────────────────────────────

.PHONY: check clippy fmt fmt-check

## Type-check + clippy
check:
	cd $(TORRENT) && $(CARGO) check
	cd $(TORRENT) && $(CARGO) clippy -- -D warnings

## Run clippy lints
clippy:
	cd $(TORRENT) && $(CARGO) clippy -- -D warnings

## Format all code
fmt:
	cd $(TORRENT) && $(CARGO) fmt

## Check formatting (CI mode)
fmt-check:
	cd $(TORRENT) && $(CARGO) fmt -- --check

# ─── Run ────────────────────────────────────────

.PHONY: run

## Run torrent TUI
run: build
	@exec $(TARGET)

# ─── Utilities ──────────────────────────────────

.PHONY: loc preflight help

## Count lines of Rust code
loc:
	@find $(TORRENT)/src -name '*.rs' | xargs wc -l

## Pre-flight check — verify everything needed to run
preflight:
	@echo "Checking prerequisites..."
	@printf "  cargo:      " && cargo --version
	@printf "  rustc:      " && rustc --version
	@printf "  tmux:       " && (tmux -V 2>/dev/null || echo "NOT FOUND")
	@printf "  claude:     " && (claude --version 2>/dev/null || echo "NOT FOUND")
	@printf "  plugin-dir: " && (test -d $(PLUGIN_DIR) && echo "OK" || echo "NOT FOUND")
	@printf "  binary:     " && (test -f $(TARGET) && echo "OK" || echo "not built (run: make build)")
	@echo "Done."

## Show this help
help:
	@echo "Torrent — Makefile targets"
	@echo ""
	@echo "Build:"
	@echo "  make build        Build release binary"
	@echo "  make dev          Build debug binary (fast compile)"
	@echo "  make install      Install to /usr/local/bin/"
	@echo "  make clean        Remove build artifacts"
	@echo ""
	@echo "Run:"
	@echo "  make run          Build release + launch TUI"
	@echo ""
	@echo "Test:"
	@echo "  make test         Run all tests"
	@echo "  make check        Type-check + clippy"
	@echo "  make fmt          Format code"
	@echo ""
	@echo "Utilities:"
	@echo "  make preflight    Check prerequisites"
	@echo "  make loc          Lines of code"
	@echo "  make help         This message"

.DEFAULT_GOAL := help
