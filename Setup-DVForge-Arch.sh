#!/usr/bin/env bash
# Setup-DVForge-Arch.sh
# Sets up a native Arch Linux build environment for DVForge (Linux/Android).
#
# Idempotent — safe to re-run. System packages are installed with pacman;
# portable SDKs are installed into the project-local .toolchains/ directory by
# the same builder/toolchains.py used by the GUI.
#
# Usage:
#   ./Setup-DVForge-Arch.sh
#   ./Setup-DVForge-Arch.sh --appimage
#   ./Setup-DVForge-Arch.sh --skip-toolchains
#
# --appimage prepares DVForge's rootless Podman AppImage packaging container.
# Unlike the legacy Ubuntu pip setup, the current AppImage integration uses a
# pinned container, so no system-wide appimage-builder installation is needed.

set -euo pipefail

INSTALL_APPIMAGE=false
INSTALL_TOOLCHAINS=true

show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --appimage          Install Podman dependencies and prepare the AppImage
                      packaging container.
  --skip-toolchains   Skip portable toolchain bootstrap (Rust 1.75, Java 17,
                      Android SDK/NDK, Flutter, LLVM, vcpkg, and sccache).
  -h, --help          Show this help message.

Default behavior:
  Updates Arch Linux, installs native build dependencies, and installs the
  failed precheck items for Linux/Android. Portable SDKs go under .toolchains/;
  Rust and sccache go under ~/.cargo/.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --appimage)
            INSTALL_APPIMAGE=true
            shift
            ;;
        --skip-toolchains)
            INSTALL_TOOLCHAINS=false
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run '$(basename "$0") --help' for usage." >&2
            exit 1
            ;;
    esac
done

