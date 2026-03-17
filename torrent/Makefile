.PHONY: build release test check clean install

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

install: release
	cp target/release/torrent /usr/local/bin/torrent
	@echo "Installed torrent to /usr/local/bin/torrent"
