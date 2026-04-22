@echo off

set "TARGET=%LOCALAPPDATA%\lua"
if not exist "%TARGET%" mkdir "%TARGET%"
echo Copying Lua scripts to %TARGET%...

copy /Y "%~dp0*.lua" "%TARGET%\" >nul

echo All Lua scripts copied successfully!
exit /b 0