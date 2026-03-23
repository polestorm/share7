@echo off
echo === Share7 Tests Build ===
echo.

set COMMON=%USERPROFILE%\Documents\Projects\common

pushd "%~dp0source"
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc32.exe" ^
  -NSSystem;Winapi;System.Win ^
  -U%COMMON%\mORMot2\src\core ^
  -U%COMMON%\mORMot2\src\net ^
  -U%COMMON%\mORMot2\src\crypt ^
  -U%COMMON%\mORMot2\src\lib ^
  -U%COMMON%\mORMot2\static\delphi ^
  -U..\..\source ^
  -N..\dcu -E..\program ^
  -B Share7.Tests.dpr
set BUILD_RESULT=%ERRORLEVEL%
popd

echo.
if %BUILD_RESULT% NEQ 0 (
  echo BUILD FAILED with error code %BUILD_RESULT%
  exit /b %BUILD_RESULT%
)

if exist "%~dp0program\Share7.Tests.exe" (
  echo BUILD SUCCESS: program\Share7.Tests.exe
) else (
  echo BUILD FAILED: Share7.Tests.exe not found
  exit /b 1
)
