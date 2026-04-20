<#
.SYNOPSIS
    PraestoClaw one-click installer for Windows.

.DESCRIPTION
    Automatically installs Python 3.11+ if needed (via winget or python.org),
    ensures pip, installs PraestoClaw from the public wheel mirror, and adds
    the CLI to your PATH.

    Run from PowerShell:
        irm https://aka.ms/praestoclaw/install.ps1 | iex

    Or download and run locally:
        .\install.ps1

.NOTES
    - Compatible with PowerShell 5.1+ and Windows 10/11.
    - Does not require administrator privileges.
    - Idempotent: safe to re-run to upgrade an existing installation.
#>

$ErrorActionPreference = "Continue"

# Force UTF-8 on the console so box-drawing / check-mark output from Rich
# (e.g. during `praestoclaw init --quick`) doesn't get mangled into
# "ΓêÜ / Γöé / Γöö" when piped through PowerShell.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
    $env:PYTHONIOENCODING     = "utf-8"
    $env:PYTHONUTF8           = "1"
} catch {}

$MinMajor  = 3
$MinMinor  = 11
$PyVersion = "3.13"
$PyArch    = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
$PyUrl     = "https://www.python.org/ftp/python/$PyVersion.0/python-$PyVersion.0-$PyArch.exe"
# PraestoClaw is not yet published on PyPI; install from the public mirror's
# pre-built wheel. Override with PRAESTOCLAW_PACKAGE (e.g. "praestoclaw" once
# on PyPI, or a local path / direct wheel URL).
$MirrorBase = "https://raw.githubusercontent.com/cogao/praestoclaw-installer/main"
$Package    = $env:PRAESTOCLAW_PACKAGE  # may be $null; resolved below

function Write-Step { param([string]$m) Write-Host "" ; Write-Host ">> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "   OK: $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "   WARNING: $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "   FAILED: $m" -ForegroundColor Red }

function Get-EnvPath {
    $m = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $u = [System.Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $m) { $m = "" }
    if (-not $u) { $u = "" }
    return (@($m, $u) | Where-Object { $_ }) -join ";"
}

function Refresh-Path {
    $env:Path = Get-EnvPath
}

function Add-ToUserPath {
    param([string]$Dir)
    if (-not $Dir -or -not (Test-Path $Dir)) { return }
    $current = [System.Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $current) { $current = "" }
    $parts = $current -split ";"
    if ($parts -contains $Dir) { return }
    $newPath = ($parts + $Dir | Where-Object { $_ }) -join ";"
    [System.Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    if ($env:Path -notlike "*$Dir*") { $env:Path = "$env:Path;$Dir" }
    Write-Ok "Added to PATH: $Dir"
}

function Test-IsStoreStub {
    param([string]$Cmd)
    try {
        $out = & $Cmd --version 2>&1
        return ($LASTEXITCODE -eq 9009 -or [string]$out -notmatch "Python")
    } catch { return $true }
}

function Find-Python {
    $candidates = @("python3", "python", "py")
    foreach ($c in $candidates) {
        if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { continue }
        if (Test-IsStoreStub $c) { continue }
        try {
            $ver = & $c --version 2>&1
            if ([string]$ver -match "Python (\d+)\.(\d+)") {
                $maj = [int]$Matches[1]
                $min = [int]$Matches[2]
                if ($maj -gt $MinMajor -or ($maj -eq $MinMajor -and $min -ge $MinMinor)) {
                    return @{ Cmd = $c; Prefix = @() }
                }
            }
        } catch {}
    }
    # py launcher with version flag
    if (Get-Command py -ErrorAction SilentlyContinue) {
        $flag = "-$($MinMajor).$($MinMinor)"
        try {
            $ver = & py $flag --version 2>&1
            if ($LASTEXITCODE -eq 0 -and [string]$ver -match "Python") {
                return @{ Cmd = "py"; Prefix = @($flag) }
            }
        } catch {}
    }
    return $null
}

# --- Step 1: Locate or install Python ---
Write-Step "Checking for Python $($MinMajor).$($MinMinor)+ ..."

$pyInfo = Find-Python

if (-not $pyInfo) {
    Write-Warn "Python $($MinMajor).$($MinMinor)+ not found. Attempting automatic install..."

    # 1a. Try winget (Windows 10 1709+ / Windows 11)
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Step "Installing Python $PyVersion via winget ..."
        winget install --id "Python.Python.$PyVersion" `
            --accept-source-agreements `
            --accept-package-agreements `
            --scope user `
            --silent 2>&1 | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
        Refresh-Path
        $pyInfo = Find-Python
        if ($pyInfo) { Write-Ok "Python installed via winget." }
    }

    # 1b. Fallback: download installer from python.org
    if (-not $pyInfo) {
        Write-Step "Downloading Python $PyVersion from python.org ..."
        $installer = Join-Path $env:TEMP "python-installer.exe"
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $PyUrl -OutFile $installer -UseBasicParsing -ErrorAction Stop
            Write-Step "Running Python installer silently (user scope, no admin needed) ..."
            $startArgs = @{
                FilePath     = $installer
                ArgumentList = "/quiet", "InstallAllUsers=0", "PrependPath=1", "Include_launcher=1"
                Wait         = $true
                PassThru     = $true
            }
            $null = Start-Process @startArgs
            Remove-Item $installer -ErrorAction SilentlyContinue
            Refresh-Path
            $pyInfo = Find-Python
            if ($pyInfo) { Write-Ok "Python installed from python.org." }
        } catch {
            Write-Warn "Direct download failed: $($_.Exception.Message)"
        }
    }

    if (-not $pyInfo) {
        Write-Fail "Could not automatically install Python."
        Write-Host ""
        Write-Host "  Please install Python $($MinMajor).$($MinMinor)+ manually:" -ForegroundColor Yellow
        Write-Host "    https://www.python.org/downloads/" -ForegroundColor Yellow
        Write-Host "  Check 'Add Python to PATH' during installation, then re-run this script." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}

$pyCmd    = $pyInfo.Cmd
$pyPrefix = $pyInfo.Prefix
$verOut   = & $pyCmd @pyPrefix --version 2>&1
Write-Ok "Found $verOut"

# --- Step 2: Ensure pip ---
Write-Step "Ensuring pip is available ..."

$pipCheck = & $pyCmd @pyPrefix -m pip --version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warn "pip not found. Bootstrapping via ensurepip ..."
    & $pyCmd @pyPrefix -m ensurepip --upgrade 2>&1 | Out-Null

    $pipCheck = & $pyCmd @pyPrefix -m pip --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "ensurepip failed. Downloading get-pip.py ..."
        $getPip = Join-Path $env:TEMP "get-pip.py"
        Invoke-WebRequest -Uri "https://bootstrap.pypa.io/get-pip.py" -OutFile $getPip -UseBasicParsing
        & $pyCmd @pyPrefix $getPip 2>&1 | Out-Null
        Remove-Item $getPip -ErrorAction SilentlyContinue
    }
}

