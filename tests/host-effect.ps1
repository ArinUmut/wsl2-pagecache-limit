<#
.SYNOPSIS
    Measure what the page cache limit does to the Windows host: vmmemWSL memory
    while WSL reads a 10 GiB file, with the limits off and on.

.DESCRIPTION
    For each mode (off = 0/0, on = the limits active before the run):
      drop caches, wait for the VM to settle, read the file with pcltest while
      sampling vmmemWSL working set / private bytes every 0.5 s, then record the
      peak and the value 30 s after the read. /proc/buddyinfo is saved too
      (free page reporting returns free blocks to Windows; WSL 3.0.5 boots with
      page_reporting.page_reporting_order=5, i.e. 128 KiB blocks).
    The previous limits are restored at the end.
#>
[CmdletBinding()]
param(
    [string]$Distro,
    [string]$RepoLinux,
    [int]$SettleSeconds = 20
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'

# Distro and repo path default to where this script lives: \\wsl.localhost\<distro>\<repo>\tests
if (-not $Distro -or -not $RepoLinux) {
    $m = [regex]::Match($PSScriptRoot, '^\\\\wsl(?:\.localhost|\$)\\([^\\]+)(\\.+)\\tests$', 'IgnoreCase')
    if (-not $m.Success) { throw 'Run from the repo inside WSL (\\wsl.localhost\<distro>\...\tests) or pass -Distro and -RepoLinux.' }
    if (-not $Distro) { $Distro = $m.Groups[1].Value }
    if (-not $RepoLinux) { $RepoLinux = $m.Groups[2].Value.Replace('\', '/') }
}

function Wsl([string]$cmd) {
    $o = & wsl.exe -d $Distro -u root --exec bash -c $cmd 2>&1
    if ($LASTEXITCODE -ne 0) { throw "wsl: $cmd -> $($o | Out-String)" }
    return ($o | Out-String).Trim()
}
function Vmmem {
    $p = Get-Process -Name 'vmmemWSL', 'vmmem' -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 1
    if (-not $p) { throw 'vmmemWSL process not found' }
    return [pscustomobject]@{ ws = [math]::Round($p.WorkingSet64 / 1MB); priv = [math]::Round($p.PrivateMemorySize64 / 1MB) }
}

$P = '/sys/module/pagecache_limit/parameters'
$oldSoft = Wsl "cat $P/soft_limit"
$oldHard = Wsl "cat $P/hard_limit"
$file = '/root/pclimit-bench/func10g.dat'
Wsl "test -f $file && test -x $RepoLinux/out/pcltest" | Out-Null
$results = @()

try {
    foreach ($mode in @(@('off', '0', '0'), @('on', $oldSoft, $oldHard))) {
        Wsl "echo $($mode[1]) > $P/soft_limit; echo $($mode[2]) > $P/hard_limit; sync; echo 3 > /proc/sys/vm/drop_caches" | Out-Null
        Start-Sleep -Seconds $SettleSeconds
        $before = Vmmem
        $job = Start-Job -ScriptBlock { param($d, $r, $f) $env:WSL_UTF8 = '1'; & wsl.exe -d $d -u root --exec "$r/out/pcltest" read $f } -ArgumentList $Distro, $RepoLinux, $file
        $peakWs = 0; $peakPriv = 0
        while ($job.State -eq 'Running') {
            $v = Vmmem
            if ($v.ws -gt $peakWs) { $peakWs = $v.ws }
            if ($v.priv -gt $peakPriv) { $peakPriv = $v.priv }
            Start-Sleep -Milliseconds 500
        }
        $readOut = (Receive-Job $job | Out-String).Trim(); Remove-Job $job
        $after0 = Vmmem
        $buddy = Wsl 'cat /proc/buddyinfo'
        Start-Sleep -Seconds 30
        $after30 = Vmmem
        $row = [pscustomobject]@{
            mode = $mode[0]; soft = $mode[1]; hard = $mode[2]
            before_ws_mb = $before.ws; peak_ws_mb = $peakWs; end_ws_mb = $after0.ws; after30s_ws_mb = $after30.ws
            before_priv_mb = $before.priv; peak_priv_mb = $peakPriv; after30s_priv_mb = $after30.priv
            read = $readOut
        }
        $results += $row
        $row | Format-List | Out-String | Write-Output
        Write-Output "buddyinfo after read ($($mode[0])):`n$buddy"
    }
} finally {
    Wsl "echo $oldSoft > $P/soft_limit; echo $oldHard > $P/hard_limit" | Out-Null
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outUnc = "\\wsl.localhost\$Distro$($RepoLinux.Replace('/', '\'))\results\host-effect-$stamp.json"
$results | ConvertTo-Json | Set-Content -LiteralPath $outUnc -Encoding utf8
Write-Output "results: $outUnc"
