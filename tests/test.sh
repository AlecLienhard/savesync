#!/usr/bin/env bash
# End-to-end tests for savesync. Needs rclone on PATH.
#
# The "NAS" is a plain folder reached through an rclone alias remote, and each
# "machine" is a throwaway $HOME with a fake EmuDeck or RetroDECK install, so
# nothing real is touched.

set -uo pipefail

SAVESYNC="$(cd "$(dirname "$0")/.." && pwd)/savesync.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
NAS="$TMP/nas"
mkdir -p "$NAS"
PASS=0 FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
has()  { grep -qF -- "$2" <<< "$1"; }
lacks() { ! has "$@"; }

# machine <name> - a fresh $HOME whose savesync points at the NAS folder
machine() {
  local h="$TMP/$1"
  mkdir -p "$h/.config/savesync"
  rclone --config "$h/.config/savesync/rclone.conf" config create nas alias remote="$NAS" >/dev/null 2>&1
  echo "$h"
}

# ss <home> <args...> - run savesync as that machine
ss() {
  local h="$1"; shift
  env -u XDG_CONFIG_HOME -u XDG_DATA_HOME HOME="$h" NO_COLOR=1 bash "$SAVESYNC" "$@" < /dev/null 2>&1
}

# emudeck <home> - EmuDeck layout: saves/<emu>/<entry> are links to the real folders
emudeck() {
  local h="$1" real="$1/.var/app/org.libretro.RetroArch/config/retroarch"
  mkdir -p "$real/saves" "$real/states" "$h/Emulation/saves/retroarch" \
           "$h/Emulation/bios/dc" "$h/Emulation/roms/gba" "$h/Emulation/roms/psx"
  ln -s "$real/saves" "$h/Emulation/saves/retroarch/saves"
  ln -s "$real/states" "$h/Emulation/saves/retroarch/states"
}

echo "== EmuDeck: push from the Deck"
DECK="$(machine deck)"; emudeck "$DECK"
RA="$DECK/.var/app/org.libretro.RetroArch/config/retroarch"
echo "deck save" > "$RA/saves/Pokemon Emerald.srm"
echo "deck state" > "$RA/states/Pokemon Emerald.state1"
echo "vmu" > "$DECK/Emulation/bios/dc/vmu_save_A1.bin"
echo "bios" > "$DECK/Emulation/bios/scph5501.bin"
for g in "Zelda - Minish Cap.gba" "Metroid Fusion.gba" "Zelda - Link to the Past.gba"; do
  echo "$g" > "$DECK/Emulation/roms/gba/$g"
done
echo cue > "$DECK/Emulation/roms/psx/Final Fantasy VII (Disc 1).cue"
echo bin > "$DECK/Emulation/roms/psx/Final Fantasy VII (Disc 1).bin"
echo info > "$DECK/Emulation/roms/gba/systeminfo.txt"

out="$(ss "$DECK" push -n)"
check "dry run lists the save"        has "$out" "Pokemon Emerald.srm"
check "dry run changes nothing"       test ! -e "$NAS/emudeck"
out="$(ss "$DECK" push)"
check "push uploads saves"            test -f "$NAS/emudeck/saves/retroarch/saves/Pokemon Emerald.srm"
check "push uploads states"           test -f "$NAS/emudeck/saves/retroarch/states/Pokemon Emerald.state1"
check "push uploads Dreamcast VMUs"   test -f "$NAS/emudeck/bios/dc/vmu_save_A1.bin"
check "push leaves other BIOS alone"  test ! -e "$NAS/emudeck/bios/scph5501.bin"
check "push reports 3 new files"      has "$out" "Uploaded 3 file(s)  (3 new, 0 updated)"
out="$(ss "$DECK" push)"
check "second push is a no-op"        has "$out" "Nothing new"

echo "== EmuDeck: a second PC pulls, plays, pushes back"
PC="$(machine pc)"; emudeck "$PC"
PCRA="$PC/.var/app/org.libretro.RetroArch/config/retroarch"
out="$(ss "$PC" pull)"
check "pull downloads the save"       test "$(cat "$PCRA/saves/Pokemon Emerald.srm")" = "deck save"
check "pull downloads the VMU"        test -f "$PC/Emulation/bios/dc/vmu_save_A1.bin"
sleep 1
echo "pc save" > "$PCRA/saves/Pokemon Emerald.srm"
ss "$PC" push >/dev/null
check "newer save replaces NAS copy"  test "$(cat "$NAS/emudeck/saves/retroarch/saves/Pokemon Emerald.srm")" = "pc save"
check "old NAS copy is backed up"     test -n "$(find "$NAS/emudeck/.savesync-backups" -name 'Pokemon Emerald.srm')"
out="$(ss "$DECK" pull)"
check "deck gets the newer save"      test "$(cat "$RA/saves/Pokemon Emerald.srm")" = "pc save"
check "pull counts it as updated"     has "$out" "(0 new, 1 updated)"
check "old local copy is backed up"   test -n "$(find "$DECK/.local/share/savesync/backups" -name 'Pokemon Emerald.srm')"
touch -d '2001-01-01' "$RA/saves/Pokemon Emerald.srm"
ss "$DECK" pull >/dev/null
touch -d '2030-01-01' "$RA/saves/Pokemon Emerald.srm"
out="$(ss "$DECK" push)"
# (over SMB savesync compares the bytes itself; on a plain folder rclone's
# checksums already catch it - either way nothing may be sent)
check "identical file isn't re-sent"  has "$out" "Nothing new"

