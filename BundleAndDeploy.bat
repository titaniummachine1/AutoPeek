@echo off

set "TARGET=%LOCALAPPDATA%\lua"
if not exist "%TARGET%" mkdir "%TARGET%"
echo Copying Lua scripts to %TARGET%...

copy /Y "%~dp0*.lua" "%TARGET%\" >nul

if not exist "%TARGET%\autopeek" mkdir "%TARGET%\autopeek"
copy /Y "%~dp0autopeek\*.lua" "%TARGET%\autopeek\" >nul

echo All Lua scripts copied successfully!
exit /b 0