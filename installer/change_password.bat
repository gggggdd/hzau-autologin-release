@echo off
rem Change the saved campus network password without reinstalling.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0change_password.ps1" %*
