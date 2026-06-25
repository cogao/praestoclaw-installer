#!/usr/bin/env bash
# PraestoClaw one-click installer for macOS / Linux.
#
# Usage:
#   curl -fsSL https://aka.ms/praestoclaw/install.sh | bash
#
# Or download and run locally:
#   chmod +x install.sh && ./install.sh
#
# - Automatically installs Python 3.11+ if no compatible version is found.
# - Automatically installs Python via system package manager if needed (may
#   use sudo on Linux). PraestoClaw itself installs with --user where possible.
# - Idempotent: safe to re-run to upgrade an existing installation.

set -uo pipefail   # -e intentionally omitted: handle errors explicitly

MIN_MAJOR=3
MIN_MINOR=11
PYTHON_INSTALL_VERSION="3.13"
# PraestoClaw is not yet published on PyPI; install from the public mirror's
# pre-built versioned wheel. The mirror publishes a latest.txt pointer we
# resolve at install time (pip rejects non-PEP440 filenames like
# "praestoclaw-latest-…whl"). Override with PRAESTOCLAW_PACKAGE to point at
# a local wheel path, a direct URL, or "praestoclaw" once on PyPI.
MIRROR_BASE="https://raw.githubusercontent.com/cogao/praestoclaw-installer/main"
PACKAGE="${PRAESTOCLAW_PACKAGE:-}"
OS="$(uname -s)"