log()  { printf '\n=== %s ===\n' "$1"; }
ok()   { printf '  [OK] %s\n' "$1"; }
skip() { printf '  [SKIP] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1" >&2; }
fail() { printf '  [ERROR] %s\n' "$1" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

install_packages() {
    # Omarchy deliberately blocks direct pacman system transactions. Its
    # package helper also keeps the Omarchy package state and update history
    # consistent. Plain Arch uses pacman directly.
    if have omarchy; then
        omarchy pkg add "$@"
    else
        sudo pacman -S --needed --noconfirm "$@"
    fi
}

[[ "${EUID}" -ne 0 ]] || fail "Run this script as a normal user, not root."
have pacman || fail "pacman was not found; this script is for Arch Linux."
have sudo || fail "sudo is required to install Arch system packages."

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log "Updating Arch packages"
sudo -v
trap 'sudo -k' EXIT
# Arch does not support partial upgrades, so keep the system in sync before
# installing build dependencies. Omarchy must perform this transaction through
# its own update command; its pacman hook rejects a direct `pacman -Syu`.
if have omarchy; then
    omarchy update -y
else
    sudo pacman -Syu --needed --noconfirm
fi
ok "Packages updated"

log "Installing build dependencies"

# Mapping of the packages used by Setup-DVForge-Ubuntu.sh to Arch packages.
# pacman resolves the runtime libraries pulled in by these development tools.
DEPS=(
    base-devel git python python-pip curl wget unzip zip tar
    pkgconf openssl sqlite clang llvm
    cmake ninja file rpm-tools dpkg libarchive
    nasm yasm autoconf automake libtool
    pam gtk3 libayatana-appindicator libxrandr xdotool
    alsa-lib libpulse gstreamer gst-plugins-base
    libva libvdpau patchelf libffi potrace imagemagick
)

if [[ "${INSTALL_APPIMAGE}" == true ]]; then
    # The AppImage builder runs in a rootless container. Arch calls the
    # subordinate-ID support tools newuidmap/newgidmap (provided by shadow).
    DEPS+=(podman shadow slirp4netns fuse-overlayfs)
fi

# Add optional multilib/FUSE packages only when they exist in the configured
# repositories. This keeps the script usable when Arch multilib is disabled.
for optional_pkg in lib32-zlib lib32-ncurses lib32-gcc-libs fuse2; do
    if pacman -Si "${optional_pkg}" >/dev/null 2>&1; then
        DEPS+=("${optional_pkg}")
    fi
done

install_packages "${DEPS[@]}"
ok "Build dependencies installed"

if have rpmbuild; then
    ok "rpmbuild present"
else
    warn "rpmbuild is missing; RPM output will not be available"
fi

if have magick || have convert; then
    ok "ImageMagick present"
else
    warn "ImageMagick is missing; branding conversion may be unavailable"
fi

if have dpkg-deb; then
    ok "dpkg-deb present"
else
    warn "dpkg-deb is missing; DEB output will not be available"
fi

if [[ "${INSTALL_TOOLCHAINS}" == true ]]; then
    log "Bootstrapping portable toolchains"

    PY_EXEC="$(command -v python || command -v python3 || true)"
    [[ -n "${PY_EXEC}" ]] || fail "Python 3 was not found after package installation"

    TOOLCHAINS_PY="${PROJECT_DIR}/builder/toolchains.py"
    [[ -f "${TOOLCHAINS_PY}" ]] || fail "Could not find ${TOOLCHAINS_PY}"

    # Make rustup/cargo installed for the current user visible to Python and
    # to every subprocess started by the builder. The toolchain installer uses
    # the official rustup bootstrap, so Rust 1.75 is not replaced by Arch's
    # rolling rust package.
    export PATH="${HOME}/.cargo/bin:${PATH}"

    TOOLCHAIN_IDS=(rust java android_sdk android_ndk flutter llvm vcpkg sccache)
    if [[ "${INSTALL_APPIMAGE}" == true ]]; then
        TOOLCHAIN_IDS+=(appimage_builder)
    fi

    log "Running toolchains.py"
    # The CLI entry point intentionally keeps going after an individual
    # failure. Call the API here instead, so setup cannot report success when
    # (for example) rustup, vcpkg, or sdkmanager failed.
    "${PY_EXEC}" - "${PROJECT_DIR}" "${TOOLCHAIN_IDS[@]}" <<'PY'
import os
import sys

root = os.path.abspath(sys.argv[1])
sys.path.insert(0, root)
from builder import toolchains

ids = sys.argv[2:]
result = toolchains.install_many(ids, root, print)
toolchains.apply_persisted_env(root)
errors = result.get("errors") or []
if errors:
    print("\nToolchain installation errors:")
    for tool, error in errors:
        print(f"  - {tool}: {error}")
    raise SystemExit(1)
print("Toolchains installed:", ", ".join(result.get("installed") or ids))
PY
    ok "Toolchains installed and env.json generated"

    # Load env.json into this process so the verification below sees the
    # project-local SDKs immediately, without requiring a new terminal.
    eval "$(${PY_EXEC} - "${PROJECT_DIR}" <<'PY'
import os
import shlex
import sys

root = os.path.abspath(sys.argv[1])
sys.path.insert(0, root)
from builder import toolchains

env = toolchains.apply_persisted_env(root)
for key, value in (env.get("vars") or {}).items():
    if value:
        print(f"export {key}={shlex.quote(value)}")
paths = [p for p in (env.get("path") or []) if os.path.isdir(p)]
if paths:
    print("export PATH=" + ":".join(shlex.quote(p) for p in paths) + ":$PATH")
PY
)"

    # Keep the same environment for future shells. Only replace the block we
    # own, so re-running setup remains idempotent and does not touch user
    # configuration outside the markers.
    PROFILE_MARKER="# >>> DVForge Arch build env >>>"
    PROFILE_END="# <<< DVForge Arch build env <<<"
    PROFILE_ENV="$(${PY_EXEC} - "${PROJECT_DIR}" <<'PY'
import os
import shlex
import sys

root = os.path.abspath(sys.argv[1])
sys.path.insert(0, root)
from builder import toolchains

env = toolchains.apply_persisted_env(root)
for key, value in (env.get("vars") or {}).items():
    if value:
        print(f"export {key}={shlex.quote(value)}")
paths = [p for p in (env.get("path") or []) if p]
if paths:
    print("export PATH=" + ":".join(shlex.quote(p) for p in paths) + ":$PATH")
PY
)"

    write_profile() {
        local profile="$1"
        local tmp
        touch "${profile}"
        if grep -qF "${PROFILE_MARKER}" "${profile}"; then
            tmp="${profile}.dvforge.tmp"
            awk -v start="${PROFILE_MARKER}" -v end="${PROFILE_END}" '
                $0 == start { skip=1; next }
                $0 == end { skip=0; next }
                !skip { print }
            ' "${profile}" > "${tmp}"
            mv "${tmp}" "${profile}"
        fi
        {
            printf '\n%s\n' "${PROFILE_MARKER}"
            printf '%s\n' "${PROFILE_ENV}"
            printf '%s\n' "${PROFILE_END}"
        } >> "${profile}"
        ok "Environment block written to ${profile}"
    }

    write_profile "${HOME}/.bashrc"
    if [[ -f "${HOME}/.zshrc" ]]; then
        write_profile "${HOME}/.zshrc"
    fi

    if have rustup || [[ -x "${HOME}/.cargo/bin/rustup" ]]; then
        rustup toolchain install 1.75 --profile minimal || true
        rustup default 1.75 || true
        rustup component add rustfmt --toolchain 1.75 || true
        ok "Rust 1.75 toolchain and rustfmt configured"
    else
        warn "rustup was not found; Rust will need to be installed from the GUI"
    fi

    log "Verifying Linux/Android precheck requirements"
    VERIFY_APPIMAGE="${INSTALL_APPIMAGE}" "${PY_EXEC}" - "${PROJECT_DIR}" <<'PY'
