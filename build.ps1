# Compiles WakeListener.exe with the C# compiler that ships with Windows.
$ErrorActionPreference = "Stop"
$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "The .NET Framework 4 compiler wasn't found at $csc." }
$wpf = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\WPF"
$speech = (Get-ChildItem "$env:WINDIR\Microsoft.NET\assembly\GAC_MSIL\System.Speech" -Recurse -Filter System.Speech.dll | Select-Object -First 1).FullName
& $csc /nologo /target:winexe /optimize+ /out:"$PSScriptRoot\WakeListener.exe" `
  /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll /reference:"$speech" `
  "$PSScriptRoot\WakeListener.cs"
if ($LASTEXITCODE -ne 0) { throw "The build failed." }
Write-Output "Built $PSScriptRoot\WakeListener.exe"
