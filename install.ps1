[CmdletBinding()]
param(
  [string]$InstallDir = (Join-Path $env:APPDATA "npm"),
  [switch]$NoPathUpdate
)

$ErrorActionPreference = "Stop"
$releaseTag = "v0.1.1"
$rawBase = if ($env:CCSWITCH_LAUNCHER_RAW_BASE) { $env:CCSWITCH_LAUNCHER_RAW_BASE.TrimEnd("/") } else { "https://raw.githubusercontent.com/9527-rain/ccswitch-opencode-launcher/$releaseTag" }
$scriptPath = $MyInvocation.MyCommand.Path
$sourceDir = if ($scriptPath) { Split-Path -Parent $scriptPath } else { $null }
$temporarySource = $false

if (-not $sourceDir -or -not (Test-Path -LiteralPath (Join-Path $sourceDir "opencode-ccswitch.ps1"))) {
  $sourceDir = Join-Path ([IO.Path]::GetTempPath()) ("ccswitch-opencode-install-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
  $temporarySource = $true
  try {
    Invoke-WebRequest -UseBasicParsing -Uri "$rawBase/opencode-ccswitch.ps1" -OutFile (Join-Path $sourceDir "opencode-ccswitch.ps1")
    Invoke-WebRequest -UseBasicParsing -Uri "$rawBase/opencode-ccswitch.cmd" -OutFile (Join-Path $sourceDir "opencode-ccswitch.cmd")
  } catch {
    Remove-Item -LiteralPath $sourceDir -Recurse -Force -ErrorAction SilentlyContinue
    throw "Could not download launcher files from $rawBase`: $($_.Exception.Message)"
  }
}

try {
  New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $sourceDir "opencode-ccswitch.ps1") -Destination (Join-Path $InstallDir "opencode-ccswitch.ps1") -Force
  Copy-Item -LiteralPath (Join-Path $sourceDir "opencode-ccswitch.cmd") -Destination (Join-Path $InstallDir "opencode-ccswitch.cmd") -Force

  if (-not $NoPathUpdate) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @($userPath -split ";" | Where-Object { $_ })
    $normalized = $parts | ForEach-Object { $_.TrimEnd("\") }
    if ($normalized -notcontains $InstallDir.TrimEnd("\")) {
      [Environment]::SetEnvironmentVariable("Path", (($parts + $InstallDir) -join ";"), "User")
      Write-Host "Added $InstallDir to the user PATH. Open a new terminal to use opencode-ccswitch."
    }
  }
  Write-Host "Installed opencode-ccswitch to $InstallDir"
  Write-Host "Run: opencode-ccswitch"
} finally {
  if ($temporarySource) { Remove-Item -LiteralPath $sourceDir -Recurse -Force -ErrorAction SilentlyContinue }
}
