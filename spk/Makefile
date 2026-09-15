PREFIX ?= /usr
CARGO  ?= cargo

build:
	$(CARGO) build --release

install: build
	install -Dm755 target/release/spk $(PREFIX)/bin/spk

clean:
	$(CARGO) clean