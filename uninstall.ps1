# Stops the wake listener, stops it starting with Windows, and removes its settings and log
# (and the copy 1.0.0 installed, with its Run key, if it's still there). Leaves the exe you downloaded.
Get-Process WakeListener -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1
Remove-Item (Join-Path ([Environment]::GetFolderPath("Startup")) "Wake listener.lnk") -ErrorAction SilentlyContinue
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name WakeListener -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\WakeListener" -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "Removed: stopped, won't start with Windows, settings and log deleted."
