unit Share7.Net.Discovery;

interface

uses
  Classes,
  mormot.core.base,
  mormot.core.os,
  mormot.net.sock,
  Share7.Core.Types;

type
  TOnPeerEvent = procedure(const APeer: TPeerInfo) of object;

  /// UDP broadcast peer discovery thread.
  /// Broadcasts smkAnnounce every ~5s, replies smkAnnounceAck to new peers,
  /// removes peers not seen for 15s.
  /// Uses raw TNetSocket UDP instead of TUdpServerThread to avoid
  /// pulling in the heavy mormot.net.server unit.
  TDiscoveryThread = class(TThread)
  private
    FName: RawUtf8;
    FUdpPort: Word;
    FTcpPort: Word;
    FSock: TNetSocket;
    FPeers: TPeerInfoDynArray;
    FPeerLock: TLightLock;
    FIdleTicks: Integer;
    FBroadcastAddr: TNetAddr;
    FOnPeerDiscovered: TOnPeerEvent;
    FOnPeerLost: TOnPeerEvent;
    procedure SendMessage(AKind: TShare7MessageKind; const AAddr: TNetAddr);
    procedure HandleMessage(AData: PByte; ALen: Integer; var ARemote: TNetAddr);
    procedure AddOrUpdatePeer(const AName, AIP: RawUtf8; ATcpPort: Word;
      AUtcTime: TDateTime; const ARemote: TNetAddr);
    procedure PurgeStale(ATick: Int64);
  protected
    procedure Execute; override;
  public
    constructor Create(const AName: RawUtf8; AUdpPort, ATcpPort: Word);
    destructor Destroy; override;
    procedure SendGoodbye;
    function GetPeerList: TPeerInfoDynArray;
    function PeerCount: Integer;
    property OnPeerDiscovered: TOnPeerEvent read FOnPeerDiscovered write FOnPeerDiscovered;
    property OnPeerLost: TOnPeerEvent read FOnPeerLost write FOnPeerLost;
  end;

implementation

uses
  SysUtils,
  Share7.Net.Protocol;

const
  UDP_FRAME_SIZE = 65536;
  IDLE_POLL_MS = 512;

{ TDiscoveryThread }

constructor TDiscoveryThread.Create(const AName: RawUtf8; AUdpPort, ATcpPort: Word);
begin
  FName := AName;
  FUdpPort := AUdpPort;
  FTcpPort := ATcpPort;
  FIdleTicks := 0;
  FSock := nil;
  inherited Create(False);
end;

destructor TDiscoveryThread.Destroy;
begin
  if FSock <> nil then
    FSock.Close;
  inherited;
end;

procedure TDiscoveryThread.Execute;
var
  BindAddr: TNetAddr;
  Buf: array[0..UDP_FRAME_SIZE - 1] of Byte;
  Events: TNetEvents;
  Remote: TNetAddr;
  Len: Integer;
begin
  // Bind UDP socket
  BindAddr.SetFrom(cAnyHost, RawUtf8(IntToStr(FUdpPort)), nlUdp);
  FSock := BindAddr.NewSocket(nlUdp);
  if FSock = nil then
    Exit;
  FSock.SetReuseAddrPort;
  if BindAddr.SocketBind(FSock) <> nrOk then
  begin
    FSock.Close;
    FSock := nil;
    Exit;
  end;
  FSock.SetBroadcast(True);

  FBroadcastAddr.SetFrom(cBroadcast, RawUtf8(IntToStr(FUdpPort)), nlUdp);

  // Send initial announce immediately
  SendMessage(smkAnnounce, FBroadcastAddr);

  while not Terminated do
  begin
    Events := FSock.WaitFor(IDLE_POLL_MS, [neRead]);
    if neRead in Events then
    begin
      Len := FSock.RecvFrom(@Buf[0], UDP_FRAME_SIZE, Remote);
      if Len > 0 then
        HandleMessage(@Buf[0], Len, Remote);
    end
    else
    begin
      // Idle tick - periodic announce + purge
      Inc(FIdleTicks);
      if FIdleTicks >= ANNOUNCE_INTERVAL_TICKS then
      begin
        FIdleTicks := 0;
        SendMessage(smkAnnounce, FBroadcastAddr);
      end;
      PurgeStale(GetTickCount64);
    end;
  end;
end;

procedure TDiscoveryThread.SendMessage(AKind: TShare7MessageKind; const AAddr: TNetAddr);
var
  Msg: RawByteString;
