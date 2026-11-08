FROM node:22-slim AS base

# Install bash & curl for entrypoint script compatibility, graphicsmagick for pdf2pic, and vips-dev & build-base for sharp 
# ca-certificates/python3: required for @openzim/libzim download + node-gyp
RUN apt-get update && apt-get install -y \
      bash \
      curl \
      openssl \
      ca-certificates \
      python3 \
      graphicsmagick \
      libvips-dev \
      build-essential \
      pciutils \
      && rm -rf /var/lib/apt/lists/*

# Must match @openzim/libzim@4.0.0's bundled .env (download.openzim.org)
ENV LIBZIM_VERSION=9.4.0

# Prefetch libzim headers/libs so npm install doesn't depend on the flaky
# async download-libzim.js (it swallows CDN errors and then node-gyp fails
# with: fatal error: zim/archive.h: No such file or directory).
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64) zim_arch=x86_64 ;; \
      aarch64) zim_arch=aarch64-manylinux ;; \
      *) echo "Unsupported arch for libzim prefetch: $arch" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/libzim-prefetch; \
    url="https://download.openzim.org/release/libzim/libzim_linux-${zim_arch}-${LIBZIM_VERSION}.tar.gz"; \
    echo "Prefetching libzim from $url"; \
    curl -fsSL -o "/opt/libzim-prefetch/libzim.tar.gz" "$url"; \
    tar -tzf /opt/libzim-prefetch/libzim.tar.gz >/dev/null; \
    printf '%s\n' "$zim_arch" > /opt/libzim-prefetch/arch

# All deps stage
FROM base AS deps
WORKDIR /app
ADD admin/package.json admin/package-lock.json ./
RUN set -eux; \
    zim_arch="$(cat /opt/libzim-prefetch/arch)"; \
    npm ci --ignore-scripts; \
    mkdir -p node_modules/@openzim/libzim/download; \
    cp /opt/libzim-prefetch/libzim.tar.gz \
      "node_modules/@openzim/libzim/download/libzim_linux-${zim_arch}-${LIBZIM_VERSION}.tar.gz"; \
    tar --strip-components=1 -xf \
      "node_modules/@openzim/libzim/download/libzim_linux-${zim_arch}-${LIBZIM_VERSION}.tar.gz" \
      -C node_modules/@openzim/libzim/download; \
    test -f node_modules/@openzim/libzim/download/include/zim/archive.h; \
    npm rebuild

# Production only deps stage
FROM base AS production-deps
WORKDIR /app
ADD admin/package.json admin/package-lock.json ./
RUN set -eux; \
    zim_arch="$(cat /opt/libzim-prefetch/arch)"; \
    npm ci --omit=dev --ignore-scripts; \
    mkdir -p node_modules/@openzim/libzim/download; \
    cp /opt/libzim-prefetch/libzim.tar.gz \
      "node_modules/@openzim/libzim/download/libzim_linux-${zim_arch}-${LIBZIM_VERSION}.tar.gz"; \
    tar --strip-components=1 -xf \
      "node_modules/@openzim/libzim/download/libzim_linux-${zim_arch}-${LIBZIM_VERSION}.tar.gz" \
      -C node_modules/@openzim/libzim/download; \
    test -f node_modules/@openzim/libzim/download/include/zim/archive.h; \
    npm rebuild

# Build stage
FROM base AS build
WORKDIR /app
COPY --from=deps /app/node_modules /app/node_modules
ADD admin/ ./
# Regenerate the curated drug-reference data modules
# (app/data/{conditions,natural_remedies,home_remedies}.ts) from their single
# source of truth — the repo-root collections/*.json — so the JSON is what gets
# compiled into the image and the committed .ts can never silently drift from it
# in a build. The gen script resolves ../../collections relative to admin/scripts,
# which is /collections once admin/ has been copied to /app.
COPY collections/ /collections/
RUN npm run gen:curated-data
RUN node ace build

# Production stage
FROM base
ARG VERSION=dev
ARG BUILD_DATE
ARG VCS_REF
ARG TARGETARCH

# go-pmtiles (regional map extracts). Pinned so the CLI's stdout format stays
# in sync with parseDryRunOutput().
ARG PMTILES_VERSION=1.30.2
# Upstream releases don't ship a checksums file, so pin per-arch SHA256 here.
# When bumping PMTILES_VERSION, regenerate these with:
#   curl -fsSL <release-url> | sha256sum
ARG PMTILES_SHA256_AMD64=2cd3aa18868297fc88425038f794efdc0995e0275f4ca16fa496dd79e245a40c
ARG PMTILES_SHA256_ARM64=804cdf071834e1156af554c1a26cc42b56b9cde5a2db9c6e3653d16fb846d5fa
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) PMTILES_ARCH=x86_64; PMTILES_SHA256="${PMTILES_SHA256_AMD64}" ;; \
      arm64) PMTILES_ARCH=arm64;  PMTILES_SHA256="${PMTILES_SHA256_ARM64}" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    TARBALL="go-pmtiles_${PMTILES_VERSION}_Linux_${PMTILES_ARCH}.tar.gz"; \
    cd /tmp; \
    curl -fsSL -o "$TARBALL" \
      "https://github.com/protomaps/go-pmtiles/releases/download/v${PMTILES_VERSION}/${TARBALL}"; \
    echo "${PMTILES_SHA256}  ${TARBALL}" | sha256sum -c -; \
    tar -xzf "$TARBALL" -C /usr/local/bin pmtiles; \
    rm -f "$TARBALL"; \
    chmod +x /usr/local/bin/pmtiles; \
    /usr/local/bin/pmtiles version

# Labels
LABEL org.opencontainers.image.title="Project NOMAD" \
      org.opencontainers.image.description="The Project NOMAD Official Docker image" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.vendor="Crosstalk Solutions, LLC" \
      org.opencontainers.image.documentation="https://github.com/CrosstalkSolutions/project-nomad/blob/main/README.md" \
      org.opencontainers.image.source="https://github.com/CrosstalkSolutions/project-nomad" \
      org.opencontainers.image.licenses="Apache-2.0"

ENV NODE_ENV=production

# Creator Packs entitlement key, injected into OFFICIAL release builds at build
# time (--build-arg CREATOR_PACKS_APP_KEY=... from the CREATOR_PACKS_APP_KEY CI
# secret; see build-primary-image.yml). Baked as an ENV so admin/start/env.ts
# reads it at runtime. Empty by default, so builds from source (and any build
# without the secret) ship UNCONFIGURED and hide the Creator Packs UI. The key
# lands in this public image layer (extractable — the accepted ceiling); rotate
# via `wrangler secret put APP_KEY` + a new image if it leaks.
ARG CREATOR_PACKS_APP_KEY=""
ENV CREATOR_PACKS_APP_KEY=$CREATOR_PACKS_APP_KEY

WORKDIR /app
COPY --from=production-deps /app/node_modules /app/node_modules
COPY --from=build /app/build /app
# Generate version.json from the VERSION build-arg so the image tag is the
# single source of truth (previously copied root package.json, which drifted
# from the tag when semantic-release did not commit the bump back).
RUN echo "{\"version\":\"${VERSION}\"}" > /app/version.json

# Copy docs and README for access within the container
COPY admin/docs /app/docs
COPY README.md /app/README.md

# Empty Calibre library, seeded into storage/books on Calibre-Web install
# (see DockerService._runPreinstallActions__CalibreWeb)
COPY install/calibre-empty-library/metadata.db /app/assets/calibre/metadata.db

# Copy entrypoint script and ensure it's executable
COPY install/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]