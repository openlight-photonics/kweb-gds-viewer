#!/usr/bin/env bash
# kweb-gds-viewer per-user installer
# Usage: /opt/tools/kweb-gds-viewer/install
# Installs or updates the kweb GDS Viewer Cursor extension and its Python runtime
# for the current user. No root required.
set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────
PACKAGE_NAME="kweb-gds-viewer"
INSTALL_DIR="${HOME}/.local/share/${PACKAGE_NAME}"
VENV_DIR="${INSTALL_DIR}/venv"
VERSION_FILE="${INSTALL_DIR}/version.txt"

# This script lives inside the versioned deploy directory; the VSIX and wheels
# are siblings. Resolve the canonical path of this script's directory.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ── Helpers ────────────────────────────────────────────────────────────────────
info()    { printf '\e[1;34m[kweb-gds-viewer]\e[0m %s\n' "$*"; }
success() { printf '\e[1;32m[kweb-gds-viewer]\e[0m %s\n' "$*"; }
warn()    { printf '\e[1;33m[kweb-gds-viewer]\e[0m WARNING: %s\n' "$*"; }
die()     { printf '\e[1;31m[kweb-gds-viewer]\e[0m ERROR: %s\n' "$*" >&2; exit 1; }

# ── Version detection ──────────────────────────────────────────────────────────
BUNDLE_VERSION_FILE="${SCRIPT_DIR}/version.txt"
if [[ ! -f "${BUNDLE_VERSION_FILE}" ]]; then
    die "version.txt not found in ${SCRIPT_DIR}. This script must be run from the deployed package directory."
fi
BUNDLE_VERSION="$(cat "${BUNDLE_VERSION_FILE}")"

# Check if already up to date
if [[ -f "${VERSION_FILE}" ]] && [[ "$(cat "${VERSION_FILE}")" == "${BUNDLE_VERSION}" ]]; then
    success "Already at version ${BUNDLE_VERSION}. Nothing to do."
    success "To force reinstall, run: rm ${VERSION_FILE} && $0"
    exit 0
fi

info "Installing ${PACKAGE_NAME} ${BUNDLE_VERSION}..."
info "Deploy directory: ${SCRIPT_DIR}"

# ── Locate VSIX ────────────────────────────────────────────────────────────────
VSIX_FILE="$(ls "${SCRIPT_DIR}/"*.vsix 2>/dev/null | head -1 || true)"
if [[ -z "${VSIX_FILE}" ]]; then
    die "No .vsix file found in ${SCRIPT_DIR}."
fi
info "Found extension: $(basename "${VSIX_FILE}")"

# ── Locate Python >= 3.10 ──────────────────────────────────────────────────────
PYTHON_CANDIDATES=(
    "${HOME}/miniforge3/envs/ocp-kweb/bin/python3"
    "${HOME}/miniforge3/bin/python3"
    "${HOME}/mambaforge/envs/ocp-kweb/bin/python3"
    "${HOME}/mambaforge/bin/python3"
    "${HOME}/.conda/envs/ocp-kweb/bin/python3"
    "python3"
    "python"
)

find_python() {
    local candidate
    for candidate in "${PYTHON_CANDIDATES[@]}"; do
        if command -v "${candidate}" &>/dev/null || [[ -x "${candidate}" ]]; then
            local version
            version="$("${candidate}" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || true)"
            if [[ -z "${version}" ]]; then continue; fi
            local major minor
            major="${version%%.*}"
            minor="${version#*.}"
            if (( major > 3 )) || (( major == 3 && minor >= 10 )); then
                echo "${candidate}"
                return 0
            fi
        fi
    done
    return 1
}

if BASE_PYTHON="$(find_python)"; then
    BASE_PYTHON="$(command -v "${BASE_PYTHON}" 2>/dev/null || echo "${BASE_PYTHON}")"
    info "Found Python $("${BASE_PYTHON}" --version 2>&1) at ${BASE_PYTHON}"
else
    warn "No Python >= 3.10 found. Installing Miniforge3 to ${INSTALL_DIR}/miniforge3 ..."
    MINIFORGE_DIR="${INSTALL_DIR}/miniforge3"
    MINIFORGE_INSTALLER="${SCRIPT_DIR}/miniforge3.sh"
    if [[ ! -f "${MINIFORGE_INSTALLER}" ]]; then
        die "miniforge3.sh installer not bundled in ${SCRIPT_DIR}. Contact your administrator."
    fi
    bash "${MINIFORGE_INSTALLER}" -b -p "${MINIFORGE_DIR}"
    BASE_PYTHON="${MINIFORGE_DIR}/bin/python3"
    info "Installed Python $("${BASE_PYTHON}" --version 2>&1)"
