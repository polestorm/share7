@echo off
echo === Deploy Share7.exe to FTP ===
echo.

call "%~dp0auth.bat"
if "%FTP_HOST%"=="" (
  echo ERROR: auth.bat not found or missing FTP_HOST
  exit /b 1
)

set EXE=%~dp0..\program\Share7.exe
if not exist "%EXE%" (
  echo ERROR: Share7.exe not found in program\
  exit /b 1
)

set ZIP=%~dp0..\program\Share7.zip
echo Creating Share7.zip...
powershell -Command "Compress-Archive -Path '%EXE%' -DestinationPath '%ZIP%' -Force"
if errorlevel 1 (
  echo   FAILED to create zip
  exit /b 1
)
echo   OK
echo.

set ERRORS=0

call :upload "%ZIP%" Share7.zip
call :upload "%EXE%" Share7.exe

echo.
if %ERRORS% NEQ 0 (
  echo DEPLOY FAILED
  exit /b 1
)
echo DEPLOY SUCCESS
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
