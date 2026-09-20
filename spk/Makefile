PREFIX ?= /usr
CARGO  ?= cargo

build:
	$(CARGO) build --release

install: build
	install -Dm755 target/release/spk $(DESTDIR)$(PREFIX)/bin/spk

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/spk

check:
	$(CARGO) check --manifest-path Cargo.toml

clippy:
	$(CARGO) clippy --manifest-path Cargo.toml

clean:
	$(CARGO) clean