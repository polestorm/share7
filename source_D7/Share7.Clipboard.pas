unit Share7.Clipboard;

/// Clipboard watcher thread: polls GetClipboardSequenceNumber,
/// reads text when changed, fires callback. Also provides standalone
/// functions for reading/writing clipboard text.

interface

uses
  Classes,
  mormot.core.base,
  mormot.core.os;

type
  TOnClipboardChanged = procedure(const AText: RawUtf8) of object;

  /// Polls clipboard for text changes and fires OnChanged callback.
  TClipboardWatcher = class(TThread)
  private
    FLastSeqNo: Cardinal;
    FLastSentHash: RawUtf8;
    FLastReceivedHash: RawUtf8;
    FLastSendTick: QWord;
    FOnChanged: TOnClipboardChanged;
    FLock: TLightLock;
  protected
    procedure Execute; override;
  public
    constructor Create;
    /// Set after receiving clipboard from a peer to prevent echo.
    procedure SetReceivedHash(const AHash: RawUtf8);
    property OnChanged: TOnClipboardChanged read FOnChanged write FOnChanged;
  end;

/// Read current clipboard text as UTF-8. Returns '' if not text or failed.
function ReadClipboardText: RawUtf8;

/// Write UTF-8 text to clipboard.
function WriteClipboardText(const AText: RawUtf8): Boolean;

/// Compute SHA-256 hash of text (for echo suppression).
function ClipboardHash(const AText: RawUtf8): RawUtf8;

implementation

uses
  Windows,
  SysUtils,
  mormot.crypt.core;

const
  CLIPBOARD_POLL_MS = 200;
  CLIPBOARD_DEBOUNCE_MS = 500;
  CLIPBOARD_RETRY_COUNT = 3;
  CLIPBOARD_RETRY_DELAY = 50;

function ClipboardHash(const AText: RawUtf8): RawUtf8;
begin
  Result := Sha256(AText);
end;

function ReadClipboardText: RawUtf8;
var
  H: THandle;
  {$IF CompilerVersion >= 20.0}
  P: PWideChar;
  {$ELSE}
  P: PAnsiChar;
  {$IFEND}
  Attempt: Integer;
begin
  Result := '';
  for Attempt := 1 to CLIPBOARD_RETRY_COUNT do
  begin
    if OpenClipboard(0) then
    try
      {$IF CompilerVersion >= 20.0}
      H := GetClipboardData(CF_UNICODETEXT);
      if H <> 0 then
      begin
        P := GlobalLock(H);
        if P <> nil then
        try
          Result := RawUtf8(WideString(P));
        finally
          GlobalUnlock(H);
        end;
      end;
      {$ELSE}
      H := GetClipboardData(CF_TEXT);
      if H <> 0 then
      begin
        P := GlobalLock(H);
        if P <> nil then
        try
          Result := RawUtf8(P);
        finally
          GlobalUnlock(H);
        end;
      end;
      {$IFEND}
      Exit;
    finally
      CloseClipboard;
    end;
    Sleep(CLIPBOARD_RETRY_DELAY);
  end;
end;

function WriteClipboardText(const AText: RawUtf8): Boolean;
var
  {$IF CompilerVersion >= 20.0}
  W: WideString;
  {$IFEND}
  H: HGLOBAL;
  P: Pointer;
  Size: Integer;
  Attempt: Integer;
begin
  Result := False;

  {$IF CompilerVersion >= 20.0}
  W := WideString(AText);
  Size := (Length(W) + 1) * SizeOf(WideChar);
  {$ELSE}
  Size := Length(AText) + 1;
  {$IFEND}

  H := GlobalAlloc(GMEM_MOVEABLE, Size);
  if H = 0 then
    Exit;

  P := GlobalLock(H);
  if P = nil then
  begin
    GlobalFree(H);
    Exit;
  end;
  {$IF CompilerVersion >= 20.0}
  Move(PWideChar(W)^, P^, Size);
  {$ELSE}
  Move(PAnsiChar(AText)^, P^, Size);
  {$IFEND}
  GlobalUnlock(H);

  for Attempt := 1 to CLIPBOARD_RETRY_COUNT do
  begin
    if OpenClipboard(0) then
    try
      EmptyClipboard;
      {$IF CompilerVersion >= 20.0}
      SetClipboardData(CF_UNICODETEXT, H);
      {$ELSE}
      SetClipboardData(CF_TEXT, H);
      {$IFEND}
      Result := True;
      Exit;
    finally
      CloseClipboard;
    end;
    Sleep(CLIPBOARD_RETRY_DELAY);
  end;

  // If we never succeeded, free the memory
  if not Result then
    GlobalFree(H);
end;

{ TClipboardWatcher }

constructor TClipboardWatcher.Create;
begin
  FLastSeqNo := GetClipboardSequenceNumber;
  FLastSendTick := 0;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TClipboardWatcher.SetReceivedHash(const AHash: RawUtf8);
begin
  FLock.Lock;
  try
    FLastReceivedHash := AHash;
  finally
    FLock.UnLock;
  end;
end;

procedure TClipboardWatcher.Execute;
var
  SeqNo: Cardinal;
  Text: RawUtf8;
  Hash: RawUtf8;
  RecvHash: RawUtf8;
  NowTick: QWord;
begin
  while not Terminated do
  begin
    Sleep(CLIPBOARD_POLL_MS);
    if Terminated then
      Break;

    SeqNo := GetClipboardSequenceNumber;
    if SeqNo = FLastSeqNo then
      Continue;
    FLastSeqNo := SeqNo;

    // Debounce
    NowTick := GetTickCount64;
    if (NowTick - FLastSendTick) < CLIPBOARD_DEBOUNCE_MS then
      Continue;

    Text := ReadClipboardText;
    if Text = '' then
      Continue;

    Hash := ClipboardHash(Text);

    // Skip if same as last sent
    if Hash = FLastSentHash then
      Continue;

    // Skip if this is echo from a received clipboard
    FLock.Lock;
    try
      RecvHash := FLastReceivedHash;
    finally
      FLock.UnLock;
    end;
    if Hash = RecvHash then
      Continue;

    FLastSentHash := Hash;
    FLastSendTick := NowTick;

    if Assigned(FOnChanged) then
      FOnChanged(Text);
  end;
end;

end.
