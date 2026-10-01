#!/usr/bin/env bash
# One-line installer for detour:
#   curl -fsSL https://raw.githubusercontent.com/svytl/detour/main/get.sh | bash
set -euo pipefail

# Everything is inside main so a half-downloaded script can't run halfway.
main() {
  local url="https://github.com/svytl/detour/releases/latest/download/detour.tar.gz"
  # not local: the EXIT trap runs after main has returned
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  echo "Downloading detour..."
  curl -fsSL "$url" | tar -xz -C "$tmp"
  bash "$tmp/detour/install.sh" "$@" </dev/null
}

main "$@"
