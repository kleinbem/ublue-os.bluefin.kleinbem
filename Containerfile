# Stage 1: Context for all build-related files (scripts, configs, etc.)
# All content from local 'build_files/' will be copied into /ctx_data/ in this stage.
FROM scratch AS ctx
COPY build_files /ctx_data/


# -------------------------------------------------------------
# Stage 2: Your Main Custom Bluefin-DX Image Build
#          All complex module extraction/compilation logic will now be in build.sh
# -------------------------------------------------------------
FROM ghcr.io/ublue-os/bluefin-dx:latest

# Copy your build scripts from the ctx stage
COPY --from=ctx /ctx_data /ctx/build_files

# Your main RUN directive, which calls build.sh
# build.sh will find the copied .ko files and config files in /tmp/ and /ctx/build_files/
RUN --mount=type=bind,from=ctx,source=/ctx/build_files,target=/ctx/build_files \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build_files/build.sh && \
    ostree container commit
    
### LINTING
## Verify final image and contents are correct.
RUN bootc container lint