.PHONY: build release test check clean install uninstall install-local dist

PREFIX ?= /usr/local
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

build:
	cargo build

release:
	cargo build --release

test:
	cargo test

check:
	cargo check
	cargo clippy -- -D warnings

clean:
	cargo clean

# Create distributable tarballs for multiple platforms
dist: release
	@echo "Creating release tarballs..."
	@mkdir -p dist
	@ARCH=$(shell uname -m) OS=$(shell uname -s); \
	case "$$OS" in \
		Darwin) OS_NAME="apple-darwin" ;; \
		Linux) OS_NAME="unknown-linux-gnu" ;; \
		*) OS_NAME="$$OS" ;; \
	esac; \
	TARBALL="dist/torrent-$$ARCH-$$OS_NAME.tar.gz"; \
	tar -czf "$$TARBALL" -C target/release torrent; \
	echo "✓ Created $$TARBALL"
	@echo ""
	@echo "For cross-compilation, use:"
	@echo "  cargo build --release --target aarch64-apple-darwin"
	@echo "  cargo build --release --target x86_64-apple-darwin"
	@echo "  cargo build --release --target x86_64-unknown-linux-gnu"
	@echo "  cargo build --release --target aarch64-unknown-linux-gnu"

# Install to system (requires sudo on most systems)
install: release
	@echo "Installing torrent to $(PREFIX)/bin..."
	@if [ -w "$(PREFIX)/bin" ]; then \
		cp target/release/torrent "$(PREFIX)/bin/torrent"; \
	else \
		echo "Need sudo to install to $(PREFIX)/bin"; \
		sudo cp target/release/torrent "$(PREFIX)/bin/torrent"; \
	fi
	@echo "✓ Installed torrent to $(PREFIX)/bin/torrent"

# Install to user local bin (no sudo needed)
install-local: release
	@mkdir -p ~/.local/bin
	@cp target/release/torrent ~/.local/bin/torrent
	@echo "✓ Installed torrent to ~/.local/bin/torrent"
	@if ! echo "$$PATH" | grep -q "$$HOME/.local/bin"; then \
		echo ""; \
		echo "⚠ Add ~/.local/bin to your PATH:"; \
		echo "  echo 'export PATH=\"$$HOME/.local/bin:$$PATH\"' >> ~/.zshrc"; \
		echo "  source ~/.zshrc"; \
	fi

uninstall:
	@if [ -w "$(PREFIX)/bin" ]; then \
		rm -f "$(PREFIX)/bin/torrent"; \
		echo "✓ Removed $(PREFIX)/bin/torrent"; \
	else \
		sudo rm -f "$(PREFIX)/bin/torrent"; \
		echo "✓ Removed $(PREFIX)/bin/torrent"; \
	fi
	@rm -f ~/.local/bin/torrent 2>/dev/null || true
	@echo "✓ Uninstall complete"
