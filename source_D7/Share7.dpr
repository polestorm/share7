program Share7;

{$APPTYPE CONSOLE}

// Minimize RTTI footprint - safe for console app with no LiveBindings
{$IF CompilerVersion >= 21.0}
  {$WEAKLINKRTTI ON}
  {$RTTI EXPLICIT METHODS([]) PROPERTIES([]) FIELDS([])}
{$IFEND}

// Application icon
{$R Share7.Icon.res}
// Windows application manifest (compatibility, execution level)
{$R Share7.Manifest.res}
// Version info (reduces AV false positives)
{$R Share7.Version.res}

uses
  Windows,
  SysUtils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  Share7.Core.Types in 'Share7.Core.Types.pas',
  Share7.Core.Config in 'Share7.Core.Config.pas',
  Share7.Core.App in 'Share7.Core.App.pas',
  Share7.Fs.Scanner in 'Share7.Fs.Scanner.pas',
  Share7.Fs.Watcher in 'Share7.Fs.Watcher.pas',
  Share7.Net.Protocol in 'Share7.Net.Protocol.pas',
  Share7.Net.Discovery in 'Share7.Net.Discovery.pas',
  Share7.Net.Transfer in 'Share7.Net.Transfer.pas',
  Share7.Sync.Engine in 'Share7.Sync.Engine.pas',
  Share7.Core.Captions in 'Share7.Core.Captions.pas',
  Share7.Clipboard in 'Share7.Clipboard.pas';

var
  App: TShare7App;
  Mutex: THandle;
  MutexName: string;
begin
  SetConsoleOutputCP(CP_UTF8);

  // Prevent multiple instances in the same folder
  MutexName := 'Share7_' + StringReplace(
    StringReplace(UpperCase(ExtractFilePath(ParamStr(0))),
      '\', '_', [rfReplaceAll]),
      ':', '', [rfReplaceAll]);
  Mutex := CreateMutex(nil, False, PChar(MutexName));
  if GetLastError = ERROR_ALREADY_EXISTS then
  begin
    ConsoleWrite('Share7 is already running in this folder.', ccLightRed);
    ExitCode := 1;
    CloseHandle(Mutex);
    Exit;
  end;

  try
    App := TShare7App.Create;
    try
      App.Run;
    finally
      App.Free;
    end;
  except
    on E: Exception do
    begin
      ConsoleWrite(FormatUtf8(SCaptionFatal, [RawUtf8(E.Message)]), ccLightRed);
      ExitCode := 1;
    end;
  end;
  CloseHandle(Mutex);
end.
