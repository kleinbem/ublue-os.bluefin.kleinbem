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

### Install mofules
/ctx/build_kernel_modules.sh

### Install packages

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images
# List of rpmfusion packages can be found here:
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/39/x86_64/repoview/index.html&protocol=https&redirect=1

# this installs a package from fedora repos
dnf5 install -y tmux 

dnf5 install -y waydroid lxc

# Use a COPR Example:
#
# dnf5 -y copr enable ublue-os/staging
# dnf5 -y install package
# Disable COPRs so they don't end up enabled on the final image:
# dnf5 -y copr disable ublue-os/staging

#### Example for enabling a System Unit File

systemctl enable podman.socket

rpm-ostree cleanup -m
