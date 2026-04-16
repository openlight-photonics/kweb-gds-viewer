#!/usr/bin/env bash
# packaging/make-repo.sh — publish the built RPM into a local dnf repository
#
# Usage (run as yourself, no sudo needed to write to the repo dir if you own it):
#   bash packaging/make-repo.sh /srv/repos/kweb-gds-viewer
#
# Then on each target host, drop a file into /etc/yum.repos.d/ like:
#   [kweb-gds-viewer]
#   name=kweb GDS Viewer
#   baseurl=file:///srv/repos/kweb-gds-viewer    # or http://your-server/repos/...
#   enabled=1
#   gpgcheck=0
#
# After that, users install with:  sudo dnf install kweb-gds-viewer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"

info()    { printf '\e[1;34m[make-repo]\e[0m %s\n' "$*"; }
success() { printf '\e[1;32m[make-repo]\e[0m %s\n' "$*"; }
die()     { printf '\e[1;31m[make-repo]\e[0m ERROR: %s\n' "$*" >&2; exit 1; }

REPO_DIR="${1:-}"
[[ -n "${REPO_DIR}" ]] || die "Usage: $0 <repo-directory>"

command -v createrepo_c >/dev/null || die "createrepo_c not found. Install createrepo_c."

RPM_COUNT="$(ls "${DIST_DIR}"/*.rpm 2>/dev/null | wc -l)"
(( RPM_COUNT > 0 )) || die "No .rpm files in ${DIST_DIR}. Run packaging/build-rpm.sh first."

mkdir -p "${REPO_DIR}"

info "Copying ${RPM_COUNT} RPM(s) into ${REPO_DIR} ..."
cp "${DIST_DIR}"/*.rpm "${REPO_DIR}/"

info "Running createrepo_c ..."
createrepo_c --update "${REPO_DIR}"

success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
success "Repo updated: ${REPO_DIR}"
success ""
success "To configure a host, create /etc/yum.repos.d/kweb-gds-viewer.repo:"
success "  [kweb-gds-viewer]"
success "  name=kweb GDS Viewer"
success "  baseurl=file://${REPO_DIR}"
success "  enabled=1"
success "  gpgcheck=0"
success ""
success "Then:  sudo dnf install kweb-gds-viewer"
success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
