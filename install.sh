#!/usr/bin/env bash
# Install detour for the current user. No root needed, no questions asked.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
PREFIX="$DATA_HOME/detour"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$DATA_HOME/applications"
AUTOSTART_DIR="$CONFIG_HOME/autostart"
CONFIG="$CONFIG_HOME/detour/detour.ini"
MARKER="X-Detour=true"

usage() {
  cat <<EOF
Usage: bash install.sh [options]

  --proxy SPEC      proxy setting to save (default: auto, which finds the
                    fastest route by itself)
  --separate-icon   leave the normal app icons alone and add
                    "<App> (Detour)" menu entries instead
  -h, --help        show this help
EOF
}

PROXY="" SEPARATE=0
while (($#)); do
  case $1 in
    --proxy) PROXY=${2-}; shift ;;
    --separate-icon) SEPARATE=1 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

for f in detour detour-auth-proxy.py detour.ini uninstall.sh; do
  [[ -f $SRC/$f ]] || { echo "Missing $f - run install.sh from the extracted detour folder." >&2; exit 1; }
done
for cmd in curl timeout; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "detour needs '$cmd' - install it with your package manager first." >&2; exit 1; }
done

mkdir -p "$PREFIX" "$BIN_DIR" "$APPS_DIR"
install -m 755 "$SRC/detour" "$SRC/uninstall.sh" "$PREFIX/"
install -m 644 "$SRC/detour-auth-proxy.py" "$PREFIX/"
install -m 644 "$SRC/detour.ini" "$PREFIX/detour.ini.example"
ln -sfn "$PREFIX/detour" "$BIN_DIR/detour"
DETOUR="$PREFIX/detour"

if [[ ! -f $CONFIG ]]; then
  mkdir -p "$(dirname "$CONFIG")"
  (umask 077 && cp "$SRC/detour.ini" "$CONFIG")
fi
if [[ -n $PROXY ]]; then
  "$DETOUR" --config "$CONFIG" --set-proxy "$PROXY" >/dev/null
fi

desktop_quote() { printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"`$]/\\\\&/g')"; }

