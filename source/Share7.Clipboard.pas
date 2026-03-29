unit Share7.Clipboard;

/// Clipboard watcher thread: polls GetClipboardSequenceNumber,
/// reads text when changed, fires callback. Also provides static
/// methods for reading/writing clipboard text.

interface

uses
  System.Classes,
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
  Winapi.Windows,
  System.SysUtils,
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
  P: PWideChar;
  Attempt: Integer;
begin
  Result := '';
  for Attempt := 1 to CLIPBOARD_RETRY_COUNT do
  begin
    if OpenClipboard(0) then
    try
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
      Exit;
    finally
      CloseClipboard;
    end;
    Sleep(CLIPBOARD_RETRY_DELAY);
  end;
end;

function WriteClipboardText(const AText: RawUtf8): Boolean;
var
  W: WideString;
  H: HGLOBAL;
  P: PWideChar;
  Size: Integer;
  Attempt: Integer;
begin
  Result := False;
  W := WideString(AText);
  Size := (Length(W) + 1) * SizeOf(WideChar);

  H := GlobalAlloc(GMEM_MOVEABLE, Size);
  if H = 0 then
    Exit;

  P := GlobalLock(H);
  if P = nil then
  begin
    GlobalFree(H);
    Exit;
  end;
  Move(PWideChar(W)^, P^, Size);
  GlobalUnlock(H);

  for Attempt := 1 to CLIPBOARD_RETRY_COUNT do
  begin
    if OpenClipboard(0) then
    try
      EmptyClipboard;
      SetClipboardData(CF_UNICODETEXT, H);
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
  Now: QWord;
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
    Now := GetTickCount64;
    if (Now - FLastSendTick) < CLIPBOARD_DEBOUNCE_MS then
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
    FLastSendTick := Now;

    if Assigned(FOnChanged) then
      FOnChanged(Text);
  end;
end;

end.
