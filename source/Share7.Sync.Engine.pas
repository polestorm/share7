unit Share7.Sync.Engine;

interface

uses
  mormot.core.base,
  mormot.core.os,
  Share7.Core.Types,
  Share7.Fs.Watcher;

type
  TSyncStats = record
    Received: Integer;
    Sent: Integer;
    Deleted: Integer;
    procedure Clear;
  end;

  /// Sync engine: merges file lists between local and remote peer,
  /// downloads newer files, handles deletions.
  TSyncEngine = record
    RootDir: string;
    Entries: ^TFileEntries;
    EntriesLock: ^TLightLock;
    Watcher: TFileWatcher;

    /// Perform initial sync with a peer: pull files newer on peer.
    function SyncWithPeer(const APeerIP: RawUtf8; APeerPort: Word;
      const APeerName: RawUtf8): TSyncStats;

    /// Handle a delete notification from a peer: delete local file.
    procedure HandleRemoteDelete(const ARelPath: RawUtf8);

    /// Handle a local file change: notify all peers to pull.
    procedure NotifyPeersOfChange(const APeers: TPeerInfoDynArray);

    /// Handle a local file deletion: notify all peers.
    procedure NotifyPeersOfDelete(const ARelPath: RawUtf8;
      const APeers: TPeerInfoDynArray);
  end;

implementation

uses
  System.SysUtils,
  mormot.core.datetime,
  Share7.Net.Transfer,
  Share7.Fs.Scanner;

const
  SecsPerDay = 86400;
  PROGRESS_BAR_WIDTH = 20;
  PROGRESS_MIN_SIZE = 256 * 1024; // show progress bar for files >= 256 KB

