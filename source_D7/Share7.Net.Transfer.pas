unit Share7.Net.Transfer;

interface

uses
  Classes,
  SysUtils,
  mormot.core.base,
  mormot.core.os,
  mormot.net.sock,
  Share7.Core.Types;

type
  TOnDeleteNotify = procedure(const ARelPath: RawUtf8) of object;
  TOnChangesNotify = procedure(const APeerIP: RawUtf8; ATcpPort: Word) of object;
  TOnClipboardNotify = procedure(const AText: RawUtf8) of object;
  /// Progress callback: received bytes, total bytes.
  TTransferProgress = procedure(AReceived, ATotal: Int64) of object;

  /// TCP server thread: listens for incoming file requests and delete notifications.
  TTcpServerThread = class(TThread)
  private
    FPort: Word;
    FRootDir: string;
    FServerSock: TCrtSocket;
    FEntries: ^TFileEntries;
    FEntriesLock: ^TLightLock;
    FOnDeleteNotify: TOnDeleteNotify;
    FOnChangesNotify: TOnChangesNotify;
    FOnClipboardNotify: TOnClipboardNotify;
    procedure HandleClient(AClient: TCrtSocket);
    procedure HandleRequestFileList(AClient: TCrtSocket);
    procedure HandleRequestFile(AClient: TCrtSocket);
    procedure HandleNotifyDelete(AClient: TCrtSocket);
    procedure HandleNotifyClipboard(AClient: TCrtSocket);
  protected
    procedure Execute; override;
  public
    constructor Create(APort: Word; const ARootDir: string;
      AEntries: Pointer; AEntriesLock: Pointer);
    procedure Shutdown;
    property OnDeleteNotify: TOnDeleteNotify read FOnDeleteNotify write FOnDeleteNotify;
    property OnChangesNotify: TOnChangesNotify read FOnChangesNotify write FOnChangesNotify;
    property OnClipboardNotify: TOnClipboardNotify read FOnClipboardNotify write FOnClipboardNotify;
  end;

/// Client-side TCP operations for syncing with a peer.
function TransferRequestFileList(const AIP: RawUtf8; APort: Word): TFileEntries;
function TransferDownloadFile(const AIP: RawUtf8; APort: Word;
  const ARelPath: RawUtf8; const ADestPath: string;
  AOnProgress: TTransferProgress = nil): Boolean;
procedure TransferSendDeleteNotify(const AIP: RawUtf8; APort: Word;
  const ARelPath: RawUtf8);
procedure TransferSendChangesNotify(const AIP: RawUtf8; APort: Word);
procedure TransferSendClipboardNotify(const AIP: RawUtf8; APort: Word;
  const AText: RawUtf8);

implementation

uses
  Share7.Net.Protocol;

const
  CONNECT_TIMEOUT = 5000;
  IO_TIMEOUT = 30000;

{ Helper: safe recv of exact N bytes }
function RecvExact(ASock: TCrtSocket; ABuf: PByte; ALen: Integer): Boolean;
var
  Data: RawByteString;
begin
  try
    Data := ASock.SockRecv(ALen);
    if Length(Data) <> ALen then
    begin
      Result := False;
      Exit;
    end;
    Move(Data[1], ABuf^, ALen);
    Result := True;
  except
    Result := False;
  end;
end;

{ Helper: safe send of raw bytes }
function SendRaw(ASock: TCrtSocket; ABuf: PByte; ALen: Integer): Boolean;
begin
  Result := ASock.TrySndLow(ABuf, ALen);
end;

{ Helper: connect to a peer }
function ConnectToPeer(const AIP: RawUtf8; APort: Word): TCrtSocket;
begin
  try
    Result := TCrtSocket.Open(AIP, RawUtf8(IntToStr(APort)), nlTcp, CONNECT_TIMEOUT);
  except
    Result := nil;
  end;
end;

{ TTcpServerThread }

constructor TTcpServerThread.Create(APort: Word; const ARootDir: string;
  AEntries: Pointer; AEntriesLock: Pointer);
begin
  FPort := APort;
  FRootDir := ARootDir;
  FEntries := AEntries;
  FEntriesLock := AEntriesLock;
  inherited Create(False);
end;

procedure TTcpServerThread.Execute;
var
  ClientSock: TNetSocket;
  ClientAddr: TNetAddr;
  Client: TCrtSocket;
begin
  try
    FServerSock := TCrtSocket.Bind(RawUtf8(IntToStr(FPort)), nlTcp, IO_TIMEOUT);
  except
    Exit;
  end;

  try
    while not Terminated do
    begin
      if FServerSock.Sock.Accept(ClientSock, ClientAddr, False) = nrOk then
      begin
        Client := TCrtSocket.Create(IO_TIMEOUT);
        try
          Client.AcceptRequest(ClientSock, @ClientAddr);
          Client.CreateSockIn;
          HandleClient(Client);
        finally
          Client.Free;
        end;
      end
      else
        Sleep(50); // Brief pause if no connection pending
    end;
  finally
    FreeAndNil(FServerSock);
  end;
