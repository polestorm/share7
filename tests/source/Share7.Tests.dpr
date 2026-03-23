program Share7.Tests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  mormot.core.base,
  mormot.core.os,
  Share7.Core.Types in '..\..\source\Share7.Core.Types.pas',
  Share7.Core.Config in '..\..\source\Share7.Core.Config.pas',
  Share7.Fs.Scanner in '..\..\source\Share7.Fs.Scanner.pas',
  Share7.Net.Protocol in '..\..\source\Share7.Net.Protocol.pas',
  Share7.Tests.Protocol in 'Share7.Tests.Protocol.pas',
  Share7.Tests.Scanner in 'Share7.Tests.Scanner.pas';

var
  Passed, Failed: Integer;

procedure RunTest(const AName: string; ATestProc: TProc);
begin
  try
    ATestProc;
    Inc(Passed);
    ConsoleWrite(RawUtf8('  PASS: ' + AName), ccLightGreen);
  except
    on E: Exception do
    begin
      Inc(Failed);
      ConsoleWrite(RawUtf8('  FAIL: ' + AName + ' - ' + E.Message), ccLightRed);
    end;
  end;
end;

begin
  Passed := 0;
  Failed := 0;

  ConsoleWrite('Share7 Unit Tests', ccWhite);
  ConsoleWrite('', ccLightGray);

  ConsoleWrite('--- Protocol Tests ---', ccYellow);
  RunTest('UDP encode/decode roundtrip', Share7.Tests.Protocol.TestUdpRoundtrip);
  RunTest('UDP decode rejects bad magic', Share7.Tests.Protocol.TestUdpBadMagic);
  RunTest('UDP decode rejects short data', Share7.Tests.Protocol.TestUdpShortData);
  RunTest('FileList encode/decode roundtrip', Share7.Tests.Protocol.TestFileListRoundtrip);
  RunTest('FileList empty', Share7.Tests.Protocol.TestFileListEmpty);

  ConsoleWrite('', ccLightGray);
  ConsoleWrite('--- Scanner Tests ---', ccYellow);
  RunTest('ShouldExclude patterns', Share7.Tests.Scanner.TestExcludePatterns);
  RunTest('FormatFileSize', Share7.Tests.Scanner.TestFormatFileSize);
  RunTest('FindEntry', Share7.Tests.Scanner.TestFindEntry);

  ConsoleWrite('', ccLightGray);
  ConsoleWrite(RawUtf8('Results: ' + IntToStr(Passed) + ' passed, ' +
    IntToStr(Failed) + ' failed'), ccWhite);

  if Failed > 0 then
    ExitCode := 1;
end.
