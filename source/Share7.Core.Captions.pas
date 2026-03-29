unit Share7.Core.Captions;

interface

uses
  mormot.core.base;

{$DEFINE USE_GLYPHS}  // Comment out this line for plain text captions

const
  {$IFDEF USE_GLYPHS}

  // Glyph constants (UnicodeString -> auto-converted to UTF-8 by StringToUtf8)
  SGlyphTerminal       = #$25C6;  // ◆
  SGlyphFolder         = #$25B8;  // ▸
  SGlyphListening      = #$2301;  // ⌁
  SGlyphPeerOnline     = #$25CF;  // ●
  SGlyphPeerOffline    = #$25CB;  // ○
  SGlyphSync           = #$21C4;  // ⇄
  SGlyphSyncDone       = #$2713;  // ✓
  SGlyphFileChanged    = #$25B3;  // △
  SGlyphFileDeleted    = #$2715;  // ✕
  SGlyphFileReceived   = #$2193;  // ↓
  SGlyphScanning       = #$2026;  // …
  SGlyphFoundFiles     = #$25AA;  // ▪
  SGlyphReady          = #$25B6;  // ▶
  SGlyphShuttingDown   = #$25A0;  // ■
  SGlyphWarning        = #$26A0;  // ⚠

  {$ENDIF}

var
  // Banner
  SCaptionTerminal:  RawUtf8;
  SCaptionFolder:    RawUtf8;
  SCaptionListening: RawUtf8;

  // Peers
  SCaptionPeerDiscovered: RawUtf8;
  SCaptionPeerGone:       RawUtf8;
  SCaptionPeersOnline:    RawUtf8;
  SCaptionNoPeers:        RawUtf8;

  // Sync
  SCaptionSyncing:      RawUtf8;
  SCaptionSyncComplete: RawUtf8;
  SCaptionSyncUpToDate: RawUtf8;

  // Files
  SCaptionFileChanged:       RawUtf8;
  SCaptionFileDeleted:       RawUtf8;
  SCaptionFileReceived:      RawUtf8;
  SCaptionFileProgress:      RawUtf8;
  SCaptionFileRemoteDeleted: RawUtf8;

  // Startup / Shutdown
  SCaptionScanning:     RawUtf8;
  SCaptionFoundFiles:   RawUtf8;
  SCaptionReady:        RawUtf8;
  SCaptionShuttingDown: RawUtf8;

  // Clipboard
  SCaptionClipboardSent:     RawUtf8;
  SCaptionClipboardReceived: RawUtf8;

  // Errors
  SCaptionDenied: RawUtf8;
  SCaptionFatal:  RawUtf8;

implementation

uses
  mormot.core.unicode;

procedure InitCaptions;
begin
  {$IFDEF USE_GLYPHS}
  SCaptionTerminal   := StringToUtf8(SGlyphTerminal + ' %');
  SCaptionFolder     := StringToUtf8(SGlyphFolder + ' %');
  SCaptionListening  := StringToUtf8(SGlyphListening + ' UDP :%, TCP :%');

  SCaptionPeerDiscovered := StringToUtf8(SGlyphPeerOnline + ' % (%)');
  SCaptionPeerGone       := StringToUtf8(SGlyphPeerOffline + ' %');
  SCaptionPeersOnline    := StringToUtf8(SGlyphPeerOnline + ' % online: %');
  SCaptionNoPeers        := StringToUtf8(SGlyphPeerOffline + ' Waiting for peers...');

  SCaptionSyncing      := StringToUtf8(SGlyphSync + ' %...');
  SCaptionSyncComplete := StringToUtf8(SGlyphSyncDone + ' % received, % sent');
  SCaptionSyncUpToDate := StringToUtf8(SGlyphSyncDone + ' Up to date');

  SCaptionFileChanged       := StringToUtf8(SGlyphFileChanged + ' %');
  SCaptionFileDeleted       := StringToUtf8(SGlyphFileDeleted + ' %');
  SCaptionFileReceived      := StringToUtf8('  ' + SGlyphFileReceived + ' % (%)');
  SCaptionFileProgress      := StringToUtf8('  ' + SGlyphFileReceived + ' % [%] %%');
  SCaptionFileRemoteDeleted := StringToUtf8('  ' + SGlyphFileDeleted + ' %');

  SCaptionScanning     := StringToUtf8(SGlyphScanning + ' Scanning...');
  SCaptionFoundFiles   := StringToUtf8(SGlyphFoundFiles + ' % files');
  SCaptionReady        := StringToUtf8(SGlyphReady + ' Ready');
  SCaptionShuttingDown := StringToUtf8(SGlyphShuttingDown + ' Stopping...');

  SCaptionClipboardSent     := StringToUtf8(SGlyphSync + ' Clipboard sent (% bytes)');
  SCaptionClipboardReceived := StringToUtf8(SGlyphSync + ' Clipboard received (% bytes)');

  SCaptionDenied := StringToUtf8(SGlyphWarning + ' % - clock drift %s exceeds %s limit');
  SCaptionFatal  := StringToUtf8(SGlyphFileDeleted + ' %');
  {$ELSE}
  SCaptionTerminal   := 'Terminal: %';
  SCaptionFolder     := 'Folder:   %';
  SCaptionListening  := 'Listening on UDP :%, TCP :%';

  SCaptionPeerDiscovered := 'Peer discovered: % (%)';
  SCaptionPeerGone       := 'Peer gone: %';
  SCaptionPeersOnline    := '% peer(s) online: %';
  SCaptionNoPeers        := 'No peers online - waiting for terminals...';

  SCaptionSyncing      := 'Syncing with %...';
  SCaptionSyncComplete := 'Sync complete: % received, % sent';
  SCaptionSyncUpToDate := 'Sync complete: up to date';

  SCaptionFileChanged       := 'File changed: %';
  SCaptionFileDeleted       := 'File deleted: %';
  SCaptionFileReceived      := '  <- % (%)';
  SCaptionFileProgress      := '  <- % [%] %%';
  SCaptionFileRemoteDeleted := '  [deleted] %';

  SCaptionScanning     := 'Scanning folder...';
  SCaptionFoundFiles   := 'Found % files';
  SCaptionReady        := 'Ready. Press Ctrl+C to stop.';
  SCaptionShuttingDown := 'Shutting down...';

  SCaptionClipboardSent     := 'Clipboard sent (% bytes)';
  SCaptionClipboardReceived := 'Clipboard received (% bytes)';

  SCaptionDenied := 'DENIED sync with % - clock drift %s exceeds %s limit';
  SCaptionFatal  := 'FATAL: %';
  {$ENDIF}
end;

initialization
  InitCaptions;

end.