& $pyCmd @pyPrefix -m pip install --upgrade pip --quiet 2>&1 | Out-Null
Write-Ok "$( & $pyCmd @pyPrefix -m pip --version 2>&1 )"

# --- Step 3: Install PraestoClaw ---
if (-not $Package) {
    Write-Step "Resolving latest PraestoClaw version ..."
    try {
        # Cache-buster so we bypass GitHub Raw's 5-minute CDN TTL after a release.
        $bust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $ver  = (Invoke-WebRequest -Uri "$MirrorBase/latest.txt?t=$bust" -UseBasicParsing).Content.Trim()
        if ($ver -notmatch '^\d+\.\d+(\.\d+)?') {
            throw "latest.txt did not contain a valid version: '$ver'"
        }
        $Package = "$MirrorBase/dist/praestoclaw-$ver-py3-none-any.whl"
        Write-Ok "Latest version: $ver"
    } catch {
        Write-Fail "Could not resolve latest version from $MirrorBase/latest.txt"
        Write-Host "   $_" -ForegroundColor Red
        Write-Host "   Override with `$env:PRAESTOCLAW_PACKAGE = '<wheel URL or path>'" -ForegroundColor Yellow
        exit 1
    }
}
Write-Step "Installing / upgrading from $Package ..."

# --force-reinstall ensures the wheel is always re-downloaded and reinstalled,
# even when the version string matches what's already on disk — necessary
# because the mirror rebuilds wheels under time-stamped versions and pip
# otherwise skips same-version URLs as "already satisfied".
$out = & $pyCmd @pyPrefix -m pip install --upgrade --force-reinstall $Package 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Standard install failed. Retrying with --user ..."
    $out = & $pyCmd @pyPrefix -m pip install --upgrade --force-reinstall --user $Package 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "pip install failed:"
        Write-Host ($out | Out-String) -ForegroundColor Red
        Write-Host "  If behind a corporate proxy, set HTTPS_PROXY and retry." -ForegroundColor Yellow
        exit 1
    }
}
Write-Ok "$Package installed."

