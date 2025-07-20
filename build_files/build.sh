#!/bin/bash

set -ouex pipefail

# --- DEBUG START ---
echo "--- DEBUG INFO START (from main build.sh) ---"
echo "Current working directory: $(pwd)"
echo "Contents of /: $(ls -la /)"
echo "Contents of /etc/os-release: $(cat /etc/os-release || true)"
echo "Contents of /usr/lib/ostree-release: $(cat /usr/lib/ostree-release || true)"
echo "Running kernel version (uname -r): $(uname -r)"
echo "Path to uname: $(which uname || true)"
echo "Path to rpm: $(which rpm || true)"
echo "Path to dnf5: $(which dnf5 || true)"
echo "Path to rpm-ostree: $(which rpm-ostree || true)"
echo "--- DEBUG INFO END (from main build.sh) ---"
# --- DEBUG END ---

# -------------------------------------------------------------
# Call the kernel module modification script first
# It will internally decide if a build is needed.
# -------------------------------------------------------------
echo "Calling build_kernel_modules.sh..."
# Note: Path is now /ctx/build_files/build_kernel_modules.sh due to new COPY setup
/ctx/build_files/build_kernel_modules.sh
echo "build_kernel_modules.sh finished."

# -------------------------------------------------------------
# Install other packages (including Waydroid application)
# -------------------------------------------------------------
echo "Installing main packages..."

# Your existing packages
dnf5 install -y tmux

# Install Waydroid application and its user-space dependencies
echo "Installing waydroid application and its user-space dependencies..."
dnf5 install -y waydroid lxc # `lxc` is a common Waydroid dependency
echo "Waydroid application and its user-space dependencies installed."

# Use a COPR Example:
#
# dnf5 -y copr enable ublue-os/staging
# dnf5 -y install package
# Disable COPRs so they don't end up enabled on the final image:
# dnf5 -y copr disable ublue-os/staging

#### Example for enabling a System Unit File
systemctl enable podman.socket

# -------------------------------------------------------------
# Final cleanup for rpm-ostree cache
# This should be done at the very end of the main build.sh
# -------------------------------------------------------------
echo "Running rpm-ostree cleanup..."
rpm-ostree cleanup -m

echo "Main build.sh finished."