fi

# ── Create/update Python venv ───────────────────────────────────────────────────
WHEELS_DIR="${SCRIPT_DIR}/wheels"
if [[ ! -d "${WHEELS_DIR}" ]]; then
    die "wheels/ directory not found in ${SCRIPT_DIR}."
fi

info "Creating Python virtual environment at ${VENV_DIR} ..."
mkdir -p "${INSTALL_DIR}"
"${BASE_PYTHON}" -m venv "${VENV_DIR}"

info "Installing Python packages from bundled wheels ..."
"${VENV_DIR}/bin/pip" install \
    --quiet \
    --no-index \
    --find-links "${WHEELS_DIR}" \
    kweb uvicorn fastapi starlette

KWEB_VERSION="$("${VENV_DIR}/bin/python" -c "import kweb; print(kweb.__version__)" 2>/dev/null || echo "unknown")"
info "Installed kweb ${KWEB_VERSION}"

VENV_PYTHON="${VENV_DIR}/bin/python"

# ── Install Cursor extension ────────────────────────────────────────────────────
info "Installing Cursor extension from ${VSIX_FILE} ..."

# Prefer the remote-cli cursor/code binary that installs extensions server-side
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
        warn "cursor CLI install returned non-zero -- extension may already be installed."
    success "Extension installed via Cursor CLI."
else
    warn "cursor/code CLI not found. Falling back to manual extraction."
    EXT_DIR="${HOME}/.cursor-server/extensions"
    mkdir -p "${EXT_DIR}"
    EXTRACT_DIR="${EXT_DIR}/optocompiler.${PACKAGE_NAME}-${BUNDLE_VERSION}"
    mkdir -p "${EXTRACT_DIR}"
    # VSIX is a zip file
    if command -v unzip &>/dev/null; then
        unzip -qo "${VSIX_FILE}" -d "${EXTRACT_DIR}/vsix_tmp" 2>/dev/null
        rsync -a "${EXTRACT_DIR}/vsix_tmp/extension/" "${EXTRACT_DIR}/" 2>/dev/null || \
            cp -rf "${EXTRACT_DIR}/vsix_tmp/extension/." "${EXTRACT_DIR}/"
        rm -rf "${EXTRACT_DIR}/vsix_tmp"
        success "Extension extracted to ${EXTRACT_DIR}."
    else
        warn "unzip not found. Please install the extension manually: cursor --install-extension ${VSIX_FILE}"
    fi
fi

# ── Configure Cursor kwebPythonPath setting ────────────────────────────────────
# On a Cursor SSH remote, machine-level settings override user settings and
# are stored in ~/.cursor-server/data/Machine/settings.json
SETTINGS_DIR="${HOME}/.cursor-server/data/Machine"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"
mkdir -p "${SETTINGS_DIR}"

info "Configuring kwebPythonPath in ${SETTINGS_FILE} ..."

if [[ -f "${SETTINGS_FILE}" ]] && [[ -s "${SETTINGS_FILE}" ]]; then
    # Merge into existing settings using Python's json module (available in the venv)
    "${VENV_PYTHON}" - "${SETTINGS_FILE}" "${VENV_PYTHON}" <<'PYEOF'
import json, sys
settings_path = sys.argv[1]
python_path = sys.argv[2]
with open(settings_path) as f:
    settings = json.load(f)
settings["kweb-gds-viewer.kwebPythonPath"] = python_path
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF
else
    # Create fresh settings file
    "${VENV_PYTHON}" -c "
import json
settings = {'kweb-gds-viewer.kwebPythonPath': '${VENV_PYTHON}'}
with open('${SETTINGS_FILE}', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
"
fi

success "Set kweb-gds-viewer.kwebPythonPath = ${VENV_PYTHON}"

# ── Record installed version ────────────────────────────────────────────────────
echo "${BUNDLE_VERSION}" > "${VERSION_FILE}"

success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
success "kweb-gds-viewer ${BUNDLE_VERSION} installed successfully!"
success ""
success "Open or reopen a .gds file in Cursor to use the viewer."
success "If Cursor was already open, reload the window first:"
success "  Ctrl+Shift+P → Developer: Reload Window"
success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
