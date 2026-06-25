<#
.SYNOPSIS
    PraestoClaw one-click updater for Windows.

.DESCRIPTION
    Checks the public mirror for a newer version. If one is available, stops
    any running PraestoClaw processes, upgrades via pip, re-runs init --quick,
    and starts the server. Exits cleanly when already up to date.

    Run from PowerShell:
        irm https://aka.ms/praestoclaw/update.ps1 | iex

    Or download and run locally:
        .\update.ps1

.NOTES
- Compatible with PowerShell 5.1+ and Windows 10/11.
- Does not require administrator privileges.
- Idempotent: safe to re-run at any time.
#>

$ErrorActionPreference = "Continue"

# Force UTF-8 on the console so Rich output doesn't get mangled.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
    $env:PYTHONIOENCODING     = "utf-8"
    $env:PYTHONUTF8           = "1"
} catch {}

$MirrorBase = "https://raw.githubusercontent.com/cogao/praestoclaw-installer/main"
$Package    = $env:PRAESTOCLAW_PACKAGE  # may be $null; resolved below

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Step { param([string]$m) Write-Host "" ; Write-Host ">> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "   OK: $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "   WARNING: $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "   FAILED: $m" -ForegroundColor Red }

function Refresh-Path {
    $m = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $u = [System.Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $m) { $m = "" }
    if (-not $u) { $u = "" }
    $env:Path = (@($m, $u) | Where-Object { $_ }) -join ";"
}

function Compare-Version {
    <#
    .SYNOPSIS
        Compare two version strings using Python's packaging.version for
        PEP 440-correct behavior. Falls back to simple numeric compare
        if Python is unavailable.
        Returns: -1 (left < right), 0 (equal), 1 (left > right).
    #>
    param([string]$Left, [string]$Right)

    # Try Python packaging.version (PEP 440 correct)
    try {
        $pyResult = & $pyCmd @pyPrefix -c "
from packaging.version import Version
import sys
l, r = Version(sys.argv[1]), Version(sys.argv[2])
print(-1 if l < r else (1 if l > r else 0))
" $Left $Right 2>$null
        if ($LASTEXITCODE -eq 0 -and $pyResult -match '^-?\d+$') {
            return [int]$pyResult
        }
    } catch {}

    # Fallback: strip .postNNN timestamps and compare numeric segments
    $Left  = $Left  -replace '\.post\d{10,}', ''  # only timestamp-shaped
    $Right = $Right -replace '\.post\d{10,}', ''

    $lParts = [regex]::Matches($Left,  '\d+') | ForEach-Object { [int]$_.Value }
    $rParts = [regex]::Matches($Right, '\d+') | ForEach-Object { [int]$_.Value }

    $max = [Math]::Max($lParts.Count, $rParts.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $l = if ($i -lt $lParts.Count) { $lParts[$i] } else { 0 }
        $r = if ($i -lt $rParts.Count) { $rParts[$i] } else { 0 }
        if ($l -lt $r) { return -1 }
        if ($l -gt $r) { return  1 }
    }
    return 0
}

function Get-OurExePaths {
    <#
    .SYNOPSIS
        Return full paths to our praestoclaw.exe and pc.exe entry points
        in Python Scripts directories.
    #>
    $paths = @()
    try {
        $scriptsDirs = @()
        $d1 = & $pyCmd @pyPrefix -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>$null
        $d2 = & $pyCmd @pyPrefix -c "import sysconfig; print(sysconfig.get_path('scripts','nt_user'))" 2>$null
        if ($d1) { $scriptsDirs += $d1 }
        if ($d2) { $scriptsDirs += $d2 }
        foreach ($d in $scriptsDirs | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique) {
            foreach ($name in @("praestoclaw.exe", "pc.exe")) {
                $p = Join-Path $d $name
                if (Test-Path $p) {
                    $paths += (Resolve-Path $p).Path.ToLower()
                }
            }
        }
    } catch {}
    return $paths
}

function Is-PraestoClawProcess {
    <#
    .SYNOPSIS
        Return $true only when a Win32_Process can be confidently identified
        as a PraestoClaw process.
    #>
    param($Proc, [string[]]$OurPaths)

    # 1. Exact executable path match — most reliable
    if ($Proc.ExecutablePath) {
        $normExe = $Proc.ExecutablePath.ToLower()
        if ($OurPaths -contains $normExe) { return $true }
    }

    # 2. Process named praestoclaw
    if ($Proc.Name -eq "praestoclaw.exe") { return $true }

    # 3. Command line contains praestoclaw executable or module invocation
    $cmd = $Proc.CommandLine
    if ($cmd) {
        $lowerCmd = $cmd.ToLower()
        if ($lowerCmd -match 'praestoclaw\.cli\.commands') { return $true }
        if ($lowerCmd -match '(?:^|\s)-m\s+praestoclaw(?:\s|$)') { return $true }
        if ($lowerCmd -match '[/\\]praestoclaw(?:\.exe)?["''\s]') { return $true }
        # pc.exe only when command line explicitly mentions praestoclaw
        if ($Proc.Name -eq "pc.exe" -and $lowerCmd -match 'praestoclaw') { return $true }
    }

    return $false
}

function Get-AncestorPids {
    <#
    .SYNOPSIS
        Walk up the parent process chain and return all ancestor PIDs
        to avoid killing ourselves.
    #>
    $pids = @($PID)
    $current = $PID
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $current" -ErrorAction SilentlyContinue
            if (-not $proc -or -not $proc.ParentProcessId -or $proc.ParentProcessId -eq 0) { break }
            $parent = $proc.ParentProcessId
            if ($pids -contains $parent) { break }
            $pids += $parent
            $current = $parent
        } catch { break }
    }
    return $pids
}

