program Share7;

{$APPTYPE CONSOLE}

// Minimize RTTI footprint - safe for console app with no LiveBindings
{$IF CompilerVersion >= 21.0}
  {$WEAKLINKRTTI ON}
  {$RTTI EXPLICIT METHODS([]) PROPERTIES([]) FIELDS([])}
{$IFEND}

// Strip relocation table from EXE (not needed for .exe, only .dll)
{$SetPEFlags 1} // IMAGE_FILE_RELOCS_STRIPPED

// Application icon
{$R Share7.Icon.res}

uses
  System.SysUtils,
  mormot.core.base,
  mormot.core.os,
  Share7.Core.Types in 'Share7.Core.Types.pas',
  Share7.Core.Config in 'Share7.Core.Config.pas',
  Share7.Core.App in 'Share7.Core.App.pas',
  Share7.Fs.Scanner in 'Share7.Fs.Scanner.pas',
  Share7.Fs.Watcher in 'Share7.Fs.Watcher.pas',
  Share7.Net.Protocol in 'Share7.Net.Protocol.pas',
  Share7.Net.Discovery in 'Share7.Net.Discovery.pas',
  Share7.Net.Transfer in 'Share7.Net.Transfer.pas',
  Share7.Sync.Engine in 'Share7.Sync.Engine.pas';

begin
  try
    var App := TShare7App.Create;
    try
      App.Run;
    finally
      App.Free;
    end;
  except
    on E: Exception do
    begin
      ConsoleWrite(RawUtf8('FATAL: ' + E.Message), ccLightRed);
      ExitCode := 1;
    end;
  end;
end.
