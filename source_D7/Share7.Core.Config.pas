unit Share7.Core.Config;

interface

uses
  mormot.core.base,
  Share7.Core.Types;

type
  TShare7Config = record
    Name: RawUtf8;
    Folder: string;
    UdpPort: Word;
    TcpPort: Word;
    Sound: Boolean;
    Clipboard: Boolean;
  end;

procedure InitConfig(var AConfig: TShare7Config);

implementation

uses
  SysUtils,
  mormot.core.os;

const
  ADJECTIVES: array[0..31] of string = (
    'fast', 'calm', 'bold', 'warm', 'cool', 'keen', 'wise', 'wild',
    'soft', 'dark', 'tall', 'deep', 'fair', 'good', 'kind', 'pure',
    'rich', 'safe', 'true', 'vast', 'free', 'glad', 'just', 'neat',
    'rare', 'slim', 'sure', 'tidy', 'wary', 'mild', 'pale', 'deft'
  );
  NOUNS: array[0..31] of string = (
    'fox', 'owl', 'elk', 'bee', 'cat', 'dog', 'bat', 'ant',
    'yak', 'emu', 'jay', 'ram', 'cod', 'hen', 'ape', 'cow',
    'pig', 'rat', 'fly', 'bug', 'wren', 'deer', 'swan', 'toad',
    'wolf', 'bear', 'lynx', 'mole', 'hare', 'seal', 'crab', 'dove'
  );

function IsValidName(const AName: RawUtf8): Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 1 to Length(AName) do
    if not (AName[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-']) then
    begin
      Result := False;
      Exit;
    end;
end;

function GenerateRandomName: RawUtf8;
begin
  Randomize;
  Result := RawUtf8(ADJECTIVES[Random(32)] + '-' + NOUNS[Random(32)]);
end;

procedure InitConfig(var AConfig: TShare7Config);
var
  FolderStr: RawUtf8;
  NameStr: RawUtf8;
  PortStr: RawUtf8;
  CompName: RawUtf8;
begin
  AConfig.Folder := GetCurrentDir;
  AConfig.UdpPort := SHARE7_UDP_PORT;
  AConfig.TcpPort := SHARE7_TCP_PORT;

  if Executable.Command.Get('folder', FolderStr, 'folder to watch and sync') then
  begin
    AConfig.Folder := ExpandFileName(string(FolderStr));
    if not DirectoryExists(AConfig.Folder) then
      raise Exception.CreateFmt('Folder does not exist: %s', [AConfig.Folder]);
  end;

  if Executable.Command.Get('name', NameStr, 'terminal name') then
    AConfig.Name := NameStr;

  if Executable.Command.Get('udp-port', PortStr, 'UDP discovery port') then
    AConfig.UdpPort := StrToIntDef(string(PortStr), AConfig.UdpPort);
  if Executable.Command.Get('tcp-port', PortStr, 'TCP transfer port') then
    AConfig.TcpPort := StrToIntDef(string(PortStr), AConfig.TcpPort);

  if AConfig.Name = '' then
  begin
    CompName := RawUtf8(GetEnvironmentVariable('COMPUTERNAME'));
    if (CompName <> '') and IsValidName(CompName) then
      AConfig.Name := CompName
    else
      AConfig.Name := GenerateRandomName;
  end;

  AConfig.Sound := Executable.Command.Option('sound', 'play sounds on peer events');
  AConfig.Clipboard := Executable.Command.Option('clipboard', 'share clipboard with peers');

  if not IsValidName(AConfig.Name) then
    AConfig.Name := GenerateRandomName;
end;

end.
