# Stage 1: Context for build scripts
FROM scratch AS ctx
COPY build_files /ctx/build_files # Copy build_files content to /ctx/build_files in ctx stage.

# -------------------------------------------------------------
# Stage 2: Your Main Custom Bluefin-DX Image Build
# -------------------------------------------------------------
FROM ghcr.io/ublue-os/bluefin-dx:latest

# Your main RUN directive, which calls build.sh
RUN --mount=type=bind,from=ctx,source=/ctx/build_files,target=/ctx/build_files \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build_files/build.sh && \
    ostree container commit
    
### LINTING
## Verify final image and contents are correct.
RUN bootc container lint