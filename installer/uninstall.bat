@echo off
rem HZAU Campus Network Auto Login - uninstall
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall
echo.
pause
