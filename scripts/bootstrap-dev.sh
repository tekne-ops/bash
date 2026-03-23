#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Install developer tooling for Debian/Ubuntu
sudo apt-get update
sudo apt-get install -y shellcheck bats
if ! command -v shfmt >/dev/null 2>&1; then
    curl -sSLo /usr/local/bin/shfmt https://github.com/mvdan/sh/releases/latest/download/shfmt_linux_amd64
    chmod +x /usr/local/bin/shfmt
fi

echo "Tooling installed: shellcheck $(shellcheck --version | head -n1 2>/dev/null || echo not-found), bats $(bats --version 2>/dev/null || echo not-found), shfmt $(shfmt -version 2>/dev/null || echo not-found)"
