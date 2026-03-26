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
  Windows,
  Classes,
  SysUtils,
  Math;

type
  /// Thread to run sync with a specific peer (replaces anonymous threads)
  TSyncThread = class(TThread)
  private
    FApp: TShare7App;
    FPeer: TPeerInfo;
  protected
    procedure Execute; override;
  public
    constructor Create(AApp: TShare7App; const APeer: TPeerInfo);
  end;

constructor TSyncThread.Create(AApp: TShare7App; const APeer: TPeerInfo);
begin
  FApp := AApp;
  FPeer := APeer;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TSyncThread.Execute;
begin
  FApp.DoSyncWithPeer(FPeer);
end;

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
  InitConfig(FConfig);
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

  ConsoleWrite('', ccLightGray);
  ConsoleWrite(FormatUtf8(SCaptionTerminal, [FConfig.Name]), ccLightGreen);
  ConsoleWrite(FormatUtf8(SCaptionFolder, [RawUtf8(FConfig.Folder)]), ccLightGray);
  ConsoleWrite(FormatUtf8(SCaptionListening,
    [FConfig.UdpPort, FConfig.TcpPort]), ccLightGray);
  ConsoleWrite('', ccLightGray);
end;

procedure TShare7App.OnPeerDiscovered(const APeer: TPeerInfo);
var
  Drift: Integer;
begin
  // Check clock drift
  Drift := Round(Abs(APeer.UtcTime - NowUtc) * SecsPerDay);
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

  // Launch sync in background thread
  TSyncThread.Create(Self, APeer);
end;

procedure TShare7App.OnPeerLost(const APeer: TPeerInfo);
begin
  ConsoleWrite(FormatUtf8('[%] ' + SCaptionPeerGone,
    [TimeStampStr, APeer.Name]), ccLightRed);

  if FConfig.Sound then
    MessageBeep(MB_ICONHAND);
end;

procedure TShare7App.DoSyncWithPeer(const APeer: TPeerInfo);
var
  Stats: TSyncStats;
begin
  ConsoleWrite(FormatUtf8('[%] ' + SCaptionSyncing,
    [TimeStampStr, APeer.Name]), ccLightGray);

  Stats := SyncWithPeer(FSyncEngine, APeer.IP, APeer.TcpPort, APeer.Name);

  if (Stats.Received > 0) or (Stats.Sent > 0) then
    ConsoleWrite(FormatUtf8('[%] ' + SCaptionSyncComplete,
      [TimeStampStr, Stats.Received, Stats.Sent]), ccLightGray)
  else
    ConsoleWrite(FormatUtf8('[%] ' + SCaptionSyncUpToDate,
      [TimeStampStr]), ccDarkGray);
end;

procedure TShare7App.OnFileChange(AAction: TFileAction; const ARelPath: RawUtf8);
var
  Peers: TPeerInfoDynArray;
  Tick: QWord;
begin
  Peers := FDiscovery.GetPeerList;

  case AAction of
    faCreated, faModified:
      begin
        // Coalesce rapid notifications (2s cooldown)
        Tick := GetTickCount64;
        if (Tick - FLastNotifyTick) < 2000 then
          Exit;
        FLastNotifyTick := Tick;

        ConsoleWrite(FormatUtf8('[%] ' + SCaptionFileChanged,
          [TimeStampStr, ARelPath]), ccYellow);
        // Rescan to update manifest
        RescanAndUpdateManifest;
        // Notify peers to pull
        NotifyPeersOfChange(Peers);
      end;
    faDeleted:
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
        NotifyPeersOfDelete(ARelPath, Peers);
      end;
  end;
end;

procedure TShare7App.OnDeleteNotify(const ARelPath: RawUtf8);
begin
  HandleRemoteDelete(FSyncEngine, ARelPath);
end;

procedure TShare7App.OnChangesNotify(const APeerIP: RawUtf8; ATcpPort: Word);
var
  Tick: QWord;
  Peers: TPeerInfoDynArray;
  I: Integer;
begin
  // Cooldown: don't re-sync within 3s of last sync
  Tick := GetTickCount64;
  if (Tick - FLastSyncTick) < 3000 then
    Exit;
  FLastSyncTick := Tick;

  Peers := FDiscovery.GetPeerList;
  for I := 0 to High(Peers) do
    if Peers[I].IP = APeerIP then
    begin
      TSyncThread.Create(Self, Peers[I]);
      Break;
    end;
end;

procedure TShare7App.RescanAndUpdateManifest;
var
  NewEntries: TFileEntries;
begin
  ScanDirectory(FConfig.Folder, NewEntries);
  FEntriesLock.Lock;
  try
    FEntries := NewEntries;
  finally
    FEntriesLock.UnLock;
  end;
end;

procedure TShare7App.PrintPeerStatus;
var
  Count: Integer;
  Peers: TPeerInfoDynArray;
  Names: string;
  I: Integer;
begin
  if FDiscovery = nil then
    Exit;
  Count := FDiscovery.PeerCount;
  if Count = FLastPeerCount then
    Exit;
  FLastPeerCount := Count;
  if Count = 0 then
    ConsoleWrite(FormatUtf8('[%] ' + SCaptionNoPeers,
      [TimeStampStr]), ccDarkGray)
  else
  begin
    Peers := FDiscovery.GetPeerList;
    Names := '';
    for I := 0 to High(Peers) do
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
var
  NowTick: QWord;
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

  ConsoleWrite(FormatUtf8('[%] ' + SCaptionReady,
    [TimeStampStr]), ccLightGray);
  ConsoleWrite('', ccLightGray);

  // Main loop - check peer status every 5s
  while FRunning do
  begin
    Sleep(100);
    NowTick := GetTickCount64;
    if (NowTick - FLastStatusTick) >= 5000 then
    begin
      FLastStatusTick := NowTick;
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
