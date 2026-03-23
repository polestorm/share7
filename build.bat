@echo off
echo === Share7 Build ===

set MODE=debug
if /i "%1"=="release" set MODE=release
echo Mode: %MODE%
echo.

set RELEASE_FLAGS=
if "%MODE%"=="release" set RELEASE_FLAGS=-$O+ -$R- -$Q- -$D- -$L- -$Y- -$C-

pushd "%~dp0source"

rem Compile icon resource
echo Compiling icon resource...
rc Share7.Icon.rc
if %ERRORLEVEL% NEQ 0 (
  echo WARNING: Icon resource compilation failed, using existing .res
)

call "..\dcc32.bat" -B %RELEASE_FLAGS% Share7.dpr
set BUILD_RESULT=%ERRORLEVEL%
popd

echo.
if %BUILD_RESULT% NEQ 0 (
  echo BUILD FAILED with error code %BUILD_RESULT%
  exit /b %BUILD_RESULT%
)

if exist "%~dp0program\Share7.exe" (
  for %%A in ("%~dp0program\Share7.exe") do echo BUILD SUCCESS: Share7.exe [%%~zA bytes]
) else (
  echo BUILD FAILED: Share7.exe not found
  exit /b 1
)
