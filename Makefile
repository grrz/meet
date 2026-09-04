PREFIX ?= $(HOME)/.local/bin

.PHONY: build test install clean

build:
	swift build -c release

test:
	swift test

install: build
	mkdir -p $(PREFIX)
	cp .build/release/meet $(PREFIX)/meet

clean:
	swift package clean
