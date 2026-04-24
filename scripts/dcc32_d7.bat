@echo off
set COMMON=%USERPROFILE%\Documents\Projects\common
"C:\Program Files (x86)\Borland\Delphi7\Bin\dcc32.exe" ^
  -U%COMMON%\mORMot2\src\core ^
  -U%COMMON%\mORMot2\src\net ^
  -U%COMMON%\mORMot2\src\crypt ^
  -U%COMMON%\mORMot2\src\lib ^
  -U%COMMON%\mORMot2\static\delphi ^
  -N..\dcu -E..\program_D7 ^
  %*
