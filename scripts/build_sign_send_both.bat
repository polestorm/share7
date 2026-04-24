@echo off
setlocal enabledelayedexpansion
echo === Share7 Release ===
echo.

rem --- Build D13 ---
call "%~dp0build.bat" release
if %ERRORLEVEL% NEQ 0 (
  echo.
  echo RELEASE ABORTED: D13 build failed
  exit /b 1
)
echo.

rem --- Build D7 ---
call "%~dp0build_d7.bat" release
if %ERRORLEVEL% NEQ 0 (
  echo.
  echo RELEASE ABORTED: D7 build failed
  exit /b 1
)
echo.

rem --- Sign executables ---
set SIGN=%~dp0sign.bat
set D13_EXE=%~dp0..\program\Share7.exe
set D7_EXE=%~dp0..\program_D7\Share7.exe

echo Signing D13 build...
call "%SIGN%" "%D13_EXE%"
if %ERRORLEVEL% NEQ 0 (
  echo RELEASE ABORTED: D13 signing failed
  exit /b 1
)

echo Signing D7 build...
call "%SIGN%" "%D7_EXE%"
if %ERRORLEVEL% NEQ 0 (
  echo RELEASE ABORTED: D7 signing failed
  exit /b 1
)
echo.

rem --- Rename D7 exe ---
set SMALL_EXE=%~dp0..\program_D7\Share7_small.exe
copy /y "%D7_EXE%" "%SMALL_EXE%" >nul
if errorlevel 1 (
  echo RELEASE ABORTED: Failed to create Share7_small.exe
  exit /b 1
)
echo Renamed D7 build to Share7_small.exe

rem --- Auth ---
call "%~dp0auth.bat"
if "%FTP_HOST%"=="" (
  echo ERROR: auth.bat not found or missing FTP_HOST
  exit /b 1
)

rem --- Create zip ---
set D13_ZIP=%~dp0..\program\Share7.zip
echo Creating Share7.zip...
powershell -Command "Compress-Archive -Path '%D13_EXE%' -DestinationPath '%D13_ZIP%' -Force"
if errorlevel 1 (
  echo   FAILED to create zip
  exit /b 1
)
echo   OK
echo.

rem --- Deploy ---
set ERRORS=0

call :upload "%D13_EXE%" Share7.exe
call :upload "%D13_ZIP%" Share7.zip
call :upload "%SMALL_EXE%" Share7_small.exe

del "%D13_ZIP%"

echo.
if !ERRORS! NEQ 0 (
  echo RELEASE FAILED: !ERRORS! upload(s) failed
  exit /b 1
)
echo RELEASE SUCCESS
exit /b 0

:upload
echo Uploading %2...
curl -s -S --ftp-create-dirs -T %1 "ftp://%FTP_USER%:%FTP_PASS%@%FTP_HOST%%FTP_RDIR%/downloads/%2"
if errorlevel 1 (
  echo   FAILED
  set /a ERRORS+=1
) else (
  echo   OK
)
exit /b 0