end;

procedure TTcpServerThread.HandleClient(AClient: TCrtSocket);
var
  Cmd: Byte;
begin
  if not RecvExact(AClient, @Cmd, 1) then
    Exit;

  case Cmd of
    TCP_REQUEST_FILE_LIST: HandleRequestFileList(AClient);
    TCP_REQUEST_FILE:      HandleRequestFile(AClient);
    TCP_NOTIFY_DELETE:     HandleNotifyDelete(AClient);
    TCP_NOTIFY_CHANGES:
      begin
        if Assigned(FOnChangesNotify) then
          FOnChangesNotify(AClient.RemoteIP, 0);
      end;
    TCP_NOTIFY_CLIPBOARD: HandleNotifyClipboard(AClient);
  end;
end;

procedure TTcpServerThread.HandleRequestFileList(AClient: TCrtSocket);
var
  Data: RawByteString;
  DataLen: Cardinal;
begin
  FEntriesLock^.Lock;
  try
    Data := EncodeFileList(FEntries^);
  finally
    FEntriesLock^.UnLock;
  end;

  DataLen := Length(Data);
  SendRaw(AClient, @DataLen, SizeOf(DataLen));
  if DataLen > 0 then
    SendRaw(AClient, @Data[1], DataLen);
end;

procedure TTcpServerThread.HandleRequestFile(AClient: TCrtSocket);
var
  PathLen: Word;
  PathBuf: RawByteString;
  RelPath: RawUtf8;
  FullPath: string;
  NotFound: Int64;
  Stream: TFileStream;
  FileSize: Int64;
  Buf: array[0..TRANSFER_BUFFER_SIZE - 1] of Byte;
  Remaining: Int64;
  ToRead: Integer;
