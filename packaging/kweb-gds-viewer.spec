Name:           kweb-gds-viewer
Version:        %{_version}
Release:        1%{?dist}
Summary:        GDS/OAS layout viewer for Cursor powered by kweb
License:        MIT
BuildArch:      x86_64

# Prevent RPM from auto-scanning the bundled Python tree for deps/provides —
# it would generate spurious Requires: libpython3.12.so.1.0, Provides: python(abi), etc.
AutoReqProv:    no

# This is a pre-compiled, self-contained binary bundle.
# Disable the debuginfo subpackage: the stripped python-build-standalone
# binaries have no ELF build-IDs, which RHEL8 find-debuginfo.sh --strict-build-id
# treats as a fatal error. We have no source to debug anyway.
%define debug_package %{nil}

# Disable /usr/lib/.build-id symlink generation. Our bundled Python ships the
# same shared libraries (libssl, libcrypto, libffi, etc.) as system packages.
# Without this, RPM creates build-id symlinks that conflict with libidn2, brotli,
# krb5-libs, and many others already installed on the host.
%global _build_id_links none

# Disable post-install BRP processing: brp-mangle-shebangs rewrites
# #!/usr/bin/env python3 in the bundled stdlib to #!/usr/libexec/platform-python
# (Python 3.6), and brp-python-bytecompile fails trying to compile py3.12 files.
%define __os_install_post %{nil}

# Source0: repo snapshot tarball (vsix, install.sh, ocp-kweb-pins.txt)
# Source1: python-build-standalone install_only tarball (cpython 3.12, linux x86_64)
# Source2: pre-downloaded wheels tarball (all deps from ocp-kweb-pins.txt)
Source0:        kweb-gds-viewer-%{_version}.tar.gz
Source1:        cpython-3.12-linux-x86_64-install_only.tar.gz
Source2:        wheels.tar.gz

%define instdir /opt/tools/kweb-gds-viewer

%description
kweb-gds-viewer embeds the kweb Python ASGI server in a Cursor (VS Code) custom
editor to provide an interactive GDS/OAS layout viewer. This package installs
a self-contained Python 3.12 runtime plus all required wheels into %{instdir} so
that no separate Python installation is needed on the target host. Each user then
runs %{instdir}/install (no sudo) to register the Cursor extension.

%prep
%setup -q -n kweb-gds-viewer-%{_version}

# Unpack wheels alongside the source tree so the install section can find them.
tar -xf %{SOURCE2} -C .

%build
# Nothing to compile; the .vsix is pre-built by build-rpm.sh.

%install
rm -rf %{buildroot}

# ── 1. Extract python-build-standalone ───────────────────────────────────────
mkdir -p %{buildroot}%{instdir}/python
# The tarball has a single top-level directory (e.g. python/) — strip it.
tar -xf %{SOURCE1} --strip-components=1 -C %{buildroot}%{instdir}/python

# ── 2. Install Python packages from bundled wheels (no network) ───────────────
%{buildroot}%{instdir}/python/bin/python3.12 -m pip install \
    --quiet \
    --no-index \
    --find-links wheels \
    -r ocp-kweb-pins.txt

# ── 3. Fix shebangs baked with the buildroot prefix ───────────────────────────
# pip installs entry-point scripts (pip3, uvicorn, etc.) into python/bin/ with
# shebangs that include the buildroot path. Only those ~20 files need patching;
# .py source files in site-packages do not contain absolute shebangs.
find %{buildroot}%{instdir}/python/bin -maxdepth 1 -type f \
    -exec sed -i "s|%{buildroot}||g" {} \;

# ── 4. Stable entry-point symlink ─────────────────────────────────────────────
mkdir -p %{buildroot}%{instdir}/bin
ln -sf ../python/bin/python3.12 %{buildroot}%{instdir}/bin/python

# ── 5. Extension assets ───────────────────────────────────────────────────────
install -m 0644 kweb-gds-viewer-%{_version}.vsix \
    %{buildroot}%{instdir}/kweb-gds-viewer.vsix
install -m 0755 install.sh  %{buildroot}%{instdir}/install
install -m 0644 ocp-kweb-pins.txt %{buildroot}%{instdir}/ocp-kweb-pins.txt

%files
%defattr(-,root,root,-)
%{instdir}

%post
# Verify the bundled kweb import works after install (best-effort).
if KWEB_FILESLOCATION=/tmp %{instdir}/bin/python \
       -c "import kweb.default, uvicorn" >/dev/null 2>&1; then
    echo "kweb-gds-viewer: Python runtime OK."
else
    echo "kweb-gds-viewer: WARNING — kweb import probe failed. Try reinstalling." >&2
fi
echo "kweb-gds-viewer: installed to %{instdir}."
echo "Each user should now run (no sudo required):"
echo "  %{instdir}/install"

%preun
# Nothing to clean up in the shared tree; user per-extension data lives in ~/

%changelog
* Thu Apr 16 2026 optocompiler <admin@optocompiler> - 1.1.1-1
- Fix build-id symlink conflicts with system packages (libidn2, brotli, krb5-libs, etc.).
  Add %%global _build_id_links none to suppress /usr/lib/.build-id/ entries.

* Thu Apr 16 2026 optocompiler <admin@optocompiler> - 1.1.0-1
- Add RPM packaging with bundled python-build-standalone 3.12 and kweb 1.1.10.
- Zero external Python dependencies; works on AlmaLinux 8/9/10 out of the box.
- Per-user install script requires no sudo.
