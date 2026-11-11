<#
.SYNOPSIS
    Change the page cache limits and dirty-page bounds now and keep them across WSL restarts.

.DESCRIPTION
    Applies the new values immediately inside WSL (no restart) through
    scripts/pclimit.sh, rewrites /etc/sysctl.d/90-pclimit-dirty.conf for the
    dirty values, and rewrites the pagecache_limit.* tokens of
    kernelCommandLine in %UserProfile%\.wslconfig (after a byte backup) for the
    limits. Omitted parameters are left unchanged.

.EXAMPLE
    .\set-limits.ps1 -Soft 3G -Hard 4G
    .\set-limits.ps1 -DirtyBytes 2G -DirtyBackgroundBytes 512M
    .\set-limits.ps1 -Soft 0 -Hard 0          # turn the limits off
#>
[CmdletBinding()]
param(
    [string]$Soft,
    [string]$Hard,
    [string]$DirtyBytes,
    [string]$DirtyBackgroundBytes,
    [string]$Distro = 'Ubuntu-24.04',
    [string]$RepoLinux = '/root/work/wsl2-pagecache-limit'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'

foreach ($p in @(@('Soft', $Soft), @('Hard', $Hard), @('DirtyBytes', $DirtyBytes), @('DirtyBackgroundBytes', $DirtyBackgroundBytes))) {
    if ($p[1] -and $p[1] -notmatch '^[0-9]+[KkMmGgTt]?$') { throw "$($p[0]) must look like 0, 512M, 3G (got '$($p[1])')." }
}
if (-not ($Soft -or $Hard -or $DirtyBytes -or $DirtyBackgroundBytes)) { throw 'Nothing to change.' }

# 1. runtime (and sysctl.d for the dirty values)
$cmd = @('bash', "$RepoLinux/scripts/pclimit.sh", 'set')
if ($Soft) { $cmd += @('--soft', $Soft) }
if ($Hard) { $cmd += @('--hard', $Hard) }
if ($DirtyBytes) { $cmd += @('--dirty', $DirtyBytes) }
if ($DirtyBackgroundBytes) { $cmd += @('--dirty-bg', $DirtyBackgroundBytes) }
if ($DirtyBytes -or $DirtyBackgroundBytes) { $cmd += '--persist' }
$out = & wsl.exe -d $Distro -u root --exec @cmd 2>&1
if ($LASTEXITCODE -ne 0) { throw "pclimit.sh failed: $($out | Out-String)" }
Write-Output ($out | Out-String).Trim()

# 2. .wslconfig kernelCommandLine for the limits
if ($Soft -or $Hard) {
    $wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
    $raw = [IO.File]::ReadAllText($wslConfig)
    $backup = "$wslConfig.pclimit-$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
    Copy-Item -LiteralPath $wslConfig -Destination $backup -Force
    $m = [regex]::Match($raw, '(?im)^[ \t]*kernelCommandLine[ \t]*=([^\r\n]*)')
    if (-not $m.Success) { throw 'kernelCommandLine not found in .wslconfig; run install.ps1 first.' }
    $tokens = $m.Groups[1].Value.Trim() -split '\s+' | Where-Object { $_ }
    $keep = @($tokens | Where-Object { $_ -notlike 'pagecache_limit.*' })
    $curSoft = ($tokens | Where-Object { $_ -like 'pagecache_limit.soft_limit=*' } | Select-Object -Last 1)
    $curHard = ($tokens | Where-Object { $_ -like 'pagecache_limit.hard_limit=*' } | Select-Object -Last 1)
    $newSoft = if ($Soft) { "pagecache_limit.soft_limit=$Soft" } else { $curSoft }
    $newHard = if ($Hard) { "pagecache_limit.hard_limit=$Hard" } else { $curHard }
    $keep += @($newSoft, $newHard | Where-Object { $_ })
    $line = 'kernelCommandLine=' + ($keep -join ' ')
    $raw = $raw.Substring(0, $m.Index) + $line + $raw.Substring($m.Index + $m.Length)
    [IO.File]::WriteAllText($wslConfig, $raw, [Text.UTF8Encoding]::new($false))
    Write-Output "wslconfig: $line (backup: $backup)"
}