begin
  if not RecvExact(AClient, @PathLen, SizeOf(PathLen)) then
    Exit;
  if PathLen > 4096 then
    Exit;

  SetLength(PathBuf, PathLen);
  if not RecvExact(AClient, @PathBuf[1], PathLen) then
    Exit;
  RelPath := RawUtf8(PathBuf);

  // Security: reject path traversal
  if Pos('..', string(RelPath)) > 0 then
    Exit;

  FullPath := IncludeTrailingPathDelimiter(FRootDir) +
    StringReplace(string(RelPath), '/', '\', [rfReplaceAll]);

  if not FileExists(FullPath) then
  begin
    NotFound := -1;
    SendRaw(AClient, @NotFound, SizeOf(NotFound));
    Exit;
  end;

  Stream := TFileStream.Create(FullPath, fmOpenRead or fmShareDenyNone);
  try
    FileSize := Stream.Size;
    SendRaw(AClient, @FileSize, SizeOf(FileSize));

    Remaining := FileSize;
    while Remaining > 0 do
    begin
      ToRead := TRANSFER_BUFFER_SIZE;
      if Remaining < ToRead then
        ToRead := Integer(Remaining);
      Stream.ReadBuffer(Buf[0], ToRead);
      if not SendRaw(AClient, @Buf[0], ToRead) then
        Exit;
      Dec(Remaining, ToRead);
    end;
  finally
    Stream.Free;
  end;
end;

procedure TTcpServerThread.HandleNotifyDelete(AClient: TCrtSocket);
var
  PathLen: Word;
  PathBuf: RawByteString;
  RelPath: RawUtf8;
begin
  if not RecvExact(AClient, @PathLen, SizeOf(PathLen)) then
    Exit;
  if PathLen > 4096 then
    Exit;

  SetLength(PathBuf, PathLen);
  if not RecvExact(AClient, @PathBuf[1], PathLen) then
    Exit;
  RelPath := RawUtf8(PathBuf);

  if Pos('..', string(RelPath)) > 0 then
    Exit;

  if Assigned(FOnDeleteNotify) then
    FOnDeleteNotify(RelPath);
end;

procedure TTcpServerThread.Shutdown;
begin
  Terminate;
  if FServerSock <> nil then
    FServerSock.Close;
end;

{ Client-side transfer functions }

function TransferRequestFileList(const AIP: RawUtf8; APort: Word): TFileEntries;
var
  Sock: TCrtSocket;
  Cmd: Byte;
  DataLen: Cardinal;
  Data: RawByteString;
begin
  Result := nil;
  Sock := ConnectToPeer(AIP, APort);
  if Sock = nil then
    Exit;
  try
    Cmd := TCP_REQUEST_FILE_LIST;
    SendRaw(Sock, @Cmd, 1);

    if not RecvExact(Sock, @DataLen, SizeOf(DataLen)) then
      Exit;
    if (DataLen = 0) or (DataLen > 100 * 1024 * 1024) then
      Exit;

    SetLength(Data, DataLen);
    if not RecvExact(Sock, @Data[1], DataLen) then
      Exit;

    Result := DecodeFileList(Data);
  finally
    Sock.Free;
  end;
end;

function TransferDownloadFile(const AIP: RawUtf8; APort: Word;
  const ARelPath: RawUtf8; const ADestPath: string;
  AOnProgress: TTransferProgress): Boolean;
var
  Sock: TCrtSocket;
  Cmd: Byte;
  PathLen: Word;
  FileSize: Int64;
  Dir: string;
  TmpPath: string;
  Stream: TFileStream;
  Buf: array[0..TRANSFER_BUFFER_SIZE - 1] of Byte;
  Remaining: Int64;
  ToRead: Integer;
begin
  Result := False;
  Sock := ConnectToPeer(AIP, APort);
  if Sock = nil then
    Exit;
  try
    // Send command
    Cmd := TCP_REQUEST_FILE;
    SendRaw(Sock, @Cmd, 1);

    // Send path
    PathLen := Length(ARelPath);
    SendRaw(Sock, @PathLen, SizeOf(PathLen));
    SendRaw(Sock, @ARelPath[1], PathLen);

    // Read file size
    if not RecvExact(Sock, @FileSize, SizeOf(FileSize)) then
      Exit;
    if FileSize < 0 then
      Exit;

    // Ensure directory exists
    Dir := ExtractFilePath(ADestPath);
    if (Dir <> '') and not DirectoryExists(Dir) then
      ForceDirectories(Dir);

    // Write to temp file, then rename
    TmpPath := ADestPath + '.share7tmp';
    Stream := TFileStream.Create(TmpPath, fmCreate);
    try
      Remaining := FileSize;
      while Remaining > 0 do
      begin
        ToRead := TRANSFER_BUFFER_SIZE;
        if Remaining < ToRead then
          ToRead := Integer(Remaining);
        if not RecvExact(Sock, @Buf[0], ToRead) then
          Exit;
        Stream.WriteBuffer(Buf[0], ToRead);
        Dec(Remaining, ToRead);
        if Assigned(AOnProgress) then
          AOnProgress(FileSize - Remaining, FileSize);
      end;
    finally
      Stream.Free;
    end;

    // Atomic rename
    if FileExists(ADestPath) then
      DeleteFile(ADestPath);
    Result := RenameFile(TmpPath, ADestPath);
  finally
    Sock.Free;
  end;
end;

procedure TransferSendDeleteNotify(const AIP: RawUtf8; APort: Word;
  const ARelPath: RawUtf8);
var
  Sock: TCrtSocket;
  Cmd: Byte;
  PathLen: Word;
begin
  Sock := ConnectToPeer(AIP, APort);
  if Sock = nil then
    Exit;
  try
    Cmd := TCP_NOTIFY_DELETE;
    SendRaw(Sock, @Cmd, 1);

    PathLen := Length(ARelPath);
    SendRaw(Sock, @PathLen, SizeOf(PathLen));
    SendRaw(Sock, @ARelPath[1], PathLen);
  finally
    Sock.Free;
  end;
end;

procedure TransferSendChangesNotify(const AIP: RawUtf8; APort: Word);
var
  Sock: TCrtSocket;
  Cmd: Byte;
begin
  Sock := ConnectToPeer(AIP, APort);
  if Sock = nil then
    Exit;
  try
    Cmd := TCP_NOTIFY_CHANGES;
    SendRaw(Sock, @Cmd, 1);
  finally
    Sock.Free;
  end;
end;

procedure TransferSendClipboardNotify(const AIP: RawUtf8; APort: Word;
  const AText: RawUtf8);
var
  Sock: TCrtSocket;
  Cmd: Byte;
  DataLen: Cardinal;
begin
  Sock := ConnectToPeer(AIP, APort);
  if Sock = nil then
    Exit;
  try
    Cmd := TCP_NOTIFY_CLIPBOARD;
    SendRaw(Sock, @Cmd, 1);

    DataLen := Length(AText);
    SendRaw(Sock, @DataLen, SizeOf(DataLen));
    if DataLen > 0 then
      SendRaw(Sock, @AText[1], DataLen);
  finally
    Sock.Free;
  end;
end;

procedure TTcpServerThread.HandleNotifyClipboard(AClient: TCrtSocket);
var
  DataLen: Cardinal;
  Data: RawByteString;
begin
  if not RecvExact(AClient, @DataLen, SizeOf(DataLen)) then
    Exit;
  if DataLen = 0 then
    Exit;
  if DataLen > 100 * 1024 * 1024 then
    Exit;

  SetLength(Data, DataLen);
  if not RecvExact(AClient, @Data[1], DataLen) then
    Exit;

  if Assigned(FOnClipboardNotify) then
    FOnClipboardNotify(RawUtf8(Data));
end;

end.