# --- Step 3b: Install uv (Python package runner, used by MCP servers) ---
if (Get-Command uvx -ErrorAction SilentlyContinue) {
    Write-Ok "uv already installed: $( & uv --version 2>&1 )"
} else {
    Write-Step "Installing uv (Python package runner) ..."
    $uvOut = & $pyCmd @pyPrefix -m pip install uv --quiet 2>&1
    if ($LASTEXITCODE -ne 0) {
        $uvOut = & $pyCmd @pyPrefix -m pip install uv --quiet --user 2>&1
    }
    Refresh-Path
    if (Get-Command uvx -ErrorAction SilentlyContinue) {
        Write-Ok "uv installed: $( & uv --version 2>&1 )"
    } else {
        Write-Warn "uv installed but uvx not on PATH (non-critical, MCP servers will use pip fallback)."
    }
}

# --- Step 3c: Install Agency CLI (used by bundled MS-internal MCP servers) ---
if (Get-Command agency -ErrorAction SilentlyContinue) {
    try { Write-Ok "agency already installed: $( & agency --version 2>&1 )" } catch { Write-Ok "agency already installed." }
} else {
    Write-Step "Installing Agency CLI ..."
    try {
        Invoke-Expression 'iex "& { $(irm https://aka.ms/InstallTool.ps1) } agency"'
        Refresh-Path
        if (Get-Command agency -ErrorAction SilentlyContinue) {
            try { Write-Ok "agency installed: $( & agency --version 2>&1 )" } catch { Write-Ok "agency installed." }
        } else {
            Write-Warn "Agency installer ran but 'agency' not found on PATH yet (restart your terminal). MCP still works without it; bundled MS-internal servers will be unavailable."
        }
    } catch {
        Write-Warn "Failed to install Agency CLI: $($_.Exception.Message)"
        Write-Warn "Non-critical: MCP still works without agency; bundled MS-internal servers will be unavailable."
    }
}

# --- Step 4: Ensure praestoclaw is on PATH ---
Write-Step "Verifying praestoclaw CLI ..."

Refresh-Path

if (-not (Get-Command praestoclaw -ErrorAction SilentlyContinue)) {
    # Auto-add Scripts directories to User PATH
    $scriptsDir  = & $pyCmd @pyPrefix -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>&1
    $userScripts = & $pyCmd @pyPrefix -c "import sysconfig; print(sysconfig.get_path('scripts', 'nt_user'))" 2>&1

    foreach ($d in @($scriptsDir, $userScripts) | Select-Object -Unique) {
        if ($d) { Add-ToUserPath $d }
    }
    Refresh-Path
}

if (Get-Command praestoclaw -ErrorAction SilentlyContinue) {
    Write-Ok "$( & praestoclaw version 2>&1 )"
} else {
    Write-Warn "praestoclaw not found on PATH yet."
    $sd = & $pyCmd @pyPrefix -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>&1
    Write-Host ""
    Write-Host "  Restart your terminal to pick up PATH changes, then run:" -ForegroundColor Yellow
    Write-Host "    praestoclaw version" -ForegroundColor Yellow
    if ($sd) { Write-Host "  (Scripts dir: $sd)" -ForegroundColor DarkGray }
    Write-Host ""
}

# --- Done ---
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  PraestoClaw installed successfully!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

# ── One-click finishing touch ───────────────────────────────────────────────
# Set PRAESTOCLAW_SKIP_POST_INSTALL=1 to skip the automatic config + Teams
# install + server launch, and exit right after CLI is on PATH.
$skipPost = $env:PRAESTOCLAW_SKIP_POST_INSTALL -eq '1'

if ((Get-Command praestoclaw -ErrorAction SilentlyContinue) -and (-not $skipPost)) {

    Write-Step "Creating default config ..."
    & praestoclaw init --quick 2>&1 | ForEach-Object { Write-Host "   $_" }

    Write-Step "Installing PraestoClaw into Microsoft Teams ..."
    Write-Host "   A browser window will open — sign in with your Microsoft 365 account." -ForegroundColor DarkGray
    & praestoclaw teams install
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Teams sideload did not complete. You can retry anytime with: praestoclaw teams install"
    }

    Write-Step "Starting PraestoClaw ..."
    Write-Host "   Press Ctrl+C in this window to stop the server." -ForegroundColor DarkGray
    Write-Host ""
    & praestoclaw

} elseif (Get-Command praestoclaw -ErrorAction SilentlyContinue) {
    Write-Host "  Skipped post-install (PRAESTOCLAW_SKIP_POST_INSTALL=1)." -ForegroundColor DarkGray
    Write-Host "  To finish setup manually:" -ForegroundColor Cyan
    Write-Host "    praestoclaw init --quick" -ForegroundColor White
    Write-Host "    praestoclaw teams install" -ForegroundColor White
    Write-Host "    praestoclaw" -ForegroundColor White
    Write-Host ""
} else {
    Write-Host "  Restart your terminal, then run:" -ForegroundColor Cyan
    Write-Host "    praestoclaw" -ForegroundColor White
    Write-Host ""
}
