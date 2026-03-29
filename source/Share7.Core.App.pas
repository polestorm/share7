unit Share7.Core.App;

interface

uses
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  Share7.Core.Types,
  Share7.Core.Config,
  Share7.Core.Captions,
  Share7.Net.Discovery,
  Share7.Net.Transfer,
  Share7.Fs.Scanner,
  Share7.Fs.Watcher,
  Share7.Sync.Engine,
  Share7.Clipboard;

type
  TShare7App = class
  private
    FConfig: TShare7Config;
    FEntries: TFileEntries;
    FEntriesLock: TLightLock;
    FDiscovery: TDiscoveryThread;
    FTcpServer: TTcpServerThread;
    FWatcher: TFileWatcher;
    FClipboardWatcher: TClipboardWatcher;
    FSyncEngine: TSyncEngine;
    FRunning: Boolean;
    FLastPeerCount: Integer;
    FLastStatusTick: QWord;
    FLastSyncTick: QWord;       // cooldown: last sync timestamp
    FLastNotifyTick: QWord;     // cooldown: last notify-peers timestamp
    procedure PrintBanner;
    procedure PrintPeerStatus;
    procedure OnPeerDiscovered(const APeer: TPeerInfo);
    procedure OnPeerLost(const APeer: TPeerInfo);
    procedure OnFileChange(AAction: TFileAction; const ARelPath: RawUtf8);
    procedure OnDeleteNotify(const ARelPath: RawUtf8);
    procedure OnChangesNotify(const APeerIP: RawUtf8; ATcpPort: Word);
    procedure OnLocalClipboardChanged(const AText: RawUtf8);
    procedure OnRemoteClipboardReceived(const AText: RawUtf8);
    procedure DoSyncWithPeer(const APeer: TPeerInfo);
    procedure RescanAndUpdateManifest;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
    procedure Stop;
  end;

implementation

uses
  Winapi.Windows,
  System.Classes,
  System.SysUtils,
  System.Math;

var
  GApp: TShare7App;

function ConsoleCtrlHandler(ACtrlType: DWORD): BOOL; stdcall;
begin
  if GApp <> nil then
    GApp.Stop;
  Result := True;
end;

{ TShare7App }

constructor TShare7App.Create;
begin
  inherited;
  FConfig.Init;
  FRunning := False;

  FLastPeerCount := -1;
  FLastStatusTick := 0;
  FSyncEngine.RootDir := FConfig.Folder;
  FSyncEngine.Entries := @FEntries;
  FSyncEngine.EntriesLock := @FEntriesLock;
  FSyncEngine.Watcher := nil; // set after watcher is created
end;

destructor TShare7App.Destroy;
begin
  Stop;
  inherited;
end;

procedure TShare7App.PrintBanner;
begin
  ConsoleWrite('Share7 v' + SHARE7_VERSION + ' (c)2026 michal@glebowski.pl', ccWhite);
  ConsoleWrite('Peer-to-peer file sync for local networks (same subnet).', ccDarkGray);
  ConsoleWrite('Run share7.exe in a folder on each computer - files sync automatically.', ccDarkGray);
  //ConsoleWrite('Use --folder <path> to sync a different folder than the current one.', ccDarkGray);
  //ConsoleWrite('All computers must be on the same network subnet (no NAT/VPN).', ccDarkGray);

  ConsoleWrite('', ccLightGray);
  ConsoleWrite(FormatUtf8(SCaptionTerminal, [FConfig.Name]), ccLightGreen);
  ConsoleWrite(FormatUtf8(SCaptionFolder, [RawUtf8(FConfig.Folder)]), ccLightGray);
  ConsoleWrite(FormatUtf8(SCaptionListening,
    [FConfig.UdpPort, FConfig.TcpPort]), ccLightGray);
  ConsoleWrite('', ccLightGray);
end;

procedure TShare7App.OnPeerDiscovered(const APeer: TPeerInfo);
begin
  // Check clock drift
  var Drift := Round(Abs(APeer.UtcTime - NowUtc) * SecsPerDay);
  if Drift > CLOCK_MAX_DRIFT_SEC then
  begin
    ConsoleWrite(FormatUtf8('[%] ' + SCaptionDenied,
      [TimeStampStr, APeer.Name, IntToStr(Drift) + 's',
      IntToStr(CLOCK_MAX_DRIFT_SEC) + 's']), ccLightRed);
    Exit;
  end;

  ConsoleWrite(FormatUtf8('[%] ' + SCaptionPeerDiscovered,
    [TimeStampStr, APeer.Name, APeer.IP]), ccLightGreen);

  if FConfig.Sound then
    MessageBeep(MB_OK);

  // Capture peer by value before passing to anonymous thread
  var PeerCopy := APeer;
  TThread.CreateAnonymousThread(
    procedure
    begin
      DoSyncWithPeer(PeerCopy);
    end
  ).Start;
