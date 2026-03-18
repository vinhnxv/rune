# Torrent — Tmux Arc Orchestrator
# TUI for managing batch Claude Code arc sessions

BINARY     := torrent
CARGO      := cargo
TORRENT    := torrent
TARGET     := $(TORRENT)/target/release/$(BINARY)
PLUGIN_DIR := ./plugins/rune
PREFIX     ?= /usr/local
VERSION    ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

# ─── Build ──────────────────────────────────────

.PHONY: build dev release clean

## Build release binary
build:
	cd $(TORRENT) && $(CARGO) build --release

## Build debug binary (faster compile, slower runtime)
dev:
	cd $(TORRENT) && $(CARGO) build

## Alias for build (explicit release naming)
release: build

## Remove build artifacts
clean:
	cd $(TORRENT) && $(CARGO) clean

# ─── Run ────────────────────────────────────────

.PHONY: run

## Build release + launch TUI
run: build
	@exec $(TARGET)

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

# ─── Install ───────────────────────────────────

.PHONY: install install-local uninstall uninstall-local

## Install to $(PREFIX)/bin (may need sudo)
install: build
	@echo "Installing $(BINARY) to $(PREFIX)/bin..."
	@if [ -w "$(PREFIX)/bin" ]; then \
		cp $(TARGET) "$(PREFIX)/bin/$(BINARY)"; \
	else \
		echo "Need sudo to install to $(PREFIX)/bin"; \
		sudo cp $(TARGET) "$(PREFIX)/bin/$(BINARY)"; \
	fi
	@echo "✓ Installed $(BINARY) to $(PREFIX)/bin/$(BINARY)"

## Install to ~/.local/bin (no sudo needed)
install-local: build
	@mkdir -p ~/.local/bin
	@cp $(TARGET) ~/.local/bin/$(BINARY)
	@echo "✓ Installed $(BINARY) to ~/.local/bin/$(BINARY)"
	@if ! echo "$$PATH" | grep -q "$$HOME/.local/bin"; then \
		echo ""; \
		echo "⚠ Add ~/.local/bin to your PATH:"; \
		echo "  echo 'export PATH=\"$$HOME/.local/bin:$$PATH\"' >> ~/.zshrc"; \
		echo "  source ~/.zshrc"; \
	fi

## Uninstall from all known locations
uninstall:
	@echo "Uninstalling $(BINARY)..."
	@if [ -f "$(PREFIX)/bin/$(BINARY)" ]; then \
		if [ -w "$(PREFIX)/bin" ]; then \
			rm -f "$(PREFIX)/bin/$(BINARY)"; \
			echo "✓ Removed $(PREFIX)/bin/$(BINARY)"; \
		else \
			sudo rm -f "$(PREFIX)/bin/$(BINARY)"; \
			echo "✓ Removed $(PREFIX)/bin/$(BINARY)"; \
		fi; \
	else \
		echo "  $(PREFIX)/bin/$(BINARY) not found (skipping)"; \
	fi
	@if [ -f "$$HOME/.local/bin/$(BINARY)" ]; then \
		rm -f "$$HOME/.local/bin/$(BINARY)"; \
		echo "✓ Removed ~/.local/bin/$(BINARY)"; \
	else \
		echo "  ~/.local/bin/$(BINARY) not found (skipping)"; \
	fi
	@echo "✓ Uninstall complete"

## Uninstall from ~/.local/bin only
uninstall-local:
	@echo "Uninstalling $(BINARY) from ~/.local/bin..."
	@if [ -f "$$HOME/.local/bin/$(BINARY)" ]; then \
		rm -f "$$HOME/.local/bin/$(BINARY)"; \
		echo "✓ Removed ~/.local/bin/$(BINARY)"; \
	else \
		echo "  ~/.local/bin/$(BINARY) not found (already removed)"; \
	fi

# ─── Distribution ──────────────────────────────

.PHONY: dist

## Create release tarball for current platform
dist: build
	@echo "Creating release tarball..."
	@mkdir -p dist
	@ARCH=$$(uname -m); OS=$$(uname -s); \
	case "$$OS" in \
		Darwin) OS_NAME="apple-darwin" ;; \
		Linux) OS_NAME="unknown-linux-gnu" ;; \
		*) OS_NAME="$$OS" ;; \
	esac; \
	TARBALL="dist/$(BINARY)-$$ARCH-$$OS_NAME.tar.gz"; \
	tar -czf "$$TARBALL" -C $(TORRENT)/target/release $(BINARY); \
	echo "✓ Created $$TARBALL"
	@echo ""
	@echo "For cross-compilation, use:"
	@echo "  cargo build --release --target aarch64-apple-darwin"
	@echo "  cargo build --release --target x86_64-apple-darwin"
	@echo "  cargo build --release --target x86_64-unknown-linux-gnu"
	@echo "  cargo build --release --target aarch64-unknown-linux-gnu"

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

## Show available targets
help:
	@echo "Torrent — Arc Orchestrator TUI ($(VERSION))"
	@echo ""
	@echo "  Build:"
	@echo "    make build          Build release binary"
	@echo "    make dev            Build debug binary (fast compile)"
	@echo "    make clean          Remove build artifacts"
	@echo ""
	@echo "  Run:"
	@echo "    make run            Build + launch TUI"
	@echo ""
	@echo "  Test & Lint:"
	@echo "    make test           Run all tests"
	@echo "    make check          Type-check + clippy"
	@echo "    make fmt            Format code"
	@echo "    make fmt-check      Check formatting (CI)"
	@echo ""
	@echo "  Install:"
	@echo "    make install        Install to $(PREFIX)/bin (may need sudo)"
	@echo "    make install-local  Install to ~/.local/bin (no sudo)"
	@echo "    make uninstall      Remove from all locations"
	@echo ""
	@echo "  Distribution:"
	@echo "    make dist           Create release tarball"
	@echo ""
	@echo "  Utilities:"
	@echo "    make preflight      Check prerequisites"
	@echo "    make loc            Lines of code"
	@echo ""
	@echo "  Options:"
	@echo "    PREFIX=/custom/path Override install prefix (default: /usr/local)"

.DEFAULT_GOAL := help
