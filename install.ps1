# Builds the exe and runs it: it installs itself into %LOCALAPPDATA%\WakeListener,
# starts with Windows, and runs from there. (A downloaded WakeListener.exe does the same on a double-click.)
$ErrorActionPreference = "Stop"
& "$PSScriptRoot\build.ps1"
explorer.exe "$PSScriptRoot\WakeListener.exe"
