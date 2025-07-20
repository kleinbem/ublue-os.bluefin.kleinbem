#!/bin/bash
set -euxo pipefail # Strict error checking, unbound variables, echoing commands

echo "Starting build_kernel_modules.sh - Checking and potentially building kernel modules."

# -------------------------------------------------------------
# 1. HARDCODED TARGET KERNEL VERSION FOR COMPILATION
#    We are explicitly setting this to a known-good Fedora kernel version.
#    This bypasses the potentially misleading 'uname -r' output in the build environment.
#    This is your *actual* kernel version you confirmed: 6.15.6-200.fc42.x86_64
# -------------------------------------------------------------
TARGET_KERNEL_VERSION="6.15.6-200.fc42.x86_64" # <-- HARDCODED TO YOUR CONFIRMED KERNEL
echo "Hardcoded Target Kernel Version for Compilation: ${TARGET_KERNEL_VERSION}"

# For module loading later, we still need the actual running kernel, but that's handled implicitly by dkms install.
# We'll use this TARGET_KERNEL_VERSION for installing kernel-devel and for DKMS's --kernelsourcedir.

# --- Configuration ---
REQUIRED_MODULES=(
    "binder_linux"
    "ashmem_linux"
)
ANBOX_SOURCE_DIRS=(
    "binder"
    "ashmem"
)
DKMS_MODULE_NAMES=(
    "anbox-binder"
    "anbox-ashmem"
)
DKMS_MODULE_VERSIONS=(
    "1"
    "1"
)

# Common build dependencies for kernel modules.
# skopeo and jq are NOT needed as we are not pulling kernel-devel from akmods here.
COMMON_BUILD_DEPS=(
    git
    make
    gcc
    dkms
    "kernel-devel-${TARGET_KERNEL_VERSION}" # This package *should* now be found in standard repos
)

ANBOX_MODULES_REPO_URL="https://github.com/choff/anbox-modules.git"
# IMPORTANT: Highly recommended to specify a compatible commit hash for Linux 6.15.x.
# Check choff/anbox-modules GitHub for a commit known to work with Linux 6.15.x.
# Example: ANBOX_MODULES_REPO_COMMIT="a1b2c3d4e5f6..." # REPLACE with actual commit
ANBOX_MODULES_REPO_COMMIT=""


# --- Functions ---

check_modules_present() {
    # This check is still against the *running* kernel, which might be different from TARGET_KERNEL_VERSION.
    # It just determines if we need to build at all.
    local modules_missing=false
    local current_running_kernel=$(uname -r)
    echo "  (Internal) Current running kernel for modprobe check: ${current_running_kernel}"

    if ! modprobe -n binder_linux &>/dev/null; then
        echo "  - binder_linux module not found."
        modules_missing=true
    else
        echo "  - binder_linux module found."
    fi

    if ! modprobe -n ashmem_linux &>/dev/null; then
        echo "  - ashmem_linux module not found."
        modules_missing=true
    else
        echo "  - ashmem_linux module found."
    fi
    echo "${modules_missing}"
}

install_temp_build_deps() {
    echo "Installing temporary build dependencies for kernel modules (including kernel-devel-${TARGET_KERNEL_VERSION})..."
    # Using rpm-ostree install for all build deps. This should now succeed.
    rpm-ostree install --apply-live --allow-inactive "${COMMON_BUILD_DEPS[@]}"
    echo "Temporary build dependencies installed."
}

remove_temp_build_deps() {
    echo "Cleaning up temporary build dependencies..."
    rpm-ostree override remove "${COMMON_BUILD_DEPS[@]}" || true
    echo "Temporary build dependencies cleaned up."
}

# --- Main Logic ---

# 0. Check if all required modules are already present
echo "Checking if all required kernel modules are already available..."
MODULES_STILL_MISSING=$(check_modules_present)

if [ "${MODULES_STILL_MISSING}" = "false" ]; then
    echo "All required kernel modules are already present. Skipping module build process."
    echo "build_kernel_modules.sh finished (skipped)."
    exit 0
fi

echo "One or more kernel modules are missing. Proceeding with full module build."

# Define the kernel source directory where kernel-devel installs headers
KERNEL_SOURCE_DIR="/usr/src/kernels/${TARGET_KERNEL_VERSION}" # Uses the HARDCODED version
echo "DKMS will use kernel source directory: ${KERNEL_SOURCE_DIR}"

# 2. Temporarily install general build tools AND kernel-devel from standard repos
install_temp_build_deps

