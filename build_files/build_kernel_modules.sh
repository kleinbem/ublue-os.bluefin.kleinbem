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

# Common build dependencies for kernel modules (re-including kernel-devel)
COMMON_BUILD_DEPS=(
    git
    make
    gcc
    dkms
    # Add any other universally required build dependencies here (e.g., flex, bison, libelf-devel)
    "kernel-devel-${TARGET_KERNEL_VERSION}" # <-- RE-ADDING THIS HERE
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
    # Use rpm-ostree install - it's designed for layering and can fix state
    # Added --force to ensure it truly re-installs if needed.
    rpm-ostree install --apply-live --allow-inactive --force "${COMMON_BUILD_DEPS[@]}"
    echo "Temporary build dependencies installed."
}

remove_temp_build_deps() {
    echo "Cleaning up temporary build dependencies..."
    # Use rpm-ostree override remove for clean removal of layered packages
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

# 1. Determine the exact kernel version of the base image
TARGET_KERNEL_VERSION=$(uname -r)
echo "Target Kernel Version detected: ${TARGET_KERNEL_VERSION}"

# Define the kernel source directory where kernel-devel installs headers
KERNEL_SOURCE_DIR="/usr/src/kernels/${TARGET_KERNEL_VERSION}"
echo "DKMS will use kernel source directory: ${KERNEL_SOURCE_DIR}"

# 2. Temporarily install general build tools AND kernel-devel
# This time using rpm-ostree install with force.
install_temp_build_deps

# >>> Verify kernel source directory *again* after installation <<<
echo "Verifying kernel source directory contents AFTER forced install:"
ls -l "${KERNEL_SOURCE_DIR}" || true
if [ ! -d "${KERNEL_SOURCE_DIR}" ] || [ -z "$(ls -A "${KERNEL_SOURCE_DIR}")" ]; then
    echo "CRITICAL ERROR: Kernel source directory ${KERNEL_SOURCE_DIR} is still empty or does NOT exist after attempting installation!"
    echo "This indicates a fundamental issue with kernel-devel package or base image. Cannot proceed."
    exit 1 # Exit with error, as this is unrecoverable without headers
fi

# >>> Create the expected DKMS symlink (still needed if kernel-devel doesn't do it) <<<
echo "Creating /lib/modules/${TARGET_KERNEL_VERSION}/build symlink for DKMS..."
mkdir -p /lib/modules/"${TARGET_KERNEL_VERSION}"/
ln -sfn "${KERNEL_SOURCE_DIR}" /lib/modules/"${TARGET_KERNEL_VERSION}"/build
echo "Symlink created. Verifying symlink target:"
ls -l /lib/modules/"${TARGET_KERNEL_VERSION}"/build


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

    echo "Attempting DKMS build for ${DKMS_NAME}/${DKMS_VERSION} (verbose output follows)..."
    dkms build "${DKMS_NAME}/${DKMS_VERSION}" --kernelsourcedir "${KERNEL_SOURCE_DIR}" --arch x86_64 --verbose
    
    BUILD_LOG_PATH="/var/lib/dkms/${DKMS_NAME}/${DKMS_VERSION}/build/make.log"
    if [ -f "${BUILD_LOG_PATH}" ]; then
        echo "DKMS build log for ${DKMS_NAME} at ${BUILD_LOG_PATH}:"
        cat "${BUILD_LOG_PATH}"
    else
        echo "DKMS build log not found at ${BUILD_LOG_PATH}."
    fi
    
    echo "Attempting DKMS install for ${DKMS_NAME}/${DKMS_VERSION}..."
    dkms install "${DKMS_NAME}/${DKMS_VERSION}"

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
