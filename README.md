<p align="center">
  <img src="assets/icon.png" alt="Simple-Backup icon" width="140">
</p>

<h1 align="center">Simple-Backup</h1>

<p align="center">
  Incremental backups for Linux Mint (Cinnamon), in a small Bash project. Keep your files (photos, documents, programs...) always synced to your external drive, without ever having to guess what's left to update.
</p>

<p align="center">
  <a href="LICENSE.txt"><img alt="GPLv3 license" src="https://img.shields.io/badge/License-GPLv3-blue.svg"></a>
  <img alt="Bash" src="https://img.shields.io/badge/bash-%3E%3D4.3-4EAA25?logo=gnubash&logoColor=white">
  <img alt="Linux Mint" src="https://img.shields.io/badge/Linux%20Mint-22.3%20Cinnamon-87CF3E?logo=linuxmint&logoColor=white">
</p>

> **Language:** the project is available in English and Spanish. On a fresh configuration, the script uses Spanish when the system locale is Spanish; otherwise it defaults to English. Press **`l`** or **`L`** in the main menu to switch between English and Spanish. The selected language is saved for future runs.
>
> [Leer en español / Read in Spanish](README.es.md)

---

Simple-Backup is an interactive script that copies your personal folders (Documents, Music, Pictures, Videos, Downloads...) to another drive —usually an external one, although a second internal drive works too— using `rsync`. It does not create a disk image: it copies real, browsable files that you can open directly from the file manager on any PC. It also lets you create full-system snapshots with Timeshift and schedule everything with cron, without having to touch the terminal every time.

<img width="652" height="439" alt="menu-simple-backup-en" src="https://github.com/user-attachments/assets/7824e06e-e108-4956-976c-cfc0648a0027" />
<img width="652" height="442" alt="config-simple-backup-en" src="https://github.com/user-attachments/assets/2797a38e-a008-4a3c-8271-84c3bf279060" />
<img width="650" height="435" alt="simple-backup-automatic-backup-en" src="https://github.com/user-attachments/assets/783dce17-e62d-4bee-b03a-b0537ede49f5" />
<img width="656" height="450" alt="simple-backup-config-check-en" src="https://github.com/user-attachments/assets/37694218-1faa-425a-951f-0b48cd79bf3f" />
<img width="652" height="441" alt="simple-backup-mirror-delete-en" src="https://github.com/user-attachments/assets/f40c6aa5-67e2-4af8-b530-d4ad7df29fe3" />
<img width="654" height="432" alt="simple-backup-quick-help-en" src="https://github.com/user-attachments/assets/82ca2164-43ab-4952-ad5d-462854c5b5b6" />

## Why this script instead of something else?

Backups on Linux usually mean either a **disk image** (`dd`, Clonezilla...) or **system snapshots** (Timeshift, Déjà Dup...). Neither handles the most common case well —having your photos, documents and music also on the external drive, as-is, in case your computer dies tomorrow— because you can't open an image to grab a single file without restoring the whole thing. Simple-Backup uses `rsync` to copy only what's new or modified on each run, leaving the same folder structure on the external drive as you have at home: plug the drive into any PC and your files are right there, with no software needed to recover them.

On top of a plain `rsync -a`, the script adds:

- **It never deletes anything by accident.** It never removes files from the destination, even if you delete them from the source (mirror mode is optional and must be turned on deliberately).
- **It avoids the usual mistakes:** it warns about infinite backups (destination inside a source), an unmounted external drive, a destination on the same disk as your home folder, or source folders with the same name that could get mixed together.
- **It adapts to the destination drive**, adjusting `rsync` automatically for FAT32, exFAT or NTFS.
- **It combines file backup and system snapshots** from the same menu.
- **Everything in one small project:** no unusual dependencies, no `.deb` package, just execution permissions.

## Table of contents