end;

procedure TShare7App.OnPeerLost(const APeer: TPeerInfo);
begin
  ConsoleWrite(FormatUtf8('[%] ' + SCaptionPeerGone,
    [TimeStampStr, APeer.Name]), ccLightRed);

  if FConfig.Sound then
    MessageBeep(MB_ICONHAND);
end;

procedure TShare7App.DoSyncWithPeer(const APeer: TPeerInfo);
begin
  ConsoleWrite(FormatUtf8('[%] ' + SCaptionSyncing,
    [TimeStampStr, APeer.Name]), ccLightGray);

  var Stats := FSyncEngine.SyncWithPeer(APeer.IP, APeer.TcpPort, APeer.Name);

  if (Stats.Received > 0) or (Stats.Sent > 0) then
    ConsoleWrite(FormatUtf8('[%] ' + SCaptionSyncComplete,
      [TimeStampStr, Stats.Received, Stats.Sent]), ccLightGray)
  else
    ConsoleWrite(FormatUtf8('[%] ' + SCaptionSyncUpToDate,
      [TimeStampStr]), ccDarkGray);
end;

procedure TShare7App.OnFileChange(AAction: TFileAction; const ARelPath: RawUtf8);
begin
  var Peers := FDiscovery.GetPeerList;

  case AAction of
    TFileAction.faCreated, TFileAction.faModified:
      begin
        // Coalesce rapid notifications (2s cooldown)
        var Tick := GetTickCount64;
        if (Tick - FLastNotifyTick) < 2000 then
          Exit;
        FLastNotifyTick := Tick;

        ConsoleWrite(FormatUtf8('[%] ' + SCaptionFileChanged,
          [TimeStampStr, ARelPath]), ccYellow);
        // Rescan to update manifest
        RescanAndUpdateManifest;
        // Notify peers to pull
        FSyncEngine.NotifyPeersOfChange(Peers);
      end;
    TFileAction.faDeleted:
      begin
        ConsoleWrite(FormatUtf8('[%] ' + SCaptionFileDeleted,
          [TimeStampStr, ARelPath]), ccLightRed);
        // Remove from manifest
        FEntriesLock.Lock;
        try
          RemoveEntry(FEntries, ARelPath);
        finally
          FEntriesLock.UnLock;
        end;
        // Notify peers to delete
        FSyncEngine.NotifyPeersOfDelete(ARelPath, Peers);
      end;
  end;
end;

procedure TShare7App.OnDeleteNotify(const ARelPath: RawUtf8);
begin
  FSyncEngine.HandleRemoteDelete(ARelPath);
end;

procedure TShare7App.OnChangesNotify(const APeerIP: RawUtf8; ATcpPort: Word);
begin
  // Cooldown: don't re-sync within 3s of last sync
  var Tick := GetTickCount64;
  if (Tick - FLastSyncTick) < 3000 then
    Exit;
  FLastSyncTick := Tick;

  var Peers := FDiscovery.GetPeerList;
  for var I := 0 to High(Peers) do
    if Peers[I].IP = APeerIP then
    begin
      var PeerCopy := Peers[I];
      TThread.CreateAnonymousThread(
        procedure
        begin
          DoSyncWithPeer(PeerCopy);
        end
      ).Start;
      Break;
    end;
end;

procedure TShare7App.OnLocalClipboardChanged(const AText: RawUtf8);
begin
  var Peers := FDiscovery.GetPeerList;
  for var I := 0 to High(Peers) do
    TTransferClient.SendClipboardNotify(Peers[I].IP, Peers[I].TcpPort, AText);
  ConsoleWrite(FormatUtf8('[%] ' + SCaptionClipboardSent,
    [TimeStampStr, Length(AText)]), ccDarkGray);
end;

procedure TShare7App.OnRemoteClipboardReceived(const AText: RawUtf8);
begin
  if FClipboardWatcher <> nil then
    FClipboardWatcher.SetReceivedHash(ClipboardHash(AText));
  WriteClipboardText(AText);
  ConsoleWrite(FormatUtf8('[%] ' + SCaptionClipboardReceived,
    [TimeStampStr, Length(AText)]), ccLightCyan);
  if FConfig.Sound then
    MessageBeep(MB_OK);
