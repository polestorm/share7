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
    procedure Init;
  end;

implementation

uses
  System.SysUtils,
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
begin
  Result := True;
  for var I := 1 to Length(AName) do
    if not (AName[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-']) then
      Exit(False);
end;

function GenerateRandomName: RawUtf8;
begin
  Randomize;
  Result := RawUtf8(ADJECTIVES[Random(32)] + '-' + NOUNS[Random(32)]);
end;

procedure TShare7Config.Init;
begin
  Folder := GetCurrentDir;
  UdpPort := SHARE7_UDP_PORT;
  TcpPort := SHARE7_TCP_PORT;

  var FolderStr: RawUtf8;
  if Executable.Command.Get('folder', FolderStr, 'folder to watch and sync') then
  begin
    Folder := ExpandFileName(string(FolderStr));
    if not DirectoryExists(Folder) then
      raise Exception.CreateFmt('Folder does not exist: %s', [Folder]);
  end;

  var NameStr: RawUtf8;
  if Executable.Command.Get('name', NameStr, 'terminal name') then
    Name := NameStr;

  var PortStr: RawUtf8;
  if Executable.Command.Get('udp-port', PortStr, 'UDP discovery port') then
    UdpPort := StrToIntDef(string(PortStr), UdpPort);
  if Executable.Command.Get('tcp-port', PortStr, 'TCP transfer port') then
    TcpPort := StrToIntDef(string(PortStr), TcpPort);

  if Name = '' then
  begin
    var CompName := RawUtf8(GetEnvironmentVariable('COMPUTERNAME'));
    if (CompName <> '') and IsValidName(CompName) then
      Name := CompName
    else
      Name := GenerateRandomName;
  end;

  Sound := Executable.Command.Option('sound', 'play sounds on peer events');

  if not IsValidName(Name) then
    Name := GenerateRandomName;
end;

end.
