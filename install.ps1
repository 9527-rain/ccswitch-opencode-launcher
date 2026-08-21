[CmdletBinding()]
param(
  [string]$InstallDir = (Join-Path $env:APPDATA "npm")
)

$ErrorActionPreference = "Stop"
$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceDir "opencode-ccswitch.ps1") -Destination (Join-Path $InstallDir "opencode-ccswitch.ps1") -Force
Copy-Item -LiteralPath (Join-Path $sourceDir "opencode-ccswitch.cmd") -Destination (Join-Path $InstallDir "opencode-ccswitch.cmd") -Force
Write-Host "Installed opencode-ccswitch to $InstallDir"
Write-Host "Run: opencode-ccswitch"
