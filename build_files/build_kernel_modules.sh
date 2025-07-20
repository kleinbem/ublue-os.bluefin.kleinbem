#!/bin/bash
set -euxo pipefail # Strict error checking, unbound variables, echoing commands

echo "Starting build_kernel_modules.sh - Copying pre-built Waydroid kernel modules."

# -------------------------------------------------------------
# 1. Determine the exact kernel version of the base image (for module loading)
#    This is your problematic 6.11.0-1018-azure kernel.
# -------------------------------------------------------------
TARGET_KERNEL_VERSION=$(uname -r)
echo "Target Kernel Version detected: ${TARGET_KERNEL_VERSION}"

# --- Configuration ---
REQUIRED_MODULES=(
    "binder_linux"
    "ashmem_linux"
)

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

# --- Main Logic ---

# 0. Check if all required modules are already present
echo "Checking if all required kernel modules are already available..."
MODULES_STILL_MISSING=$(check_modules_present)

if [ "${MODULES_STILL_MISSING}" = "false" ]; then
    echo "All required kernel modules are already present. Skipping module installation."
    echo "build_kernel_modules.sh finished (skipped)."
    exit 0
fi

echo "One or more kernel modules are missing. Proceeding with pre-built module installation."

# -------------------------------------------------------------
# 2. Copy pre-built kernel modules from /tmp (where Containerfile copied them)
# -------------------------------------------------------------
echo "Copying pre-built kernel modules for ${TARGET_KERNEL_VERSION}..."
MODULE_DEST_DIR="/usr/lib/modules/${TARGET_KERNEL_VERSION}/extra"
mkdir -p "${MODULE_DEST_DIR}"

# Copy the actual .ko files from the /tmp location where Containerfile placed them
cp "/tmp/extracted_binder_linux.ko" "${MODULE_DEST_DIR}/"
cp "/tmp/extracted_ashmem_linux.ko" "${MODULE_DEST_DIR}/"

echo "Pre-built modules copied to ${MODULE_DEST_DIR}."

# -------------------------------------------------------------
# 3. Update kernel module dependencies
# -------------------------------------------------------------
echo "Running depmod -a..."
depmod -a "${TARGET_KERNEL_VERSION}"
echo "depmod complete."

# -------------------------------------------------------------
# 4. Install configuration files
# -------------------------------------------------------------
echo "Installing Anbox configuration files..."
cp /tmp/anbox.conf /etc/modules-load.d/
cp /tmp/99-anbox.rules /lib/udev/rules.d/
echo "Anbox configuration files installed."

# -------------------------------------------------------------
# 5. Cleanup (no build source/deps to remove in this case, just temp files)
# -------------------------------------------------------------
echo "Cleaning up temporary extracted module files..."
rm -f /tmp/extracted_binder_linux.ko \
      /tmp/extracted_ashmem_linux.ko \
      /tmp/anbox.conf \
      /tmp/99-anbox.rules
echo "Temporary files cleaned up."

echo "build_kernel_modules.sh finished (completed pre-built module installation)."
