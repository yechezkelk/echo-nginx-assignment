# Builds our two .deb files from upstream source:
#   libpcre2-8-0 10.49-0echo1  (version bump, CVE-2026-103111)
#   nginx        1.25.5-1echo1 (backport of upstream f8a2342, CVE-2026-15176)
# Run from the repo root (it needs rootfs/ too):  make debs
# Nothing from the baseline image or from apt ends up in the packages: apt only
# installs compilers, -dev headers and tools in the build stages.

# debian:bookworm-slim, pinned by digest (`docker pull --platform linux/amd64 debian:bookworm-slim`,
# 2026-10-26), so every build starts from the same bytes.
ARG BASE=debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8

# ---- Stage 1: download and verify all sources (sha256 + GPG) ----
FROM ${BASE} AS sources
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gpg gpgv \
 && rm -rf /var/lib/apt/lists/*
COPY build/checksums.sha256 /cfg/checksums.sha256
COPY build/keys/ /cfg/keys/
COPY build/scripts/fetch-sources.sh /cfg/scripts/
# Scripts are run with `sh`, so their file mode in the git checkout does not matter.
RUN sh /cfg/scripts/fetch-sources.sh /dl /cfg /evidence

# ---- Stage 2 (Part A): PCRE2 10.49 -> libpcre2-8-0 .deb ----
FROM ${BASE} AS pcre2
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential dpkg-dev \
 && rm -rf /var/lib/apt/lists/*
COPY --from=sources /dl/pcre2-10.49.tar.gz /dl/
COPY --from=sources /evidence/ /evidence/
COPY build/scripts/build-pcre2.sh /cfg/scripts/
RUN sh /cfg/scripts/build-pcre2.sh /dl /work /out /evidence /pcre2-dev

# ---- Stage 3 (Parts B, C, D): nginx + modules + nginx-debug -> nginx .deb ----
FROM ${BASE} AS nginx
# Build dependencies: OpenSSL, zlib (core); libxml2/libxslt (xslt + njs); libgd (image_filter);
# libgeoip (geoip). libcrypt-dev comes with libc6-dev via build-essential.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential dpkg-dev patch \
      libssl-dev zlib1g-dev libxml2-dev libxslt1-dev libgd-dev libgeoip-dev \
 && rm -rf /var/lib/apt/lists/*
# Guard: Debian's PCRE2 headers must not be here, or nginx could compile against 10.42.
RUN if dpkg -s libpcre2-dev >/dev/null 2>&1; then echo "libpcre2-dev is installed" >&2; exit 1; fi
# Install OUR libpcre2-8-0 (replaces Debian's 10.42 in this stage), then our header,
# linker symlink and pkg-config file, so nginx compiles and links against 10.49.
COPY --from=pcre2 /out/ /out/
RUN dpkg -i /out/libpcre2-8-0_10.49-0echo1_amd64.deb \
 && dpkg-query -W -f='${Package} ${Version}\n' libpcre2-8-0 | grep -qx 'libpcre2-8-0 10.49-0echo1'
COPY --from=pcre2 /pcre2-dev/ /
COPY --from=pcre2 /evidence/ /evidence/
COPY --from=sources /dl/nginx-1.25.5.tar.gz /dl/njs-0.8.4.tar.gz /dl/
COPY rootfs/etc/nginx/ /rootfs/etc/nginx/
COPY rootfs/usr/share/nginx/html/ /rootfs/usr/share/nginx/html/
COPY build/nginx-configure.sh /cfg/
COPY build/patches/ /cfg/patches/
COPY build/scripts/build-nginx.sh build/scripts/nginx.postinst /cfg/scripts/
RUN sh /cfg/scripts/build-nginx.sh /dl /work /out /evidence /cfg /rootfs
# Evidence: what is inside each package (control data and file list).
RUN for d in /out/*.deb; do \
      n=$(basename "$d" .deb); \
      dpkg-deb -I "$d" > "/evidence/$n.dpkg-deb-I.txt"; \
      dpkg-deb -c "$d" > "/evidence/$n.dpkg-deb-c.txt"; \
    done \
 && (cd /out && sha256sum *.deb > /evidence/debs.sha256)

# ---- Stage 4: only the results, exported by `make debs` (.debs -> build/out/, evidence/ -> docs/evidence/build/) ----
FROM scratch AS out
COPY --from=nginx /out/ /
COPY --from=nginx /evidence/ /evidence/
