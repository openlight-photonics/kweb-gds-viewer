#!/usr/bin/env bash
# packaging/build-rpm.sh — build the kweb-gds-viewer RPM
#
# Run from the repository root:
#   bash packaging/build-rpm.sh
#
# What this script does:
#   1. Builds the Cursor .vsix from TypeScript source
#   2. Downloads python-build-standalone CPython 3.12 (pinned release, stripped)
#   3. Downloads all Python wheels from ocp-kweb-pins.txt (no network at RPM install time)
#   4. Tars sources into the layout rpmbuild expects
#   5. Runs rpmbuild -bb to produce the .rpm
#   6. Copies the result into packaging/dist/
set -euo pipefail

# ── Pins ──────────────────────────────────────────────────────────────────────
# Read version from package.json so it stays in sync with the npm/vsce version.
VERSION="$(node -p "require('./package.json').version" 2>/dev/null || echo "1.1.0")"
PBS_RELEASE="20260325"
PBS_PYTHON_VER="3.12.13"
PBS_FILENAME="cpython-${PBS_PYTHON_VER}+${PBS_RELEASE}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${PBS_FILENAME}"
# SHA-256 of the stripped glibc tarball (verify with: sha256sum <file>)
PBS_SHA256="c77b4e1c6aa94fa73ce8d7e6cabce0f14635b6520a3564939b70b2490cfe3eff"

PINS_FILE="scripts/ocp-kweb-pins.txt"

# ── Helpers ───────────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/.."
cd "${REPO_DIR}"

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

info()    { printf '\e[1;34m[build-rpm]\e[0m %s\n' "$*"; }
success() { printf '\e[1;32m[build-rpm]\e[0m %s\n' "$*"; }
die()     { printf '\e[1;31m[build-rpm]\e[0m ERROR: %s\n' "$*" >&2; exit 1; }

# ── Pre-checks ────────────────────────────────────────────────────────────────
command -v rpmbuild  >/dev/null || die "rpmbuild not found. Install rpm-build."
command -v npm       >/dev/null || die "npm not found. Install Node.js."
[[ -f "${PINS_FILE}" ]] || die "Cannot find ${PINS_FILE}. Run from the repo root."

# Need a Python >= 3.10 on the build host to run pip download with --python-version.
PYTHON_CANDIDATES=(
    "${HOME}/miniforge3/bin/python3"
    "${HOME}/mambaforge/bin/python3"
    "/usr/bin/python3"
    "python3"
)
BUILD_PYTHON=""
for candidate in "${PYTHON_CANDIDATES[@]}"; do
    if command -v "${candidate}" &>/dev/null || [[ -x "${candidate}" ]]; then
        ver="$("${candidate}" -c "import sys; print(f'{sys.version_info.major}{sys.version_info.minor}')" 2>/dev/null || true)"
        if [[ -n "${ver}" ]] && (( ver >= 310 )); then
            BUILD_PYTHON="$(command -v "${candidate}" 2>/dev/null || echo "${candidate}")"
            break
        fi
    fi
done
[[ -n "${BUILD_PYTHON}" ]] || die "No Python >= 3.10 found on the build host."
info "Build Python: $("${BUILD_PYTHON}" --version 2>&1) at ${BUILD_PYTHON}"

RPMBUILD_ROOT="${BUILD_DIR}/rpmbuild"
mkdir -p "${RPMBUILD_ROOT}"/{SOURCES,SPECS,BUILD,RPMS,SRPMS}

# ── Step 1: Build .vsix ───────────────────────────────────────────────────────
info "Building Cursor extension (.vsix) ..."
VSIX_OUT="${REPO_DIR}/kweb-gds-viewer-${VERSION}.vsix"
npm run build
npx vsce package --no-dependencies -o "${VSIX_OUT}"
[[ -f "${VSIX_OUT}" ]] || die ".vsix not produced at ${VSIX_OUT}"
info "Built: ${VSIX_OUT}"

# ── Step 2: Fetch python-build-standalone (cached) ────────────────────────────
PBS_CACHE="${HOME}/.cache/kweb-gds-viewer-build/${PBS_FILENAME}"
mkdir -p "$(dirname "${PBS_CACHE}")"

if [[ -f "${PBS_CACHE}" ]]; then
    info "Using cached python-build-standalone: ${PBS_CACHE}"
else
    info "Downloading python-build-standalone ${PBS_PYTHON_VER} ..."
    curl -fsSL --retry 3 --output "${PBS_CACHE}" "${PBS_URL}"
    info "Download complete."
fi

