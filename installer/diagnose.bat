@echo off
rem HZAU-AutoLogin diagnose tool - double click to run.
rem Important: do NOT "Run as administrator"; use the account you normally log in with.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose.ps1" %*
echo.
pause
