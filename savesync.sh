#!/usr/bin/env bash
# savesync - sync emulator saves, save states, BIOS files and ROMs with a NAS
#
# Made for EmuDeck on the Steam Deck; also works with RetroDECK and on any
# Linux PC. Uses rclone in user space - no sudo, no fstab, no mounts.
#
#   savesync setup                 one-time: pick your NAS and folders (per machine)
#   savesync push                  upload saves + states (newer files win)
#   savesync pull                  download saves + states (newer files win)
#   savesync sync                  push, then pull (newest copy of every file wins)
#   savesync bios push|pull        copy BIOS files (only needed when you add new ones)
#   savesync games list [system] [search]   browse the games on the NAS
#   savesync games pull <system> [search]   download games to this machine
#   savesync games push [system] [search]   upload games the NAS doesn't have yet
#   savesync recent [hours]        list save files changed here lately (default 24h)
#   savesync config                show the settings in use and test the connection
#   savesync install               copy savesync to ~/.local/bin (+ menu shortcuts)
#
#   -n, --dry-run   preview any command without changing anything
#   -y, --yes       don't ask before transferring games
#   -V, --version   show the version
#
# Files that are identical on both sides are never re-sent, even if their dates
# differ. Nothing is ever deleted. Any file that gets overwritten is kept first:
#   pull -> ~/.local/share/savesync/backups/<time>/
#   push -> <NAS folder>/.savesync-backups/<time>/
# Backups older than 30 days (SAVESYNC_KEEP_DAYS) are pruned automatically.

set -uo pipefail

VERSION="2.0.0"

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/savesync"
CONF_FILE="$CONF_DIR/config"
RCLONE_CONF="$CONF_DIR/rclone.conf"
LOCAL_BACKUPS="${XDG_DATA_HOME:-$HOME/.local/share}/savesync/backups"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
REMOTE="nas"

# ---- settings -------------------------------------------------------------------
# Every setting is a SAVESYNC_* variable. Environment variables win over the
# config file (written by `savesync setup`), which wins over the defaults.
#   SAVESYNC_HOST        NAS name shown in messages (setup fills this in)
#   SAVESYNC_ROOT        NAS folder for saves, states, BIOS, backups  [emudeck]
#   SAVESYNC_GAMES       NAS folder for ROMs                          [Games]
#   SAVESYNC_SAVES, SAVESYNC_BIOS, SAVESYNC_BACKUPS   override single NAS folders
#   SAVESYNC_EMU         local Emulation folder              [auto-detected]
#   SAVESYNC_LAYOUT      emudeck | retrodeck | custom        [auto-detected]
#   SAVESYNC_SAVE_DIRS   save folders inside SAVESYNC_EMU    [emudeck: saves,
#                                                             others: saves states]
#   SAVESYNC_BIOS_DIR, SAVESYNC_ROMS_DIR   local folders     [bios, roms]
#   SAVESYNC_KEEP_DAYS   days to keep backups                [30]

# The config file is read as plain KEY="value" lines, never executed.
load_config() {
  local key val
  [ -f "$CONF_FILE" ] || return 0
  while IFS='=' read -r key val; do
    [[ "$key" =~ ^SAVESYNC_[A-Z_]+$ ]] || continue
    [ -n "${!key+x}" ] && continue            # already set in the environment
    val="${val%\"}"; val="${val#\"}"
    printf -v "$key" '%s' "$val"
  done < "$CONF_FILE"
}

derive_settings() {
  REMOTE_ROOT="${SAVESYNC_ROOT:-emudeck}"; REMOTE_ROOT="${REMOTE_ROOT%/}"
  SAVES_SHARE_PATH="${SAVESYNC_SAVES:-$REMOTE_ROOT/saves}"
  BIOS_SHARE_PATH="${SAVESYNC_BIOS:-$REMOTE_ROOT/bios}"
  GAMES_SHARE_PATH="${SAVESYNC_GAMES:-Games}"
  BACKUP_SHARE_PATH="${SAVESYNC_BACKUPS:-$REMOTE_ROOT/.savesync-backups}"
  KEEP_DAYS="${SAVESYNC_KEEP_DAYS:-30}"
  NAS_NAME="${SAVESYNC_HOST:-the NAS}"
}

load_config
derive_settings
# ------------------------------------------------------------------------------

DRY=()
YES=0
FAILS=0
RCLONE=""
EMU=""
LAYOUT=""
SAVE_DIRS=()
BIOS_DIR=""
ROMS_DIR=""
NET=(--contimeout 5s --timeout 20s)
if [ -t 1 ]; then PROGRESS=(-P); else PROGRESS=(-v); fi

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_HEAD=$'\033[1;36m' C_WARN=$'\033[1;33m' C_ERR=$'\033[1;31m' C_DIM=$'\033[2m' C_OFF=$'\033[0m'
else
  C_HEAD="" C_WARN="" C_ERR="" C_DIM="" C_OFF=""
fi

msg()  { printf '%s==>%s %s\n' "$C_HEAD" "$C_OFF" "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '%s  ! %s%s\n' "$C_WARN" "$*" "$C_OFF" >&2; }
die()  { printf '%sxx %s%s\n' "$C_ERR" "$*" "$C_OFF" >&2; exit 1; }

# prints the comment block at the top of this file
usage() { sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit "${1:-0}"; }

human() {  # human <bytes>  ->  1.4G
  numfmt --to=iec --format='%.1f' "$1" 2>/dev/null | sed 's/\.0$//; s/\.0\([A-Z]\)$/\1/' \
    || echo "$1"
}

confirm() {  # confirm <question>  - exits unless the answer is yes
  local a
  [ ${#DRY[@]} -gt 0 ] && return 0
  [ "$YES" = 1 ] && return 0
  [ -t 0 ] || die "Not asking without a terminal - add -y to go ahead."
  read -rp "    $1 [y/N] " a
  [[ "$a" =~ ^[Yy]$ ]] || { note "Cancelled."; exit 0; }
}

# ---- rclone -------------------------------------------------------------------
install_rclone() {
  local arch tmp
  case "$(uname -m)" in
    x86_64)        arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l)        arch=arm-v7 ;;
    *) die "No rclone download for $(uname -m) - install rclone yourself and re-run" ;;
  esac
  msg "rclone not found - installing it to ~/.local/bin"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/rclone.zip" \
    "https://downloads.rclone.org/rclone-current-linux-$arch.zip" \
    || { rm -rf "$tmp"; die "Couldn't download rclone (no internet?)"; }
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
      "$tmp/rclone.zip" "$tmp"
  else
    unzip -q "$tmp/rclone.zip" -d "$tmp"
  fi || { rm -rf "$tmp"; die "Couldn't unpack rclone"; }
  mkdir -p "$HOME/.local/bin"
  install -m 755 "$tmp"/rclone-*-linux-"$arch"/rclone "$HOME/.local/bin/rclone"
  rm -rf "$tmp"
}

