#!/bin/bash
set -euxo pipefail

echo "Starting build_kernel_modules.sh - Checking and potentially building kernel modules."

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

# Common build dependencies for kernel modules
COMMON_BUILD_DEPS=(
    git
    make
    gcc
    dkms
    # Add any other universally required build dependencies
)

ANBOX_MODULES_REPO_URL="https://github.com/choff/anbox-modules.git"
ANBOX_MODULES_REPO_COMMIT="" # Leave empty if you want to use the default branch (e.g., 'main')

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
    echo "${modules_missing}" # Return true/false
}

install_temp_build_deps() {
    echo "Installing temporary build dependencies for kernel modules..."
    dnf5 install -y "${COMMON_BUILD_DEPS[@]}" \
        "kernel-headers-${TARGET_KERNEL_VERSION}" \
        "kernel-devel-${TARGET_KERNEL_VERSION}"
    echo "Temporary build dependencies installed."
}

remove_temp_build_deps() {
    echo "Cleaning up temporary build dependencies..."
    dnf5 remove -y "${COMMON_BUILD_DEPS[@]}" \
        "kernel-headers-${TARGET_KERNEL_VERSION}" \
        "kernel-devel-${TARGET_KERNEL_VERSION}" \
        || true # `|| true` to prevent script failure if a package isn't found
    echo "Temporary build dependencies cleaned up."
}

# --- Main Logic ---

# Check if all required modules are already present
echo "Checking if all required kernel modules are already available..."
MODULES_STILL_MISSING=$(check_modules_present)

if [ "${MODULES_STILL_MISSING}" = "false" ]; then
    echo "All required kernel modules are already present. Skipping module build process."
    echo "build_kernel_modules.sh finished (skipped)."
    exit 0 # Exit successfully if modules are already there
fi

echo "One or more kernel modules are missing. Proceeding with full module build."

# Determine the exact kernel version of the base image
TARGET_KERNEL_VERSION=$(uname -r)
echo "Target Kernel Version detected: ${TARGET_KERNEL_VERSION}"

# Temporarily install build tools and kernel headers
install_temp_build_deps

# Clone Kernel Modules source
echo "Cloning Anbox kernel modules source from ${ANBOX_MODULES_REPO_URL}..."
ANBOX_MODULES_REPO_DIR="/tmp/anbox-modules-repo"
git clone --depth 1 "${ANBOX_MODULES_REPO_URL}" "${ANBOX_MODULES_REPO_DIR}"
cd "${ANBOX_MODULES_REPO_DIR}"

if [ -n "${ANBOX_MODULES_REPO_COMMIT}" ]; then
    echo "Checking out specific commit: ${ANBOX_MODULES_REPO_COMMIT}"
    git checkout "${ANBOX_MODULES_REPO_COMMIT}"
fi

# Copy module sources to /usr/src/ and use dkms to build and install
echo "Copying module sources to /usr/src/ and building/installing with DKMS..."
TEMP_SRC_DIRS=() # Keep track of temporary /usr/src directories for cleanup

for i in "${!ANBOX_SOURCE_DIRS[@]}"; do
    SOURCE_DIR="${ANBOX_SOURCE_DIRS[$i]}"
    DKMS_NAME="${DKMS_MODULE_NAMES[$i]}"
    DKMS_VERSION="${DKMS_MODULE_VERSIONS[$i]}"
    MODULE_PATH="/usr/src/${DKMS_NAME}-${DKMS_VERSION}"

    echo "  - Processing ${SOURCE_DIR} (DKMS: ${DKMS_NAME}/${DKMS_VERSION})..."
    cp -rT "${SOURCE_DIR}" "${MODULE_PATH}"
    TEMP_SRC_DIRS+=("${MODULE_PATH}") # Add to list for cleanup

    dkms install "${DKMS_NAME}/${DKMS_VERSION}" --kernel "${TARGET_KERNEL_VERSION}" --arch x86_64
done
echo "All specified kernel modules built and installed via DKMS."

# Update kernel module dependencies
echo "Running depmod -a..."
depmod -a "${TARGET_KERNEL_VERSION}"
echo "depmod complete."

# Install configuration files (assuming these are shared for all Anbox modules)
echo "Installing Anbox configuration files..."
cp anbox.conf /etc/modules-load.d/
cp 99-anbox.rules /lib/udev/rules.d/
echo "Anbox configuration files installed."

# Cleanup temporary build dependencies
remove_temp_build_deps

# Clean up source directories
echo "Cleaning up source directories..."
rm -rf "${ANBOX_MODULES_REPO_DIR}"
for dir in "${TEMP_SRC_DIRS[@]}"; do
    rm -rf "${dir}"
done
echo "Source directories cleaned up."

echo "build_kernel_modules.sh finished (completed build)."
