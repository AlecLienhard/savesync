# savesync

Sync your emulator **saves, save states, BIOS files and ROMs** between a Steam Deck, your other Linux PCs and a NAS, with a few short commands.

It was built for [EmuDeck](https://www.emudeck.com/). EmuDeck already backs up saves, but syncing save states is a paid feature. savesync covers both, plus pulling individual games from your NAS onto whichever machine you're on. It also works with [RetroDECK](https://retrodeck.net/) and with custom setups.

```text
$ savesync push
==> Uploading saves  (/home/deck/Emulation/saves -> emudeck/saves)
    ↑ retroarch/saves/Pokemon Emerald.srm (updated)
    ↑ retroarch/states/Pokemon Emerald.state1 (new)
==> Uploaded 2 file(s)  (1 new, 1 updated)
==> All done.

$ savesync games pull wii
==> wii games not on this machine yet:
      1)    2.7G  Mario Kart Wii (USA) (En,Fr,Es).nkit.gcz
      2)    1.3G  Super Mario Galaxy 2 (USA) (En,Fr,Es).nkit.iso
      3)    3.3G  Super Mario Galaxy (USA) (En,Fr,Es).nkit.gcz
      4)    6.7G  Super Smash Bros. Brawl (USA, Canada) (Rev 2).rvz
    (1 more already there)
    Which ones? (e.g. 2 5 7-9, a = all, Enter = cancel): 1 3
==> Copying 2 item(s), 6G
```

## Why it's safe

- **Newer file wins.** An older copy never replaces a newer one.
- **Nothing is ever deleted**, on either side.
- **Every overwritten file is backed up first:** on the NAS for a push, in `~/.local/share/savesync/backups/` for a pull. Backups are pruned after 30 days.
- **Identical files aren't re-sent**, even when their dates differ (after a plain `cp`, for example). The dates are matched instead.
- **It warns if an emulator is still running**, so you don't sync a save that's halfway through being written.
- **`-n` previews** any command without changing anything.

## Requirements

- Linux with bash 4+ (SteamOS works as-is in Desktop Mode)
- [rclone](https://rclone.org) 1.60 or newer. If it isn't installed, savesync downloads it into `~/.local/bin` on first run. No root needed.
- A NAS or server reachable over **SMB, SFTP or WebDAV**, or any **folder** on the machine (an NFS/sshfs mount, a USB drive, a Syncthing folder...)

## Install

```bash
curl -fsSLO https://raw.githubusercontent.com/AlecLienhard/savesync/main/savesync.sh
bash savesync.sh install      # copies itself to ~/.local/bin/savesync
savesync setup
```

`install` also adds **SaveSync Push / Pull / Sync** to the application menu on KDE (SteamOS Desktop Mode included). Each one opens a terminal window, so you can sync without typing anything.

## Setup

Run `savesync setup` once on each machine. It asks:

1. **How to reach the NAS:** SMB, SFTP/SSH, WebDAV, or a local folder, plus the address and login.
2. **Where things go on the NAS:** a folder for saves/states/BIOS (default `emudeck`) and one for ROMs (default `Games`). With SMB the first part of the path is the share name, so `emudeck` means the `emudeck` share and `data/emudeck` means the `emudeck` folder inside the `data` share.
3. **Your Emulation folder.** It's found automatically for EmuDeck (including on an SD card) and for RetroDECK.

The connection is stored in `~/.config/savesync/rclone.conf` (password obscured, file mode 600). It's separate from EmuDeck's own rclone setup. Your other choices go in `~/.config/savesync/config`. Run `savesync config` to see what's in use and test the connection.

## Usage

| Command | What it does |
| --- | --- |
| `savesync push` | Upload saves and states |
| `savesync pull` | Download saves and states |
| `savesync sync` | Push, then pull, so the newest copy of every file ends up everywhere |
| `savesync bios push` / `bios pull` | Copy BIOS files (only needed after adding new ones) |
| `savesync games list` | List the systems on the NAS |
| `savesync games list gba zelda` | List matching GBA games on the NAS (✓ = already on this machine) |
| `savesync games pull wii` | Pick games to download from a numbered list (`2 5 7-9`, `a` for all) |
| `savesync games pull wii mario` | Same, but only games matching "mario" |
| `savesync games pull wii -y` | Download every Wii game you don't already have, without asking |
| `savesync games push` | Upload every game the NAS doesn't have yet (also just `savesync games`) |
| `savesync games push gba advance` | Upload only the matching games |
| `savesync recent [hours]` | Show save files changed here lately, to check the emulator actually saved |
| `savesync config` | Show settings and test the connection |

Flags: `-n` / `--dry-run` previews, `-y` / `--yes` skips the questions and takes every matching game.

**Searching games:** a game is any file or folder directly inside a system folder. The search matches names that contain every word you type, in any case. Multi-file games (`.cue` + `.bin`, `.m3u` + discs) come along together because their names share the title. Games already on the destination aren't offered again, cover images are left out of lists, downloads check for free disk space first, and games are never overwritten.

### A typical day

```bash
# on the Deck, after playing (Desktop Mode):
savesync push

# on the PC, before playing:
savesync pull
savesync games pull psx           # pick what to take along for offline play
```

## How it works

savesync is a single bash script wrapped around `rclone copy --update`, so no mounts, fstab entries or sudo are needed.

- **EmuDeck** keeps each emulator's saves in its own folder and puts symlinks to them in `~/Emulation/saves/<emulator>/`. savesync follows every link and syncs against the real folder, which avoids the usual symlink problems with SMB, `cp` and `rsync`. Flycast's Dreamcast memory cards sit in the BIOS folder but are really saves, so they go with every push and pull.
- **RetroDECK** and custom layouts keep saves in real folders, so `saves/` and `states/` are mirrored as they are.
- Before overwriting, savesync compares contents, so a file whose date changed but whose contents didn't isn't sent again.

NAS layout (defaults):

```text
emudeck/
  saves/<emulator>/...          EmuDeck (RetroDECK: saves/<system>/... and states/)
  bios/
  .savesync-backups/<time>/     replaced files, pruned after 30 days
Games/
  <system>/<rom files>
```

Use a separate NAS folder for each layout (e.g. `emudeck` and `retrodeck`), since EmuDeck and RetroDECK organise saves differently.

## Configuration

Any of these can go in `~/.config/savesync/config` (as `KEY="value"`) or be set as environment variables. Environment variables win.

| Setting | Default | Meaning |
| --- | --- | --- |
| `SAVESYNC_ROOT` | `emudeck` | NAS folder for saves, states, BIOS, backups |
| `SAVESYNC_GAMES` | `Games` | NAS folder for ROMs |
| `SAVESYNC_SAVES`, `SAVESYNC_BIOS`, `SAVESYNC_BACKUPS` | under `SAVESYNC_ROOT` | Override single NAS folders |
| `SAVESYNC_EMU` | auto-detected | Local Emulation folder |
| `SAVESYNC_LAYOUT` | auto-detected | `emudeck`, `retrodeck` or `custom` |
| `SAVESYNC_SAVE_DIRS` | `saves` (EmuDeck) / `saves states` | Save folders inside `SAVESYNC_EMU` |
| `SAVESYNC_BIOS_DIR`, `SAVESYNC_ROMS_DIR` | `bios`, `roms` | Local folders (relative to `SAVESYNC_EMU`, or absolute) |
| `SAVESYNC_KEEP_DAYS` | `30` | How long backups are kept |

Example: standalone RetroArch on a regular PC:

```bash
SAVESYNC_LAYOUT="custom"
SAVESYNC_EMU="/home/me/.config/retroarch"
SAVESYNC_SAVE_DIRS="saves states"
SAVESYNC_BIOS_DIR="system"
SAVESYNC_ROMS_DIR="/home/me/roms"
SAVESYNC_ROOT="retroarch"
```

For connection options setup doesn't ask about (SMB domain, SFTP host-key checking, ...), edit `~/.config/savesync/rclone.conf`. The remote is called `nas`, and every option from the [rclone docs](https://rclone.org/docs/) works.

## Notes and limits

- "Newer wins" uses file dates, so keep the clocks on your machines roughly right (they are by default). Some plain WebDAV servers don't keep file dates. Nextcloud and ownCloud do.
- Syncing is manual. On the Deck that means switching to Desktop Mode, or using the menu shortcuts.
- To restore an overwritten save, copy it back from the backups folder.
- To uninstall, delete `~/.local/bin/savesync`, `~/.config/savesync` and `~/.local/share/applications/savesync-*.desktop`.

## Development

```bash
shellcheck savesync.sh tests/test.sh
tests/test.sh        # end-to-end tests against a fake NAS folder; needs rclone
```

## License

[MIT](LICENSE)