end;

procedure TShare7App.RescanAndUpdateManifest;
begin
  var NewEntries: TFileEntries;
  ScanDirectory(FConfig.Folder, NewEntries);
  FEntriesLock.Lock;
  try
    FEntries := NewEntries;
  finally
    FEntriesLock.UnLock;
  end;
end;

procedure TShare7App.PrintPeerStatus;
begin
  if FDiscovery = nil then
    Exit;
  var Count := FDiscovery.PeerCount;
  if Count = FLastPeerCount then
    Exit;
  FLastPeerCount := Count;
  if Count = 0 then
    ConsoleWrite(FormatUtf8('[%] ' + SCaptionNoPeers,
      [TimeStampStr]), ccDarkGray)
  else
  begin
    var Peers := FDiscovery.GetPeerList;
    var Names := '';
    for var I := 0 to High(Peers) do
    begin
      if I > 0 then
        Names := Names + ', ';
      Names := Names + string(Peers[I].Name);
    end;
    ConsoleWrite(FormatUtf8('[%] ' + SCaptionPeersOnline,
      [TimeStampStr, Count, RawUtf8(Names)]), ccLightGreen);
  end;
end;

procedure TShare7App.Run;
begin
  GApp := Self;
  FRunning := True;

  PrintBanner;

  // Initial scan
  ConsoleWrite(FormatUtf8('[%] ' + SCaptionScanning,
    [TimeStampStr]), ccDarkGray);
  ScanDirectory(FConfig.Folder, FEntries);
  ConsoleWrite(FormatUtf8('[%] ' + SCaptionFoundFiles,
    [TimeStampStr, Length(FEntries)]), ccDarkGray);

  // Start TCP server
  FTcpServer := TTcpServerThread.Create(FConfig.TcpPort, FConfig.Folder,
    @FEntries, @FEntriesLock);
  FTcpServer.OnDeleteNotify := OnDeleteNotify;
  FTcpServer.OnChangesNotify := OnChangesNotify;
  if FConfig.Clipboard then
    FTcpServer.OnClipboardNotify := OnRemoteClipboardReceived;

  // Start UDP discovery
  FDiscovery := TDiscoveryThread.Create(FConfig.Name, FConfig.UdpPort, FConfig.TcpPort);
  FDiscovery.OnPeerDiscovered := OnPeerDiscovered;
  FDiscovery.OnPeerLost := OnPeerLost;

  // Start file watcher
  FWatcher := TFileWatcher.Create(FConfig.Folder);
  FWatcher.OnChange := OnFileChange;
  FSyncEngine.Watcher := FWatcher;

  // Start clipboard watcher (if enabled)
  if FConfig.Clipboard then
  begin
    FClipboardWatcher := TClipboardWatcher.Create;
    FClipboardWatcher.OnChanged := OnLocalClipboardChanged;
  end;

  // Install Ctrl+C handler
  SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);

  ConsoleWrite(FormatUtf8('[%] ' + SCaptionReady,
    [TimeStampStr]), ccLightGray);
  ConsoleWrite('', ccLightGray);

  // Main loop - check peer status every 5s
  while FRunning do
  begin
    Sleep(100);
    var Now := GetTickCount64;
    if (Now - FLastStatusTick) >= 5000 then
    begin
      FLastStatusTick := Now;
      PrintPeerStatus;
    end;
  end;

  // Cleanup
  ConsoleWrite('', ccLightGray);
  ConsoleWrite(FormatUtf8('[%] ' + SCaptionShuttingDown,
    [TimeStampStr]), ccYellow);
end;

procedure TShare7App.Stop;
begin
  FRunning := False;

  // Send goodbye before tearing down the socket
  if FDiscovery <> nil then
    FDiscovery.SendGoodbye;

  if FClipboardWatcher <> nil then
  begin
    FClipboardWatcher.Terminate;
    FClipboardWatcher.WaitFor;
    FreeAndNil(FClipboardWatcher);
  end;

  if FWatcher <> nil then
  begin
    FWatcher.SignalStop;
    FWatcher.WaitFor;
    FreeAndNil(FWatcher);
  end;

  if FTcpServer <> nil then
  begin
    FTcpServer.Shutdown;
    FTcpServer.WaitFor;
    FreeAndNil(FTcpServer);
  end;

  if FDiscovery <> nil then
  begin
    FDiscovery.Terminate;
    FDiscovery.WaitFor;
    FreeAndNil(FDiscovery);
  end;
end;

end.
