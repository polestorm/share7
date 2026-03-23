unit Share7.Core.App;

interface

uses
  mormot.core.base,
  mormot.core.os,
  Share7.Core.Types,
  Share7.Core.Config,
  Share7.Net.Discovery,
  Share7.Net.Transfer,
  Share7.Fs.Scanner,
  Share7.Fs.Watcher,
  Share7.Sync.Engine;

type
  TShare7App = class
  private
    FConfig: TShare7Config;
    FEntries: TFileEntries;
    FEntriesLock: TLightLock;
    FDiscovery: TDiscoveryThread;
    FTcpServer: TTcpServerThread;
    FWatcher: TFileWatcher;
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
  ConsoleWrite('Share7 v' + SHARE7_VERSION + ' - freeware, (c)2026 michal@glebowski.pl', ccWhite);
  ConsoleWrite('Peer-to-peer file sync for local networks (same subnet).', ccDarkGray);
  ConsoleWrite('Run share7.exe in a folder on each computer - files sync automatically.', ccDarkGray);
  //ConsoleWrite('Use --folder <path> to sync a different folder than the current one.', ccDarkGray);
  //ConsoleWrite('All computers must be on the same network subnet (no NAT/VPN).', ccDarkGray);
  ConsoleWrite('Uses Synopse mORMot 2 framework - https://synopse.info (MPL 1.1)', ccDarkGray);
  ConsoleWrite('', ccLightGray);
  ConsoleWrite('Terminal: ' + FConfig.Name, ccLightGreen);
  ConsoleWrite(RawUtf8('Folder:   ' + FConfig.Folder), ccLightGray);
  ConsoleWrite(RawUtf8('Listening on UDP :' + IntToStr(FConfig.UdpPort) +
    ', TCP :' + IntToStr(FConfig.TcpPort)), ccLightGray);
  ConsoleWrite('', ccLightGray);
end;

procedure TShare7App.OnPeerDiscovered(const APeer: TPeerInfo);
begin
  // Check clock drift
  var Drift := Round(Abs(APeer.UtcTime - NowUtc) * SecsPerDay);
  if Drift > CLOCK_MAX_DRIFT_SEC then
  begin
    ConsoleWrite(RawUtf8('[' + string(TimeStampStr) +
      '] DENIED sync with ' + string(APeer.Name) +
      ' - clock drift ' + IntToStr(Drift) + 's exceeds ' +
      IntToStr(CLOCK_MAX_DRIFT_SEC) + 's limit'), ccLightRed);
    Exit;
  end;

  ConsoleWrite(RawUtf8('[' + string(TimeStampStr) + '] Peer discovered: ' +
    string(APeer.Name) + ' (' + string(APeer.IP) + ')'), ccLightGreen);

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
  ConsoleWrite(RawUtf8('[' + string(TimeStampStr) + '] Peer gone: ' +
    string(APeer.Name)), ccLightRed);

  if FConfig.Sound then
    MessageBeep(MB_ICONHAND);
end;

procedure TShare7App.DoSyncWithPeer(const APeer: TPeerInfo);
begin
  ConsoleWrite(RawUtf8('[' + string(TimeStampStr) + '] Syncing with ' +
    string(APeer.Name) + '...'), ccLightGray);

  var Stats := FSyncEngine.SyncWithPeer(APeer.IP, APeer.TcpPort, APeer.Name);

  if (Stats.Received > 0) or (Stats.Sent > 0) then
    ConsoleWrite(RawUtf8('[' + string(TimeStampStr) + '] Sync complete: ' +
      IntToStr(Stats.Received) + ' received, ' +
      IntToStr(Stats.Sent) + ' sent'), ccLightGray)
  else
    ConsoleWrite(RawUtf8('[' + string(TimeStampStr) + '] Sync complete: up to date'), ccDarkGray);
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

        ConsoleWrite(RawUtf8('[' + string(TimeStampStr) + '] File changed: ' +
          string(ARelPath)), ccYellow);
        // Rescan to update manifest
        RescanAndUpdateManifest;
        // Notify peers to pull
        FSyncEngine.NotifyPeersOfChange(Peers);
      end;
    TFileAction.faDeleted:
      begin
        ConsoleWrite(RawUtf8('[' + string(TimeStampStr) + '] File deleted: ' +
          string(ARelPath)), ccLightRed);
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
    ConsoleWrite(RawUtf8('[' + string(TimeStampStr) +
      '] No peers online - waiting for terminals...'), ccDarkGray)
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
    ConsoleWrite(RawUtf8('[' + string(TimeStampStr) + '] ' +
      IntToStr(Count) + ' peer(s) online: ' + Names), ccLightGreen);
  end;
end;

procedure TShare7App.Run;
begin
  GApp := Self;
  FRunning := True;

  PrintBanner;

  // Initial scan
  ConsoleWrite(RawUtf8('[' + string(TimeStampStr) + '] Scanning folder...'), ccDarkGray);
  ScanDirectory(FConfig.Folder, FEntries);
  ConsoleWrite(RawUtf8('[' + string(TimeStampStr) + '] Found ' +
    IntToStr(Length(FEntries)) + ' files'), ccDarkGray);

  // Start TCP server
  FTcpServer := TTcpServerThread.Create(FConfig.TcpPort, FConfig.Folder,
    @FEntries, @FEntriesLock);
  FTcpServer.OnDeleteNotify := OnDeleteNotify;
  FTcpServer.OnChangesNotify := OnChangesNotify;

  // Start UDP discovery
  FDiscovery := TDiscoveryThread.Create(FConfig.Name, FConfig.UdpPort, FConfig.TcpPort);
  FDiscovery.OnPeerDiscovered := OnPeerDiscovered;
  FDiscovery.OnPeerLost := OnPeerLost;

  // Start file watcher
  FWatcher := TFileWatcher.Create(FConfig.Folder);
  FWatcher.OnChange := OnFileChange;
  FSyncEngine.Watcher := FWatcher;

  // Install Ctrl+C handler
  SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);

  ConsoleWrite(RawUtf8('[' + string(TimeStampStr) + '] Ready. Press Ctrl+C to stop.'), ccLightGray);
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
  ConsoleWrite(RawUtf8('[' + string(TimeStampStr) + '] Shutting down...'), ccYellow);
end;

procedure TShare7App.Stop;
begin
  FRunning := False;

  // Send goodbye before tearing down the socket
  if FDiscovery <> nil then
    FDiscovery.SendGoodbye;

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
