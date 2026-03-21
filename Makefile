# Torrent — Tmux Arc Orchestrator
# TUI for managing batch Claude Code arc sessions

BINARY     := torrent
CLI_BINARY := torrent-cli
CARGO      := cargo
TORRENT    := torrent
TARGET     := $(TORRENT)/target/release/$(BINARY)
CLI_TARGET := $(TORRENT)/target/release/$(CLI_BINARY)
PLUGIN_DIR := ./plugins/rune
PREFIX     ?= /usr/local
VERSION    ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

# Channels bridge configuration (PORT=auto unless overridden)
CONFIG ?= .claude

# ─── Build ──────────────────────────────────────

.PHONY: build dev release clean

## Build release binary (TUI + CLI)
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

.PHONY: run run-channel run-channel-custom run-dev run-dev-channel

## Build release + launch TUI (file-only monitoring)
run: build
	@exec $(TARGET)

## Run TUI with channels bridge (port auto-allocated, or PORT=9900)
run-channel: build bridge-deps
	@exec $(TARGET) --channels $(if $(PORT),--callback-port $(PORT))

## Channel test: create Claude session via CLI, send test messages, capture response
## Usage: make run-channel-test CONFIG=~/.claude-work
run-channel-test: build bridge-deps
	@echo "=== Channel Bridge Test ==="
	@echo ""
	@echo "[1/5] Creating tmux session with Claude Code..."
	@$(CLI_TARGET) kill --session torrent-ch-test 2>/dev/null || true
	@$(CLI_TARGET) new-session --config-dir $(CONFIG) --session torrent-ch-test --channels $(if $(PORT),--callback-port $(PORT))
	@echo ""
	@echo "[2/5] Waiting 20s for Claude Code to start..."
	@sleep 20
	@$(CLI_TARGET) capture-pane --session torrent-ch-test --lines 5
	@echo ""
	@echo "[3/5] Sending: hello"
	@$(CLI_TARGET) send-msg --session torrent-ch-test --text "hello"
	@sleep 10
	@echo ""
	@echo "[4/5] Sending: explain codebase"
	@$(CLI_TARGET) send-msg --session torrent-ch-test --text "explain this codebase briefly in 2 sentences"
	@sleep 15
	@echo ""
	@echo "[5/5] Capturing Claude response..."
	@$(CLI_TARGET) capture-pane --session torrent-ch-test --lines 15
	@echo ""
	@echo "=== Test complete. Session still running. ==="
	@echo "  Attach:  tmux attach -t torrent-ch-test"
	@echo "  Kill:    make kill-channel-test"
	@echo "  Send:    make send-msg SESSION=torrent-ch-test MSG=\"your message\""

## Kill the channel test session
kill-channel-test: build
	@$(CLI_TARGET) kill --session torrent-ch-test

## Run TUI in debug mode
run-dev:
	cd $(TORRENT) && $(CARGO) run

## Run TUI in debug mode with channels
run-dev-channel: bridge-deps
	cd $(TORRENT) && $(CARGO) run -- --channels $(if $(PORT),--callback-port $(PORT))

# ─── CLI ───────────────────────────────────────

.PHONY: run-cli run-cli-channel send-msg list-sessions clean-sessions

## Show CLI help
run-cli: build
	@$(CLI_TARGET)

## Create CLI session (file mode, CONFIG=.claude)
run-cli-session: build
	@$(CLI_TARGET) new-session --config-dir $(CONFIG)

## Create CLI session with channels (PORT=auto, CONFIG=.claude)
run-cli-channel: build bridge-deps
	@$(CLI_TARGET) new-session --config-dir $(CONFIG) --channels $(if $(PORT),--callback-port $(PORT))

## Send message to Claude (make send-msg MSG="hello" SESSION=rune-xxx)
send-msg: build
	@$(CLI_TARGET) send-msg --session $(SESSION) --text "$(MSG)"

## List active torrent/rune tmux sessions
list-sessions: build
	@$(CLI_TARGET) list

## Clean session registry
clean-sessions:
	@rm -rf tmp/torrent-sessions/
	@echo "Session registry cleared"

# ─── Bridge ────────────────────────────────────

.PHONY: bridge-deps bridge-check

## Install bridge dependencies (Bun)
bridge-deps:
	@cd $(TORRENT)/bridge && (test -d node_modules || bun install)

## Verify bridge compiles
bridge-check: bridge-deps
	@cd $(TORRENT)/bridge && bun build --target=bun server.ts --outdir /tmp/bridge-check

# ─── Test ───────────────────────────────────────

.PHONY: test test-verbose test-e2e test-bridge test-all

## Run Rust unit tests
test:
	cd $(TORRENT) && $(CARGO) test --release

