<div align="center">

<img src="ico/share7-logo.svg" width="88" height="88" alt="Share7 logo">

# Share**7**

**Zero-config peer-to-peer file sync for local networks**

*Drop it in a folder. Run it. Files sync.*

![Windows 7+](https://img.shields.io/badge/Windows_7%2B-0078D4?logo=windows&logoColor=white)
![Delphi](https://img.shields.io/badge/Object%20Pascal-Delphi-EE1F35?logo=delphi&logoColor=white)
![Free](https://img.shields.io/badge/free-forever-2d6cdf)
![Size](https://img.shields.io/badge/size-~300%20KB%20%2F%20~1%20MB-555)

[**Go to website**](https://polestorm.pl/share7/)

</div>

---

## What is Share7?

Share7 is a tiny Windows console application that syncs files between computers on the same WiFi network — with **zero configuration**. No server, no account, no port forwarding required. Copy `Share7.exe` into any folder, run it on two or more machines, and they stay in sync automatically.

## Features

|  | |
|---|---|
| **Always free** | No license fees, no subscriptions, no hidden costs — ever |
| **No installation** | Single `.exe` — no installer, no registry entries, no admin rights |
| **300 KB / 1 MB** | Native compiled binary. No .NET, no JVM, no runtime to install. The download is the ~1 MB build — the ~300 KB variant triggers Windows Defender false positives |
| **Zero config** | Peers discover each other automatically via UDP broadcast |
| **Real-time** | File changes detected instantly using `ReadDirectoryChangesW` |
| **Safe deletions** | Only explicit deletes propagate — a missing file is never assumed gone |

## Usage

```
Share7.exe [options]

  -name:<id>      Terminal name — ASCII letters, digits, hyphens, underscores
                  Default: auto-generated two-word name (e.g. fast-zebra)

  -folder:<path>  Watch a specific folder instead of the exe's location

  -sound          Beep when a peer is found or lost
```

On first run, Share7 uses your Windows computer name. If that's not available, it generates a random two-word name like `fast-fox` or `calm-owl`. You can override it with `-name:`.

## How It Works

```
1. Drop Share7.exe into the folder you want to sync and run it
2. It broadcasts its presence on UDP port 7731 every 5 seconds
3. Other Share7 instances on the same network respond immediately
4. File lists are exchanged over TCP port 7732
5. Newer files are pulled — the newest timestamp always wins
6. Deletions propagate in real time via explicit notifications
7. The folder is watched continuously; changes are pushed to all peers
```

**Conflict resolution** — same timestamp but different content? SHA-256 decides. A file absent on one peer is not treated as deleted; only an explicit `NOTIFY_DELETE` message triggers removal. This means you can run Share7 on a non-empty folder and it will safely merge files across peers.

**Clock safety** — if system clocks drift by more than 5 seconds, a warning is printed. Sync continues.

**Security** — path traversal (`..`) in any filename is rejected outright.

## Protocol

### UDP Discovery — port 7731

Wire format per packet:

```
[4B magic][1B kind][8B utcTime][2B tcpPort][1B nameLen][N bytes name]
```

| Message | Behaviour |
|---------|-----------|
| `smkAnnounce` | Broadcast every ~5 s |
| `smkAnnounceAck` | Unicast reply when a new peer is spotted |
| `smkGoodbye` | Sent on clean shutdown |

Peers that go silent for 15 s are considered gone.

### TCP Transfer — port 7732

| Command | Response |
|---------|----------|
| `REQUEST_FILE_LIST` | `[4B length][encoded manifest]` |
| `REQUEST_FILE(path)` | `[8B size][raw data]` streamed in 64 KB chunks |
| `NOTIFY_DELETE(path)` | *(no response)* |
| `NOTIFY_CHANGES` | *(no response — triggers peer to request diff)* |

## Technical Details

| Item | Detail |
|------|--------|
| Language | Object Pascal (Delphi) |
| Output | Single native Win32 executable |
| Framework | [mORMot2](https://github.com/synopse/mORMot2) — UDP, TCP, SHA-256 |
| File watching | `ReadDirectoryChangesW` (Windows native) |
| Hashing | SHA-256 per file for conflict resolution |
| Discovery | UDP broadcast, no multicast, no mDNS |
| GUI | None — pure console |

## Building from Source

The repository contains two source variants. Both implement identical sync logic, protocol, and algorithms — the differences are purely syntactic.

| | `source/` (Modern) | `source_D7/` (Compatible) |
|---|---|---|
| **Compiler** | Delphi 12/13 | Delphi 7 — 2024 (also compiles with 12/13) |
| **EXE size** | ~1 MB | ~300 KB |
| **Variables** | Inline declarations (`var X := ...`) | Traditional `var` section |
| **Closures** | Anonymous methods (`reference to procedure`) | Helper classes with method pointers |
| **Records** | Methods on records (`Engine.SyncWithPeer`) | Standalone procedures (`SyncWithPeer(Engine, ...)`) |
| **Arrays** | `Arr := Arr + [item]`, `Delete(Arr, I, 1)` | Manual `SetLength` + shift loops |
| **Strings** | TStringHelper (`.ToLower`, `.Replace`) | Classic functions (`StringReplace`, `Trim`) |
| **Unicode filenames** | Full support (UnicodeString + `W` APIs) | Limited to current Windows ANSI codepage |

Both versions require [mORMot2](https://github.com/synopse/mORMot2) checked out alongside this repo.

```bash
# Modern (Delphi 12/13) — from repo root
scripts\build.bat            # release (default)
scripts\build.bat debug      # debug

# Compatible (Delphi 7+) — from repo root
scripts\build_d7.bat         # release (default)
scripts\build_d7.bat debug   # debug
```

See `scripts\dcc32.bat` / `scripts\dcc32_d7.bat` for compiler paths and mORMot2 unit references.

## Credits

- Developed with [Claude Code](https://claude.ai/code) — Anthropic's AI coding agent
- Networking and cryptography powered by [mORMot2](https://github.com/synopse/mORMot2)
- Author: [michal@glebowski.pl](mailto:michal@glebowski.pl)

---

<div align="center">
Always free &nbsp;·&nbsp; No installation &nbsp;·&nbsp; Windows only &nbsp;·&nbsp; ~300 KB / ~1 MB
</div>