# exec_args EXEC - the arguments an Exec= value hands to the client itself:
# everything after the program (after the app id for "flatpak run"), minus
# Flatpak's @@ file-forwarding markers. "/usr/bin/discord --url -- %u" gives
# "--url -- %u".
exec_args() {
  local exec=$1 i=1
  local -a words rest out=()
  if [[ $exec == \"* ]]; then   # quoted program path
    exec=${exec#\"}
    read -ra rest <<<"${exec#*\"}"
    words=(program "${rest[@]}")
  else
    read -ra words <<<"$exec"
  fi
  if [[ ${words[0]##*/} == flatpak ]]; then
    for ((i = 1; i < ${#words[@]}; i++)); do
      [[ ${words[i]} == run || ${words[i]} == -* ]] || break
    done
    ((i++))   # the app id
  fi
  for ((; i < ${#words[@]}; i++)); do
    [[ ${words[i]} == @@* ]] || out+=("${words[i]}")
  done
  printf '%s' "${out[*]}"
}

# point_at_detour DEST SRC APP - write DEST as a copy of the .desktop file SRC
# whose Exec= lines start APP through detour, keeping the client's own
# arguments (Discord's "--url -- %u" for discord:// links, "--start-minimized"
# in autostart entries). A file of the user's own at DEST is backed up first
# (uninstall.sh puts it back).
point_at_detour() {
  local dest=$1 src=$2 app=$3 line args out=""
  if [[ -f $dest ]] && ! command grep -qx "$MARKER" "$dest"; then
    mv -f "$dest" "$dest.detour-backup"
    [[ $src == "$dest" ]] && src="$dest.detour-backup"
  fi
  # re-installing over one of ours: start again from the original
  if command grep -qx "$MARKER" "$src" && [[ -f $src.detour-backup ]]; then
    src="$src.detour-backup"
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    case $line in
      "$MARKER" | TryExec=* | DBusActivatable=* | X-Flatpak*=*) continue ;;
      Exec=*)
        args=$(exec_args "${line#Exec=}")
        line="Exec=$(desktop_quote "$DETOUR") --app $app --${args:+ $args}"
        ;;
    esac
    out+="$line"$'\n'
    [[ $line == "[Desktop Entry]" ]] && out+="$MARKER"$'\n'
  done <"$src"
  printf '%s' "$out" >"$dest.tmp"
  mv -f "$dest.tmp" "$dest"
}

# undo_entry FILE - remove a file we wrote and put back the user's own.
undo_entry() {
  [[ -f $1 ]] && command grep -qx "$MARKER" "$1" || return 0
  rm -f "$1"
  if [[ -f $1.detour-backup ]]; then mv -f "$1.detour-backup" "$1"; fi
}

# find_original IDS - the client's own menu entry (not one of ours).
find_original() {
  local id dir
  for id in $1; do
    for dir in "$DATA_HOME/flatpak/exports/share/applications" /var/lib/flatpak/exports/share/applications \
      /usr/local/share/applications /usr/share/applications; do
      if [[ -f $dir/$id.desktop ]]; then
        echo "$dir/$id.desktop"
        return 0
      fi
    done
  done
  return 1
}

found=()
for app in vesktop discord discord-ptb discord-canary; do
  read -r _ kind icon < <(DETOUR_CONFIG="$CONFIG" "$DETOUR" --app "$app" --detect 2>/dev/null) || continue
  case $app in
    vesktop) pretty=Vesktop ids="dev.vencord.Vesktop vesktop" ;;
    discord) pretty=Discord ids="com.discordapp.Discord discord discord-stable" ;;
    discord-ptb) pretty="Discord PTB" ids="com.discordapp.DiscordPTB discord-ptb" ;;
    discord-canary) pretty="Discord Canary" ids="com.discordapp.DiscordCanary discord-canary" ;;
  esac
  found+=("$pretty")
  separate_entry="$APPS_DIR/detour-$app.desktop"

  if ((!SEPARATE)) && original=$(find_original "$ids"); then
    # Same file name in ~/.local/share/applications wins over the system one.
    point_at_detour "$APPS_DIR/$(basename "$original")" "$original" "$app"
    undo_entry "$separate_entry"
    echo "✓ $pretty ($kind): its normal icon now picks the fastest connection"
  else
    for id in $ids; do undo_entry "$APPS_DIR/$id.desktop"; done
    args="%U"
    if original=$(find_original "$ids"); then
      args=$(exec_args "$(command grep -m1 '^Exec=' "$original" | cut -d= -f2-)")
    fi
    cat >"$separate_entry" <<EOF
[Desktop Entry]
Type=Application
Name=$pretty (Detour)
GenericName=Internet Messenger
Comment=$pretty through the fastest connection
Exec=$(desktop_quote "$DETOUR") --app $app --${args:+ $args}
Icon=$icon
Terminal=false
Categories=Network;InstantMessaging;
Keywords=discord;vencord;proxy;detour;
$MARKER
EOF
    echo "✓ $pretty ($kind): added \"$pretty (Detour)\" to your app menu"
  fi

  # "Start with system" entries the app made itself would skip detour.
  for id in $ids; do
    if [[ -f $AUTOSTART_DIR/$id.desktop ]]; then
      point_at_detour "$AUTOSTART_DIR/$id.desktop" "$AUTOSTART_DIR/$id.desktop" "$app"
      echo "✓ $pretty: start-on-login now goes through detour too"
    fi
  done
done

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$APPS_DIR" 2>/dev/null || true

if ((${#found[@]} == 0)); then
  echo "detour is installed, but Vesktop or Discord wasn't found." >&2
  echo "Install Vesktop (flatpak install flathub dev.vencord.Vesktop), then run this again." >&2
  exit 1
fi

names=$(IFS=/; echo "${found[*]}")
echo
echo "Done! Fully quit $names (tray icon -> Quit) and open it again."
echo "From now on it connects through the fastest working route by itself."
echo
echo "  See what it picks:  detour --check"
echo "  Uninstall:          bash $PREFIX/uninstall.sh"
