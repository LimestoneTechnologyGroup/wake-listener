# Stops the wake listener, stops it starting with Windows, and removes the installed copy.
Get-Process WakeListener -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name WakeListener -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath("Startup")) "Wake listener.lnk") -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\WakeListener" -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "Removed: stopped, won't start with Windows, installed copy deleted."