function Stop-PraestoClawProcesses {
    <#
    .SYNOPSIS
        Find and stop running PraestoClaw processes (excluding own ancestry).
    #>
    $excludePids = Get-AncestorPids
    $ourPaths = Get-OurExePaths
    $allProcs = Get-CimInstance Win32_Process 2>$null

    $targets = @()
    foreach ($proc in $allProcs) {
        if ($excludePids -contains $proc.ProcessId) { continue }
        if (Is-PraestoClawProcess $proc $ourPaths) {
            $targets += $proc
        }
    }

    if ($targets.Count -eq 0) {
        Write-Ok "No running PraestoClaw processes found."
        return
    }

    Write-Host "   Stopping $($targets.Count) PraestoClaw process(es) ..." -ForegroundColor Yellow
    foreach ($t in $targets) {
        try {
            Stop-Process -Id $t.ProcessId -Force -ErrorAction Stop
            Write-Ok "Stopped PID $($t.ProcessId) ($($t.Name))"
        } catch {
            Write-Warn "Could not stop PID $($t.ProcessId) ($($t.Name)): $_"
        }
    }
    Start-Sleep -Seconds 2
}

# ═══════════════════════════════════════════════════════════════════════════
# Main flow
# ═══════════════════════════════════════════════════════════════════════════

# --- Step 1: Verify praestoclaw is installed ---
Write-Step "Checking current installation ..."
Refresh-Path

