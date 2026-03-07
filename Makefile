SHELL := /usr/bin/env bash

.PHONY: all format format-check lint test check install clean
all: check

format:
	shfmt -i 4 -ci -w bin lib scripts

# Check formatting without modifying files (for CI). Fails with exit 1 if any file needs formatting.
# Normalize shfmt exit code to 1 so CI always sees exit 1 (some shfmt versions return 2).
format-check:
	shfmt -i 4 -ci -d bin lib scripts || exit 1

lint:
	shellcheck bin/* lib/*.sh scripts/*.sh

test:
	bats -r tests

check: format lint test

install:
	install -d /usr/local/bin
	install -m 755 bin/* /usr/local/bin

clean:
	rm -rf dist build
