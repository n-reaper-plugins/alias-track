#!/usr/bin/env bash
# AliasTrack installer - macOS first (bash 3.2 compatible). Also works with --portable on any OS.
#
#   ./install_mac.sh                      install into ~/Library/Application Support/REAPER
#   ./install_mac.sh --portable DIR       install into a portable REAPER folder
#   ./install_mac.sh --no-register        do not touch reaper-kb.ini (add the action by hand)
#   ./install_mac.sh --src DIR            folder containing AliasTrack.lua (default: next to this script, or ./dist)
#   ./install_mac.sh --uninstall          remove exactly what this script added
#
# Nothing here modifies your projects. reaper-kb.ini is only edited while REAPER is closed,
# and is backed up first.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
RES=""
SRC=""
DO_REGISTER=1
DO_UNINSTALL=0

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --portable)    [ $# -ge 2 ] || die "--portable needs a folder"; RES="$2"; shift 2 ;;
    --src)         [ $# -ge 2 ] || die "--src needs a folder"; SRC="$2"; shift 2 ;;
    --no-register) DO_REGISTER=0; shift ;;
    --uninstall)   DO_UNINSTALL=1; shift ;;
    -h|--help)     sed -n '2,11p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ---- locate REAPER's resource folder -------------------------------------------------------
if [ -z "$RES" ]; then
  case "$(uname -s)" in
    Darwin) RES="$HOME/Library/Application Support/REAPER" ;;
    *)      RES="$HOME/.config/REAPER" ;;
  esac
fi
[ -d "$RES" ] || die "REAPER resource folder not found: $RES
Start REAPER once so it creates it, or pass --portable <folder>."

SCRIPT_DIR="$RES/Scripts/AliasTrack"
SCRIPT_PATH="$SCRIPT_DIR/AliasTrack.lua"
KB="$RES/reaper-kb.ini"

reaper_running() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x REAPER >/dev/null 2>&1 || pgrep -x reaper >/dev/null 2>&1
  else
    return 0     # cannot tell: be safe and treat as running
  fi
}

sha1() {
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 1 | cut -d' ' -f1
  else printf '%s' "$1" | sha1sum | cut -d' ' -f1; fi
}

backup_kb() {
  [ -f "$KB" ] || return 0
  cp "$KB" "$KB.prototypesequence-backup-$(date +%Y%m%d-%H%M%S)"
}

# remove every reaper-kb.ini line that registers our script
kb_remove() {
  [ -f "$KB" ] || return 0
  grep -qF -e "$SCRIPT_PATH" "$KB" 2>/dev/null || return 0
  backup_kb
  grep -vF -e "$SCRIPT_PATH" "$KB" > "$KB.tmp.$$" || true
  mv "$KB.tmp.$$" "$KB"
}

# ---- uninstall ----------------------------------------------------------------------------
if [ "$DO_UNINSTALL" = 1 ]; then
  say "Uninstalling AliasTrack from: $RES"
  if reaper_running; then
    warn "REAPER seems to be running. Close it first so reaper-kb.ini can be cleaned; skipping that part."
  else
    kb_remove
    say "  removed action registration (if it existed)"
  fi
  rm -f "$SCRIPT_PATH"
  rmdir "$SCRIPT_DIR" 2>/dev/null || true
  say "Done. Your projects are untouched: PROTO tracks and items stay as ordinary tracks/items."
  exit 0
fi

# ---- install ------------------------------------------------------------------------------
if [ -z "$SRC" ]; then
  if   [ -f "$HERE/AliasTrack.lua" ];      then SRC="$HERE"
  elif [ -f "$HERE/dist/AliasTrack.lua" ]; then SRC="$HERE/dist"
  else die "AliasTrack.lua not found next to this script. Use --src <folder>."; fi
fi
[ -f "$SRC/AliasTrack.lua" ] || die "$SRC/AliasTrack.lua not found"

VERSION="$(sed -n 's/^-- @version[[:space:]]*//p' "$SRC/AliasTrack.lua" | head -n 1)"
say "Installing AliasTrack ${VERSION:-?} into: $RES"

mkdir -p "$SCRIPT_DIR"
cp "$SRC/AliasTrack.lua" "$SCRIPT_PATH"
say "  script  -> $SCRIPT_PATH"

# macOS: files downloaded from the internet carry a quarantine flag
if [ "$(uname -s)" = "Darwin" ] && command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$SCRIPT_DIR" 2>/dev/null || true
  say "  removed download quarantine flag"
fi

# ReaImGui (required) and js_ReaScriptAPI (optional, for the folder dialog)
if ls "$RES/UserPlugins" 2>/dev/null | grep -i 'imgui' >/dev/null 2>&1; then
  say "  ReaImGui: found"
else
  warn "ReaImGui was not found in $RES/UserPlugins."
  say  "  The window needs it: in REAPER open Extensions > ReaPack > Browse packages, search 'ReaImGui', install, restart."
fi
if ls "$RES/UserPlugins" 2>/dev/null | grep -i 'js_ReaScriptAPI' >/dev/null 2>&1; then
  say "  js_ReaScriptAPI: found (folder dialog available)"
else
  say "  js_ReaScriptAPI: not found - optional. Without it, choose the folder by drag & drop, typing, or a file dialog."
fi

# register the action
REGISTERED=0
if [ "$DO_REGISTER" = 1 ]; then
  if reaper_running; then
    warn "REAPER seems to be running - not editing reaper-kb.ini."
  elif [ ! -f "$KB" ]; then
    warn "$KB does not exist yet (start and close REAPER once)."
  else
    kb_remove
    backup_kb
    ID="RS$(sha1 "$SCRIPT_PATH")"
    printf 'SCR 4 0 %s "Script: AliasTrack.lua" "%s"\n' "$ID" "$SCRIPT_PATH" >> "$KB"
    REGISTERED=1
    say "  action  -> registered as 'Script: AliasTrack.lua' (backup of reaper-kb.ini kept next to it)"
  fi
fi

say ""
if [ "$REGISTERED" = 1 ]; then
  say "Next: start REAPER, open Actions > Show action list, search 'AliasTrack', run 'Script: AliasTrack.lua'."
else
  say "Next: in REAPER open Actions > Show action list > New action > Load ReaScript..., choose"
  say "      $SCRIPT_PATH"
  say "      then run it."
fi
say "Run the action again while the window is open to close it. Uninstall any time with: $0 --uninstall"