if (-not (Get-Command praestoclaw -ErrorAction SilentlyContinue)) {
    Write-Fail "PraestoClaw is not installed."
    Write-Host ""
    Write-Host "  Run the installer first:" -ForegroundColor Yellow
    Write-Host "    irm https://aka.ms/praestoclaw/install.ps1 | iex" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

$currentVersionRaw = & praestoclaw version 2>&1
Write-Ok "Current: $currentVersionRaw"

# Extract version number (e.g. "PraestoClaw v1.0.0.post..." -> "1.0.0.post...")
$currentVersion = ""
if ($currentVersionRaw -match '(\d+\.\d+[^\s]*)') {
    $currentVersion = $Matches[1]
}

# Locate Python — prefer py launcher (avoids Microsoft Store stub)
$pyCmd = $null
$pyPrefix = @()
if (Get-Command py -ErrorAction SilentlyContinue) {
    try {
        $ver = & py -3 --version 2>&1
        if ($LASTEXITCODE -eq 0 -and [string]$ver -match "Python") {
            $pyCmd = "py"
            $pyPrefix = @("-3")
        }
    } catch {}
}
if (-not $pyCmd) {
    foreach ($c in @("python3", "python")) {
        if (Get-Command $c -ErrorAction SilentlyContinue) {
            try {
                $ver = & $c --version 2>&1
                if ($LASTEXITCODE -eq 0 -and [string]$ver -match "Python \d+\.\d+") {
                    $pyCmd = $c
                    break
                }
            } catch {}
        }
    }
}
if (-not $pyCmd) {
    Write-Fail "Python not found on PATH."
    exit 1
}
Write-Ok "Python: $( & $pyCmd @pyPrefix --version 2>&1 )"

# --- Step 2: Resolve latest version and compare ---
$latest = $null
if (-not $Package) {
    Write-Step "Checking for updates ..."
    try {
        $bust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $latest = (Invoke-WebRequest -Uri "$MirrorBase/latest.txt?t=$bust" -UseBasicParsing).Content.Trim()
        if ($latest -notmatch '^\d+\.\d+(\.\d+)?') {
            throw "latest.txt did not contain a valid version: '$latest'"
        }
        Write-Ok "Latest version: $latest"
    } catch {
        Write-Fail "Could not resolve latest version from $MirrorBase/latest.txt"
        Write-Host "   $_" -ForegroundColor Red
        Write-Host "   Override with `$env:PRAESTOCLAW_PACKAGE = '<wheel URL or path>'" -ForegroundColor Yellow
        exit 1
    }

    # Compare versions
    if ($currentVersion -and $latest) {
        $cmp = Compare-Version $currentVersion $latest
        if ($cmp -ge 0) {
            Write-Host ""
            Write-Host "   Already up to date! (current: v$currentVersion, latest: v$latest)" -ForegroundColor Green
            Write-Host ""
            if ($env:PRAESTOCLAW_ENSURE_RUNNING -eq "1") {
                # Bot self-update path: the daemon was already stopped before
                # this script ran. There is nothing to install, but we must
                # restart the server or the bot stays offline.
                Write-Step "Starting PraestoClaw ..."
                Write-Host "   Press Ctrl+C in this window to stop the server." -ForegroundColor DarkGray
                Write-Host ""
                & praestoclaw s
            }
            exit 0
        }
        Write-Host "   Update available: v$currentVersion -> v$latest" -ForegroundColor Cyan
    }

    $Package = "$MirrorBase/dist/praestoclaw-$latest-py3-none-any.whl"
}

# Build list of packages to install in a single pip invocation. The
# praestoclaw wheel declares `Requires-Dist: agent-gateway-protocol`,
# `Requires-Dist: praesto-telemetry`, and `Requires-Dist: os-sandbox`
# with no version pin and no source URL, so pip would otherwise try
# PyPI and fail (these packages are private to this workspace and only
# published to the public mirror). Passing all wheels to pip in one go
# satisfies the deps locally.
#
# When PRAESTOCLAW_PACKAGE is overridden (dev / local-wheel testing) we
# still pull the dep wheels from the mirror unless the caller also
# overrides PRAESTOCLAW_GATEWAY_PROTOCOL_PACKAGE / PRAESTO_TELEMETRY_PACKAGE /
# OS_SANDBOX_PACKAGE.
$DepsPackage = $env:PRAESTOCLAW_GATEWAY_PROTOCOL_PACKAGE
$TelemetryPackage = $env:PRAESTO_TELEMETRY_PACKAGE
$SandboxPackage = $env:OS_SANDBOX_PACKAGE
if ((-not $DepsPackage -or -not $TelemetryPackage -or -not $SandboxPackage) -and -not $latest) {
    # PRAESTOCLAW_PACKAGE was set so we never resolved latest — fetch now.
    try {
        $bust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $latest = (Invoke-WebRequest -Uri "$MirrorBase/latest.txt?t=$bust" -UseBasicParsing).Content.Trim()
    } catch {}
}
if (-not $DepsPackage) {
    if ($latest -match '^\d+\.\d+(\.\d+)?') {
        $DepsPackage = "$MirrorBase/dist/agent_gateway_protocol-$latest-py3-none-any.whl"
    } else {
        Write-Warn "Could not resolve agent_gateway_protocol wheel URL — pip will try PyPI and likely fail."
        Write-Host "   Override with `$env:PRAESTOCLAW_GATEWAY_PROTOCOL_PACKAGE = '<wheel URL or path>'" -ForegroundColor Yellow
    }
}
if (-not $TelemetryPackage) {
    if ($latest -match '^\d+\.\d+(\.\d+)?') {
        $TelemetryPackage = "$MirrorBase/dist/praesto_telemetry-$latest-py3-none-any.whl"
    } else {
        Write-Warn "Could not resolve praesto_telemetry wheel URL — pip will try PyPI and likely fail."
        Write-Host "   Override with `$env:PRAESTO_TELEMETRY_PACKAGE = '<wheel URL or path>'" -ForegroundColor Yellow
    }
}
if (-not $SandboxPackage) {
    if ($latest -match '^\d+\.\d+(\.\d+)?') {
        $SandboxPackage = "$MirrorBase/dist/os_sandbox-$latest-py3-none-any.whl"
    } else {
        Write-Warn "Could not resolve os_sandbox wheel URL — pip will try PyPI and likely fail."
        Write-Host "   Override with `$env:OS_SANDBOX_PACKAGE = '<wheel URL or path>'" -ForegroundColor Yellow
    }
}
$InstallTargets = @()
if ($DepsPackage) { $InstallTargets += $DepsPackage }
if ($TelemetryPackage) { $InstallTargets += $TelemetryPackage }
if ($SandboxPackage) { $InstallTargets += $SandboxPackage }
$InstallTargets += $Package

# --- Step 3: Stop running PraestoClaw processes (only after confirming update needed) ---
Write-Step "Stopping running PraestoClaw processes ..."
Stop-PraestoClawProcesses

# --- Step 4: Upgrade via pip ---
Write-Step "Upgrading to v$latest ..."

$spin = '|','/','—','\'
function Run-PipSilent([string[]]$PipArgs) {
    $errFile = "$env:TEMP\_pc_pip_err.txt"
    $outFile = "$env:TEMP\_pc_pip_out.txt"
    $allArgs = @($pyPrefix) + $PipArgs
    $argStr = ($allArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    $p = Start-Process -FilePath $pyCmd -ArgumentList $argStr -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $i = 0
    while (!$p.HasExited) { Write-Host "`r   $($spin[$i++%4]) Installing..." -NoNewline -ForegroundColor Cyan; Start-Sleep -Milliseconds 120 }
    Write-Host "`r                        `r" -NoNewline
    $p.WaitForExit()
    $code = $p.ExitCode
    $errText = ""
    if ($code -ne 0) { $errText = Get-Content $errFile -Raw -ErrorAction SilentlyContinue }
    Remove-Item $errFile, $outFile -ErrorAction SilentlyContinue
    return @{ Code = $code; Err = $errText }
}

$r = Run-PipSilent (@("-m","pip","install","--upgrade","--force-reinstall") + $InstallTargets)
if ($r.Code -ne 0) {
    Write-Warn "Standard install failed. Retrying with --user ..."
    $r = Run-PipSilent (@("-m","pip","install","--upgrade","--force-reinstall","--user") + $InstallTargets)
    if ($r.Code -ne 0) {
        Write-Fail "pip install failed:"
        if ($r.Err) { Write-Host $r.Err -ForegroundColor Red }
        exit 1
    }
}
Write-Ok "Upgrade complete."

Refresh-Path
if (Get-Command praestoclaw -ErrorAction SilentlyContinue) {
    Write-Ok "$( & praestoclaw version 2>&1 )"
} else {
    Write-Warn "praestoclaw not found on PATH after upgrade."
}

# --- Step 5: Post-update startup ---
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  PraestoClaw updated to v$latest!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

if (Get-Command praestoclaw -ErrorAction SilentlyContinue) {
    Write-Step "Running post-update config ..."
    & praestoclaw init --quick 2>&1 | ForEach-Object { Write-Host "   $_" }

    # Idempotent — see 'praestoclaw teams install --help'.
    Write-Step "Checking Teams app version ..."
    & praestoclaw teams install --quiet --no-open-teams --if-installed 2>&1 | ForEach-Object { Write-Host "   $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Teams version check did not complete — re-run with: praestoclaw teams install"
    }

    Write-Step "Starting PraestoClaw ..."
    Write-Host "   Press Ctrl+C in this window to stop the server." -ForegroundColor DarkGray
    Write-Host ""
    & praestoclaw s
} else {
    Write-Host "  Restart your terminal, then run:" -ForegroundColor Cyan
    Write-Host "    praestoclaw s" -ForegroundColor White
    Write-Host ""
}
