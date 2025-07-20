#!/bin/bash
set -euxo pipefail

echo "Starting build_kernel_modules.sh - Finalizing kernel module setup."

# -------------------------------------------------------------
# 1. Determine the exact kernel version for module loading
# -------------------------------------------------------------
TARGET_KERNEL_VERSION=$(uname -r)
echo "Target Running Kernel Version detected: ${TARGET_KERNEL_VERSION}"

# --- Configuration (for verification) ---
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

# 0. Check if all required modules are now present after copying
echo "Verifying if all required kernel modules are now available after Containerfile copy steps..."
MODULES_STILL_MISSING=$(check_modules_present)

if [ "${MODULES_STILL_MISSING}" = "false" ]; then
    echo "All required kernel modules are present. Proceeding with depmod and finalization."
else
    echo "WARNING: One or more kernel modules are still missing after copy steps. Waydroid might not work."
    # We allow the build to continue to see if it installs waydroid,
    # but the user will know there's a module issue.
    # We should add more robust logging to see what was actually copied.
    echo "Contents of /tmp/ after copying from stages:"
    ls -l /tmp/extracted_*.ko /tmp/anbox.conf /tmp/99-anbox.rules || true
    echo "Attempting to copy modules into /usr/lib/modules/..."
    mkdir -p /usr/lib/modules/"${TARGET_KERNEL_VERSION}"/extra/
    cp /tmp/extracted_binder_linux.ko /usr/lib/modules/"${TARGET_KERNEL_VERSION}"/extra/ || echo "Failed to copy binder_linux.ko!"
    cp /tmp/extracted_ashmem_linux.ko /usr/lib/modules/"${TARGET_KERNEL_VERSION}"/extra/ || echo "Failed to copy ashmem_linux.ko!"
    cp /tmp/anbox.conf /etc/modules-load.d/anbox.conf || echo "Failed to copy anbox.conf!"
    cp /tmp/99-anbox.rules /lib/udev/rules.d/99-anbox.rules || echo "Failed to copy 99-anbox.rules!"

fi

# -------------------------------------------------------------
# 2. Update kernel module dependencies
# -------------------------------------------------------------
echo "Running depmod -a..."
depmod -a "${TARGET_KERNEL_VERSION}"
echo "depmod complete."

# -------------------------------------------------------------
# 3. Final Verification (optional, but good for logs)
# -------------------------------------------------------------
echo "Final module status check:"
lsmod | grep -e ashmem_linux -e binder_linux || true
ls -alh /dev/binder /dev/ashmem || true

echo "build_kernel_modules.sh finished."