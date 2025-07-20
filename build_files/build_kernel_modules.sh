#!/bin/bash
set -euxo pipefail

echo "Starting build_kernel_modules.sh - Checking and potentially building kernel modules."

# --- Configuration ---
# Define modules to be checked and built.
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

COMMON_BUILD_DEPS=(
    git
    make
    gcc
    dkms
    # Add any other universally required build dependencies here (e.g., flex, bison, libelf-devel)
)

ANBOX_MODULES_REPO_URL="https://github.com/choff/anbox-modules.git"
ANBOX_MODULES_REPO_COMMIT="" # Or your specific commit hash

# --- Functions ---

check_modules_present() {
    local modules_missing=false
    for module in "${REQUIRED_MODULES[@]}"; do
        if ! modprobe -n "${module}" &>/dev/null; then
            echo "  - ${module} module not found."
            modules_missing=true
        else
            echo "  - ${module} module found."
        fi
    done
    echo "${modules_missing}"
}

install_temp_build_deps() {
    echo "Installing temporary build dependencies for kernel modules..."
    dnf5 install -y "${COMMON_BUILD_DEPS[@]}"
    echo "Temporary build dependencies installed."
}

remove_temp_build_deps() {
    echo "Cleaning up temporary build dependencies..."
    dnf5 remove -y "${COMMON_BUILD_DEPS[@]}" || true
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

# 1. Determine the exact kernel version of the base image
TARGET_KERNEL_VERSION=$(uname -r)
echo "Target Kernel Version detected: ${TARGET_KERNEL_VERSION}"

# 2. Temporarily install general build tools (kernel headers/devel are already there)
install_temp_build_deps

# 3. Clone Kernel Modules source
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

    # Explicitly call build first, then install (without --kernel on install)
    dkms build "${DKMS_NAME}/${DKMS_VERSION}" --kernel "${TARGET_KERNEL_VERSION}" --arch x86_64
    dkms install "${DKMS_NAME}/${DKMS_VERSION}" # Removed --kernel here
done
echo "All specified kernel modules built and installed via DKMS."

# 5. Update kernel module dependencies
echo "Running depmod -a..."
depmod -a "${TARGET_KERNEL_VERSION}"
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