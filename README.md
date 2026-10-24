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

## Quick start

1. [Prepare your NAS](#preparing-your-nas): a share and a user that can write to it.
2. [Install](#install) savesync on each machine.
3. Run `savesync setup` on each machine.
4. Preview with `savesync pull -n`, then `savesync push` / `savesync pull` for real.

## Preparing your NAS

savesync needs one place on the NAS for saves and BIOS files, and optionally one for ROMs, plus a user account that can read and write both. Any folder layout works. A simple, tidy one is:

- a share called **`emudeck`** for saves, states and BIOS (small: usually well under 1 GB)
- a share called **`Games`** for ROMs (as big as your library)

savesync creates the folders inside a share by itself. It can't create an SMB *share*, so make those on the NAS first. It's also worth giving the NAS a fixed IP address (a DHCP reservation in your router), so the address you enter in setup keeps working.

### SMB (most NASes and Windows)

Create a user (e.g. `steamdeck`), create the share(s), and give that user read/write access:

- **TrueNAS SCALE:** *Credentials → Local Users → Add*. Then *Datasets → Add Dataset* (preset **SMB**), and *Shares → Windows (SMB) Shares → Add* for that dataset. Give the user Modify/Full Control in the dataset's permissions (ACL).
- **Synology DSM:** *Control Panel → User & Group → Create*, *Control Panel → Shared Folder → Create*, then tick Read/Write for the user. Make sure *Control Panel → File Services → SMB* is enabled.
- **Unraid:** *Users → Add User*, *Shares → Add Share*, then under the share's *SMB Security Settings* set Export to Yes, Security to Private, and the user to Read/Write.
- **Windows:** right-click a folder → *Properties → Sharing → Advanced Sharing*, tick *Share this folder*, and under *Permissions* allow Change for your account.

In setup, pick **1 (SMB)** and enter the NAS's IP address, the user and the password. The folder `emudeck` means the `emudeck` share. If you'd rather use one existing share (say `data`), enter `data/emudeck` and `data/Games`.

savesync speaks SMB2/SMB3. Very old devices that only offer SMB1 need SMB2 turned on.

### SFTP / SSH

Any NAS or Linux box with SSH enabled works, with no shares needed. Paths are relative to the user's home folder unless they start with `/` (e.g. `/mnt/tank/emudeck`). Setup takes a password, or press Enter to use your SSH key (`~/.ssh/id_ed25519` is picked up automatically) or ssh-agent.

### WebDAV (Nextcloud, ownCloud, Synology/QNAP WebDAV)

Pick **3** and paste the WebDAV address. For Nextcloud that's `https://your.server/remote.php/dav/files/USERNAME`. Use an app password if you have two-factor login turned on.

### NFS, sshfs, USB drives, Syncthing

Mount it the normal way, then pick **4 (local folder)** in setup and give the mount point (e.g. `/mnt/nas`). savesync then treats that folder as the NAS. Example NFS mount:

```bash
sudo mount -t nfs 192.168.0.31:/mnt/tank/emudeck-share /mnt/nas
```

## Install

### Steam Deck

1. Switch to **Desktop Mode** (Steam button → Power → Switch to Desktop).
2. Open **Konsole** from the application menu and run:

   ```bash
   curl -fsSLO https://raw.githubusercontent.com/AlecLienhard/savesync/main/savesync.sh
   bash savesync.sh install
   savesync setup
   ```

No sudo password and no system changes are needed. Everything lives in your home folder, and it survives SteamOS updates. An Emulation folder on the microSD card is found automatically.

`install` also adds **SaveSync Push / Pull / Sync** to the application menu. Each one opens a terminal window and runs that command, so you can sync without typing anything.

### Other Linux PCs

The same three commands. On Arch you can `sudo pacman -S rclone` first. Otherwise savesync downloads rclone into `~/.local/bin` by itself.

If `install` says `~/.local/bin isn't on your PATH`, run the line it prints and open a new terminal.

### Updating

Download the new `savesync.sh` and run `bash savesync.sh install` again. Your settings are kept.

## Setup

Run `savesync setup` once on each machine. Press Enter to keep the value shown in `[brackets]`, so re-running setup later only means changing what's different.

```text
==> How do you reach your NAS?
    1) SMB / Windows share   TrueNAS, Synology, Unraid, QNAP, Windows, Samba
    2) SFTP / SSH            any machine you can ssh into
    3) WebDAV                Nextcloud, ownCloud, Synology/QNAP WebDAV
    4) A local folder        an NFS or sshfs mount, USB drive, Syncthing folder...
    Choice [1]: 1
    NAS address (IP or name): 192.168.0.31
    Username: steamdeck
    Password:
==> Folders on the NAS   (Enter = keep the [default])
    Folder for saves, states and BIOS [emudeck]:
    Folder for games (ROMs) [Games]:
==> Connected to 192.168.0.31.
==> Where are your emulator files on this machine?
    Found: /home/deck/Emulation
    Press Enter to use it, or type a different folder.
    Folder [/home/deck/Emulation]:
    /home/deck/Emulation  (emudeck layout, syncing: saves)
```

Use the same NAS folders on every machine so they share saves.

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

## Troubleshooting

| Message or problem | What to do |
| --- | --- |
| `Can't reach the NAS (off, asleep, or wrong login?)` | Check the NAS is on and awake, and that its IP hasn't changed. Re-run `savesync setup` to fix the address or password. |
| `... doesn't exist on the NAS and couldn't be created` | With SMB, the first part of the folder must be an existing share name, and the user needs write access to it. |
| `problem with ...` or permission errors | The NAS user can read but not write. Give it read/write on the share. |
| `skipping <emulator>/<folder> (no matching folder here...)` | That emulator hasn't been started on this machine yet. Launch it once, then pull again. |
| `Emulators look like they're still running` | Quit the game and the emulator (and ES-DE) fully so the save is written, then run again. |
| Not sure whether the emulator saved | `savesync recent` lists save files changed in the last 24 hours. |
| Transfers are slow | It's almost always the network. Use 5 GHz Wi-Fi instead of 2.4 GHz, or Ethernet for big game downloads. |
| A save got overwritten | Copy it back from `~/.local/share/savesync/backups/<time>/` (after a pull) or `.savesync-backups/<time>/` on the NAS (after a push). |

When in doubt, add `-n` to see what would happen without changing anything.

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
