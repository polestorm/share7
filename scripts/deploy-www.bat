@echo off
setlocal enabledelayedexpansion
echo === Deploy www to FTP ===
echo.

call "%~dp0auth.bat"
if "%FTP_HOST%"=="" (
  echo ERROR: auth.bat not found or missing FTP_HOST
  exit /b 1
)

set ERRORS=0

for %%F in ("%FTP_LDIR%\*") do call :upload "%%F" %%~nxF

echo.
if !ERRORS! NEQ 0 (
  echo DEPLOY FAILED: !ERRORS! file^(s^) failed
  exit /b 1
)
echo DEPLOY SUCCESS
exit /b 0

:upload
echo Uploading %2...
curl -s -S --ftp-create-dirs -T %1 "ftp://%FTP_USER%:%FTP_PASS%@%FTP_HOST%%FTP_RDIR%/%2"
if errorlevel 1 (
  echo   FAILED
  set /a ERRORS+=1
) else (
  echo   OK
)
exit /b 0
