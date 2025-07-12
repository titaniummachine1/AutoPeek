@echo off

echo Copying Lua scripts to %LOCALAPPDATA%...

copy /Y "%~dp0*.lua" "%LOCALAPPDATA%\"

echo All Lua scripts copied successfully!
pause
exit