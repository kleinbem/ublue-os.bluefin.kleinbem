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
# -------------------------------------------------------------
echo "Calling build_kernel_modules.sh..."
/ctx/build_files/build_kernel_modules.sh
echo "build_kernel_modules.sh finished."

# -------------------------------------------------------------
# Install Anbox Configuration Files (EMBEDDED HERE)
# This directly creates the files needed by Waydroid.
# -------------------------------------------------------------
echo "Creating /etc/modules-load.d/anbox.conf..."
tee /etc/modules-load.d/anbox.conf <<EOF
ashmem_linux
binder_linux
EOF
echo "anbox.conf created."

echo "Creating /lib/udev/rules.d/99-anbox.rules..."
tee /lib/udev/rules.d/99-anbox.rules <<EOF
# Anbox
# Creates the binder and ashmem devices
KERNEL=="binder", MODE="0666"
KERNEL=="ashmem", MODE="0666"
EOF
echo "99-anbox.rules created."

# -------------------------------------------------------------
# Install other packages (including Waydroid application)
# -------------------------------------------------------------
echo "Installing main packages..."

dnf5 install -y tmux
dnf5 install -y waydroid lxc
echo "Waydroid application and its user-space dependencies installed."

# ... (other package installations) ...

# -------------------------------------------------------------
# Final cleanup for rpm-ostree cache
# -------------------------------------------------------------
echo "Running rpm-ostree cleanup..."
rpm-ostree cleanup -m

echo "Main build.sh finished."