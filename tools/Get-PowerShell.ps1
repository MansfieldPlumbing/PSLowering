<#
.SYNOPSIS
    Downloads the pinned PowerShell build into build/cache and returns pwsh.exe.
.DESCRIPTION
    PSLowering is tested on PowerShell 7.7.0-preview.5 (.NET 11) only. The
    pin moves to preview.6 or to the 7.7 release when either is published.
    The archive is verified against the SHA-256 GitHub publishes for the
    release asset before it is extracted.
#>
[CmdletBinding()]
param([string] $ArchivePath)   # an already-downloaded release zip; verified the same way
$ErrorActionPreference = 'Stop'
$version = '7.7.0-preview.5'
$asset = "PowerShell-$version-win-x64.zip"
$sha256 = 'BA727D1890F7DBCBA05286BC0E61FC9F168DE9BA2A1003C4934BCE8E38BBFD1B'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$cache = Join-Path $root "build/cache/pwsh/$version"
$pwsh = Join-Path $cache 'pwsh.exe'
if (Test-Path -LiteralPath $pwsh) { return $pwsh }
$null = New-Item -ItemType Directory -Force -Path $cache
$zip = if ($ArchivePath) { [IO.Path]::GetFullPath($ArchivePath) } else { Join-Path $root "build/cache/pwsh/$asset" }
if (-not $ArchivePath -and -not (Test-Path -LiteralPath $zip)) {
    Invoke-WebRequest -Uri "https://github.com/PowerShell/PowerShell/releases/download/v$version/$asset" -OutFile $zip
}
$actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
if ($actual -ne $sha256) {
    if (-not $ArchivePath) { Remove-Item -LiteralPath $zip }
    throw "$asset SHA-256 $actual does not match the pinned $sha256."
}
Expand-Archive -LiteralPath $zip -DestinationPath $cache
if (-not (Test-Path -LiteralPath $pwsh)) { throw "pwsh.exe missing from $asset." }
$pwsh