- [Why this script instead of something else?](#why-this-script-instead-of-something-else)
- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
- [Compatibility](#compatibility)
- [Where it stores its files](#where-it-stores-its-files)
- [Language](#language)
- [Roadmap](#roadmap)
- [License](#license)
- [Contributing](#contributing)

## Features

### Personal file backup

- **Automatic folder detection** via `xdg-user-dirs`: recognizes Documents, Music, Pictures, Videos, Downloads, Desktop, Templates and Public in your system's language.
- **Add folders manually**, with a graphical picker (`zenity`) or by typing the path.
- **Overlap warning** if a folder is already contained in another one, or points to the same place through a symbolic link.
- **Configurable exclusions** (`.cache`, `*.tmp`, `*.part`, `*.crdownload`, `*.download`, `node_modules`, `.thumbnails`, `lost+found` by default), editable from the menu.
- **Same-name folders don't get mixed up:** if two sources share a name, each is renamed in the destination by prefixing its parent folder, and the script tells you which name was used.
- **Adapted to the destination filesystem:** adjusts `rsync` options on FAT32, exFAT or NTFS to avoid false permission warnings, and on FAT32 cleanly excludes files over 4 GiB.
- **Mounted-drive detection** (`lsblk`), with label, size and type; choose by number, typed path or graphical picker.
- **Optional mirror mode** (`--delete`, off by default) so the destination is an exact copy of the source, deletions included.
- **Pre-copy checks:** destination accessible and writable, not inside a source nor on the same disk as your home folder, enough free space, and a warning if the drive doesn't look removable.
- **Execution lock** so two backups (say, manual and scheduled) don't collide.
- **Progress bar** per folder, and a final summary that separates minor warnings from real errors.
- **Desktop notifications** on completion (success, warnings or errors), including automatic cron runs.

### Full system snapshots (Timeshift)

The menu gives direct access to [Timeshift](https://github.com/linuxmint/timeshift) for full-system snapshots (the operating system, not your personal files): create one now, list existing snapshots, open its graphical interface, or choose the disk/partition where they're stored. If it's not installed, the script offers to install it.

### Automation

- **Cron scheduling** from the menu (daily or weekly, with hour and day), without editing the crontab by hand; the task can also be removed from there.
- **`--auto` mode:** runs the already-configured backup with no menus, meant for cron. If the drive isn't connected or configuration is missing, it logs it and notifies you if there's a desktop session, instead of failing silently.

### Other useful details

- **Execution logs**, viewable from the menu, with automatic cleanup of older logs (the latest 90 are kept).
- **Verify configuration** (option 7): without copying anything, checks that `rsync` is installed, that sources and destination are accessible, the free space, and whether the cron task (if any) will be able to run; it finishes with a summary of whether everything's fine, there are warnings, or there are problems to fix.
- **First-run wizard** that detects your folders and takes you straight to choosing the destination drive, without hunting for the option in the menu.
- **Dependency check** at startup, with the option to install missing components automatically (`rsync`, `xdg-user-dirs`, and optionally `zenity`).

## Installation

**Requirements:**

| Package | Used for | Required? |
|---|---|---|
| `bash` ≥ 4.3 | Running the script | Yes |
| `rsync` | Performing backups | Yes |
| `xdg-user-dirs` | Detecting personal folders | Yes |
| `zenity` | Graphical folder picker | No (paths can be entered manually) |
| `libnotify-bin` | Desktop notifications | No |
| `timeshift` | System snapshots | No, only if you use that feature |
| `cron` | Scheduled backups | No, only if you use that feature |

When a required dependency is missing, the script detects it at startup and offers to install it with `apt`.

**Steps:**

```bash
git clone https://github.com/filonux/Simple-Backup.git
cd Simple-Backup
chmod +x script/simple-backup.sh
./script/simple-backup.sh
```

This launches the first-run wizard.

**Prefer not to rely on the terminal?** [**Scriptya**](https://github.com/filonux/Scriptya), another tool by the same author, lets you launch, install, uninstall and change the icon of Simple-Backup just like any other application, with its own menu and no commands to type. Just point it at this repository's `script/` folder.

## Usage

**Interactive menu** (normal use):

```bash
./script/simple-backup.sh
```

The main menu has seven options: configure source and destination paths, run the backup now, create a system snapshot, schedule automatic backups, view the log history, enable or disable mirror mode, and verify the configuration without copying anything.

**From zero to automatic backups:** the first run launches the first-run wizard, which detects your folders and takes you straight to choosing the destination drive from a list of mounted drives. With that configured, option 2 runs the first backup, and option 4 only asks for frequency (daily or weekly), hour and, if applicable, day, to schedule it in the crontab for you. From then on you go straight to the main menu, and scheduled backups run on their own, notifying you by desktop notification of each result — all without writing a line of `rsync` or touching the crontab by hand.

**Other commands:**

```bash
./script/simple-backup.sh --auto     # Run the configured backup without menus (for cron)
./script/simple-backup.sh --version  # Show the installed version
./script/simple-backup.sh --help     # Show the help
```

You do not need to call `--auto` yourself: when you schedule a backup from the menu (option 4), the script creates the corresponding cron entry for you.

## Compatibility

Developed and tested on **Linux Mint 22.3 (Cinnamon)**. Since it's built on bash, `rsync` and standard GNU/Linux tools, it should work unchanged on any Debian/Ubuntu-based distribution (other Mint editions, Ubuntu, Pop!_OS...) and with other desktop environments, too — what's Cinnamon-specific is mostly just the notification icons. The one catch is that automatic dependency installation uses `apt`: on distributions that don't use it (Fedora, Arch...) you'll need to install `rsync`, `xdg-user-dirs` and, if you want them, `zenity` and `timeshift` yourself; the rest of the script works the same.

## Where it stores its files

Simple-Backup does not touch anything outside your home folder except the destination drive you explicitly choose:

| What | Where |
|---|---|
| Configuration (folders, destination, exclusions...) | `~/.config/simple-backup/config.conf` |
| Backup logs | `~/.local/share/simple-backup/logs/` |
| Execution lock | `~/.config/simple-backup/backup.lock` |

The configuration file is generated and overwritten automatically from the menu; there is no need (and it is not recommended) to edit it by hand.

## Language

Language selection is independent from the system locale: on a fresh configuration, Simple-Backup checks `LC_ALL`, `LC_MESSAGES` and `LANG`, in that order, and starts in Spanish only if it detects a Spanish locale (`es`, `es_ES`, `es-ES`...); any other case starts in English. The **`l`/`L`** shortcut in the main menu switches between the two and saves the choice in `UI_LANGUAGE` (inside `~/.config/simple-backup/config.conf`), which then overrides automatic detection; existing configurations without that field behave as `auto`.

Code comments are in English; the interface and documentation are translated.

### Tests

Includes a regression suite focused on behavior contracts: language catalogs, locale precedence, real `rsync` behavior, exclusions, mirror deletion, locking, cron integration, Timeshift helpers and exit-code classification, among others — with temporary fixtures and deterministic mocks so each failure points to a specific contract. Run it with `bash tests/test.sh`; `bash tests/mutation.sh` checks that intentional regressions (language switching, menu wording, exclusions, mirror deletion...) are actually caught.

## Roadmap

- [x] Translate the interface into English — the project started Spanish-only; it is now available in both Spanish and English (see [Language](#language)).
- [ ] Possible optional `.deb` package, for people who prefer installing and updating with `apt` instead of cloning the repository. The standalone `.sh` will continue to work for anyone who prefers it.

## License

Published under the **GNU GPLv3** license. See [LICENSE.txt](LICENSE.txt) for the full text.

## Contributing

Contributions are welcome. Before opening an issue or pull request, take a look at [CONTRIBUTING.md](.github/CONTRIBUTING.md) and the [code of conduct](.github/CODE_OF_CONDUCT.md). To report a bug or request a new feature, use the appropriate templates in [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/). If you find a security issue, follow the process described in [SECURITY.md](.github/SECURITY.md) instead of opening a public issue.

---

Made by **[Filonux](https://github.com/filonux)**.
