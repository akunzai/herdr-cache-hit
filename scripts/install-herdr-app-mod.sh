#!/usr/bin/env bash
# Experimental: install the cache-hit panel into Herdr App (GUI).
# Copies the mod (Herdr App does not watch files behind a symlinked mod
# folder) and records this checkout so the mod can run watch.sh from it.
set -eu
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
# Herdr App's own lookup order for its configuration folder.
DEST="${HERDR_APP_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-app}/mods/cache-hit"
[[ -L "$DEST" ]] && rm -f "$DEST"
mkdir -p "$DEST"
cp "$ROOT"/herdr-app/mods/cache-hit/{main.js,mod.json} "$DEST/"
printf '%s\n' "$ROOT" >"$DEST/plugin-root"
# Herdr App on Windows starts without Git Bash or jq on PATH, and its `bash`
# may be WSL's. Record this Git Bash and the folders of the tools it needs.
rm -f "$DEST/bash-path" "$DEST/runtime-path"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    # The app passes the checkout as a working directory: needs C:/ form.
    cygpath -m "$ROOT" >"$DEST/plugin-root"
    cygpath -w "$(command -v bash)" >"$DEST/bash-path"
    dirs=""
    for tool in env jq python3 hc; do
      bin=$(command -v "$tool") || { echo "install-herdr-app-mod: $tool not found" >&2; exit 1; }
      dir=$(dirname -- "$bin")
      case ":$dirs:" in *":$dir:"*) ;; *) dirs=${dirs:+$dirs:}$dir ;; esac
    done
    printf '%s\n' "$dirs" >"$DEST/runtime-path"
    ;;
esac
if command -v herdr-app >/dev/null 2>&1; then herdr-app check "$DEST"; fi
