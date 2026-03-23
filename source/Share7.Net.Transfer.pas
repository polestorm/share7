unit Share7.Net.Transfer;

interface

uses
  System.Classes,
  System.SysUtils,
  mormot.core.base,
  mormot.core.os,
  mormot.net.sock,
  Share7.Core.Types;

type
  TOnDeleteNotify = procedure(const ARelPath: RawUtf8) of object;
  TOnChangesNotify = procedure(const APeerIP: RawUtf8; ATcpPort: Word) of object;
  /// Progress callback: received bytes, total bytes.
  TTransferProgress = reference to procedure(AReceived, ATotal: Int64);

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
    procedure HandleClient(AClient: TCrtSocket);
    procedure HandleRequestFileList(AClient: TCrtSocket);
    procedure HandleRequestFile(AClient: TCrtSocket);
    procedure HandleNotifyDelete(AClient: TCrtSocket);
  protected
    procedure Execute; override;
  public
    constructor Create(APort: Word; const ARootDir: string;
      AEntries: Pointer; AEntriesLock: Pointer);
    procedure Shutdown;
    property OnDeleteNotify: TOnDeleteNotify read FOnDeleteNotify write FOnDeleteNotify;
    property OnChangesNotify: TOnChangesNotify read FOnChangesNotify write FOnChangesNotify;
  end;

  /// Client-side TCP operations for syncing with a peer.
  TTransferClient = record
    class function RequestFileList(const AIP: RawUtf8; APort: Word): TFileEntries; static;
    class function DownloadFile(const AIP: RawUtf8; APort: Word;
      const ARelPath: RawUtf8; const ADestPath: string;
      AOnProgress: TTransferProgress = nil): Boolean; static;
    class procedure SendDeleteNotify(const AIP: RawUtf8; APort: Word;
      const ARelPath: RawUtf8); static;
    class procedure SendChangesNotify(const AIP: RawUtf8; APort: Word); static;
  end;

implementation

uses
  Share7.Net.Protocol;

const
  CONNECT_TIMEOUT = 5000;
  IO_TIMEOUT = 30000;

{ Helper: safe recv of exact N bytes }
function RecvExact(ASock: TCrtSocket; ABuf: PByte; ALen: Integer): Boolean;
begin
  try
    var Data := ASock.SockRecv(ALen);
    if Length(Data) <> ALen then
      Exit(False);
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
begin
  try
    FServerSock := TCrtSocket.Bind(RawUtf8(IntToStr(FPort)), nlTcp, IO_TIMEOUT);
  except
    Exit;
  end;

  try
    while not Terminated do
    begin
      var ClientSock: TNetSocket;
      var ClientAddr: TNetAddr;
      if FServerSock.Sock.Accept(ClientSock, ClientAddr, False) = nrOk then
      begin
        var Client := TCrtSocket.Create(IO_TIMEOUT);
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
begin
  var Cmd: Byte;
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
  end;
end;

procedure TTcpServerThread.HandleRequestFileList(AClient: TCrtSocket);
begin
  var Data: RawByteString;
  FEntriesLock^.Lock;
  try
    Data := EncodeFileList(FEntries^);
  finally
    FEntriesLock^.UnLock;
  end;

  var DataLen: Cardinal := Length(Data);
  SendRaw(AClient, @DataLen, SizeOf(DataLen));
  if DataLen > 0 then
    SendRaw(AClient, @Data[1], DataLen);
end;

