#!/usr/bin/env bash
# Build dist/detour.zip and dist/detour.tar.gz for a GitHub release. The
# names carry no version so that get.sh can always fetch
# releases/latest/download/detour.tar.gz.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

mkdir "$stage/detour"
install -m 755 detour install.sh uninstall.sh detour-auth-proxy.py "$stage/detour/"
install -m 644 detour.ini README.md LICENSE "$stage/detour/"

mkdir -p dist
rm -f dist/detour.zip dist/detour.tar.gz
(cd "$stage" && zip -qr -X "$OLDPWD/dist/detour.zip" detour)
tar -czf dist/detour.tar.gz -C "$stage" --owner=0 --group=0 detour
echo "Built dist/detour.zip and dist/detour.tar.gz (version $(sed -n 's/^VERSION="\(.*\)"$/\1/p' detour))"
