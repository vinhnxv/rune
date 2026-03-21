# Torrent — Tmux Arc Orchestrator
# Usage: make [target]

BINARY     := torrent
CLI_BINARY := torrent-cli
RELEASE    := target/release
DEBUG      := target/debug
INSTALL_SYSTEM := /usr/local/bin
INSTALL_LOCAL  := $(HOME)/.local/bin

# Default callback/bridge ports
CALLBACK_PORT ?= 9900
BRIDGE_PORT   ?= 9901

.PHONY: help build dev install install-local uninstall dist clean \
        run run-channel run-cli test test-e2e clippy check fmt

## ── Build ───────────────────────────────────────────────────

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

build: ## Build release binaries
	cargo build --release

dev: ## Build debug binaries (fast compile)
	cargo build

install: build ## Install to /usr/local/bin (may need sudo)
	install -m 755 $(RELEASE)/$(BINARY) $(INSTALL_SYSTEM)/$(BINARY)
	install -m 755 $(RELEASE)/$(CLI_BINARY) $(INSTALL_SYSTEM)/$(CLI_BINARY)

install-local: build ## Install to ~/.local/bin (no sudo)
	mkdir -p $(INSTALL_LOCAL)
	install -m 755 $(RELEASE)/$(BINARY) $(INSTALL_LOCAL)/$(BINARY)
	install -m 755 $(RELEASE)/$(CLI_BINARY) $(INSTALL_LOCAL)/$(CLI_BINARY)

uninstall: ## Remove installed binaries
	rm -f $(INSTALL_SYSTEM)/$(BINARY) $(INSTALL_SYSTEM)/$(CLI_BINARY)
	rm -f $(INSTALL_LOCAL)/$(BINARY) $(INSTALL_LOCAL)/$(CLI_BINARY)

dist: build ## Create release tarballs
	@mkdir -p dist
	tar -czf dist/$(BINARY)-$(shell uname -m)-$(shell uname -s | tr '[:upper:]' '[:lower:]').tar.gz \
		-C $(RELEASE) $(BINARY) $(CLI_BINARY)
	@echo "Created: dist/$(BINARY)-$(shell uname -m)-$(shell uname -s | tr '[:upper:]' '[:lower:]').tar.gz"

clean: ## Remove build artifacts
	cargo clean

## ── Run ─────────────────────────────────────────────────────

run: build ## Run TUI (file-only monitoring)
	$(RELEASE)/$(BINARY)

run-channel: build bridge-deps ## Run TUI with channels bridge enabled
	$(RELEASE)/$(BINARY) --channels --callback-port $(CALLBACK_PORT)

run-dev: ## Run TUI in debug mode
	cargo run

run-dev-channel: bridge-deps ## Run TUI in debug mode with channels
	cargo run -- --channels --callback-port $(CALLBACK_PORT)

## ── CLI ─────────────────────────────────────────────────────

run-cli: build ## Show CLI help
	$(RELEASE)/$(CLI_BINARY)

send-msg: build ## Send message to Claude (usage: make send-msg MSG="hello" SESSION=rune-xxx)
	$(RELEASE)/$(CLI_BINARY) send-msg --session $(SESSION) --text "$(MSG)"

list: build ## List active torrent/rune tmux sessions
	$(RELEASE)/$(CLI_BINARY) list

## ── Bridge ──────────────────────────────────────────────────

bridge-deps: ## Install bridge npm dependencies
	@cd bridge && (test -d node_modules || npm install --silent)

bridge-check: bridge-deps ## Type-check bridge server
	cd bridge && npx --yes tsc --noEmit --esModuleInterop --module nodenext \
		--moduleResolution nodenext --target es2022 server.ts 2>/dev/null || true

## ── Quality ─────────────────────────────────────────────────

test: ## Run all Rust tests
	cargo test --release

test-e2e: build bridge-deps ## Run E2E integration tests (Rust + Bridge)
	bash tests/test_channels_e2e.sh

test-bridge: build bridge-deps ## Run bridge integration tests
	bash tests/test_channels_bridge.sh

test-all: test test-bridge test-e2e ## Run everything

check: ## Compile check (no codegen)
	cargo check

clippy: ## Run clippy linter
	cargo clippy

fmt: ## Format code
	cargo fmt

lint: check clippy fmt ## Run all linters