import os
import sys

root = os.path.abspath(sys.argv[1])
sys.path.insert(0, root)
from builder import prereqs, toolchains

toolchains.apply_persisted_env(root)
required = [
    "rust", "flutter", "clang", "llvm", "vcpkg", "java",
    "android_ndk", "android_sdk", "rpmbuild", "dpkg_deb", "sccache",
    "imagemagick", "potrace", "cmake", "ninja", "nasm", "pkgconfig",
]
if os.environ.get("VERIFY_APPIMAGE") == "true":
    required.append("appimage_builder")

failed = []
for tool in required:
    status = prereqs.CHECKS[tool]()
    if status.get("present"):
        print(f"  [OK] {prereqs.LABELS[tool]}")
    else:
        print(f"  [ERROR] {prereqs.LABELS[tool]}")
        if status.get("hint"):
            print(f"          {status['hint']}")
        failed.append(tool)
if failed:
    raise SystemExit("Precheck requirements still missing: " + ", ".join(failed))
PY
    ok "Linux/Android precheck requirements passed"

    NDK_DIR="${PROJECT_DIR}/.toolchains/android_ndk"
    if [[ -d "${NDK_DIR}" ]]; then
        log "Fixing Android NDK permissions"
        find "${NDK_DIR}" -type f \
            -path '*/toolchains/llvm/prebuilt/*/bin/*' -exec chmod +x {} +
        find "${NDK_DIR}" -maxdepth 3 -type f \
            \( -name ndk-build -o -name '*.sh' \) -exec chmod +x {} +
        ok "Android NDK permissions fixed"
    fi
else
    skip "Portable toolchains installation (--skip-toolchains passed)"
fi

log "Setup complete"
printf '  Run the application with:\n'
printf '    cd %q && ./run.sh\n' "${PROJECT_DIR}"
printf '  Then open http://127.0.0.1:8765\n'
