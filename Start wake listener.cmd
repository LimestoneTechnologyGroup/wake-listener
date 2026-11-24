@echo off
rem Starts the wake listener in a minimized window. To start it with Windows,
rem put a shortcut to this file in your Startup folder (Win+R, shell:startup).
start "Wake listener" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WakeListener.ps1"
