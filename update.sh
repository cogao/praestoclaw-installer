#!/usr/bin/env bash
# PraestoClaw one-click updater for macOS / Linux.
#
# Usage:
#   curl -fsSL https://aka.ms/praestoclaw/update.sh | bash
#
# Or download and run locally:
#   chmod +x update.sh && ./update.sh
#
# - Requires an existing PraestoClaw installation (run install.sh first).
# - Checks for a newer version before doing anything destructive.
# - Stops running PraestoClaw processes only when an update is needed.
# - Idempotent: safe to re-run — exits cleanly when already up to date.

set -uo pipefail   # -e intentionally omitted: handle errors explicitly

MIRROR_BASE="https://raw.githubusercontent.com/cogao/praestoclaw-installer/main"
PACKAGE="${PRAESTOCLAW_PACKAGE:-}"
RESTART_REQUIRED="${PRAESTOCLAW_ENSURE_RUNNING:-0}"
STOPPED_COUNT=0
PC_LAUNCHER=(praestoclaw)
PRAESTOCLAW_DATA_DIR="${PRAESTOCLAW_DATA_DIR:-$HOME/.praestoclaw}"

# ── Helpers ──────────────────────────────────────────────────────────────────
step()  { printf '\n\033[36m>> %s\033[0m\n' "$*"; }
ok()    { printf '   \033[32mOK: %s\033[0m\n' "$*"; }
warn()  { printf '   \033[33mWARNING: %s\033[0m\n' "$*"; }
fail()  {
    printf '   \033[31mFAILED: %s\033[0m\n' "$*"
    [[ "$RESTART_REQUIRED" = "1" ]] && start_praestoclaw_best_effort
    exit 1
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

compare_version() {
    # Compare two version strings using Python's packaging.version (PEP 440).
    # Returns via exit code: 0 = left >= right, 1 = left < right.
    # Falls back to simple numeric compare if Python is unavailable.
    local left="$1" right="$2"

    # Try Python packaging.version — only if import succeeds
    if has_cmd "$PYTHON_CMD"; then
        if "$PYTHON_CMD" -c "from packaging.version import Version" 2>/dev/null; then
            "$PYTHON_CMD" -c "
from packaging.version import Version
import sys
l, r = Version(sys.argv[1]), Version(sys.argv[2])
sys.exit(0 if l >= r else 1)
" "$left" "$right" 2>/dev/null
            return $?
        fi
    fi

    # Fallback: strip timestamp-shaped .postNNN and compare digits
    left=$(echo "$left" | sed 's/\.post[0-9]\{10,\}//')
    right=$(echo "$right" | sed 's/\.post[0-9]\{10,\}//')

    IFS='.' read -ra lparts <<< "$left"
    IFS='.' read -ra rparts <<< "$right"

    local max=${#lparts[@]}
    [[ ${#rparts[@]} -gt $max ]] && max=${#rparts[@]}

    for ((i = 0; i < max; i++)); do
        local l=${lparts[$i]:-0}
        local r=${rparts[$i]:-0}
        l=$(echo "$l" | grep -oE '^[0-9]+' || echo 0)
        r=$(echo "$r" | grep -oE '^[0-9]+' || echo 0)
        if [[ "$l" -lt "$r" ]]; then return 1; fi
        if [[ "$l" -gt "$r" ]]; then return 0; fi
    done
    return 0  # equal
}

stop_praestoclaw_processes() {
    # Find and stop running PraestoClaw processes (excluding own process chain).
    local current_pid=$$
    local parent_pid
    parent_pid=$(ps -o ppid= -p "$current_pid" 2>/dev/null | tr -d ' ')
    local exclude_pids="$current_pid ${parent_pid:-0}"
    local killed=0

    while IFS= read -r line; do
        local pid cmd
        pid=$(echo "$line" | awk '{print $1}')
        cmd=$(echo "$line" | awk '{$1=""; print}' | sed 's/^ //')

        # Skip own process chain
        local skip=false
        for ep in $exclude_pids; do
            [[ "$pid" = "$ep" ]] && skip=true
        done
        $skip && continue

        # Only kill processes whose executable is praestoclaw/pc or invoked via python -m praestoclaw
        local _exe
        _exe=$(echo "$cmd" | awk '{print $1}')
        _exe=$(basename "$_exe" 2>/dev/null || echo "$_exe")
        local _match=false
        case "$_exe" in
            praestoclaw|praestoclaw.exe|pc|pc.exe) _match=true ;;
        esac
        # Also match: python -m praestoclaw ...
        if echo "$cmd" | grep -qE '(^|\s)-m\s+praestoclaw(\s|$)'; then
            _match=true
        fi
        # Also match: python /path/to/praestoclaw ...
        if echo "$cmd" | grep -qE '[/]praestoclaw(\s|$)'; then
            _match=true
        fi
        if ! $_match; then continue; fi

        # Graceful SIGTERM first, then SIGKILL after 3s
        kill -TERM "$pid" 2>/dev/null || true
        local waited=0
        while kill -0 "$pid" 2>/dev/null && [[ "$waited" -lt 3 ]]; do
            sleep 1
            waited=$((waited + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
        if kill -0 "$pid" 2>/dev/null; then
            warn "Could not stop PID $pid"
        else
            ok "Stopped PID $pid"
            killed=$((killed + 1))
        fi
    done < <(ps -eo pid=,args= 2>/dev/null || true)

    if [[ "$killed" -eq 0 ]]; then
        ok "No running PraestoClaw processes found."
    else
        STOPPED_COUNT=$killed
        sleep 1
    fi
}

start_praestoclaw_best_effort() {
    step "Starting PraestoClaw ..."
    "${PC_LAUNCHER[@]}" s --data-dir "$PRAESTOCLAW_DATA_DIR" &
    disown 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# Main flow
# ═══════════════════════════════════════════════════════════════════════════

# --- Step 1: Verify current installation ---
step "Checking current installation ..."

if ! has_cmd praestoclaw; then
    fail "PraestoClaw is not installed.
  Run the installer first:
    curl -fsSL https://aka.ms/praestoclaw/install.sh | bash"
fi

current_version_raw=$(praestoclaw version 2>&1)
ok "Current: $current_version_raw"

# Extract version number
current_version=$(echo "$current_version_raw" | grep -oE '[0-9]+\.[0-9]+[^ ]*' | head -1)

# Locate Python
PYTHON_CMD=""
for candidate in python3 python; do
    if has_cmd "$candidate"; then
        PYTHON_CMD="$candidate"
        break
    fi
done
[[ -z "$PYTHON_CMD" ]] && fail "Python not found on PATH."
ok "Python: $($PYTHON_CMD --version 2>&1)"

if [[ -n "${PRAESTOCLAW_LAUNCHER:-}" ]]; then
    if parsed_launcher=$(PRAESTOCLAW_LAUNCHER="$PRAESTOCLAW_LAUNCHER" "$PYTHON_CMD" -c \
        'import json, os; p=json.loads(os.environ["PRAESTOCLAW_LAUNCHER"]); assert isinstance(p, list) and p and all(isinstance(v, str) and v and "\n" not in v for v in p); print(*p, sep="\n")' \
        2>/dev/null); then
        PC_LAUNCHER=()
        while IFS= read -r launcher_part; do
            PC_LAUNCHER+=("$launcher_part")
        done <<< "$parsed_launcher"
    fi
fi

# --- Step 2: Resolve latest version and compare ---
latest=""
if [[ -z "$PACKAGE" ]]; then
    step "Checking for updates ..."
    _bust=$(date +%s)
    if has_cmd curl; then
        latest=$(curl -fsSL "$MIRROR_BASE/latest.txt?t=$_bust" | tr -d '[:space:]')
    elif has_cmd wget; then
        latest=$(wget -qO- "$MIRROR_BASE/latest.txt?t=$_bust" | tr -d '[:space:]')
    else
        fail "Neither curl nor wget is available."
    fi
    if ! [[ "$latest" =~ ^[0-9]+\.[0-9]+ ]]; then
        fail "latest.txt did not contain a valid version: '$latest'
  Override with PRAESTOCLAW_PACKAGE=<wheel URL or path>"
    fi
    ok "Latest version: $latest"

    # Compare versions — exit if already up to date
    if [[ -n "$current_version" && -n "$latest" ]]; then
        if compare_version "$current_version" "$latest"; then
            echo ""
            echo "   Already up to date! (current: v$current_version, latest: v$latest)"
            echo ""
            if [ "${PRAESTOCLAW_ENSURE_RUNNING:-}" = "1" ]; then
                # Bot self-update path: the daemon was already stopped before
                # this script ran. Nothing to install, but we must restart the
                # server or the bot stays offline.
                start_praestoclaw_best_effort
            fi
            exit 0
        fi
        echo "   Update available: v$current_version -> v$latest"
    fi

    PACKAGE="$MIRROR_BASE/dist/praestoclaw-${latest}-py3-none-any.whl"
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
    if [ -z "$latest" ]; then
        # PRAESTOCLAW_PACKAGE was set so we never resolved latest — fetch now.
        _bust=$(date +%s)
        if has_cmd curl; then
            latest=$(curl -fsSL "$MIRROR_BASE/latest.txt?t=$_bust" | tr -d '[:space:]')
        elif has_cmd wget; then
            latest=$(wget -qO- "$MIRROR_BASE/latest.txt?t=$_bust" | tr -d '[:space:]')
        fi
    fi
    if [[ "$latest" =~ ^[0-9]+\.[0-9]+ ]]; then
        DEPS_PACKAGE="$MIRROR_BASE/dist/agent_gateway_protocol-${latest}-py3-none-any.whl"
    else
        warn "Could not resolve agent_gateway_protocol wheel URL — pip will try PyPI and likely fail."
        warn "Override with PRAESTOCLAW_GATEWAY_PROTOCOL_PACKAGE=<wheel URL or path>"
    fi
fi

# Same rationale for praesto-telemetry: the praestoclaw wheel declares
# `Requires-Dist: praesto-telemetry` with no source, so we point pip at
# the mirror-hosted wheel.
TELEMETRY_PACKAGE="${PRAESTO_TELEMETRY_PACKAGE:-}"
if [ -z "$TELEMETRY_PACKAGE" ] && [[ "$latest" =~ ^[0-9]+\.[0-9]+ ]]; then
    TELEMETRY_PACKAGE="$MIRROR_BASE/dist/praesto_telemetry-${latest}-py3-none-any.whl"
fi
if [ -z "$TELEMETRY_PACKAGE" ]; then
    warn "Could not resolve praesto_telemetry wheel URL — pip will try PyPI and likely fail."
    warn "Override with PRAESTO_TELEMETRY_PACKAGE=<wheel URL or path>"
fi

# Same rationale for os-sandbox: the praestoclaw wheel declares
# `Requires-Dist: os-sandbox` with no source, so we point pip at
# the mirror-hosted wheel.
SANDBOX_PACKAGE="${OS_SANDBOX_PACKAGE:-}"
if [ -z "$SANDBOX_PACKAGE" ] && [[ "$latest" =~ ^[0-9]+\.[0-9]+ ]]; then
    SANDBOX_PACKAGE="$MIRROR_BASE/dist/os_sandbox-${latest}-py3-none-any.whl"
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

# --- Step 3: Stop running PraestoClaw processes (only after confirming update needed) ---
step "Stopping running PraestoClaw processes ..."
"${PC_LAUNCHER[@]}" watchdog-stop --data-dir "$PRAESTOCLAW_DATA_DIR"
watchdog_rc=$?
if [[ "$watchdog_rc" -eq 0 ]]; then
    RESTART_REQUIRED=1
elif [[ "$watchdog_rc" -eq 2 || "$watchdog_rc" -eq 3 ]]; then
    stop_praestoclaw_processes
    [[ "$STOPPED_COUNT" -gt 0 ]] && RESTART_REQUIRED=1
else
    exit "$watchdog_rc"
fi

# --- Step 4: Upgrade via pip ---
step "Upgrading to v${latest:-latest} ..."

PIP_FLAGS=(--upgrade --force-reinstall)

if "$PYTHON_CMD" -m pip install "${PIP_FLAGS[@]}" "${INSTALL_TARGETS[@]}" >/dev/null 2>&1; then
    ok "Upgrade complete."
elif "$PYTHON_CMD" -m pip install "${PIP_FLAGS[@]}" --user "${INSTALL_TARGETS[@]}" >/dev/null 2>&1; then
    ok "Upgrade complete (--user)."
elif "$PYTHON_CMD" -m pip install "${PIP_FLAGS[@]}" --break-system-packages "${INSTALL_TARGETS[@]}" >/dev/null 2>&1; then
    ok "Upgrade complete (--break-system-packages)."
else
    pip_out=$("$PYTHON_CMD" -m pip install "${PIP_FLAGS[@]}" "${INSTALL_TARGETS[@]}" 2>&1) || {
        printf '%s\n' "$pip_out"
        printf '   \033[31mFAILED: %s\033[0m\n' "pip install failed.
  Common fixes:
    - Corporate proxy: export HTTPS_PROXY=http://proxy:port
    - Manual: $PYTHON_CMD -m pip install --upgrade --force-reinstall ${INSTALL_TARGETS[*]}"
        [[ "$RESTART_REQUIRED" = "1" ]] && start_praestoclaw_best_effort
        exit 1
    }
    ok "Upgrade complete."
fi

# Verify
if has_cmd praestoclaw; then
    ok "$(praestoclaw version 2>&1)"
else
    warn "praestoclaw not found on PATH after upgrade."
fi

# --- Step 5: Post-update startup ---
echo ""
echo "============================================"
echo "  PraestoClaw updated to v${latest:-latest}!"
echo "============================================"
echo ""

if has_cmd praestoclaw; then
    step "Running post-update config ..."
    "${PC_LAUNCHER[@]}" init --quick 2>&1 | sed 's/^/   /' || true

    # Idempotent — see 'praestoclaw teams install --help'.
    step "Checking Teams app version ..."
    "${PC_LAUNCHER[@]}" teams install --quiet --no-open-teams --if-installed 2>&1 | sed 's/^/   /' || \
        warn "Teams version check did not complete — re-run with: praestoclaw teams install"

else
    echo "  Restart your terminal, then run:"
    echo "    praestoclaw s"
    echo ""
fi

[[ "$RESTART_REQUIRED" = "1" ]] && start_praestoclaw_best_effort
