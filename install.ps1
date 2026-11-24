# Builds the exe and starts it from this folder. To have it start with Windows,
# right-click the tray icon and tick "Start with Windows".
$ErrorActionPreference = "Stop"
& "$PSScriptRoot\build.ps1"
explorer.exe "$PSScriptRoot\WakeListener.exe"