## Run tests with output visible
test-verbose:
	cd $(TORRENT) && $(CARGO) test -- --nocapture

## Run E2E channel bridge tests (Rust + Node.js + Python)
test-e2e: build bridge-deps
	cd $(TORRENT) && bash tests/test_channels_e2e.sh

## Run bridge integration tests
test-bridge: build bridge-deps
	cd $(TORRENT) && bash tests/test_channels_bridge.sh

## Run everything (unit + bridge + E2E)
test-all: test test-bridge test-e2e

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
	@echo "Installing $(BINARY) + $(CLI_BINARY) to $(PREFIX)/bin..."
	@if [ -w "$(PREFIX)/bin" ]; then \
		cp $(TARGET) "$(PREFIX)/bin/$(BINARY)"; \
		cp $(CLI_TARGET) "$(PREFIX)/bin/$(CLI_BINARY)"; \
	else \
		echo "Need sudo to install to $(PREFIX)/bin"; \
		sudo cp $(TARGET) "$(PREFIX)/bin/$(BINARY)"; \
		sudo cp $(CLI_TARGET) "$(PREFIX)/bin/$(CLI_BINARY)"; \
	fi
	@echo "✓ Installed $(BINARY) + $(CLI_BINARY) to $(PREFIX)/bin/"

## Install to ~/.local/bin (no sudo needed)
install-local: build
	@mkdir -p ~/.local/bin
	@cp $(TARGET) ~/.local/bin/$(BINARY)
	@cp $(CLI_TARGET) ~/.local/bin/$(CLI_BINARY)
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
	@printf "  bun:        " && (bun --version 2>/dev/null || echo "NOT FOUND (needed for --channels)")
	@printf "  plugin-dir: " && (test -d $(PLUGIN_DIR) && echo "OK" || echo "NOT FOUND")
	@printf "  binary:     " && (test -f $(TARGET) && echo "OK" || echo "not built (run: make build)")
	@echo "Done."

## Show available targets
help:
	@echo "Torrent — Arc Orchestrator TUI ($(VERSION))"
	@echo ""
	@echo "  Build:"
	@echo "    make build              Build release binaries (TUI + CLI)"
	@echo "    make dev                Build debug binaries (fast compile)"
	@echo "    make clean              Remove build artifacts"
	@echo ""
	@echo "  Run:"
	@echo "    make run                  Launch TUI (file-only monitoring)"
	@echo "    make run-channel          Launch TUI with channels (port auto)"
	@echo "    make run-channel PORT=9900  Channels with explicit port"
	@echo "    make run-dev              Launch TUI in debug mode"
	@echo "    make run-dev-channel      Launch TUI debug + channels"
	@echo "    make run-channel-test     Full E2E channel test"
	@echo ""
	@echo "  CLI:"
	@echo "    make run-cli              Show torrent-cli help"
	@echo "    make run-cli-session      Create session (file mode)"
	@echo "    make run-cli-channel      Create session with channels"
	@echo "    make run-cli-channel PORT=9900 CONFIG=~/.claude-work"
	@echo "    make send-msg MSG=\"...\" SESSION=rune-xxx"
	@echo "    make list-sessions        List active tmux sessions"
	@echo ""
	@echo "  Bridge:"
	@echo "    make bridge-deps          Install bridge deps (Bun)"
	@echo "    make bridge-check         Verify bridge compiles"
	@echo ""
	@echo "  Test & Lint:"
	@echo "    make test               Run Rust unit tests (225)"
	@echo "    make test-bridge        Run bridge integration tests"
	@echo "    make test-e2e           Run E2E channel tests"
	@echo "    make test-all           Run everything"
	@echo "    make check              Type-check + clippy"
	@echo "    make fmt                Format code"
	@echo "    make fmt-check          Check formatting (CI)"
	@echo ""
	@echo "  Install:"
	@echo "    make install            Install to $(PREFIX)/bin (may need sudo)"
	@echo "    make install-local      Install to ~/.local/bin (no sudo)"
	@echo "    make uninstall          Remove from all locations"
	@echo ""
	@echo "  Distribution:"
	@echo "    make dist               Create release tarball"
	@echo ""
	@echo "  Utilities:"
	@echo "    make preflight          Check prerequisites"
	@echo "    make loc                Lines of code"
	@echo ""
	@echo "  Clean:"
	@echo "    make clean-sessions     Clear session registry"
	@echo ""
	@echo "  Options:"
	@echo "    PORT=9900               Callback port (default: auto 9900-9998)"
	@echo "    CONFIG=~/.claude-work   Claude config dir (default: .claude)"
	@echo "    PREFIX=/custom/path     Install prefix (default: /usr/local)"

.DEFAULT_GOAL := help