find_rclone() {
  if command -v rclone >/dev/null 2>&1; then
    RCLONE="$(command -v rclone)"
  elif [ -x "$HOME/.local/bin/rclone" ]; then
    RCLONE="$HOME/.local/bin/rclone"
  else
    install_rclone
    RCLONE="$HOME/.local/bin/rclone"
  fi
}

# Own config file, so it never clashes with EmuDeck's rclone setup.
rc() { "$RCLONE" --config "$RCLONE_CONF" "$@"; }

remote_get() {  # remote_get <key>  - a value from the NAS connection settings
  rc config show "$REMOTE" 2>/dev/null | sed -n "s/^$1 = //p"
}

# ---- locating the Emulation folder --------------------------------------------
emudeck_dir() {
  local p f
  for f in "$HOME/.config/EmuDeck/settings.sh" "$HOME/emudeck/settings.sh"; do
    [ -f "$f" ] || continue
    p="$(sed -n "s/^emulationPath=[\"']\{0,1\}\([^\"']*\).*/\1/p" "$f" | tail -n 1)"
    p="${p//\$HOME/$HOME}"; p="${p/#\~/$HOME}"; p="${p%/}"
    [ -n "$p" ] && [ -d "$p/saves" ] && { echo "$p"; return 0; }
  done
  [ -d "$HOME/Emulation/saves" ] && { echo "$HOME/Emulation"; return 0; }
  for p in /run/media/*/Emulation /run/media/*/*/Emulation; do
    [ -d "$p/saves" ] && { echo "$p"; return 0; }
  done
  return 1
}