# ── Helpers ──────────────────────────────────────────────────────────────────
step()  { printf '\n\033[36m>> %s\033[0m\n' "$*"; }
ok()    { printf '   \033[32mOK: %s\033[0m\n' "$*"; }
warn()  { printf '   \033[33mWARNING: %s\033[0m\n' "$*"; }
fail()  { printf '   \033[31mFAILED: %s\033[0m\n' "$*"; exit 1; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

python_version_ok() {
    local cmd="$1"
    local ver major minor
    ver=$("$cmd" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1) || return 1
    major="${ver%%.*}"
    minor="${ver#*.}"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
    [[ "$major" -gt "$MIN_MAJOR" ]] || { [[ "$major" -eq "$MIN_MAJOR" && "$minor" -ge "$MIN_MINOR" ]]; }
}

find_python() {
    for candidate in "python${PYTHON_INSTALL_VERSION}" "python3.13" "python3.12" "python3.11" python3 python; do
        if has_cmd "$candidate" && python_version_ok "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

add_to_shell_profile() {
    local line="$1"
    for profile in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.profile"; do
        if [[ -f "$profile" ]]; then
            if ! grep -qF "$line" "$profile" 2>/dev/null; then
                echo "" >> "$profile"
                echo "# Added by PraestoClaw installer" >> "$profile"
                echo "$line" >> "$profile"
                ok "Added to $profile: $line"
            fi
        fi
    done
}

# ── 1. Locate or install Python ─────────────────────────────────────────────
step "Checking for Python ${MIN_MAJOR}.${MIN_MINOR}+ ..."

PYTHON_CMD=""
if PYTHON_CMD=$(find_python); then
    ok "Found $($PYTHON_CMD --version 2>&1)"
else
    warn "Python ${MIN_MAJOR}.${MIN_MINOR}+ not found — attempting automatic install ..."

    if [[ "$OS" == "Darwin" ]]; then
        # ── macOS ──────────────────────────────────────────────────────────
        if ! has_cmd brew; then
            warn "Homebrew not found — installing Homebrew ..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
            # Activate brew for this session
            for brew_path in /opt/homebrew/bin/brew /usr/local/bin/brew; do
                [[ -x "$brew_path" ]] && eval "$("$brew_path" shellenv)" && break
            done
        fi
        if has_cmd brew; then
            step "Installing Python ${PYTHON_INSTALL_VERSION} via Homebrew ..."
            brew install "python@${PYTHON_INSTALL_VERSION}" 2>&1 | sed 's/^/   /' || true
            # Homebrew may link as python3.13 — add its prefix to PATH
            brew_prefix=$(brew --prefix "python@${PYTHON_INSTALL_VERSION}" 2>/dev/null || true)
            if [[ -n "$brew_prefix" && -d "$brew_prefix/bin" ]]; then
                export PATH="$brew_prefix/bin:$PATH"
                add_to_shell_profile "export PATH=\"$brew_prefix/bin:\$PATH\""
            fi
        fi

    else
        # ── Linux ──────────────────────────────────────────────────────────
        SUDO=""
        has_cmd sudo && SUDO="sudo"

        if has_cmd apt-get; then
            step "Installing Python via apt ..."
            # Always update package lists first (required on fresh/minimal images)
            $SUDO apt-get update -qq 2>&1 | sed 's/^/   /' || true
            # Try python3.13 via deadsnakes PPA if not in main apt
            if ! apt-cache show "python${PYTHON_INSTALL_VERSION}" >/dev/null 2>&1; then
                if has_cmd add-apt-repository; then
                    warn "python${PYTHON_INSTALL_VERSION} not in apt — adding deadsnakes PPA ..."
                    $SUDO add-apt-repository -y ppa:deadsnakes/ppa 2>&1 | sed 's/^/   /' || true
                    $SUDO apt-get update -qq 2>&1 | sed 's/^/   /' || true
                fi
            fi
            # Try versioned package first (distutils removed in 3.12+, skip it)
            if $SUDO apt-get install -y "python${PYTHON_INSTALL_VERSION}" \
                    "python${PYTHON_INSTALL_VERSION}-venv" 2>&1 | sed 's/^/   /'; then
                true
            else
                warn "Falling back to python3 ..."
                $SUDO apt-get install -y python3 python3-pip python3-venv 2>&1 | sed 's/^/   /' || true
            fi

        elif has_cmd dnf; then
            step "Installing Python via dnf ..."
            $SUDO dnf install -y "python${PYTHON_INSTALL_VERSION}" 2>&1 | sed 's/^/   /' || \
            $SUDO dnf install -y python3 2>&1 | sed 's/^/   /' || true

        elif has_cmd yum; then
            step "Installing Python via yum ..."
            $SUDO yum install -y "python${PYTHON_INSTALL_VERSION}" 2>&1 | sed 's/^/   /' || \
            $SUDO yum install -y python3 2>&1 | sed 's/^/   /' || true

        elif has_cmd zypper; then
            step "Installing Python via zypper ..."
            $SUDO zypper install -y "python${PYTHON_INSTALL_VERSION}" 2>&1 | sed 's/^/   /' || \
            $SUDO zypper install -y python3 2>&1 | sed 's/^/   /' || true

        elif has_cmd pacman; then
            step "Installing Python via pacman ..."
            $SUDO pacman -Sy --noconfirm python 2>&1 | sed 's/^/   /' || true

        elif has_cmd apk; then
            step "Installing Python via apk ..."
            $SUDO apk add --no-cache python3 py3-pip 2>&1 | sed 's/^/   /' || true

        else
            warn "No supported package manager found (apt/dnf/yum/zypper/pacman/apk)."
        fi
    fi

    # Re-check after install
    if PYTHON_CMD=$(find_python); then
        ok "Python installed: $($PYTHON_CMD --version 2>&1)"
    else
        fail "Could not automatically install Python ${MIN_MAJOR}.${MIN_MINOR}+.
  Please install manually:  https://www.python.org/downloads/
  Then re-run this script."
    fi
fi

# ── 2. Ensure pip ────────────────────────────────────────────────────────────
step "Ensuring pip is available ..."

if ! "$PYTHON_CMD" -m pip --version >/dev/null 2>&1; then
    warn "pip not found — trying ensurepip ..."
    "$PYTHON_CMD" -m ensurepip --upgrade >/dev/null 2>&1 || true

    if ! "$PYTHON_CMD" -m pip --version >/dev/null 2>&1; then
        warn "ensurepip failed — downloading get-pip.py ..."
        if has_cmd curl; then
            curl -fsSL https://bootstrap.pypa.io/get-pip.py | "$PYTHON_CMD" || true
        elif has_cmd wget; then
            wget -qO- https://bootstrap.pypa.io/get-pip.py | "$PYTHON_CMD" || true
        fi
    fi

    if ! "$PYTHON_CMD" -m pip --version >/dev/null 2>&1; then
        fail "Could not install pip. Please install it manually:
  $PYTHON_CMD -m ensurepip --upgrade
  or: curl -fsSL https://bootstrap.pypa.io/get-pip.py | $PYTHON_CMD"
    fi
fi

"$PYTHON_CMD" -m pip install --upgrade pip --quiet 2>/dev/null || true
ok "$("$PYTHON_CMD" -m pip --version 2>&1)"

# ── 3. Install / upgrade PraestoClaw ──────────────────────────────────────────
_resolved_ver=""
if [ -z "$PACKAGE" ]; then
    step "Resolving latest PraestoClaw version ..."
    # Cache-buster bypasses GitHub Raw's 5-minute CDN TTL.
    _bust=$(date +%s)
    if has_cmd curl; then
        _resolved_ver=$(curl -fsSL "$MIRROR_BASE/latest.txt?t=$_bust" | tr -d '[:space:]')
    elif has_cmd wget; then
        _resolved_ver=$(wget -qO- "$MIRROR_BASE/latest.txt?t=$_bust" | tr -d '[:space:]')
    else
        fail "Neither curl nor wget is available to resolve latest version."
    fi
    if ! [[ "$_resolved_ver" =~ ^[0-9]+\.[0-9]+ ]]; then
        fail "latest.txt did not contain a valid version: '$_resolved_ver'
  Override with PRAESTOCLAW_PACKAGE=<wheel URL or local path>"
    fi
    PACKAGE="$MIRROR_BASE/dist/praestoclaw-${_resolved_ver}-py3-none-any.whl"
    ok "Latest version: $_resolved_ver"
fi

# Build list of packages to install in a single pip invocation. The
# praestoclaw wheel declares `Requires-Dist: agent-gateway-protocol` with
# no version pin and no source URL, so pip would otherwise try PyPI and
# fail (the protocol package is private to this workspace and only
# published to the public mirror). Passing both wheels to pip in one go
# satisfies the dep locally.
#
# When PRAESTOCLAW_PACKAGE is overridden (dev / local-wheel testing) we
# still pull the protocol wheel from the mirror unless the caller also
# overrides PRAESTOCLAW_GATEWAY_PROTOCOL_PACKAGE.
DEPS_PACKAGE="${PRAESTOCLAW_GATEWAY_PROTOCOL_PACKAGE:-}"
if [ -z "$DEPS_PACKAGE" ]; then
    if [ -z "$_resolved_ver" ]; then
        # PRAESTOCLAW_PACKAGE was set (override path), but we still need the
        # protocol version — best effort fetch latest.txt.
        _bust=$(date +%s)
        if has_cmd curl; then
            _resolved_ver=$(curl -fsSL "$MIRROR_BASE/latest.txt?t=$_bust" | tr -d '[:space:]')
        elif has_cmd wget; then
            _resolved_ver=$(wget -qO- "$MIRROR_BASE/latest.txt?t=$_bust" | tr -d '[:space:]')
        fi
    fi
    if [[ "$_resolved_ver" =~ ^[0-9]+\.[0-9]+ ]]; then
        DEPS_PACKAGE="$MIRROR_BASE/dist/agent_gateway_protocol-${_resolved_ver}-py3-none-any.whl"
    else
        warn "Could not resolve agent_gateway_protocol wheel URL — pip will try PyPI and likely fail."
        warn "Override with PRAESTOCLAW_GATEWAY_PROTOCOL_PACKAGE=<wheel URL or path>"
    fi
fi

# Same rationale for praesto-telemetry: the praestoclaw wheel declares
# `Requires-Dist: praesto-telemetry` with no source, so we point pip at
# the mirror-hosted wheel.
TELEMETRY_PACKAGE="${PRAESTO_TELEMETRY_PACKAGE:-}"
if [ -z "$TELEMETRY_PACKAGE" ] && [[ "$_resolved_ver" =~ ^[0-9]+\.[0-9]+ ]]; then
    TELEMETRY_PACKAGE="$MIRROR_BASE/dist/praesto_telemetry-${_resolved_ver}-py3-none-any.whl"
fi
if [ -z "$TELEMETRY_PACKAGE" ]; then
    warn "Could not resolve praesto_telemetry wheel URL — pip will try PyPI and likely fail."
    warn "Override with PRAESTO_TELEMETRY_PACKAGE=<wheel URL or path>"
fi

# Same rationale for os-sandbox: the praestoclaw wheel declares
# `Requires-Dist: os-sandbox` with no source, so we point pip at
# the mirror-hosted wheel.
SANDBOX_PACKAGE="${OS_SANDBOX_PACKAGE:-}"
if [ -z "$SANDBOX_PACKAGE" ] && [[ "$_resolved_ver" =~ ^[0-9]+\.[0-9]+ ]]; then
    SANDBOX_PACKAGE="$MIRROR_BASE/dist/os_sandbox-${_resolved_ver}-py3-none-any.whl"
fi
if [ -z "$SANDBOX_PACKAGE" ]; then
    warn "Could not resolve os_sandbox wheel URL — pip will try PyPI and likely fail."
    warn "Override with OS_SANDBOX_PACKAGE=<wheel URL or path>"
fi

INSTALL_TARGETS=()
[ -n "$DEPS_PACKAGE" ] && INSTALL_TARGETS+=("$DEPS_PACKAGE")
[ -n "$TELEMETRY_PACKAGE" ] && INSTALL_TARGETS+=("$TELEMETRY_PACKAGE")
[ -n "$SANDBOX_PACKAGE" ] && INSTALL_TARGETS+=("$SANDBOX_PACKAGE")
INSTALL_TARGETS+=("$PACKAGE")

step "Installing / upgrading from $PACKAGE ..."

# --force-reinstall so pip always re-downloads the wheel; without it pip
# treats the versioned mirror URL as "already satisfied" when the local
# install has the same post-release version, and new fixes never roll out.
PIP_FLAGS=(--upgrade --force-reinstall)

if "$PYTHON_CMD" -m pip install "${PIP_FLAGS[@]}" "${INSTALL_TARGETS[@]}" 2>/dev/null; then
    ok "$PACKAGE installed."
elif "$PYTHON_CMD" -m pip install "${PIP_FLAGS[@]}" --user "${INSTALL_TARGETS[@]}" 2>/dev/null; then
    ok "$PACKAGE installed (--user)."
elif "$PYTHON_CMD" -m pip install "${PIP_FLAGS[@]}" --break-system-packages "${INSTALL_TARGETS[@]}" 2>/dev/null; then
    # PEP 668: Ubuntu 24.04+ / Debian 12+ mark the system Python as externally managed.
    # --break-system-packages is safe here because we are installing a user application.
    ok "$PACKAGE installed (--break-system-packages)."
else
    pip_out=$("$PYTHON_CMD" -m pip install "${PIP_FLAGS[@]}" "${INSTALL_TARGETS[@]}" 2>&1) || {
        printf '%s\n' "$pip_out"
        fail "pip install failed.
  Common fixes:
    - Corporate proxy: export HTTPS_PROXY=http://proxy:port
    - Manual: $PYTHON_CMD -m pip install --upgrade --force-reinstall ${INSTALL_TARGETS[*]}"
    }
    ok "$PACKAGE installed."
fi

# Resolve user bin directory early (needed by step 3b and step 4)
USER_BASE=$("$PYTHON_CMD" -m site --user-base 2>/dev/null || echo "")

# ── 3b. Install uv (Python package runner, used by MCP servers) ────────────
if has_cmd uvx; then
    ok "uv already installed: $(uv --version 2>&1)"
else
    step "Installing uv (Python package runner) ..."
    if "$PYTHON_CMD" -m pip install uv --quiet 2>/dev/null; then
        ok "uv installed."
    elif "$PYTHON_CMD" -m pip install uv --quiet --user 2>/dev/null; then
        ok "uv installed (--user)."
    elif "$PYTHON_CMD" -m pip install uv --quiet --break-system-packages 2>/dev/null; then
        ok "uv installed (--break-system-packages)."
    else
        warn "Failed to install uv (non-critical, MCP servers will use pip fallback)."
    fi
    # Add user bin to PATH if uvx landed there
    if [[ -n "$USER_BASE" && -d "$USER_BASE/bin" ]]; then
        export PATH="$USER_BASE/bin:$PATH"
    fi
fi

# ── 3c. Install Agency CLI (used by bundled MS-internal MCP servers) ────────
if has_cmd agency; then
    ok "agency already installed: $(agency --version 2>&1 || echo 'unknown')"
else
    step "Installing Agency CLI ..."
    if has_cmd curl; then
        if curl -sSfL https://aka.ms/InstallTool.sh | bash -s agency 2>&1 | sed 's/^/   /'; then
            # Agency installer typically drops binary into ~/.local/bin or similar
            for agency_dir in "$HOME/.local/bin" "$HOME/.dotnet/tools" "$HOME/bin"; do
                [[ -d "$agency_dir" ]] && export PATH="$agency_dir:$PATH"
            done
            if has_cmd agency; then
                ok "agency installed: $(agency --version 2>&1 || echo 'unknown')"
            else
                warn "Agency installer ran but 'agency' not found on PATH yet (restart your terminal). MCP still works without it; bundled MS-internal servers will be unavailable."
            fi
        else
            warn "Failed to install Agency CLI (non-critical). MCP still works without agency; bundled MS-internal servers will be unavailable."
        fi
    else
        warn "curl not available — skipping Agency CLI install. MCP still works without agency; bundled MS-internal servers will be unavailable."
    fi
fi

# ── 4. Ensure praestoclaw is on PATH ───────────────────────────────────────────
step "Verifying praestoclaw CLI ..."

# Add user bin dir to PATH for this session and shell profiles
if [[ -n "$USER_BASE" && -d "$USER_BASE/bin" ]]; then
    export PATH="$USER_BASE/bin:$PATH"
    add_to_shell_profile "export PATH=\"$USER_BASE/bin:\$PATH\""
fi

# macOS Homebrew bin
if [[ "$OS" == "Darwin" ]] && has_cmd brew; then
    brew_scripts=$(brew --prefix 2>/dev/null)/bin
    [[ -d "$brew_scripts" ]] && export PATH="$brew_scripts:$PATH"
fi

if has_cmd praestoclaw; then
    ok "$(praestoclaw version 2>&1)"
else
    # Try running directly from Python scripts path
    SCRIPTS_DIR=$("$PYTHON_CMD" -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>/dev/null || echo "")
    if [[ -n "$SCRIPTS_DIR" && -x "$SCRIPTS_DIR/praestoclaw" ]]; then
        export PATH="$SCRIPTS_DIR:$PATH"
        add_to_shell_profile "export PATH=\"$SCRIPTS_DIR:\$PATH\""
        ok "$(praestoclaw version 2>&1)"
    else
        warn "praestoclaw not found on PATH yet."
        echo ""
        echo "  Restart your terminal or run:"
        [[ -n "$USER_BASE" ]] && echo "    export PATH=\"$USER_BASE/bin:\$PATH\""
        echo "  Then: praestoclaw version"
        echo ""
    fi
fi

# ── 5. Done ──────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  PraestoClaw installed successfully!"
echo "============================================"
echo ""

# ── One-click finishing touch ─────────────────────────────────────────────
# Set PRAESTOCLAW_SKIP_POST_INSTALL=1 to skip the automatic config + Teams
# install + server launch, and exit right after CLI is on PATH.
if has_cmd praestoclaw && [ "${PRAESTOCLAW_SKIP_POST_INSTALL:-0}" != "1" ]; then

    step "Creating default config ..."
    praestoclaw init --quick 2>&1 | sed 's/^/   /' || true

    step "Installing PraestoClaw into Microsoft Teams ..."
    echo "   You'll be asked to sign in with your Microsoft 365 work account."
    # --force makes the one-click flow re-upload every time the installer runs;
    # without it users who already sideloaded an older PraestoClaw release
    # would get "already installed" and never receive manifest updates.
    praestoclaw teams install --force || warn "Teams sideload did not complete. You can retry anytime with: praestoclaw teams install"

    step "Starting PraestoClaw ..."
    echo "   Press Ctrl+C in this window to stop the server."
    echo ""
    # ``praestoclaw`` (no subcommand) only prints a banner — call ``s``
    # (alias for ``serve``) so the local web + cloud channels actually come
    # up. Without this the Teams bot sees "agent offline" because nothing
    # is connected back to the gateway.
    exec praestoclaw s

elif has_cmd praestoclaw; then
    echo "  Skipped post-install (PRAESTOCLAW_SKIP_POST_INSTALL=1)."
    echo "  To finish setup manually:"
    echo "    praestoclaw init --quick"
    echo "    praestoclaw teams install"
    echo "    praestoclaw s"
    echo ""
else
    echo "  Restart your terminal, then run:"
    echo "    praestoclaw s"
    echo ""
fi