procedure TTcpServerThread.HandleRequestFile(AClient: TCrtSocket);
begin
  var PathLen: Word;
  if not RecvExact(AClient, @PathLen, SizeOf(PathLen)) then
    Exit;
  if PathLen > 4096 then
    Exit;

  var PathBuf: RawByteString;
  SetLength(PathBuf, PathLen);
  if not RecvExact(AClient, @PathBuf[1], PathLen) then
    Exit;
  var RelPath := RawUtf8(PathBuf);

  // Security: reject path traversal
  if Pos('..', string(RelPath)) > 0 then
    Exit;

  var FullPath := IncludeTrailingPathDelimiter(FRootDir) +
    string(RelPath).Replace('/', '\');

  if not FileExists(FullPath) then
  begin
    var NotFound: Int64 := -1;
    SendRaw(AClient, @NotFound, SizeOf(NotFound));
    Exit;
  end;

  var Stream := TFileStream.Create(FullPath, fmOpenRead or fmShareDenyNone);
  try
    var FileSize: Int64 := Stream.Size;
    SendRaw(AClient, @FileSize, SizeOf(FileSize));

    var Buf: array[0..TRANSFER_BUFFER_SIZE - 1] of Byte;
    var Remaining := FileSize;
    while Remaining > 0 do
    begin
      var ToRead := TRANSFER_BUFFER_SIZE;
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
begin
  var PathLen: Word;
  if not RecvExact(AClient, @PathLen, SizeOf(PathLen)) then
    Exit;
  if PathLen > 4096 then
    Exit;

  var PathBuf: RawByteString;
  SetLength(PathBuf, PathLen);
  if not RecvExact(AClient, @PathBuf[1], PathLen) then
    Exit;
  var RelPath := RawUtf8(PathBuf);

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

{ TTransferClient }

class function TTransferClient.RequestFileList(const AIP: RawUtf8; APort: Word): TFileEntries;
begin
  Result := nil;
  var Sock := ConnectToPeer(AIP, APort);
  if Sock = nil then
    Exit;
  try
    var Cmd: Byte := TCP_REQUEST_FILE_LIST;
    SendRaw(Sock, @Cmd, 1);

    var DataLen: Cardinal;
    if not RecvExact(Sock, @DataLen, SizeOf(DataLen)) then
      Exit;
    if (DataLen = 0) or (DataLen > 100 * 1024 * 1024) then
      Exit;

    var Data: RawByteString;
    SetLength(Data, DataLen);
    if not RecvExact(Sock, @Data[1], DataLen) then
      Exit;

    Result := DecodeFileList(Data);
  finally
    Sock.Free;
  end;
end;

class function TTransferClient.DownloadFile(const AIP: RawUtf8; APort: Word;
  const ARelPath: RawUtf8; const ADestPath: string;
  AOnProgress: TTransferProgress): Boolean;
begin
  Result := False;
  var Sock := ConnectToPeer(AIP, APort);
  if Sock = nil then
    Exit;
  try
    // Send command
    var Cmd: Byte := TCP_REQUEST_FILE;
    SendRaw(Sock, @Cmd, 1);

    // Send path
    var PathLen: Word := Length(ARelPath);
    SendRaw(Sock, @PathLen, SizeOf(PathLen));
    SendRaw(Sock, @ARelPath[1], PathLen);

    // Read file size
    var FileSize: Int64;
    if not RecvExact(Sock, @FileSize, SizeOf(FileSize)) then
      Exit;
    if FileSize < 0 then
      Exit;

    // Ensure directory exists
    var Dir := ExtractFilePath(ADestPath);
    if (Dir <> '') and not DirectoryExists(Dir) then
      ForceDirectories(Dir);

    // Write to temp file, then rename
    var TmpPath := ADestPath + '.share7tmp';
    var Stream := TFileStream.Create(TmpPath, fmCreate);
    try
      var Buf: array[0..TRANSFER_BUFFER_SIZE - 1] of Byte;
      var Remaining := FileSize;
      while Remaining > 0 do
      begin
        var ToRead := TRANSFER_BUFFER_SIZE;
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

class procedure TTransferClient.SendDeleteNotify(const AIP: RawUtf8; APort: Word;
  const ARelPath: RawUtf8);
begin
  var Sock := ConnectToPeer(AIP, APort);
  if Sock = nil then
    Exit;
  try
    var Cmd: Byte := TCP_NOTIFY_DELETE;
    SendRaw(Sock, @Cmd, 1);

    var PathLen: Word := Length(ARelPath);
    SendRaw(Sock, @PathLen, SizeOf(PathLen));
    SendRaw(Sock, @ARelPath[1], PathLen);
  finally
    Sock.Free;
  end;
end;

class procedure TTransferClient.SendChangesNotify(const AIP: RawUtf8; APort: Word);
begin
  var Sock := ConnectToPeer(AIP, APort);
  if Sock = nil then
    Exit;
  try
    var Cmd: Byte := TCP_NOTIFY_CHANGES;
    SendRaw(Sock, @Cmd, 1);
  finally
    Sock.Free;
  end;
end;

end.
