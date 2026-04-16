#!/usr/bin/env bash
# kweb-gds-viewer ADMIN installer (requires sudo)
#
# Sets up a shared Python venv and Cursor extension in /opt/tools/kweb-gds-viewer/
# so that every user on the machine can run the lightweight per-user install
# without needing sudo, miniforge, or pip.
#
# Usage:
#   sudo scripts/admin-install.sh            # from repo root
#   sudo scripts/admin-install.sh /custom/dir # override install location
set -euo pipefail

INSTALL_ROOT="${1:-/opt/tools/kweb-gds-viewer}"
VENV_DIR="${INSTALL_ROOT}/venv"

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PINS_FILE="${SCRIPT_DIR}/ocp-kweb-pins.txt"

info()    { printf '\e[1;34m[admin-install]\e[0m %s\n' "$*"; }
success() { printf '\e[1;32m[admin-install]\e[0m %s\n' "$*"; }
die()     { printf '\e[1;31m[admin-install]\e[0m ERROR: %s\n' "$*" >&2; exit 1; }

# ── Pre-checks ────────────────────────────────────────────────────────────────
[[ -f "${PINS_FILE}" ]] || die "Cannot find ${PINS_FILE}. Run this script from the repo root."

# ── Find Python >= 3.10 ──────────────────────────────────────────────────────
PYTHON_CANDIDATES=(
    "${INSTALL_ROOT}/miniforge3/bin/python3"
    "${HOME}/miniforge3/bin/python3"
    "${HOME}/mambaforge/bin/python3"
    "/usr/bin/python3"
    "python3"
    "python"
)

find_python() {
    for candidate in "${PYTHON_CANDIDATES[@]}"; do
        if command -v "${candidate}" &>/dev/null || [[ -x "${candidate}" ]]; then
            local version
            version="$("${candidate}" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || true)"
            [[ -z "${version}" ]] && continue
            local major="${version%%.*}" minor="${version#*.}"
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
    info "Using Python $("${BASE_PYTHON}" --version 2>&1) at ${BASE_PYTHON}"
else
    die "No Python >= 3.10 found. Install Python 3.10+ or Miniforge first."
fi

# ── Find or build the .vsix ──────────────────────────────────────────────────
VSIX_FILE="$(ls "${REPO_DIR}/"*.vsix 2>/dev/null | head -1 || true)"
if [[ -z "${VSIX_FILE}" ]]; then
    info "No .vsix found in repo root. Building extension..."
    (cd "${REPO_DIR}" && npm run build && npx vsce package --no-dependencies -o "${REPO_DIR}/kweb-gds-viewer.vsix")
    VSIX_FILE="$(ls "${REPO_DIR}/"*.vsix 2>/dev/null | head -1 || true)"
    [[ -z "${VSIX_FILE}" ]] && die "Failed to build .vsix"
fi
info "Using extension: $(basename "${VSIX_FILE}")"

# ── Create shared install directory ───────────────────────────────────────────
info "Installing to ${INSTALL_ROOT} ..."
mkdir -p "${INSTALL_ROOT}"

# ── Create shared Python venv ─────────────────────────────────────────────────
info "Creating shared Python venv at ${VENV_DIR} ..."
"${BASE_PYTHON}" -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --quiet --upgrade pip
"${VENV_DIR}/bin/pip" install --quiet -r "${PINS_FILE}"

KWEB_VER="$("${VENV_DIR}/bin/python" -c "import kweb; print(kweb.__version__)" 2>/dev/null || echo "unknown")"
info "Installed kweb ${KWEB_VER} into shared venv"

# ── Copy .vsix and user install script ────────────────────────────────────────
cp "${VSIX_FILE}" "${INSTALL_ROOT}/kweb-gds-viewer.vsix"
cp "${SCRIPT_DIR}/install.sh" "${INSTALL_ROOT}/install"
chmod +x "${INSTALL_ROOT}/install"

# ── Set permissions: world-readable + executable ──────────────────────────────
chmod -R a+rX "${INSTALL_ROOT}"
chmod a+rx "${VENV_DIR}/bin/"*

# ── Verify the probe that the extension runs ──────────────────────────────────
if KWEB_FILESLOCATION=/tmp "${VENV_DIR}/bin/python" -c "import kweb.default, uvicorn" 2>/dev/null; then
    success "Probe 'import kweb.default, uvicorn' passed."
else
    die "Probe 'import kweb.default, uvicorn' FAILED. Check package compatibility."
fi

success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
success "Admin install complete!"
success ""
success "Shared venv:  ${VENV_DIR}/bin/python"
success "Extension:    ${INSTALL_ROOT}/kweb-gds-viewer.vsix"
success "User script:  ${INSTALL_ROOT}/install"
success ""
success "Each user now runs (no sudo needed):"
success "  ${INSTALL_ROOT}/install"
success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
