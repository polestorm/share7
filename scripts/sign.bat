@echo off
if "%~1"=="" (
  echo Usage: sign.bat ^<file_to_sign^>
  exit /b 1
)
"C:\Users\storm\Documents\Projects\tools\signtool.exe" sign /sha1 a634df956bbc1ad8b4ef7ece5f25532815ac24b6 /fd sha256 /tr http://timestamp.digicert.com /td sha256 "%~1"