# >>> Verify kernel source directory *after* installation <<<
echo "Verifying kernel source directory contents AFTER kernel-devel installation:"
ls -l "${KERNEL_SOURCE_DIR}" || true
if [ ! -d "${KERNEL_SOURCE_DIR}" ] || [ -z "$(ls -A "${KERNEL_SOURCE_DIR}")" ]; then
    echo "CRITICAL ERROR: Kernel source directory ${KERNEL_SOURCE_DIR} is still empty or does NOT exist after attempting installation!"
    echo "This indicates that 'kernel-devel-${TARGET_KERNEL_VERSION}' package was not successfully installed or did not populate headers as expected."
    echo "Cannot proceed with module compilation."
    exit 1 # Exit with error, as this is unrecoverable without headers
fi

# >>> Create the expected DKMS symlink <<<
echo "Creating /lib/modules/$(uname -r)/build symlink for DKMS..."
# Note: This symlink is for the *running kernel* but points to the *hardcoded compilation kernel's* headers.
mkdir -p /lib/modules/"$(uname -r)"/
ln -sfn "${KERNEL_SOURCE_DIR}" /lib/modules/"$(uname -r)"/build
echo "Symlink created. Verifying symlink target:"
ls -l /lib/modules/"$(uname -r)"/build


# 3. Clone Anbox Kernel Modules source
echo "Cloning Anbox kernel modules source from ${ANBOX_MODULES_REPO_URL}..."
ANBOX_MODULES_REPO_DIR="/tmp/anbox-modules-repo"
git clone --depth 1 "${ANBOX_MODULES_REPO_URL}" "${ANBOX_MODULES_REPO_DIR}"
cd "${ANBOX_MODULES_REPO_DIR}"

if [ -n "${ANBOX_MODULES_REPO_COMMIT}" ]; then
    echo "Checking out specific commit: ${ANBOX_MODULES_REPO_COMMIT}"
    git checkout "${ANBOX_MODULES_REPO_COMMIT}"
fi

# 4. Copy module sources to /usr/src/ and use dkms to build and install
echo "Copying module sources to /usr/src/ and building/installing with DKMS..."
TEMP_SRC_DIRS=()

for i in "${!ANBOX_SOURCE_DIRS[@]}"; do
    SOURCE_DIR="${ANBOX_SOURCE_DIRS[$i]}"
    DKMS_NAME="${DKMS_MODULE_NAMES[$i]}"
    DKMS_VERSION="${DKMS_MODULE_VERSIONS[$i]}"
    MODULE_PATH="/usr/src/${DKMS_NAME}-${DKMS_VERSION}"

    echo "  - Processing ${SOURCE_DIR} (DKMS: ${DKMS_NAME}/${DKMS_VERSION})..."
    cp -rT "${SOURCE_DIR}" "${MODULE_PATH}"
    TEMP_SRC_DIRS+=("${MODULE_PATH}")

    echo "Attempting DKMS build for ${DKMS_NAME}/${DKMS_VERSION} (verbose output follows)..."
    # Build with --kernelsourcedir pointing to the *hardcoded* kernel-devel headers
    dkms build "${DKMS_NAME}/${DKMS_VERSION}" --kernelsourcedir "${KERNEL_SOURCE_DIR}" --arch x86_64 --verbose
    
    BUILD_LOG_PATH="/var/lib/dkms/${DKMS_NAME}/${DKMS_VERSION}/build/make.log"
    if [ -f "${BUILD_LOG_PATH}" ]; then
        echo "DKMS build log for ${DKMS_NAME} at ${BUILD_LOG_PATH}:"
        cat "${BUILD_LOG_PATH}"
    else
        echo "DKMS build log not found at ${BUILD_LOG_PATH}."
    fi
    
    echo "Attempting DKMS install for ${DKMS_NAME}/${DKMS_VERSION}..."
    # Install for the *currently running kernel* (uname -r)
    dkms install "${DKMS_NAME}/${DKMS_VERSION}"

done
echo "All specified kernel modules built and installed via DKMS."

# 5. Update kernel module dependencies
echo "Running depmod -a..."
# Use the running kernel version for depmod
depmod -a "$(uname -r)"
echo "depmod complete."

# 6. Install configuration files (specific to Anbox)
echo "Installing Anbox configuration files..."
cp anbox.conf /etc/modules-load.d/
cp 99-anbox.rules /lib/udev/rules.d/
echo "Anbox configuration files installed."

# 7. Cleanup temporary build dependencies
remove_temp_build_deps

# 8. Clean up source directories
echo "Cleaning up source directories..."
rm -rf "${ANBOX_MODULES_REPO_DIR}"
for dir in "${TEMP_SRC_DIRS[@]}"; do
    rm -rf "${dir}"
done
echo "Source directories cleaned up."

echo "build_kernel_modules.sh finished (completed build)."
