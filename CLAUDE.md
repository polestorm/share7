# Share7 - CLAUDE.md

## Overview

Share7 is a peer-to-peer file synchronization tool for local WiFi networks. Drop `share7.exe` into a folder, run it - no configuration needed. It discovers other Share7 instances via UDP broadcast, syncs files via TCP, and watches the folder for real-time changes.

## Architecture

```
Share7.dpr                    -- Console entry point
Share7.Core.Types.pas         -- Shared types, constants, helpers
Share7.Core.Config.pas        -- CLI parsing, terminal name resolution
Share7.Core.App.pas           -- Main loop, orchestration, Ctrl+C handling
Share7.Net.Protocol.pas       -- Binary wire protocol encode/decode
Share7.Net.Discovery.pas      -- UDP broadcast peer discovery (TUdpServerThread)
Share7.Net.Transfer.pas       -- TCP file transfer (server + client via TCrtSocket)
Share7.Fs.Scanner.pas         -- Recursive directory scan, file manifest, SHA-256
Share7.Fs.Watcher.pas         -- ReadDirectoryChangesW file watcher
Share7.Sync.Engine.pas        -- Sync logic: merge, conflict resolution, deletion
```

## Dependencies

**mORMot2 only** - no VCL, no OExport, no OXml.

| Component | mORMot2 Unit | Usage |
|-----------|-------------|-------|
| UDP server | `mormot.net.server` | `TUdpServerThread` for discovery |
| Sockets | `mormot.net.sock` | `TCrtSocket`, `TNetSocket`, `TNetAddr` |
| Hashing | `mormot.crypt.core` | `Sha256()` for file comparison |
| Console | `mormot.core.os` | `ConsoleWrite()`, `Executable.Command` |
| Base types | `mormot.core.base` | `RawUtf8`, `TLightLock` |

## Build

```powershell
# Main build
powershell -Command "Set-Location 'source'; & '..\scripts\dcc32.bat' -B Share7.dpr"

# Or use the build script
.\scripts\build.bat release

# Tests
powershell -Command "Set-Location 'tests\source'; & '..\build.bat'"

# Run tests
.\tests\program\Share7.Tests.exe
```

## Ports

- UDP 7731: Peer discovery (broadcast)
- TCP 7732: File transfer

## Protocol

### UDP Discovery
Wire format: `[4B magic][1B kind][8B utcTime][2B tcpPort][1B nameLen][NB name]`
- `smkAnnounce` broadcast every ~5s
- `smkAnnounceAck` reply to new peers
- `smkGoodbye` on shutdown
- Peers removed after 30s silence

### TCP Transfer
Commands (1 byte):
1. `REQUEST_FILE_LIST` -> `[4B dataLen][encoded file list]`
2. `REQUEST_FILE(path)` -> `[8B size][file data]` (streamed in 64KB chunks)
3. `NOTIFY_DELETE(path)` -> no response
4. `NOTIFY_CHANGES` -> no response (triggers peer to sync)

## Sync Rules

- **Initial sync**: pull files newer on peer (by UTC timestamp)
- **Same time, different size**: compare SHA-256
- **Deletions**: only via explicit NOTIFY_DELETE (missing file = "not yet synced")
- **Clock drift > 5s**: warning printed, sync continues
- **Path traversal**: `..` in paths rejected

## Coding Style

- Modern Delphi: inline variable declarations throughout
- `TPeerInfoDynArray` instead of `TStringList` where applicable
- DRY: shared helpers in `Share7.Core.Types` (FormatFileSize, TimeStampStr, NowUtc)
- Zero hints/warnings policy enforced
