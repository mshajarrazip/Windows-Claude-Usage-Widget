@echo off
rem Double-click to install (or update) the Windows Claude Usage Widget.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
