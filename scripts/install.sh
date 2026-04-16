#!/usr/bin/env bash
# kweb-gds-viewer per-user installer (no sudo required)
#
# Installs the Cursor extension and configures it to use the shared Python
# venv that was set up by the admin via admin-install.sh.
#
# Usage:  /opt/tools/kweb-gds-viewer/install
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
INSTALL_ROOT="${SCRIPT_DIR}"
VENV_PYTHON="${INSTALL_ROOT}/venv/bin/python"

info()    { printf '\e[1;34m[kweb-gds-viewer]\e[0m %s\n' "$*"; }
success() { printf '\e[1;32m[kweb-gds-viewer]\e[0m %s\n' "$*"; }
warn()    { printf '\e[1;33m[kweb-gds-viewer]\e[0m WARNING: %s\n' "$*"; }
die()     { printf '\e[1;31m[kweb-gds-viewer]\e[0m ERROR: %s\n' "$*" >&2; exit 1; }

# ── Pre-checks ────────────────────────────────────────────────────────────────
[[ -x "${VENV_PYTHON}" ]] || die "Shared Python venv not found at ${VENV_PYTHON}. Ask your admin to run: sudo ${INSTALL_ROOT}/admin-install.sh"

VSIX_FILE="$(ls "${INSTALL_ROOT}/"*.vsix 2>/dev/null | head -1 || true)"
[[ -n "${VSIX_FILE}" ]] || die "No .vsix found in ${INSTALL_ROOT}. Ask your admin to re-run admin-install.sh."

# ── Verify shared venv works ──────────────────────────────────────────────────
if ! KWEB_FILESLOCATION=/tmp "${VENV_PYTHON}" -c "import kweb.default, uvicorn" 2>/dev/null; then
    die "Shared Python at ${VENV_PYTHON} failed kweb import probe. Ask your admin to re-run admin-install.sh."
fi

KWEB_VER="$("${VENV_PYTHON}" -c "import kweb; print(kweb.__version__)" 2>/dev/null || echo "unknown")"
info "Found shared kweb ${KWEB_VER} at ${VENV_PYTHON}"

# ── Install Cursor extension ────────────────────────────────────────────────
info "Installing Cursor extension from $(basename "${VSIX_FILE}") ..."

CURSOR_CLI=""
for candidate in \
    "cursor" \
    "${HOME}/.cursor-server/bin/linux-x64/$(ls "${HOME}/.cursor-server/bin/linux-x64/" 2>/dev/null | head -1)/bin/remote-cli/cursor" \
    "code"; do
    if command -v "${candidate}" &>/dev/null; then
        CURSOR_CLI="${candidate}"
        break
    fi
done

if [[ -n "${CURSOR_CLI}" ]]; then
    "${CURSOR_CLI}" --install-extension "${VSIX_FILE}" --force 2>&1 | tail -3 || \
        warn "CLI install returned non-zero — extension may already be installed."
    success "Extension installed via ${CURSOR_CLI}."
else
    warn "cursor/code CLI not found. Falling back to manual extraction."
    EXT_DIR="${HOME}/.cursor-server/extensions"
    mkdir -p "${EXT_DIR}"
    EXTRACT_DIR="${EXT_DIR}/optocompiler.kweb-gds-viewer"
    mkdir -p "${EXTRACT_DIR}"
    if command -v unzip &>/dev/null; then
        unzip -qo "${VSIX_FILE}" -d "${EXTRACT_DIR}/vsix_tmp" 2>/dev/null
        cp -rf "${EXTRACT_DIR}/vsix_tmp/extension/." "${EXTRACT_DIR}/"
        rm -rf "${EXTRACT_DIR}/vsix_tmp"
        success "Extension extracted to ${EXTRACT_DIR}."
    else
        die "unzip not found. Install the extension manually: cursor --install-extension ${VSIX_FILE}"
    fi
fi

# ── Configure kwebPythonPath ──────────────────────────────────────────────────
SETTINGS_DIR="${HOME}/.cursor-server/data/Machine"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"
mkdir -p "${SETTINGS_DIR}"

info "Setting kweb-gds-viewer.kwebPythonPath → ${VENV_PYTHON}"

if [[ -f "${SETTINGS_FILE}" ]] && [[ -s "${SETTINGS_FILE}" ]]; then
    "${VENV_PYTHON}" - "${SETTINGS_FILE}" "${VENV_PYTHON}" <<'PYEOF'
import json, sys
settings_path, python_path = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    settings = json.load(f)
settings["kweb-gds-viewer.kwebPythonPath"] = python_path
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF
else
    cat > "${SETTINGS_FILE}" <<JSONEOF
{
  "kweb-gds-viewer.kwebPythonPath": "${VENV_PYTHON}"
}
JSONEOF
fi

success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
success "kweb-gds-viewer installed successfully!"
success ""
success "Open or reopen a .gds file in Cursor to use the viewer."
success "If Cursor was already open, reload the window first:"
success "  Ctrl+Shift+P → Developer: Reload Window"
success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