retrodeck_dir() {
  local p f cfg="$HOME/.var/app/net.retrodeck.retrodeck/config/retrodeck"
  for f in "$cfg/retrodeck.cfg" "$cfg/retrodeck.json"; do
    [ -f "$f" ] || continue
    p="$(sed -n -e 's/^rdhome=//p' -e 's/.*"rdhome" *: *"\([^"]*\)".*/\1/p' "$f" | tail -n 1)"
    p="${p%/}"
    [ -n "$p" ] && [ -d "$p/saves" ] && { echo "$p"; return 0; }
  done
  for p in "$HOME/retrodeck" /run/media/*/retrodeck /run/media/*/*/retrodeck; do
    [ -d "$p/saves" ] && { echo "$p"; return 0; }
  done
  return 1
}

under_emu() { case "$1" in /*) echo "${1%/}" ;; *) echo "$EMU/${1%/}" ;; esac; }

# Sets EMU, LAYOUT, SAVE_DIRS, BIOS_DIR and ROMS_DIR.
resolve_layout() {
  local dirs
  LAYOUT="${SAVESYNC_LAYOUT:-auto}"
  if [ -n "${SAVESYNC_EMU:-}" ]; then
    EMU="${SAVESYNC_EMU/#\~/$HOME}"; EMU="${EMU%/}"
    [ -d "$EMU" ] || { warn "SAVESYNC_EMU=$SAVESYNC_EMU doesn't exist"; return 1; }
    if [ "$LAYOUT" = auto ]; then
      # RetroDECK keeps states next to saves; EmuDeck keeps them inside saves/<emu>/
      if [ -d "$EMU/states" ]; then LAYOUT=retrodeck; else LAYOUT=emudeck; fi
    fi
  else
    case "$LAYOUT" in
      emudeck)   EMU="$(emudeck_dir)" || return 1 ;;
      retrodeck) EMU="$(retrodeck_dir)" || return 1 ;;
      custom)    warn "SAVESYNC_LAYOUT=custom needs SAVESYNC_EMU"; return 1 ;;
      *) if EMU="$(emudeck_dir)"; then LAYOUT=emudeck
         elif EMU="$(retrodeck_dir)"; then LAYOUT=retrodeck
         else return 1
         fi ;;
    esac
  fi
  case "$LAYOUT" in
    emudeck|retrodeck|custom) ;;
    *) die "SAVESYNC_LAYOUT must be emudeck, retrodeck or custom (not \"$LAYOUT\")" ;;
  esac
  if [ "$LAYOUT" = emudeck ]; then dirs="saves"; else dirs="saves states"; fi
  read -ra SAVE_DIRS <<< "${SAVESYNC_SAVE_DIRS:-$dirs}"
  BIOS_DIR="$(under_emu "${SAVESYNC_BIOS_DIR:-bios}")"
  ROMS_DIR="$(under_emu "${SAVESYNC_ROMS_DIR:-roms}")"
}

# NAS folder for a local save folder: saves -> SAVESYNC_SAVES, others -> <root>/<name>
remote_dir() {
  if [ "$1" = saves ]; then echo "$SAVES_SHARE_PATH"; else echo "$REMOTE_ROOT/${1##*/}"; fi
}

# ---- checks -------------------------------------------------------------------
need_setup() {
  # shellcheck disable=SC2015  # either failing should stop us
  [ -f "$RCLONE_CONF" ] && rc listremotes 2>/dev/null | grep -qx "$REMOTE:" \
    || die "Not set up yet - run: savesync setup"
}

# The root folder may not exist yet on a fresh NAS, so fall back to the top level.
check_nas() {
  { rc lsf --max-depth 1 "${NET[@]}" "$REMOTE:${REMOTE_ROOT%%/*}" \
      || rc lsf --max-depth 1 "${NET[@]}" "$REMOTE:"; } >/dev/null 2>&1
}

nas_or_die() {
  check_nas || die "Can't reach $NAS_NAME (off, asleep, or wrong login?)"
}

check_emulators_closed() {
  local running a
  running="$(pgrep -ai 'retroarch|dolphin-emu|pcsx2|duckstation|ryujinx|cemu|rpcs3|xenia|azahar|citra|melonds|ppsspp|mgba|primehack|vita3k|shadps4|flycast|emulationstation|es-de|retrodeck' || true)"
  [ -z "$running" ] && return 0
  warn "Emulators look like they're still running - saves may be mid-write:"
  printf '%s\n' "$running" | sed 's/^/      /' >&2
  if [ -t 0 ]; then
    read -rp "    Continue anyway? [y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] || exit 1
  else
    die "Close them and try again."
  fi
}

# Two runs at once (e.g. a push still going in another window) could fight
# over the same files.
take_lock() {
  command -v flock >/dev/null 2>&1 || return 0
  mkdir -p "$CONF_DIR"
  exec 9>"$CONF_DIR/.lock"
  flock -n 9 || die "Another savesync is already running."
}

# ---- copy helpers -------------------------------------------------------------
# rclone flags shared by every save/BIOS transfer:
#   --update      never replace a newer file with an older one
#   --skip-links  ignore symlinks inside folders (we resolve EmuDeck's ourselves)
COMMON=(--update --skip-links --stats 0 -v)

COUNT=0      # files transferred (or that would be, in a dry run)
REPLACED=0   # of those, how many replaced an older copy
SAME=0       # files skipped because only their dates differed
declare -A SKIP=()

# Before replacing a file that exists on both sides, compare the actual
# contents. If they're identical (only the date differs - e.g. after a plain
# `cp`), nothing is transferred: the local copy's date is set to match the NAS,
# so the two agree from then on.
#   same_check <single-file?> <rclone copy|copyto args...>
same_check() {
  local single="$1"; shift
  local src="$2" dst="$3" nas lroot tmp cand n=0 t path
  SKIP=()
  if [[ "$src" == "$REMOTE:"* ]]; then nas="$src"; lroot="$dst"; else nas="$dst"; lroot="$src"; fi
  # which existing files would be replaced?
  cand="$(rc "$@" "${COMMON[@]}" --dry-run 2>&1 \
          | sed -n 's/^[0-9/]* [0-9:]* *[A-Z]* *: \(.*\): Skipped move as --dry-run is set.*$/\1/p')"
  [ -n "$cand" ] || return 0
  tmp="$(mktemp -d)"

  if [ "$single" = 1 ]; then
    # one file: fetch the NAS copy and compare byte for byte
    if rc cat "$nas" > "$tmp/nas" 2>/dev/null && cmp -s "$tmp/nas" "$lroot"; then
      t="$(rc lsf --format t --time-format RFC3339Nano "$nas" 2>/dev/null | head -n 1)"
      if [ -n "$t" ]; then
        if [ ${#DRY[@]} -gt 0 ] || touch -m -d "$t" "$lroot" 2>/dev/null; then
          SKIP["$cand"]=1; n=1
        fi
      fi
    fi
  else
    printf '%s\n' "$cand" > "$tmp/cand"
    rc check "$src" "$dst" --download --one-way --files-from "$tmp/cand" \
       --match "$tmp/match" >/dev/null 2>&1
    if [ -s "$tmp/match" ]; then
      while IFS=$'\t' read -r t path; do
        [ -n "$path" ] || continue
        if [ ${#DRY[@]} -gt 0 ] || touch -m -d "$t" "$lroot/$path" 2>/dev/null; then
          SKIP["$path"]=1; n=$((n + 1))
        fi
      done < <(rc lsf -R --files-only --files-from "$tmp/match" --format tp \
                 --separator $'\t' --time-format RFC3339Nano "${nas}" 2>/dev/null)
    fi
  fi
  rm -rf "$tmp"
  SAME=$((SAME + n))
}

# run <arrow> <label> <single-file?> <rclone args...>
# Prints one tidy line per file, e.g.   ↑ retroarch/saves/Pokemon Emerald.srm (updated)
run() {
  local arrow="$1" label="$2" single="$3"; shift 3
  local out rstatus line name kind
  same_check "$single" "$@"
  out="$(rc "$@" "${COMMON[@]}" "${DRY[@]}" 2>&1)"; rstatus=$?
  declare -A moved=()
  # first pass: note which files had an old copy set aside (= replaced)
  while IFS= read -r line; do
    if [[ "$line" =~ :\ (.+):\ (Moved\ \(server-side\)|Moved|Skipped\ move) ]]; then
      moved["${BASH_REMATCH[1]}"]=1
    fi
  done <<< "$out"
  while IFS= read -r line; do
    line="$(sed 's/^[0-9/]* [0-9:]* //' <<< "$line")"
    if [[ "$line" =~ ^(INFO|NOTICE)\ *:\ (.+):\ (Copied|Skipped\ copy) ]]; then
      name="${BASH_REMATCH[2]}"
      # identical, only the date differed (dry run only - in a real run those
      # files were re-dated and rclone doesn't send them)
      [ ${#DRY[@]} -gt 0 ] && [ -n "${SKIP[$name]:-}" ] && continue
      [ "$single" = 1 ] && name="${label#*/}" || name="${label#*/}/$name"
      if [ -n "${moved[${BASH_REMATCH[2]}]:-}" ] || [[ "$line" == *"replaced existing"* ]]; then
        kind="updated"; REPLACED=$((REPLACED + 1))
      else
        kind="new"
      fi
      printf '    %s %s %s(%s)%s\n' "$arrow" "$name" "$C_DIM" "$kind" "$C_OFF"
      COUNT=$((COUNT + 1))
    elif [[ "$line" =~ ERROR|Failed|failed ]]; then
      printf '    %s\n' "$line"
    fi
  done <<< "$out"
  if [ "$rstatus" -ne 0 ]; then
    warn "problem with $label"
    FAILS=$((FAILS + 1))
  fi
}

up()   { run "↑" "$3" 0 copy   "$1" "$REMOTE:$2" --backup-dir "$REMOTE:$BACKUP_SHARE_PATH/$STAMP/$3"; }
upf()  { run "↑" "$3" 1 copyto "$1" "$REMOTE:$2" --backup-dir "$REMOTE:$BACKUP_SHARE_PATH/$STAMP/${3%/*}"; }
down() { run "↓" "$3" 0 copy   "$REMOTE:$1" "$2" --backup-dir "$LOCAL_BACKUPS/$STAMP/$3"; }
downf(){ run "↓" "$3" 1 copyto "$REMOTE:$1" "$2" --backup-dir "$LOCAL_BACKUPS/$STAMP/${3%/*}"; }

# ---- saves --------------------------------------------------------------------
push_saves() {
  local d
  for d in "${SAVE_DIRS[@]}"; do
    if [ "$LAYOUT" = emudeck ]; then push_linked "$d"; else push_plain "$d"; fi
  done
  push_vmu
}

pull_saves() {
  local d
  for d in "${SAVE_DIRS[@]}"; do
    if [ "$LAYOUT" = emudeck ]; then pull_linked "$d"; else pull_plain "$d"; fi
  done
  pull_vmu
}

# EmuDeck's ~/Emulation/saves/<emu>/<thing> entries are symlinks into each
# emulator's real save folder. We resolve every link and copy against the real
# folder, which avoids all the symlink trouble with cp/rsync/SMB.
push_linked() {
  local d="$1" nas emu_path emu entry_path entry real
  nas="$(remote_dir "$d")"
  msg "Uploading $d  ($EMU/$d -> $nas)"
  for emu_path in "$EMU/$d"/*/; do
    [ -d "$emu_path" ] || continue
    emu="$(basename "$emu_path")"
    for entry_path in "$EMU/$d/$emu"/*; do
      [ -e "$entry_path" ] || continue            # empty dir or dangling link
      entry="$(basename "$entry_path")"
      real="$(readlink -f "$entry_path")"
      if [ -d "$real" ]; then
        up  "$real" "$nas/$emu/$entry" "$d/$emu/$entry"
      else
        upf "$real" "$nas/$emu/$entry" "$d/$emu/$entry"
      fi
    done
  done
}

pull_linked() {
  local d="$1" nas emu line name local_path real
  nas="$(remote_dir "$d")"
  msg "Downloading $d  ($nas -> $EMU/$d)"
  while IFS= read -r emu; do
    emu="${emu%/}"
    if [ ! -d "$EMU/$d/$emu" ]; then
      note "skipping $emu (not installed on this machine)"
      continue
    fi
    while IFS= read -r line; do
      name="${line%/}"
      [[ "$name" == .* ]] && continue          # EmuDeck's own marker files (.hash etc.)
      local_path="$EMU/$d/$emu/$name"
      if [ ! -e "$local_path" ]; then
        if [ -L "$local_path" ]; then
          # EmuDeck link exists but the emulator hasn't made its folder yet
          [ ${#DRY[@]} -eq 0 ] && mkdir -p "$(readlink -m "$local_path")"
        else
          note "skipping $emu/$name (no matching folder here - launch $emu once, then re-run)"
          continue
        fi
      fi
      real="$(readlink -m "$local_path")"
      if [[ "$line" == */ ]]; then
        down  "$nas/$emu/$name" "$real" "$d/$emu/$name"
      else
        downf "$nas/$emu/$name" "$real" "$d/$emu/$name"
      fi
    done < <(rc lsf "$REMOTE:$nas/$emu" 2>/dev/null)
  done < <(rc lsf --dirs-only "$REMOTE:$nas" 2>/dev/null)
}

# RetroDECK and custom setups keep saves in real folders, so each save folder
# is mirrored as a whole.
push_plain() {
  local d="$1" nas
  nas="$(remote_dir "$d")"
  if [ ! -d "$EMU/$d" ]; then note "skipping $d (no $EMU/$d here)"; return 0; fi
  msg "Uploading $d  ($EMU/$d -> $nas)"
  up "$(readlink -f "$EMU/$d")" "$nas" "$d"
}

pull_plain() {
  local d="$1" nas
  nas="$(remote_dir "$d")"
  msg "Downloading $d  ($nas -> $EMU/$d)"
  if ! rc lsf --max-depth 1 "$REMOTE:$nas" >/dev/null 2>&1; then
    note "(nothing on the NAS yet)"
    return 0
  fi
  down "$nas" "$(readlink -m "$EMU/$d")" "$d"
}

# ---- BIOS ---------------------------------------------------------------------
# BIOS files almost never change, so push/pull leave them alone - use
# `savesync bios push|pull` after adding new ones. The exception is Flycast's
# Dreamcast memory cards, which live in the bios folder but are real saves:
# those few files go with every push/pull.
VMU_FILTER=(--include "/vmu_save_*.bin" --include "/dc/vmu_save_*.bin" --include "/dc/dc_nvmem.bin")

push_vmu() {
  [ -d "$BIOS_DIR" ] || return 0
  run "↑" "bios" 0 copy "$(readlink -f "$BIOS_DIR")" "$REMOTE:$BIOS_SHARE_PATH" "${VMU_FILTER[@]}" \
      --backup-dir "$REMOTE:$BACKUP_SHARE_PATH/$STAMP/bios"
}

pull_vmu() {
  [ -d "$BIOS_DIR" ] || return 0
  run "↓" "bios" 0 copy "$REMOTE:$BIOS_SHARE_PATH" "$(readlink -f "$BIOS_DIR")" "${VMU_FILTER[@]}" \
      --backup-dir "$LOCAL_BACKUPS/$STAMP/bios"
}

push_bios() {
  [ -d "$BIOS_DIR" ] || die "No bios folder at $BIOS_DIR"
  msg "Uploading BIOS  ($BIOS_DIR -> $BIOS_SHARE_PATH)"
  up "$(readlink -f "$BIOS_DIR")" "$BIOS_SHARE_PATH" "bios"
}

pull_bios() {
  [ -d "$BIOS_DIR" ] || die "No bios folder at $BIOS_DIR"
  msg "Downloading BIOS  ($BIOS_SHARE_PATH -> $BIOS_DIR)"
  down "$BIOS_SHARE_PATH" "$(readlink -f "$BIOS_DIR")" "bios"
}

# ---- games --------------------------------------------------------------------
# The NAS games folder mirrors the local roms folder: <games>/<system>/<game>.
# A "game" is any file or folder directly inside a system folder; a search
# matches names containing every word (any case), so multi-file games
# (.cue + .bin, .m3u + discs) come along when the words fit all their names.
# Games are never overwritten - only missing files are copied.

matches() {  # matches <name> [words...]
  local n="${1,,}" w; shift
  for w in "$@"; do [[ "$n" == *"${w,,}"* ]] || return 1; done
}

# entries <nas|local> <system> [words...]  ->  "size<TAB>name" per match,
# folders end in "/" and have size -1
entries() {
  local where="$1" sys="$2" size name; shift 2
  if [ "$where" = nas ]; then
    rc lsf --format sp --separator $'\t' "$REMOTE:$GAMES_SHARE_PATH/$sys" 2>/dev/null
  else
    find "$ROMS_DIR/$sys/" -mindepth 1 -maxdepth 1 \
      \( -type d -printf '-1\t%f/\n' \) -o \( -type f -printf '%s\t%f\n' \) 2>/dev/null
  fi | sort -f -t $'\t' -k2 | while IFS=$'\t' read -r size name; do
    case "$name" in .*|systeminfo.txt|metadata.txt) continue ;; esac   # EmuDeck's own files
    if matches "$name" "$@"; then printf '%s\t%s\n' "$size" "$name"; fi
  done
}

entry_size() {  # entry_size <nas|local> <path> <listed size>
  if [ "$3" -ge 0 ]; then echo "$3"; return; fi
  if [ "$1" = nas ]; then
    rc size --json "$REMOTE:$2" 2>/dev/null | sed -n 's/.*"bytes": *\([0-9]*\).*/\1/p'
  else
    du -sb "$2" 2>/dev/null | cut -f1
  fi
}

roms_dir_or_die() {  # roms_dir_or_die <upload|download>
  [ -L "$ROMS_DIR" ] && die "$ROMS_DIR is a link (to $(readlink "$ROMS_DIR")) - this machine already uses the NAS copy, nothing to $1."
  [ -d "$ROMS_DIR" ] || die "No roms folder at $ROMS_DIR"
}

columns() {
  if command -v column >/dev/null 2>&1; then
    column -c "$(( $(tput cols 2>/dev/null || echo 80) - 4 ))" | sed 's/^/    /'
  else
    sed 's/^/    /'
  fi
}

games_list() {
  local sys="${1:-}" size name mark n=0
  shift $(( $# > 0 ))
  if [ -z "$sys" ]; then
    msg "Systems on the NAS  ($GAMES_SHARE_PATH)"
    rc lsf --dirs-only "$REMOTE:$GAMES_SHARE_PATH" 2>/dev/null | sed 's#/$##' | columns
    note "See one with:  savesync games list <system> [search]"
    return 0
  fi
  msg "$sys on the NAS${*:+ matching \"$*\"}   (✓ = already on this machine)"
  while IFS=$'\t' read -r size name; do
    n=$((n + 1))
    if [ -e "$ROMS_DIR/$sys/${name%/}" ]; then mark="✓"; else mark=" "; fi
    if [ "$size" -ge 0 ]; then size="$(human "$size")"; else size="folder"; fi
    printf '    %s %7s  %s\n' "$mark" "$size" "${name%/}"
  done < <(entries nas "$sys" "$@")
  [ "$n" -gt 0 ] || note "(nothing found - see the systems with: savesync games list)"
}

# transfer_games <up|down> <system> [words...]
# Shows the matching games, asks, then copies them one by one.
transfer_games() {
  local way="$1" sys="$2" from other size name src dst total=0 i skipped=0; shift 2
  local -a names=() sizes=()
  declare -A there=()
  if [ "$way" = down ]; then from=nas other=local; else from=local other=nas; fi
  # files already on the other side are left out (folders are always checked,
  # since they may be incomplete there)
  while IFS=$'\t' read -r size name; do there["$name"]=1; done < <(entries "$other" "$sys")
  while IFS=$'\t' read -r size name; do
    if [[ "$name" != */ ]] && [ -n "${there[$name]:-}" ]; then skipped=$((skipped + 1)); continue; fi
    if [ "$from" = nas ]; then src="$GAMES_SHARE_PATH/$sys/${name%/}"; else src="$ROMS_DIR/$sys/${name%/}"; fi
    names+=("$name")
    sizes+=("$(entry_size "$from" "$src" "$size")")
  done < <(entries "$from" "$sys" "$@")

  if [ ${#names[@]} -eq 0 ]; then
    [ "$skipped" -gt 0 ] && { msg "All $skipped match(es) are already there."; return 0; }
    die "Nothing in $sys matches \"$*\""
  fi
  if [ "$way" = down ]; then msg "Download to $ROMS_DIR/$sys:"; else msg "Upload to $GAMES_SHARE_PATH/$sys:"; fi
  for i in "${!names[@]}"; do
    printf '    %7s  %s\n' "$(human "${sizes[i]:-0}")" "${names[i]%/}"
    total=$((total + ${sizes[i]:-0}))
  done
  [ "$skipped" -gt 0 ] && note "($skipped more already there)"
  confirm "Copy ${#names[@]} item(s), $(human "$total") in total?"

  for name in "${names[@]}"; do
    if [ "$way" = down ]; then
      src="$REMOTE:$GAMES_SHARE_PATH/$sys/${name%/}" dst="$ROMS_DIR/$sys/${name%/}"
    else
      src="$ROMS_DIR/$sys/${name%/}" dst="$REMOTE:$GAMES_SHARE_PATH/$sys/${name%/}"
    fi
    if [[ "$name" == */ ]]; then i=copy; else i=copyto; fi
    if ! rc "$i" "$src" "$dst" --ignore-existing --skip-links "${PROGRESS[@]}" "${DRY[@]}"; then
      warn "problem with ${name%/}"
      FAILS=$((FAILS + 1))
    fi
  done
}

games_push() {
  local sys="${1:-}"
  roms_dir_or_die upload
  if [ -z "$sys" ]; then
    msg "Uploading new games  ($ROMS_DIR -> $GAMES_SHARE_PATH)"
    note "Only files missing from the NAS are sent; nothing there is changed or deleted."
    # --skip-links: EmuDeck adds alias links (e.g. gc -> gamecube); don't upload duplicates
    if ! rc copy "$ROMS_DIR" "$REMOTE:$GAMES_SHARE_PATH" --ignore-existing --skip-links \
           --transfers 4 "${PROGRESS[@]}" "${DRY[@]}"; then
      warn "some games didn't upload"
      FAILS=$((FAILS + 1))
    fi
  elif [ $# -eq 1 ]; then
    [ -d "$ROMS_DIR/$sys" ] || die "No $sys folder in $ROMS_DIR"
    msg "Uploading new $sys games  ($ROMS_DIR/$sys -> $GAMES_SHARE_PATH/$sys)"
    if ! rc copy "$ROMS_DIR/$sys" "$REMOTE:$GAMES_SHARE_PATH/$sys" --ignore-existing --skip-links \
           --transfers 4 "${PROGRESS[@]}" "${DRY[@]}"; then
      warn "some games didn't upload"
      FAILS=$((FAILS + 1))
    fi
  else
    transfer_games up "$@"
  fi
}

games_pull() {
  local sys="${1:-}" size
  [ -n "$sys" ] || die "Which system?  e.g.  savesync games pull gba zelda   (see: savesync games list)"
  roms_dir_or_die download
  rc lsf --max-depth 1 "$REMOTE:$GAMES_SHARE_PATH/$sys" >/dev/null 2>&1 \
    || die "No $sys folder on the NAS - see: savesync games list"
  if [ $# -eq 1 ]; then
    size="$(entry_size nas "$GAMES_SHARE_PATH/$sys" -1)"
    msg "Downloading every $sys game  ($GAMES_SHARE_PATH/$sys -> $ROMS_DIR/$sys)"
    confirm "That's up to $(human "${size:-0}") (games already here are skipped). Go ahead?"
    if ! rc copy "$REMOTE:$GAMES_SHARE_PATH/$sys" "$ROMS_DIR/$sys" --ignore-existing --skip-links \
           --transfers 4 "${PROGRESS[@]}" "${DRY[@]}"; then
      warn "some games didn't download"
      FAILS=$((FAILS + 1))
    fi
  else
    transfer_games down "$@"
  fi
}

summary() {  # summary <up|down>
  local where noun
  if [ "$1" = up ]; then where="the NAS"; noun="Uploaded"; else where="this machine"; noun="Downloaded"; fi
  [ ${#DRY[@]} -gt 0 ] && noun="Would transfer"
  if [ "$COUNT" -eq 0 ]; then
    msg "Nothing new - $where is already up to date."
  else
    msg "$noun $COUNT file(s)  ($((COUNT - REPLACED)) new, $REPLACED updated)"
  fi
  if [ "$SAME" -gt 0 ]; then
    note "$SAME file(s) were identical on both sides (only the dates differed) - not transferred, dates matched."
  fi
  COUNT=0; REPLACED=0; SAME=0
}

# ---- recent: what changed locally ---------------------------------------------
# Lists save files on THIS machine changed in the last N hours, so you can check
# an emulator actually wrote your save before pushing.
recent() {
  local hours="$1" d any=0 when path
  [[ "$hours" =~ ^[0-9]+$ ]] || die "Use:  savesync recent [hours]"
  msg "Save files changed on this machine in the last $hours hour(s):"
  for d in "${SAVE_DIRS[@]}"; do
    [ -d "$EMU/$d" ] || continue
    # -L follows EmuDeck's links into the emulators' real save folders
    while IFS=$'\t' read -r _ when path; do
      any=1
      printf '    %s  %s/%s\n' "$when" "$d" "$path"
    done < <(find -L "$EMU/$d" -type f -mmin -"$((hours * 60))" \
               -printf '%T@\t%Ta %TH:%TM\t%P\n' 2>/dev/null | sort -n)
  done
  [ "$any" = 1 ] || note "(none - the emulator may not have written your save yet; quit the game fully and check again)"
}

# ---- housekeeping -------------------------------------------------------------
# Each run's backups live in a folder named after the run's date/time
# (YYYY-MM-DD_HHMMSS). Age is judged by that name, NOT by file timestamps:
# backed-up files keep their original (often years-old) dates.
prune_backups() {
  [ ${#DRY[@]} -gt 0 ] && return 0
  local cutoff d
  cutoff="$(date -d "-${KEEP_DAYS} days" +%Y-%m-%d_%H%M%S)"
  if [ -d "$LOCAL_BACKUPS" ]; then
    for d in "$LOCAL_BACKUPS"/*/; do
      d="$(basename "$d")"
      [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$ ]] || continue
      [[ "$d" < "$cutoff" ]] && rm -rf "${LOCAL_BACKUPS:?}/$d"
    done
  fi
  while IFS= read -r d; do
    d="${d%/}"
    [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$ ]] || continue
    [[ "$d" < "$cutoff" ]] && rc purge "$REMOTE:$BACKUP_SHARE_PATH/$d" >/dev/null 2>&1
  done < <(rc lsf --dirs-only "$REMOTE:$BACKUP_SHARE_PATH" 2>/dev/null)
  return 0
}

finish() {
  prune_backups
  if [ ${#DRY[@]} -gt 0 ]; then
    msg "Dry run finished - nothing was changed."
  elif [ "$FAILS" -gt 0 ]; then
    warn "Finished with $FAILS problem(s) - see messages above."
    exit 1
  else
    msg "All done."
  fi
}

# ---- setup --------------------------------------------------------------------
ask() {  # ask <var> <question> [default]
  local _a
  read -rp "    $2${3:+ [$3]}: " _a
  printf -v "$1" '%s' "${_a:-${3:-}}"
}

# ask_pass <var> <type> [hint] - reads a password and hands it back obscured
# the way rclone stores it. Enter keeps the current one.
ask_pass() {
  local _p _old=""
  [ "$(remote_get type)" = "$2" ] && _old="$(remote_get pass)"
  read -rsp "    Password${_old:+ (Enter = keep current)}${3:+ $3}: " _p; echo
  if [ -n "$_p" ]; then
    # piped in, so the password never shows up in the process list
    _p="$(printf '%s' "$_p" | rc obscure -)" || die "rclone couldn't store the password"
  else
    _p="$_old"
  fi
  printf -v "$1" '%s' "$_p"
}

make_remote() {  # make_remote <type> key=value...   (empty values are left out)
  local type="$1" kv; shift
  local -a args=()
  for kv in "$@"; do [ -n "${kv#*=}" ] && args+=("$kv"); done
  rc config delete "$REMOTE" >/dev/null 2>&1
  rc config create "$REMOTE" "$type" "${args[@]}" --no-obscure >/dev/null \
    || die "Couldn't save the connection"
  chmod 600 "$RCLONE_CONF"
}

set_conf() {  # set_conf KEY [value]  - set (or with no value, remove) one setting
  local tmp
  tmp="$(mktemp)"
  [ -f "$CONF_FILE" ] && grep -v "^$1=" "$CONF_FILE" > "$tmp"
  [ $# -gt 1 ] && printf '%s="%s"\n' "$1" "$2" >> "$tmp"
  mv "$tmp" "$CONF_FILE"
}

setup() {
  local kind h u p port key url path auto f
  mkdir -p "$CONF_DIR"
  [ -f "$CONF_FILE" ] || printf '%s\n' \
    "# savesync settings - written by 'savesync setup', safe to edit." \
    "# Any SAVESYNC_* setting from the top of savesync.sh can go here." > "$CONF_FILE"

  case "$(remote_get type)" in sftp) kind=2 ;; webdav) kind=3 ;; alias) kind=4 ;; *) kind=1 ;; esac
  msg "How do you reach your NAS?   (press Enter to keep the [value in brackets])"
  note "1) SMB / Windows share   TrueNAS, Synology, Unraid, QNAP, Windows, Samba"
  note "2) SFTP / SSH            any machine you can ssh into"
  note "3) WebDAV                Nextcloud, ownCloud, Synology/QNAP WebDAV"
  note "4) A local folder        an NFS or sshfs mount, USB drive, Syncthing folder..."
  ask kind "Choice" "$kind"
  case "$kind" in
    1) ask h "NAS address (IP or name)" "$(remote_get host)"
       ask u "Username" "$(remote_get user)"
       ask_pass p smb
       make_remote smb host="$h" user="$u" pass="$p" ;;
    2) ask h "Server address" "$(remote_get host)"
       ask u "Username" "$(remote_get user)"
       port="$(remote_get port)"; ask port "SSH port" "${port:-22}"
       ask_pass p sftp "(Enter = use an SSH key)"
       key=""
       if [ -z "$p" ]; then
         key="$(remote_get key_file)"
         for f in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
           [ -z "$key" ] && [ -f "$f" ] && key="$f"
         done
         ask key "SSH key file (empty = use ssh-agent)" "$key"
       fi
       make_remote sftp host="$h" user="$u" port="$port" pass="$p" key_file="${key/#\~/$HOME}" ;;
    3) ask url "WebDAV URL" "$(remote_get url)"
       ask u "Username" "$(remote_get user)"
       ask_pass p webdav
       # Nextcloud/ownCloud keep file dates, which "newer file wins" relies on
       if [[ "$url" == *remote.php* ]]; then f=nextcloud; else f=other; fi
       make_remote webdav url="$url" vendor="$f" user="$u" pass="$p"
       h="${url#*://}"; h="${h%%/*}" ;;
    4) ask path "Folder" "$(remote_get remote)"
       path="${path/#\~/$HOME}"; path="${path%/}"
       [ -d "$path" ] || die "No folder at $path"
       make_remote alias remote="$path"
       h="$path" ;;
    *) die "Pick 1, 2, 3 or 4" ;;
  esac
  SAVESYNC_HOST="$h"
  set_conf SAVESYNC_HOST "$h"

  msg "Folders on the NAS   (Enter = keep the [default])"
  note "Paths on the NAS where savesync keeps its files. They're created if missing."
  [ "$kind" = 1 ] && note "For SMB the first part is the share name, e.g. emudeck or data/emudeck"
  ask SAVESYNC_ROOT "Folder for saves, states and BIOS" "$REMOTE_ROOT"
  ask SAVESYNC_GAMES "Folder for games (ROMs)" "$GAMES_SHARE_PATH"
  SAVESYNC_ROOT="${SAVESYNC_ROOT%/}"; SAVESYNC_GAMES="${SAVESYNC_GAMES%/}"
  set_conf SAVESYNC_ROOT "$SAVESYNC_ROOT"
  set_conf SAVESYNC_GAMES "$SAVESYNC_GAMES"
  derive_settings

  check_nas || die "Couldn't connect to $h - check the address and login, then run setup again."
  msg "Connected to $h."
  for f in "$REMOTE_ROOT" "$GAMES_SHARE_PATH"; do
    rc lsf --max-depth 1 "${NET[@]}" "$REMOTE:$f" >/dev/null 2>&1 && continue
    if rc mkdir "$REMOTE:$f" >/dev/null 2>&1; then
      note "created $f"
    else
      warn "$f doesn't exist on the NAS and couldn't be created (for SMB: is the share name right?)"
    fi
  done

  msg "Where are your emulator files on this machine?"
  auto="$(emudeck_dir || retrodeck_dir)" || auto=""
  resolve_layout 2>/dev/null || EMU="$auto"
  if [ -n "$EMU" ]; then
    note "Found: $EMU"
    note "Press Enter to use it, or type a different folder."
  else
    note "Couldn't find EmuDeck's Emulation or RetroDECK's retrodeck folder - type its path."
  fi
  ask path "Folder" "$EMU"
  path="${path/#\~/$HOME}"; path="${path%/}"
  if [ -n "$path" ] && [ "$path" != "$auto" ]; then
    set_conf SAVESYNC_EMU "$path"; SAVESYNC_EMU="$path"
  else
    set_conf SAVESYNC_EMU; unset SAVESYNC_EMU
  fi
  if resolve_layout; then
    note "$EMU  ($LAYOUT layout, syncing: ${SAVE_DIRS[*]})"
  else
    warn "Couldn't find an Emulation folder - set SAVESYNC_EMU in $CONF_FILE"
  fi
  note "Settings saved to $CONF_FILE"
  note "Try a preview first:  savesync pull -n"
}

show_config() {
  local d type
  type="$(remote_get type)"
  msg "savesync $VERSION"
  if [ -f "$CONF_FILE" ]; then note "config:       $CONF_FILE"; else note "config:       (none yet - run: savesync setup)"; fi
  note "NAS:          $NAS_NAME${type:+  ($type)}"
  if [ -n "$EMU" ]; then
    note "Emulation:    $EMU  ($LAYOUT layout)"
    for d in "${SAVE_DIRS[@]}"; do note "  $d -> $(remote_dir "$d")"; done
    note "  bios -> $BIOS_SHARE_PATH     ($BIOS_DIR)"
    note "  roms -> $GAMES_SHARE_PATH     ($ROMS_DIR)"
  else
    note "Emulation:    not found - set SAVESYNC_EMU"
  fi
  note "backups:      $BACKUP_SHARE_PATH on the NAS, $LOCAL_BACKUPS here  (kept $KEEP_DAYS days)"
  if [ -n "$type" ] && check_nas; then msg "NAS is reachable."; else warn "NAS isn't reachable (or not set up yet)."; fi
}

install_self() {
  local bin="$HOME/.local/bin" apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications" src c
  src="$(readlink -f "$0")"
  mkdir -p "$bin"
  if [ "$src" != "$bin/savesync" ]; then
    install -m 755 "$src" "$bin/savesync" || die "Couldn't copy savesync to $bin"
  fi
  msg "Installed: $bin/savesync"
  case ":$PATH:" in
    *":$bin:"*) ;;
    *) warn "$bin isn't on your PATH yet. Add it with:"
       note "echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc" ;;
  esac
  # Menu shortcuts that open a terminal (KDE's Konsole, as on the Steam Deck)
  if command -v konsole >/dev/null 2>&1; then
    mkdir -p "$apps"
    for c in push pull sync; do
      cat > "$apps/savesync-$c.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=SaveSync ${c^}
Comment=Run savesync $c in a terminal
Exec=konsole --hold -e "$bin/savesync" $c
Icon=folder-sync
Terminal=false
Categories=Utility;
EOF
    done
    note "Added SaveSync Push / Pull / Sync to the application menu."
  fi
}

# ---- main ---------------------------------------------------------------------
ARGS=()
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY=(--dry-run) ;;
    -y|--yes) YES=1 ;;
    -h|--help|help) usage 0 ;;
    -V|--version) echo "savesync $VERSION"; exit 0 ;;
    -*) warn "unknown option: $arg"; usage 1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
CMD="${ARGS[0]:-}"
set -- "${ARGS[@]:1}"

case "$CMD" in
  setup|push|pull|sync|bios|games|recent|config|install) ;;
  "") usage 1 ;;
  *) warn "unknown command: $CMD"; usage 1 ;;
esac

if [ "$CMD" = install ]; then install_self; exit 0; fi
find_rclone
if [ "$CMD" = setup ]; then setup; exit 0; fi

if ! resolve_layout; then
  EMU=""
  [ "$CMD" = config ] || die "Couldn't find your Emulation folder - set SAVESYNC_EMU=/path/to/Emulation"
fi
case "$CMD" in
  config) show_config; exit 0 ;;
  recent) recent "${1:-24}"; exit 0 ;;
esac
need_setup
nas_or_die
take_lock
[ ${#DRY[@]} -gt 0 ] && msg "DRY RUN - showing what would happen"
note "Emulation folder: $EMU"

case "$CMD" in
  push)  check_emulators_closed; push_saves; summary up ;;
  pull)  check_emulators_closed; pull_saves; summary down ;;
  sync)  check_emulators_closed; push_saves; summary up
         pull_saves; summary down ;;
  bios)  case "${1:-}" in
           push) push_bios; summary up ;;
           pull) pull_bios; summary down ;;
           *) die "Use:  savesync bios push   or   savesync bios pull" ;;
         esac ;;
  games) sub="${1:-push}"            # plain `savesync games` uploads, as before
         shift $(( $# > 0 ))
         case "$sub" in
           list) games_list "$@"; exit 0 ;;
           push) games_push "$@" ;;
           pull) games_pull "$@" ;;
           *) die "Use:  savesync games list|pull|push [system] [search]" ;;
         esac ;;
esac
finish
