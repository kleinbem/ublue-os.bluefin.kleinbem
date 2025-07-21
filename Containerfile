# Your custom Bluefin-DX Image
FROM ghcr.io/ublue-os/bluefin-dx:latest

# The GITHUB_WORKSPACE variable, needed for our build_files location.
# This should be injected by GitHub Actions workflow.
ARG GITHUB_WORKSPACE="/home/runner/work/ublue-os.bluefin.kleinbem/ublue-os.bluefin.kleinbem"


# Your main RUN directive, now containing all logic from build.sh AND build_kernel_modules.sh
# Also mounts cache and tmp for efficiency.
RUN --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    bash -c ' \
        # --- Start of Original build.sh content --- \
        set -euxo pipefail; \
        \
        echo "--- DEBUG INFO START (from main build.sh monolith) ---"; \
        echo "Current working directory: $(pwd)"; \
        echo "Contents of /: $(ls -la /)"; \
        echo "Contents of /etc/os-release: $(cat /etc/os-release || true)"; \
        echo "Contents of /usr/lib/ostree-release: $(cat /usr/lib/ostree-release || true)"; \
        echo "Running kernel version (uname -r): $(uname -r)"; \
        echo "Path to uname: $(which uname || true)"; \
        echo "Path to rpm: $(which rpm || true)"; \
        echo "Path to dnf5: $(which dnf5 || true)"; \
        echo "Path to rpm-ostree: $(which rpm-ostree || true)"; \
        echo "--- DEBUG INFO END (from main build.sh monolith) ---"; \
        \
        # ------------------------------------------------------------- \
        # Now, embed the entire content of build_kernel_modules.sh here. \
        # This will need all its variables and logic. \
        # ------------------------------------------------------------- \
        echo "Starting embedded kernel module extraction and setup." ; \
        \
        # --- Embedded build_kernel_modules.sh logic --- \
        TARGET_KERNEL_VERSION_FOR_RUNNING_KERNEL=$(uname -r); \
        echo "Target Running Kernel Version detected: ${TARGET_KERNEL_VERSION_FOR_RUNNING_KERNEL}"; \
        \
        REQUIRED_MODULES=("binder_linux" "ashmem_linux"); \
        BAZZITE_KERNEL_VERSION_FOR_EXTRACTION="6.15.6-103.bazzite.fc42.x86_64"; \
        BAZZITE_FEDORA_VERSION_FOR_EXTRACTION="42"; \
        AKMODS_TAG_FOR_BAZZITE="bazzite-${BAZZITE_FEDORA_VERSION_FOR_EXTRACTION}-${BAZZITE_KERNEL_VERSION_FOR_EXTRACTION}"; \
        UBLUE_AKMODS_IMAGE="ghcr.io/ublue-os/akmods"; \
        \
        # Functions need to be defined *before* they are called in this monolithic script \
        check_modules_present() { \
            local modules_missing=false; \
            local current_running_kernel=$(uname -r); \
            echo "  (Internal) Current running kernel for modprobe check: ${current_running_kernel}"; \
            for module in "${REQUIRED_MODULES[@]}"; do \
                if ! modprobe -n "${module}" &>/dev/null; then \
                    echo "  - ${module} module not found."; \
                    modules_missing=true; \
                else \
                    echo "  - ${module} module found."; \
                fi; \
            done; \
            echo "${modules_missing}"; \
        }; \
        \
        echo "Checking if all required kernel modules are already available on current system..."; \
        MODULES_STILL_MISSING=$(check_modules_present); \
        \
        if [ "${MODULES_STILL_MISSING}" = "false" ]; then \
            echo "All required kernel modules are present. Skipping module build/copy process."; \
            echo "build_kernel_modules.sh finished (skipped)."; \
        else \
            echo "One or more kernel modules are missing. Proceeding with module extraction and installation."; \
            \
            echo "Installing temporary tools: skopeo, jq, tar, gzip, rpm-build..."; \
            dnf5 install -y skopeo jq tar gzip rpm-build; \
            echo "Temporary tools installed."; \
            \
            echo "Fetching Bazzite AKMODS image: ${UBLUE_AKMODS_IMAGE}:${AKMODS_TAG_FOR_BAZZITE}"; \
            KERNEL_RPM_DIR="/tmp/bazzite_akmods_content"; \
            mkdir -p "${KERNEL_RPM_DIR}"; \
            \
            skopeo copy --retry-times 3 "docker://${UBLUE_AKMODS_IMAGE}:${AKMODS_TAG_FOR_BAZZITE}" "dir:${KERNEL_RPM_DIR}" \
                || (echo "CRITICAL ERROR: Failed to pull AKMODS image. Cannot proceed." && exit 1); \
            \
            echo "Extracting RPMs from pulled AKMODS content..."; \
            AKMODS_TARGZ_DIGEST=$(jq -r '.layers[].digest' <"${KERNEL_RPM_DIR}/manifest.json" | cut -d : -f 2); \
            tar -xvzf "${KERNEL_RPM_DIR}/${AKMODS_TARGZ_DIGEST}" -C "${KERNEL_RPM_DIR}"/; \
            \
            echo "Moving extracted kmod RPMs for processing..."; \
            EXTRACTED_RPMS_DIR="${KERNEL_RPM_DIR}/extracted_rpms"; \
            mkdir -p "${EXTRACTED_RPMS_DIR}"; \
            find "${KERNEL_RPM_DIR}/rpms/kmods/" -name "*.rpm" -exec mv {} "${EXTRACTED_RPMS_DIR}/" \;; \
            \
            TEMP_KO_EXTRACT_DIR="/tmp/temp_ko_extract"; \
            mkdir -p "${TEMP_KO_EXTRACT_DIR}"; \
            echo "Extracting .ko files from kmod RPMs using rpm2cpio..."; \
            for rpm in "${EXTRACTED_RPMS_DIR}"/*.rpm; do \
                echo "  - Processing RPM: $(basename "$rpm")"; \
                rpm2cpio "$rpm" | cpio -idmv --quiet -D "${TEMP_KO_EXTRACT_DIR}" \
                || (echo "Warning: Failed to extract modules from $(basename "$rpm")." || true); \
            done; \
            echo ".ko files extracted to temporary directory."; \
            \
            MODULE_FINAL_DEST_DIR="/usr/lib/modules/${TARGET_RUNNING_KERNEL_VERSION}/extra"; \
            mkdir -p "${MODULE_FINAL_DEST_DIR}"; \
            echo "Copying extracted .ko files to final destination: ${MODULE_FINAL_DEST_DIR}..."; \
            cp "${TEMP_KO_EXTRACT_DIR}/usr/lib/modules/${BAZZITE_KERNEL_VERSION_FOR_EXTRACTION}/extra/ashmem_linux.ko" "${MODULE_FINAL_DEST_DIR}/" \
                || (echo "ERROR: Failed to copy ashmem_linux.ko to final location!" && exit 1); \
            cp "${TEMP_KO_EXTRACT_DIR}/usr/lib/modules/${BAZZITE_KERNEL_VERSION_FOR_EXTRACTION}/extra/binder_linux.ko" "${MODULE_FINAL_DEST_DIR}/" \
                || (echo "ERROR: Failed to copy binder_linux.ko to final location!" && exit 1); \
            echo ".ko files copied."; \
            \
            echo "Running depmod -a..."; \
            depmod -a "${TARGET_RUNNING_KERNEL_VERSION}"; \
            echo "depmod complete."; \
            \
            echo "Cleaning up temporary tools and extracted content..."; \
            dnf5 remove -y skopeo jq tar gzip rpm-build || true; \
            rm -rf "${KERNEL_RPM_DIR}" "${TEMP_KO_EXTRACT_DIR}"; \
            echo "Cleanup complete."; \
            \
            echo "build_kernel_modules.sh finished (completed module extraction and installation)."; \
        fi; \
        # --- End of Embedded build_kernel_modules.sh logic --- \
        \
        echo "Creating /etc/modules-load.d/anbox.conf..."; \
        tee /etc/modules-load.d/anbox.conf <<EOF_ANBOX_CONF \n ashmem_linux \n binder_linux \n EOF_ANBOX_CONF \n echo "anbox.conf created."; \
        \
        echo "Creating /lib/udev/rules.d/99-anbox.rules..."; \
        tee /lib/udev/rules.d/99-anbox.rules <<EOF_UDEV_RULES \n # Anbox \n KERNEL=="binder", MODE="0666" \n KERNEL=="ashmem", MODE="0666" \n EOF_UDEV_RULES \n echo "99-anbox.rules created."; \
        \
        echo "Installing main packages..."; \
        dnf5 install -y tmux waydroid lxc; \
        echo "Waydroid application and its user-space dependencies installed."; \
        \
        echo "Running rpm-ostree cleanup..."; \
        rpm-ostree cleanup -m; \
        echo "Main build.sh finished."; \
    ' && ostree container commit
    
### LINTING
## Verify final image and contents are correct.
RUN bootc container lint