procedure WriteProgress(const ARelPath: RawUtf8; AReceived, ATotal: Int64);
begin
  if ATotal <= 0 then
    Exit;
  var Pct := (AReceived * 100) div ATotal;
  var Filled := (AReceived * PROGRESS_BAR_WIDTH) div ATotal;
  var Bar: RawUtf8;
  SetLength(Bar, PROGRESS_BAR_WIDTH);
  for var J := 1 to PROGRESS_BAR_WIDTH do
    if J <= Filled then
      Bar[J] := '#'
    else
      Bar[J] := '.';
  var Line := RawUtf8('  <- ' + string(ARelPath) + ' [' + string(Bar) + '] ' +
    IntToStr(Pct) + '%');
  // Pad with spaces to overwrite previous longer line
  while Length(Line) < 78 do
    Line := Line + ' ';
  ConsoleWriteRaw(#13 + Line, True);
end;

{ TSyncStats }

procedure TSyncStats.Clear;
begin
  Received := 0;
  Sent := 0;
  Deleted := 0;
end;

{ TSyncEngine }

function TSyncEngine.SyncWithPeer(const APeerIP: RawUtf8; APeerPort: Word;
  const APeerName: RawUtf8): TSyncStats;
begin
  Result.Clear;

  var RemoteEntries := TTransferClient.RequestFileList(APeerIP, APeerPort);
  if Length(RemoteEntries) = 0 then
    Exit;

  for var I := 0 to High(RemoteEntries) do
  begin
    var NeedDownload := False;

    EntriesLock^.Lock;
    try
      var LocalEntry := FindEntry(Entries^, RemoteEntries[I].RelPath);
      if LocalEntry = nil then
        NeedDownload := True
      else
      begin
        var TimeDiff := Round(Abs(RemoteEntries[I].ModifiedUtc - LocalEntry^.ModifiedUtc) * SecsPerDay);
        if TimeDiff > 1 then
        begin
          if RemoteEntries[I].ModifiedUtc > LocalEntry^.ModifiedUtc then
            NeedDownload := True;
        end
        else if (TimeDiff <= 1) and (RemoteEntries[I].Size <> LocalEntry^.Size) then
        begin
          var LocalPath := IncludeTrailingPathDelimiter(RootDir) +
            StringReplace(string(LocalEntry^.RelPath), '/', '\', [rfReplaceAll]);
          var LocalHash := HashFile(LocalPath);
          if (RemoteEntries[I].Sha256 = '') or (LocalHash <> RemoteEntries[I].Sha256) then
            NeedDownload := True;
        end;
      end;
    finally
      EntriesLock^.UnLock;
    end;

    if NeedDownload then
    begin
      var RelPath := RemoteEntries[I].RelPath;
      var DestPath := IncludeTrailingPathDelimiter(RootDir) +
        StringReplace(string(RelPath), '/', '\', [rfReplaceAll]);

      // Suppress watcher for this path to prevent feedback loop
      if Watcher <> nil then
        Watcher.SuppressPath(RelPath);
      try
        var ShowProgress := RemoteEntries[I].Size >= PROGRESS_MIN_SIZE;
        var ProgressCb: TTransferProgress := nil;
        if ShowProgress then
        begin
          var ProgressPath := RelPath; // capture for closure
          ProgressCb :=
            procedure(AReceived, ATotal: Int64)
            begin
              WriteProgress(ProgressPath, AReceived, ATotal);
            end;
        end;

        var Downloaded := TTransferClient.DownloadFile(APeerIP, APeerPort,
          RelPath, DestPath, ProgressCb);
        var Attempt := 1;
        while (not Downloaded) and (Attempt < FILE_RETRY_COUNT) do
        begin
          Inc(Attempt);
          Sleep(FILE_RETRY_DELAY_MS * Attempt);
          Downloaded := TTransferClient.DownloadFile(APeerIP, APeerPort,
            RelPath, DestPath, ProgressCb);
        end;

        if ShowProgress then
          ConsoleWriteRaw(#13); // move past progress line

        if Downloaded then
        begin
          // Preserve original modification timestamp to prevent sync loops
          FileSetDateFromUnixUtc(TFileName(DestPath),
            DateTimeToUnixTime(RemoteEntries[I].ModifiedUtc));

          Inc(Result.Received);
          ConsoleWrite(RawUtf8('  <- ' +
            string(RelPath) + ' (' +
            string(FormatFileSize(RemoteEntries[I].Size)) + ')'), ccLightCyan);

          EntriesLock^.Lock;
          try
            var Existing := FindEntry(Entries^, RelPath);
            if Existing <> nil then
            begin
              Existing^.Size := RemoteEntries[I].Size;
              Existing^.ModifiedUtc := RemoteEntries[I].ModifiedUtc;
              Existing^.Sha256 := RemoteEntries[I].Sha256;
            end
            else
            begin
              Entries^ := Entries^ + [RemoteEntries[I]];
            end;
          finally
            EntriesLock^.UnLock;
          end;
        end;
      finally
        // Delay unsuppress so watcher debounce window fully passes
        Sleep(WATCHER_DEBOUNCE_MS * 3);
        if Watcher <> nil then
          Watcher.UnsuppressPath(RelPath);
      end;
    end;
  end;
end;

procedure TSyncEngine.HandleRemoteDelete(const ARelPath: RawUtf8);
begin
  if Pos('..', string(ARelPath)) > 0 then
    Exit;

  var FullPath := IncludeTrailingPathDelimiter(RootDir) +
    StringReplace(string(ARelPath), '/', '\', [rfReplaceAll]);

  if FileExists(FullPath) then
  begin
    // Suppress watcher to prevent echoing the delete back
    if Watcher <> nil then
      Watcher.SuppressPath(ARelPath);
    try
      DeleteFile(FullPath);
      ConsoleWrite(RawUtf8('  [deleted] ' + string(ARelPath)), ccLightRed);

      EntriesLock^.Lock;
      try
        RemoveEntry(Entries^, ARelPath);
      finally
        EntriesLock^.UnLock;
      end;
    finally
      Sleep(WATCHER_DEBOUNCE_MS + 50);
      if Watcher <> nil then
        Watcher.UnsuppressPath(ARelPath);
    end;
  end;
end;

procedure TSyncEngine.NotifyPeersOfChange(const APeers: TPeerInfoDynArray);
begin
  for var I := 0 to High(APeers) do
    TTransferClient.SendChangesNotify(APeers[I].IP, APeers[I].TcpPort);
end;

procedure TSyncEngine.NotifyPeersOfDelete(const ARelPath: RawUtf8;
  const APeers: TPeerInfoDynArray);
begin
  for var I := 0 to High(APeers) do
    TTransferClient.SendDeleteNotify(APeers[I].IP, APeers[I].TcpPort, ARelPath);
end;

end.
