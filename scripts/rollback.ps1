<#
.SYNOPSIS
    Restore %UserProfile%\.wslconfig from a backup and restart WSL.

.DESCRIPTION
    Without -BackupPath, uses the newest .wslconfig.pclimit-*.bak written by
    install.ps1/set-limits.ps1. Use -BackupPath for any other backup, e.g. the
    .wslconfig you had before the first wsl2-pagecache-limit install.
    The sysctl.d dirty-page file stays (it is harmless on any kernel); remove it
    with: wsl -u root rm /etc/sysctl.d/90-pclimit-dirty.conf
#>
[CmdletBinding()]
param(
    [string]$BackupPath,
    [switch]$NoShutdown
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
if (-not $BackupPath) {
    $latest = Get-ChildItem -LiteralPath $env:USERPROFILE -Filter '.wslconfig.pclimit-*.bak' -File |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { throw 'No .wslconfig.pclimit-*.bak found; pass -BackupPath.' }
    $BackupPath = $latest.FullName
}
if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) { throw "Backup not found: $BackupPath" }

Copy-Item -LiteralPath $BackupPath -Destination $wslConfig -Force
Write-Output "restored $wslConfig from $BackupPath"
if (-not $NoShutdown) {
    & wsl.exe --shutdown
    if ($LASTEXITCODE -ne 0) { throw 'wsl --shutdown failed.' }
    Write-Output 'WSL shut down; the next start uses the restored settings.'
}
