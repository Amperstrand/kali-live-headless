# Tooling image for tools/iso-hotpatch.sh (ISO surgery: xorriso + squashfs).
# Derived from the pinned upstream build image so the hot path uses the same
# base as ./build.sh; packages land via the host apt-cacher-ng on :3142 when
# present (http_proxy is set for the build below only).
FROM kali-build/kali-live
ENV DEBIAN_FRONTEND=noninteractive
RUN http_proxy=http://127.0.0.1:3142 apt-get update -qq \
 && http_proxy=http://127.0.0.1:3142 apt-get install -y -qq --no-install-recommends \
      xorriso squashfs-tools rsync coreutils \
 && rm -rf /var/lib/apt/lists/*
