<#
.SYNOPSIS
    Install a wsl2-pagecache-limit kernel build into WSL with a byte backup and automatic rollback.

.DESCRIPTION
    Dry-run by default (prints what it would do). With -Apply it:
      1. copies bzImage + modules.vhdx from the WSL build output to
         %UserProfile%\.wsl-kernels\<kernel release>\
      2. installs config/90-pclimit-dirty.conf into /etc/sysctl.d/ of the distro
      3. backs up %UserProfile%\.wslconfig byte-for-byte
      4. sets kernel=, kernelModules= and the pagecache_limit.* tokens of
         kernelCommandLine= in [wsl2] (other tokens and keys are preserved;
         memory= and swap= are asserted unchanged)
      5. runs wsl --shutdown, boots the distro and runs tests/validate.sh
      6. on any failure restores the backup bytes and shuts WSL down again

.EXAMPLE
    .\install.ps1 -Tag linux-msft-wsl-6.18.58.1 -Soft 3G -Hard 4G -Apply
#>
[CmdletBinding()]
param(
    [string]$Tag,
    [string]$Soft = '3G',
    [string]$Hard = '4G',
    [string]$Distro,
    [string]$RepoLinux,
    [string]$KernelRoot = (Join-Path $env:USERPROFILE '.wsl-kernels'),
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'

# Distro and repo path default to where this script lives: \\wsl.localhost\<distro>\<repo>\scripts
if (-not $Distro -or -not $RepoLinux) {
    $m = [regex]::Match($PSScriptRoot, '^\\\\wsl(?:\.localhost|\$)\\([^\\]+)(\\.+)\\scripts$', 'IgnoreCase')
    if (-not $m.Success) { throw 'Run from the repo inside WSL (\\wsl.localhost\<distro>\...\scripts) or pass -Distro and -RepoLinux.' }
    if (-not $Distro) { $Distro = $m.Groups[1].Value }
    if (-not $RepoLinux) { $RepoLinux = $m.Groups[2].Value.Replace('\', '/') }
}

function Assert-Size([string]$Value, [string]$Name) {
    if ($Value -notmatch '^[0-9]+[KkMmGgTt]?$') { throw "$Name must look like 0, 512M, 3G (got '$Value')." }
}
function Escape-WslConfigPath([string]$Path) { return $Path.Replace('\', '\\') }
function Invoke-Wsl([string[]]$ArgList) {
    $out = & wsl.exe -d $Distro -u root --exec @ArgList 2>&1
    if ($LASTEXITCODE -ne 0) { throw "wsl --exec $($ArgList -join ' ') failed ($LASTEXITCODE): $($out | Out-String)" }
    return $out
}

Assert-Size $Soft 'Soft'
Assert-Size $Hard 'Hard'
if (-not $Tag) {
    $Tag = (Invoke-Wsl @('cat', "$RepoLinux/patches/BASE_TAG") | Out-String).Trim()
}
if ($Tag -notmatch '^linux-msft-wsl-[0-9.]+$') { throw "Unexpected tag '$Tag'." }

$outLinux = "$RepoLinux/out/$Tag-release"
$outUnc = "\\wsl.localhost\$Distro" + $outLinux.Replace('/', '\')
$buildInfo = Get-Content -LiteralPath (Join-Path $outUnc 'BUILDINFO') -ErrorAction Stop
$release = ($buildInfo | Where-Object { $_ -like 'kernel_release=*' }) -replace '^kernel_release=', ''
if (-not $release) { throw "kernel_release missing in $outUnc\BUILDINFO" }

$srcBz = Join-Path $outUnc 'build\arch\x86\boot\bzImage'
$srcVhdx = Join-Path $outUnc 'modules.vhdx'
foreach ($f in @($srcBz, $srcVhdx)) { if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "Missing build artifact: $f" } }

$dstDir = Join-Path $KernelRoot $release
$dstBz = Join-Path $dstDir 'bzImage'
$dstVhdx = Join-Path $dstDir 'modules.vhdx'
$wslConfig = Join-Path $env:USERPROFILE '.wslconfig'

Write-Output "tag=$Tag"
Write-Output "kernel_release=$release"
Write-Output "install_dir=$dstDir"
Write-Output "limits soft=$Soft hard=$Hard"
if (-not $Apply) {
    Write-Output 'dry-run: nothing copied, .wslconfig untouched, WSL not restarted (use -Apply)'
    exit 0
}

# 1. artifacts
New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
Copy-Item -LiteralPath $srcBz -Destination $dstBz -Force
Copy-Item -LiteralPath $srcVhdx -Destination $dstVhdx -Force
foreach ($pair in @(@($srcBz, $dstBz), @($srcVhdx, $dstVhdx))) {
    $a = (Get-FileHash -Algorithm SHA256 -LiteralPath $pair[0]).Hash
    $b = (Get-FileHash -Algorithm SHA256 -LiteralPath $pair[1]).Hash
    if ($a -ne $b) { throw "Copy verification failed for $($pair[1])" }
    Write-Output "copied $($pair[1]) sha256=$($b.ToLowerInvariant())"
}

# 2. dirty-page sysctl (applies at boot through systemd-sysctl)
Invoke-Wsl @('install', '-m', '0644', "$RepoLinux/config/90-pclimit-dirty.conf", '/etc/sysctl.d/90-pclimit-dirty.conf') | Out-Null

# 3. backup
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "$wslConfig.pclimit-$timestamp.bak"
if (Test-Path -LiteralPath $wslConfig -PathType Leaf) {
    Copy-Item -LiteralPath $wslConfig -Destination $backup -Force
} else {
    New-Item -ItemType File -Path $backup -Force | Out-Null
}
Write-Output "backup=$backup"

try {
    # 4. edit [wsl2]
    $raw = if (Test-Path -LiteralPath $wslConfig -PathType Leaf) { [IO.File]::ReadAllText($wslConfig) } else { '' }
    $nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $memBefore = ([regex]::Match($raw, '(?im)^[ \t]*memory[ \t]*=[^\r\n]*')).Value
    $swapBefore = ([regex]::Match($raw, '(?im)^[ \t]*swap[ \t]*=[^\r\n]*')).Value
    if ($raw -notmatch '(?im)^[ \t]*\[wsl2\][ \t]*$') {
        if ($raw.Length -gt 0 -and -not $raw.EndsWith($nl)) { $raw += $nl }
        $raw += "[wsl2]$nl"
    }
    $m = [regex]::Match($raw, '(?ims)^[ \t]*\[wsl2\][ \t]*$.*?(?=^[ \t]*\[|\z)')
    if (-not $m.Success) { throw 'Could not locate the [wsl2] section.' }
    $section = $m.Value
    if (-not $section.EndsWith($nl)) { $section += $nl }

    function Set-Key([string]$Sec, [string]$Key, [string]$Value) {
        $pattern = "(?im)^[ \t]*$Key[ \t]*=[^\r\n]*"
        if ([regex]::IsMatch($Sec, $pattern)) {
            return [regex]::Replace($Sec, $pattern, { param($x) "$Key=$Value" })
        }
        return $Sec + "$Key=$Value$nl"
    }

    $section = Set-Key $section 'kernel' (Escape-WslConfigPath $dstBz)
    $section = Set-Key $section 'kernelModules' (Escape-WslConfigPath $dstVhdx)
    $cmdMatch = [regex]::Match($section, '(?im)^[ \t]*kernelCommandLine[ \t]*=([^\r\n]*)')
    $tokens = @()
    if ($cmdMatch.Success) {
        $tokens = $cmdMatch.Groups[1].Value.Trim() -split '\s+' | Where-Object { $_ -and $_ -notlike 'pagecache_limit.*' }
    }
    $tokens += "pagecache_limit.soft_limit=$Soft"
    $tokens += "pagecache_limit.hard_limit=$Hard"
    $section = Set-Key $section 'kernelCommandLine' ($tokens -join ' ')

    $raw = $raw.Substring(0, $m.Index) + $section + $raw.Substring($m.Index + $m.Length)
    [IO.File]::WriteAllText($wslConfig, $raw, [Text.UTF8Encoding]::new($false))

    $after = [IO.File]::ReadAllText($wslConfig)
    if ($memBefore -and ([regex]::Match($after, '(?im)^[ \t]*memory[ \t]*=[^\r\n]*')).Value -ne $memBefore) { throw 'memory= changed unexpectedly.' }
    if ($swapBefore -and ([regex]::Match($after, '(?im)^[ \t]*swap[ \t]*=[^\r\n]*')).Value -ne $swapBefore) { throw 'swap= changed unexpectedly.' }

    # 5. restart and validate
    & wsl.exe --shutdown
    if ($LASTEXITCODE -ne 0) { throw 'wsl --shutdown failed.' }
    Start-Sleep -Seconds 10
    $probe = & wsl.exe -d $Distro -u root --exec bash "$RepoLinux/tests/validate.sh" --release $release --soft $Soft --hard $Hard 2>&1
    $probeText = ($probe | Out-String).Trim()
    Write-Output $probeText
    if ($LASTEXITCODE -ne 0) { throw "post-install validation failed" }
    Write-Output "installed=$release"
    Write-Output "active_wslconfig_sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $wslConfig).Hash.ToLowerInvariant())"
} catch {
    $err = ($_ | Out-String).Trim()
    Copy-Item -LiteralPath $backup -Destination $wslConfig -Force
    & wsl.exe --shutdown
    Write-Warning "Install failed; restored .wslconfig from $backup and shut WSL down. Error: $err"
    throw
}