begin
  Msg := EncodeUdpMessage(AKind, FTcpPort, FName);
  FSock.SendTo(pointer(Msg), Length(Msg), AAddr);
end;

procedure TDiscoveryThread.HandleMessage(AData: PByte; ALen: Integer; var ARemote: TNetAddr);
var
  Kind: TShare7MessageKind;
  UtcTime: TDateTime;
  TcpPort: Word;
  PeerName: RawUtf8;
  PeerIP: RawUtf8;
  I, J: Integer;
  LostPeer: TPeerInfo;
begin
  if not DecodeUdpMessage(AData, ALen, Kind, UtcTime, TcpPort, PeerName) then
    Exit;

  // Ignore our own messages
  if PeerName = FName then
    Exit;

  ARemote.IP(PeerIP);

  case Kind of
    smkAnnounce:
      begin
        AddOrUpdatePeer(PeerName, PeerIP, TcpPort, UtcTime, ARemote);
        // Reply with Ack
        SendMessage(smkAnnounceAck, ARemote);
      end;
    smkAnnounceAck:
      AddOrUpdatePeer(PeerName, PeerIP, TcpPort, UtcTime, ARemote);
    smkGoodbye:
      begin
        FPeerLock.Lock;
        try
          for I := High(FPeers) downto 0 do
            if FPeers[I].Name = PeerName then
            begin
              LostPeer := FPeers[I];
              for J := I to High(FPeers) - 1 do
                FPeers[J] := FPeers[J + 1];
              SetLength(FPeers, Length(FPeers) - 1);
              if Assigned(FOnPeerLost) then
                FOnPeerLost(LostPeer);
              Break;
            end;
        finally
          FPeerLock.UnLock;
        end;
      end;
  end;
end;

procedure TDiscoveryThread.AddOrUpdatePeer(const AName, AIP: RawUtf8;
  ATcpPort: Word; AUtcTime: TDateTime; const ARemote: TNetAddr);
var
  I: Integer;
  Peer: TPeerInfo;
  NewPeer: TPeerInfo;
begin
  FPeerLock.Lock;
  try
    for I := 0 to High(FPeers) do
      if FPeers[I].Name = AName then
      begin
        FPeers[I].LastSeenTick := GetTickCount64;
        FPeers[I].UtcTime := AUtcTime;
        FPeers[I].IP := AIP;
        FPeers[I].TcpPort := ATcpPort;
        Exit;
      end;

    Peer.Name := AName;
    Peer.IP := AIP;
    Peer.TcpPort := ATcpPort;
    Peer.LastSeenTick := GetTickCount64;
    Peer.UtcTime := AUtcTime;
    SetLength(FPeers, Length(FPeers) + 1);
    FPeers[High(FPeers)] := Peer;
  finally
    FPeerLock.UnLock;
  end;

  NewPeer.Name := AName;
  NewPeer.IP := AIP;
  NewPeer.TcpPort := ATcpPort;
  NewPeer.UtcTime := AUtcTime;
  NewPeer.LastSeenTick := GetTickCount64;

  if Assigned(FOnPeerDiscovered) then
    FOnPeerDiscovered(NewPeer);
end;

procedure TDiscoveryThread.PurgeStale(ATick: Int64);
var
  I, J: Integer;
  LostPeer: TPeerInfo;
begin
  FPeerLock.Lock;
  try
    for I := High(FPeers) downto 0 do
      if (ATick - FPeers[I].LastSeenTick) > (PEER_TIMEOUT_SEC * 1000) then
      begin
        LostPeer := FPeers[I];
        for J := I to High(FPeers) - 1 do
          FPeers[J] := FPeers[J + 1];
        SetLength(FPeers, Length(FPeers) - 1);
        if Assigned(FOnPeerLost) then
          FOnPeerLost(LostPeer);
      end;
  finally
    FPeerLock.UnLock;
  end;
end;

procedure TDiscoveryThread.SendGoodbye;
begin
  SendMessage(smkGoodbye, FBroadcastAddr);
end;

function TDiscoveryThread.PeerCount: Integer;
begin
  FPeerLock.Lock;
  try
    Result := Length(FPeers);
  finally
    FPeerLock.UnLock;
  end;
end;

function TDiscoveryThread.GetPeerList: TPeerInfoDynArray;
begin
  FPeerLock.Lock;
  try
    Result := Copy(FPeers);
  finally
    FPeerLock.UnLock;
  end;
end;

end.
