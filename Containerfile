# Temporary stage to extract Waydroid kernel modules from Bazzite
FROM ghcr.io/ublue-os/bazzite:latest AS bazzite_modules_extractor

# We don't know the exact kernel version Bazzite's 'latest' uses at this moment.
# So, we'll try to find the installed kernel module path.
# This will get the path like /usr/lib/modules/6.15.6-103.bazzite.fc42.x86_64/updates/dkms/
RUN find /usr/lib/modules -name "binder_linux.ko" -exec dirname {} \; | head -n 1 > /tmp/module_path.txt

# Copy the found modules and configuration files
RUN MODULE_PATH=$(cat /tmp/module_path.txt) && \
    mkdir -p /extracted_modules/ \
    && cp "${MODULE_PATH}/binder_linux.ko" /extracted_modules/ \
    && cp "${MODULE_PATH}/ashmem_linux.ko" /extracted_modules/ \
    && cp /etc/modules-load.d/anbox.conf /extracted_modules/ \
    && cp /lib/udev/rules.d/99-anbox.rules /extracted_modules/ \
    || true # Allow failure if files are not found (e.g., if Waydroid isn't preinstalled or path differs)

# Your main custom Bluefin-DX image build
FROM ghcr.io/ublue-os/bluefin-dx:latest

# Copy your build scripts
FROM scratch AS ctx
COPY build_files /

# Copy modules and config from the extractor stage
COPY --from=bazzite_modules_extractor /extracted_modules/binder_linux.ko /tmp/extracted_binder_linux.ko
COPY --from=bazzite_modules_extractor /extracted_modules/ashmem_linux.ko /tmp/extracted_ashmem_linux.ko
COPY --from=bazzite_modules_extractor /extracted_modules/anbox.conf /tmp/anbox.conf
COPY --from=bazzite_modules_extractor /extracted_modules/99-anbox.rules /tmp/99-anbox.rules

# Your original RUN directive, now calling a modified build.sh
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh && \
    ostree container commit
    
### LINTING
## Verify final image and contents are correct.
RUN bootc container lint