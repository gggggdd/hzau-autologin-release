@echo off
rem HZAU Campus Network Auto Login - one-click installer
rem Double click this file. It will ask for admin permission (UAC) by itself.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
if errorlevel 1 (
  echo.
  echo Installation failed. Please read the message above.
)
echo.
pause
