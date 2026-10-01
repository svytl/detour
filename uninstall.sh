#!/usr/bin/env bash
# Remove detour. Your config is kept unless you pass --purge.
set -euo pipefail

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
PREFIX="$DATA_HOME/detour"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$DATA_HOME/applications"
AUTOSTART_DIR="$CONFIG_HOME/autostart"
CONFIG_DIR="$CONFIG_HOME/detour"
MARKER="X-Detour=true"

PURGE=0
case ${1-} in
  --purge) PURGE=1 ;;
  "") ;;
  *) echo "Usage: uninstall.sh [--purge]   (--purge also deletes $CONFIG_DIR)" >&2; exit 1 ;;
esac

# Menu and autostart entries we wrote, and any originals we backed up.
for f in "$APPS_DIR"/*.desktop "$AUTOSTART_DIR"/*.desktop; do
  [[ -f $f ]] && command grep -qx "$MARKER" "$f" || continue
  rm -f "$f"
  if [[ -f $f.detour-backup ]]; then
    mv -f "$f.detour-backup" "$f"
    echo "Restored $f"
  else
    echo "Removed $f"
  fi
done

if [[ -L $BIN_DIR/detour && $(readlink "$BIN_DIR/detour") == "$PREFIX/detour" ]]; then
  rm -f "$BIN_DIR/detour"
fi
rm -rf "$PREFIX"
echo "Removed $PREFIX"

if ((PURGE)); then
  rm -rf "$CONFIG_DIR"
  echo "Removed $CONFIG_DIR"
else
  echo "Kept your config in $CONFIG_DIR (run with --purge to delete it)"
fi

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$APPS_DIR" 2>/dev/null || true
echo "detour is uninstalled. Restart Vesktop/Discord to go back to a normal connection."