echo "== games"
out="$(ss "$DECK" games -n)"
check "games dry run uploads nothing" test ! -e "$NAS/Games"
ss "$DECK" games >/dev/null
check "games uploads ROMs"            test -f "$NAS/Games/gba/Metroid Fusion.gba"
check "games uploads multi-file"      test -f "$NAS/Games/psx/Final Fantasy VII (Disc 1).bin"
out="$(ss "$PC" games list)"
check "list shows systems"            has "$out" "gba"
for i in $(seq -w 1 40); do mkdir -p "$NAS/Games/system$i"; done
mkdir -p "$NAS/Games/a-much-longer-system-name"
for width in 40 80 132; do
  out="$(COLUMNS=$width ss "$PC" games list | sed -n '/Systems on/,/See one/p' | sed '1d;$d')"
  check "systems fit in $width columns"  test "$(awk '{ if (length > m) m = length } END { print m }' <<< "$out")" -le "$width"
  check "systems line up at $width"     test "$(grep -c system40 <<< "$out")" -eq 1
done
rm -rf "$NAS/Games/system"* "$NAS/Games/a-much-longer-system-name"
out="$(ss "$PC" games list gba zelda)"
check "list filters by search"        has "$out" "Minish Cap"
check "list hides non-matches"        lacks "$out" "Metroid"
check "list hides EmuDeck files"      lacks "$out" "systeminfo"
out="$(ss "$PC" games pull gba zelda)"
check "pull refuses without a tty"    has "$out" "add -y"
check "...and copies nothing"         test ! -e "$PC/Emulation/roms/gba/Zelda - Minish Cap.gba"
ss "$PC" games pull gba ZELDA minish -y >/dev/null
check "pull gets the matching game"   test -f "$PC/Emulation/roms/gba/Zelda - Minish Cap.gba"
check "pull skips other games"        test ! -e "$PC/Emulation/roms/gba/Zelda - Link to the Past.gba"
out="$(ss "$PC" games list gba)"
check "list marks local games"        has "$out" "✓"
ss "$PC" games pull psx "final fantasy" -y >/dev/null
check "pull gets every disc file"     test -f "$PC/Emulation/roms/psx/Final Fantasy VII (Disc 1).cue" -a -f "$PC/Emulation/roms/psx/Final Fantasy VII (Disc 1).bin"
out="$(ss "$PC" games pull gba nosuchgame -y)"
check "pull says when nothing matches" has "$out" "Nothing in gba matches"
echo "pc only" > "$PC/Emulation/roms/gba/Advance Wars.gba"
ss "$PC" games push gba advance -y >/dev/null
check "push of one game"              test -f "$NAS/Games/gba/Advance Wars.gba"
echo changed > "$PC/Emulation/roms/gba/Metroid Fusion.gba"
ss "$PC" games pull gba -y >/dev/null
check "whole-system pull"             test -f "$PC/Emulation/roms/gba/Zelda - Link to the Past.gba"
check "games are never overwritten"   test "$(cat "$PC/Emulation/roms/gba/Metroid Fusion.gba")" = changed

echo "== RetroDECK layout"
RD1="$(machine rd1)"; RD2="$(machine rd2)"
for h in "$RD1" "$RD2"; do
  mkdir -p "$h/retrodeck/saves/gba" "$h/retrodeck/states" "$h/retrodeck/bios" "$h/retrodeck/roms"
  echo 'SAVESYNC_ROOT="retrodeck"' > "$h/.config/savesync/config"
done
echo "rd save" > "$RD1/retrodeck/saves/gba/Golden Sun.srm"
mkdir -p "$RD1/retrodeck/states/gba"; echo "rd state" > "$RD1/retrodeck/states/gba/Golden Sun.state"
out="$(ss "$RD1" config)"
check "detects RetroDECK"             has "$out" "retrodeck layout"
ss "$RD1" push >/dev/null
check "push RetroDECK saves"          test -f "$NAS/retrodeck/saves/gba/Golden Sun.srm"
check "push RetroDECK states"         test -f "$NAS/retrodeck/states/gba/Golden Sun.state"
ss "$RD2" pull >/dev/null
check "pull creates new folders"      test -f "$RD2/retrodeck/saves/gba/Golden Sun.srm" -a -f "$RD2/retrodeck/states/gba/Golden Sun.state"

echo "== misc"
out="$(ss "$DECK" recent 1)"
check "recent lists fresh saves"      has "$out" "states/Pokemon Emerald.state1"
out="$(ss "$DECK" bogus)"
check "unknown command shows help"    has "$out" "unknown command"
out="$(ss "$TMP/nobody" push)"
check "unconfigured machine says so"  has "$out" "Emulation folder"
out="$(ss "$DECK" config)"
check "config reports reachable"      has "$out" "NAS is reachable"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
