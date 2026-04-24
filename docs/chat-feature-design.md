# Share7 — Broadcast Chat Feature Design

Status: **Deferred** (March 2026)

## Overview

Add ability to type text messages on the keyboard that get broadcast to all connected peers via UDP, displayed on their consoles in real time.

## Design Decisions

- **Transport: UDP broadcast** — reuses existing discovery infrastructure. Chat messages are short (<500 bytes), lost messages acceptable for casual chat.
- **Console input: `PeekConsoleInput`/`ReadConsoleInput` Win32 API** in the main loop — no new thread needed.
- **Console mode**: disable `ENABLE_LINE_INPUT` and `ENABLE_ECHO_INPUT` via `SetConsoleMode`. Keep `ENABLE_PROCESSED_INPUT` for Ctrl+C.
- **Visual glitches**: accepted — background thread output may overlap typing. Pragmatic for a console app.

## Wire Format

Extends existing UDP format with new kind `smkChat = 4`:

```
[4B magic 'S7MG'][1B kind=4][8B utcTime][2B tcpPort][1B nameLen][NB name][2B msgLen][MB message]
```

Backward compatible — old versions reject unknown message kinds.

## Changes Required (5 files, both `source/` and `source_D7/`)

### 1. `Share7.Core.Types.pas`
- Add `smkChat = 4` to `TShare7MessageKind`
- Add `CHAT_MAX_LEN = 500` constant

### 2. `Share7.Net.Protocol.pas`
- Add `EncodeUdpChatMessage(ATcpPort, AName, AMessage): RawByteString`
- Add `DecodeUdpChatMessage(AData, ALen, out AMessage): Boolean`
- Fix kind-byte range validation to include `smkChat` (upper bound from `smkGoodbye` to `smkChat`)

### 3. `Share7.Net.Discovery.pas`
- Add `TOnChatMessage = procedure(const ASenderName, AMessage: RawUtf8) of object`
- Add `FOnChatMessage` field + property
- Add `SendChat(const AMessage: RawUtf8)` method — encodes and broadcasts
- Handle `smkChat` in `HandleMessage` — decode and fire callback
- Self-messages already filtered by existing name check

### 4. `Share7.Core.Captions.pas`
- Add `SCaptionChat` caption for chat display formatting

### 5. `Share7.Core.App.pas` (largest change)
- New fields: `FInputBuffer: string`, `FConsoleInput: THandle`
- `SetConsoleMode(FConsoleInput, ENABLE_PROCESSED_INPUT)` at startup
- `PollKeyboard` — non-blocking read via `PeekConsoleInput`/`ReadConsoleInput`, accumulates chars, Enter sends, Backspace deletes
- `SendChatMessage` — clears input line, displays locally (ccLightCyan), calls `FDiscovery.SendChat`
- `OnChatReceived` callback — clears input line, displays message, redraws input
- `RedrawInputLine` — `#13 + '> ' + FInputBuffer`
- Main loop: call `PollKeyboard`, reduce sleep to 50ms
- Wire up `FDiscovery.OnChatMessage := OnChatReceived`

### D7 variant differences
- No inline vars — use traditional `var` section
- `AsciiChar` instead of `UnicodeChar` in `KEY_EVENT_RECORD` (limits to ASCII chat in D7)
- Standalone procedures instead of method-on-record patterns

## Key Technical Notes

- **Thread safety of `FSock.SendTo`**: UDP `sendto` on Windows is thread-safe for distinct datagrams — no additional locking needed.
- **Console mode is critical**: Without disabling `ENABLE_LINE_INPUT`, `PeekConsoleInput` won't see individual key events until Enter is pressed, defeating the purpose.
- **Ctrl+C**: Still works with `ENABLE_PROCESSED_INPUT` flag set.
- **Self-echo**: Discovery thread already filters messages where `PeerName = FName`, so local display is handled in `SendChatMessage` only.

## Verification Plan

1. Build both variants: `scripts\build.bat` and `scripts\build_d7.bat`
2. Run two instances on same network (or same machine with two consoles)
3. Type a message + Enter on one — verify it appears on the other
4. Verify file sync still works while chatting
5. Verify Ctrl+C still gracefully shuts down
6. Verify old instances ignore chat packets (backward compat)
