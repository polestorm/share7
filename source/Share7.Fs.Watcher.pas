unit Share7.Fs.Watcher;

interface

uses
  System.Classes,
  System.SysUtils,
  mormot.core.base,
  mormot.core.os,
  Share7.Core.Types;

type
  TFileChangeEvent = procedure(AAction: TFileAction; const ARelPath: RawUtf8) of object;

  /// Watches a directory for file changes using ReadDirectoryChangesW.
  /// Debounces events by WATCHER_DEBOUNCE_MS before forwarding.
  /// Supports suppression of specific paths to avoid feedback loops
  /// when we download files from peers.
  TFileWatcher = class(TThread)
  private
    FRootDir: string;
    FDirHandle: THandle;
    FOverlapped: THandle; // event for overlapped I/O
    FOnChange: TFileChangeEvent;
    FSuppressed: array of RawUtf8;
    FSuppressLock: TLightLock;
    procedure ProcessNotifications(ABuf: PByte; ABytesRead: Cardinal);
    function IsSuppressed(const ARelPath: RawUtf8): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const ARootDir: string);
    destructor Destroy; override;
    /// Signal the watcher to stop (closes dir handle to unblock)
    procedure SignalStop;
    /// Temporarily suppress watcher events for a path (call before downloading).
    procedure SuppressPath(const ARelPath: RawUtf8);
    /// Remove suppression (call after download complete).
    procedure UnsuppressPath(const ARelPath: RawUtf8);
    property OnChange: TFileChangeEvent read FOnChange write FOnChange;
  end;

implementation

uses
  Winapi.Windows;

type
  PFileNotifyInformation = ^TFileNotifyInformation;
  TFileNotifyInformation = record
    NextEntryOffset: DWORD;
    Action: DWORD;
    FileNameLength: DWORD;
    FileName: array[0..0] of WideChar;
  end;

const
  FILE_NOTIFY_CHANGE_ALL =
    FILE_NOTIFY_CHANGE_FILE_NAME or
    FILE_NOTIFY_CHANGE_DIR_NAME or
    FILE_NOTIFY_CHANGE_SIZE or
    FILE_NOTIFY_CHANGE_LAST_WRITE or
    FILE_NOTIFY_CHANGE_CREATION;

{ TFileWatcher }

constructor TFileWatcher.Create(const ARootDir: string);
begin
  FRootDir := ARootDir;
  FOverlapped := CreateEvent(nil, True, False, nil);
  FDirHandle := CreateFile(
    PChar(FRootDir),
    FILE_LIST_DIRECTORY,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil,
    OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OVERLAPPED,
    0);
  inherited Create(False);
end;

destructor TFileWatcher.Destroy;
begin
  if FOverlapped <> 0 then
    CloseHandle(FOverlapped);
  inherited;
end;

procedure TFileWatcher.SignalStop;
begin
  Terminate;
  // Close dir handle to cancel pending ReadDirectoryChangesW
  if FDirHandle <> INVALID_HANDLE_VALUE then
  begin
    CancelIo(FDirHandle);
    CloseHandle(FDirHandle);
    FDirHandle := INVALID_HANDLE_VALUE;
  end;
end;

function ShouldIgnoreFile(const AName: string): Boolean;
begin
  Result := AName.ToLower.EndsWith('.share7tmp') or
            (AName.ToLower = 'share7.exe');
end;

procedure TFileWatcher.SuppressPath(const ARelPath: RawUtf8);
begin
  FSuppressLock.Lock;
  try
    FSuppressed := FSuppressed + [ARelPath];
  finally
    FSuppressLock.UnLock;
  end;
end;

procedure TFileWatcher.UnsuppressPath(const ARelPath: RawUtf8);
begin
  FSuppressLock.Lock;
  try
    for var I := High(FSuppressed) downto 0 do
      if PropNameEquals(FSuppressed[I], ARelPath) then
      begin
        Delete(FSuppressed, I, 1);
        Break;
      end;
  finally
    FSuppressLock.UnLock;
  end;
end;

function TFileWatcher.IsSuppressed(const ARelPath: RawUtf8): Boolean;
begin
  FSuppressLock.Lock;
  try
    for var I := 0 to High(FSuppressed) do
      if PropNameEquals(FSuppressed[I], ARelPath) then
        Exit(True);
    Result := False;
  finally
    FSuppressLock.UnLock;
  end;
end;

procedure TFileWatcher.Execute;
begin
  if FDirHandle = INVALID_HANDLE_VALUE then
    Exit;

  var Buf: array[0..8191] of Byte;
  var Ovl: TOverlapped;

  while not Terminated do
  begin
    FillChar(Ovl, SizeOf(Ovl), 0);
    Ovl.hEvent := FOverlapped;
    ResetEvent(FOverlapped);

    if not ReadDirectoryChangesW(FDirHandle, @Buf[0], SizeOf(Buf), True,
      FILE_NOTIFY_CHANGE_ALL, nil, @Ovl, nil) then
      Break;

    // Wait with 1s timeout so we can check Terminated
    while not Terminated do
    begin
      var WaitResult := WaitForSingleObject(FOverlapped, 1000);
      if WaitResult = WAIT_OBJECT_0 then
        Break
      else if WaitResult = WAIT_TIMEOUT then
        Continue
      else
        Exit; // error
    end;

    if Terminated then
      Break;

    var BytesRead: DWORD;
    if not GetOverlappedResult(FDirHandle, Ovl, BytesRead, False) then
      Break;

    if BytesRead > 0 then
    begin
      Sleep(WATCHER_DEBOUNCE_MS);
      ProcessNotifications(@Buf[0], BytesRead);
    end;
  end;
end;

procedure TFileWatcher.ProcessNotifications(ABuf: PByte; ABytesRead: Cardinal);
begin
  var P := ABuf;

  while True do
  begin
    var Info := PFileNotifyInformation(P);
    var NameLen := Info^.FileNameLength div SizeOf(WideChar);
    var FileName := '';
    SetString(FileName, Info^.FileName, NameLen);
    FileName := FileName.Replace('\', '/');

    if not ShouldIgnoreFile(FileName) then
    begin
      if Pos('..', FileName) = 0 then
      begin
        var RelPath := RawUtf8(FileName);

        // Skip if this path is suppressed (we're downloading it)
        if not IsSuppressed(RelPath) then
        begin
          var Action: TFileAction;
          case Info^.Action of
            FILE_ACTION_ADDED:            Action := TFileAction.faCreated;
            FILE_ACTION_REMOVED:          Action := TFileAction.faDeleted;
            FILE_ACTION_MODIFIED:         Action := TFileAction.faModified;
            FILE_ACTION_RENAMED_OLD_NAME: Action := TFileAction.faDeleted;
            FILE_ACTION_RENAMED_NEW_NAME: Action := TFileAction.faCreated;
          else
            Action := TFileAction.faModified;
          end;

          if Assigned(FOnChange) then
            FOnChange(Action, RelPath);
        end;
      end;
    end;

    if Info^.NextEntryOffset = 0 then
      Break;
    Inc(P, Info^.NextEntryOffset);
  end;
end;

end.