# Verify checksum
ACTUAL_SHA="$(sha256sum "${PBS_CACHE}" | awk '{print $1}')"
if [[ "${ACTUAL_SHA}" != "${PBS_SHA256}" ]]; then
    rm -f "${PBS_CACHE}"
    die "SHA-256 mismatch for ${PBS_FILENAME}.\n  expected: ${PBS_SHA256}\n  got:      ${ACTUAL_SHA}"
fi
info "Checksum OK: ${PBS_SHA256}"

cp "${PBS_CACHE}" "${RPMBUILD_ROOT}/SOURCES/cpython-3.12-linux-x86_64-install_only.tar.gz"

# ── Step 3: Download wheels for ocp-kweb-pins.txt ────────────────────────────
info "Downloading Python wheels for ocp-kweb-pins.txt (target: AlmaLinux 8+, glibc >= 2.28, cp312) ..."
WHEELS_DIR="${BUILD_DIR}/wheels"
mkdir -p "${WHEELS_DIR}"

# Provide multiple platform tags so pip can find:
#   - klayout: tagged manylinux_2_27_x86_64.manylinux_2_28_x86_64
#   - watchfiles (uvicorn[standard] dep from kweb): tagged manylinux_2_17_x86_64.manylinux2014_x86_64
#   - pure-Python wheels (any)
# All of these run fine on AlmaLinux 8 (glibc 2.28).
"${BUILD_PYTHON}" -m pip download \
    --quiet \
    --dest "${WHEELS_DIR}" \
    --platform manylinux_2_28_x86_64 \
    --platform manylinux_2_17_x86_64 \
    --platform manylinux2014_x86_64 \
    --python-version 3.12 \
    --implementation cp \
    --abi cp312 \
    --only-binary=:all: \
    -r "${PINS_FILE}"

# Collect any remaining pure-Python dependencies that aren't binary-only.
"${BUILD_PYTHON}" -m pip download \
    --quiet \
    --dest "${WHEELS_DIR}" \
    --python-version 3.12 \
    --no-deps \
    -r "${PINS_FILE}" 2>/dev/null || true

WHEEL_COUNT="$(ls "${WHEELS_DIR}"/*.whl 2>/dev/null | wc -l)"
info "Downloaded ${WHEEL_COUNT} wheels."
(cd "${BUILD_DIR}" && tar -czf "${RPMBUILD_ROOT}/SOURCES/wheels.tar.gz" wheels/)
info "Packed wheels.tar.gz"

# ── Step 4: Build source tarball for the RPM ─────────────────────────────────
info "Creating source tarball kweb-gds-viewer-${VERSION}.tar.gz ..."
SRC_STAGE="${BUILD_DIR}/kweb-gds-viewer-${VERSION}"
mkdir -p "${SRC_STAGE}"

cp "${VSIX_OUT}"             "${SRC_STAGE}/kweb-gds-viewer-${VERSION}.vsix"
cp "scripts/install.sh"      "${SRC_STAGE}/install.sh"
cp "scripts/ocp-kweb-pins.txt" "${SRC_STAGE}/ocp-kweb-pins.txt"

(cd "${BUILD_DIR}" && tar -czf \
    "${RPMBUILD_ROOT}/SOURCES/kweb-gds-viewer-${VERSION}.tar.gz" \
    "kweb-gds-viewer-${VERSION}/")
info "Source tarball ready."

# ── Step 5: Run rpmbuild ──────────────────────────────────────────────────────
cp "packaging/kweb-gds-viewer.spec" "${RPMBUILD_ROOT}/SPECS/"
info "Running rpmbuild ..."
rpmbuild -bb \
    --define "_topdir ${RPMBUILD_ROOT}" \
    --define "_version ${VERSION}" \
    "${RPMBUILD_ROOT}/SPECS/kweb-gds-viewer.spec"

# ── Step 6: Copy result ────────────────────────────────────────────────────────
mkdir -p "${REPO_DIR}/packaging/dist"
find "${RPMBUILD_ROOT}/RPMS" -name "*.rpm" -exec cp {} "${REPO_DIR}/packaging/dist/" \;

RPM_FILE="$(ls "${REPO_DIR}/packaging/dist/"*.rpm 2>/dev/null | sort | tail -1)"
[[ -n "${RPM_FILE}" ]] || die "No .rpm found after rpmbuild."

success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
success "RPM built: ${RPM_FILE}"
success "$(du -sh "${RPM_FILE}" | cut -f1) on disk."
success ""
success "Test install:  sudo dnf localinstall '${RPM_FILE}'"
success "Publish:       bash packaging/make-repo.sh /path/to/your/repo"
success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
