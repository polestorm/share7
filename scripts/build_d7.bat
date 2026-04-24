@echo off
echo === Share7 Build (Delphi 7) ===

set MODE=release
if /i "%1"=="debug" set MODE=debug
echo Mode: %MODE%
echo.

set RELEASE_FLAGS=
if "%MODE%"=="release" set RELEASE_FLAGS=-$O+ -$R- -$Q- -$D- -$L- -$Y- -$C-

pushd "%~dp0..\source_D7"

call "..\scripts\dcc32_d7.bat" -B %RELEASE_FLAGS% Share7.dpr
set BUILD_RESULT=%ERRORLEVEL%
popd

echo.
if %BUILD_RESULT% NEQ 0 (
  echo BUILD FAILED with error code %BUILD_RESULT%
  exit /b %BUILD_RESULT%
)

if exist "%~dp0..\program_D7\Share7.exe" (
  for %%A in ("%~dp0..\program_D7\Share7.exe") do echo BUILD SUCCESS: Share7.exe [%%~zA bytes]
) else (
  echo BUILD FAILED: Share7.exe not found
  exit /b 1
)
