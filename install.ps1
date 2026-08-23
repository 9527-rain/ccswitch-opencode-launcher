[CmdletBinding()]
param(
  [string]$InstallDir = (Join-Path $env:APPDATA "npm"),
  [switch]$NoPathUpdate,
  [switch]$Latest,
  [switch]$Uninstall,
  [string]$ReleaseVersion
)

$ErrorActionPreference = "Stop"
if ($Latest -and $ReleaseVersion) { throw "Use either -Latest or -ReleaseVersion, not both" }
$releaseTag = if ($ReleaseVersion) { $ReleaseVersion } elseif ($env:CCSWITCH_LAUNCHER_VERSION) { $env:CCSWITCH_LAUNCHER_VERSION } else { "v0.4.0" }
if ($Latest -and -not $ReleaseVersion -and -not $env:CCSWITCH_LAUNCHER_VERSION) {
  try {
    $releaseTag = [string](Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/9527-rain/ccswitch-opencode-launcher/releases/latest").tag_name
  } catch {
    throw "Could not resolve the latest GitHub Release: $($_.Exception.Message)"
  }
}
if ($releaseTag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') { throw "Invalid release tag: $releaseTag" }
$releaseBase = if ($env:CCSWITCH_LAUNCHER_RELEASE_BASE) { $env:CCSWITCH_LAUNCHER_RELEASE_BASE.TrimEnd("/") } else { "https://github.com/9527-rain/ccswitch-opencode-launcher/releases/download/$releaseTag" }
$scriptPath = $MyInvocation.MyCommand.Path
$sourceDir = if ($scriptPath) { Split-Path -Parent $scriptPath } else { $null }
$temporarySource = $false

if ($Uninstall) {
  foreach ($name in @("opencode-ccswitch.ps1", "opencode-ccswitch.cmd", "install.ps1")) {
    Remove-Item -LiteralPath (Join-Path $InstallDir $name) -Force -ErrorAction SilentlyContinue
  }
  Write-Host "Uninstalled opencode-ccswitch from $InstallDir"
  exit 0
}

function Get-ExpectedSha256([string]$ChecksumFile, [string]$AssetName) {
  $line = Get-Content -LiteralPath $ChecksumFile | Where-Object { $_ -match "\s$([regex]::Escape($AssetName))$" } | Select-Object -First 1
  if (-not $line) { throw "No SHA256 checksum was published for $AssetName" }
  return ($line -split '\s+')[0].ToLowerInvariant()
}

if ($Latest -or $ReleaseVersion -or -not $sourceDir -or -not (Test-Path -LiteralPath (Join-Path $sourceDir "opencode-ccswitch.ps1"))) {
  $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("ccswitch-opencode-install-" + [guid]::NewGuid().ToString("N"))
  $archiveName = "ccswitch-opencode-launcher-$releaseTag-windows.zip"
  $archivePath = Join-Path $temporaryRoot $archiveName
  $checksumPath = Join-Path $temporaryRoot "checksums.txt"
  $sourceDir = Join-Path $temporaryRoot "payload"
  New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
  $temporarySource = $true
  try {
    Invoke-WebRequest -UseBasicParsing -Uri "$releaseBase/$archiveName" -OutFile $archivePath
    Invoke-WebRequest -UseBasicParsing -Uri "$releaseBase/checksums.txt" -OutFile $checksumPath
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
    if ($actual -ne (Get-ExpectedSha256 $checksumPath $archiveName)) { throw "SHA256 verification failed for $archiveName" }
    Expand-Archive -LiteralPath $archivePath -DestinationPath $sourceDir -Force
  } catch {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    throw "Could not download or verify $releaseTag`: $($_.Exception.Message)"
  }
}

try {
  New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $sourceDir "opencode-ccswitch.ps1") -Destination (Join-Path $InstallDir "opencode-ccswitch.ps1") -Force
  Copy-Item -LiteralPath (Join-Path $sourceDir "opencode-ccswitch.cmd") -Destination (Join-Path $InstallDir "opencode-ccswitch.cmd") -Force
  Copy-Item -LiteralPath (Join-Path $sourceDir "install.ps1") -Destination (Join-Path $InstallDir "install.ps1") -Force

  if (-not $NoPathUpdate) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @($userPath -split ";" | Where-Object { $_ })
    $normalized = $parts | ForEach-Object { $_.TrimEnd("\") }
    if ($normalized -notcontains $InstallDir.TrimEnd("\")) {
      [Environment]::SetEnvironmentVariable("Path", (($parts + $InstallDir) -join ";"), "User")
      Write-Host "Added $InstallDir to the user PATH. Open a new terminal to use opencode-ccswitch."
    }
  }
  Write-Host "Installed opencode-ccswitch $releaseTag to $InstallDir"
  Write-Host "Run: opencode-ccswitch"
} finally {
  if ($temporarySource) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
