@echo off
set COMMON=%USERPROFILE%\Documents\Projects\common
"C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc32.exe" ^
  -NSSystem;Winapi;System.Win ^
  -U%COMMON%\mORMot2\src\core ^
  -U%COMMON%\mORMot2\src\net ^
  -U%COMMON%\mORMot2\src\crypt ^
  -U%COMMON%\mORMot2\src\lib ^
  -U%COMMON%\mORMot2\static\delphi ^
  -N..\dcu -E..\program ^
  %*
