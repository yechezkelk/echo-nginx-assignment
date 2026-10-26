# Final image: our two .deb files (build/out/, made by `make debs`) installed into
# debian:bookworm-slim, with the same runtime contract as nginx:1.25-bookworm
# (docs/baseline.md). Build from the repo root:  make image
# Needs BuildKit (default in Docker 23+) for RUN --mount and COPY --chmod.

# Same base and digest as build/Dockerfile (`docker pull --platform linux/amd64 debian:bookworm-slim`, 2026-10-26).
FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8

# Same names and values as the baseline image config (docs/baseline.md section 7).
# PATH is already set by the base image to the same value; it is repeated so the contract is visible here.
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    NGINX_VERSION=1.25.5 \
    NJS_VERSION=0.8.4 \
    NJS_RELEASE=3~bookworm \
    PKG_RELEASE=1~bookworm
# PKG_RELEASE keeps the baseline value for compatibility, although our package release is 1echo1 (D12).

# Same label key as the baseline, but naming who maintains THIS image, not NGINX (D10).
LABEL maintainer="Yechezkel Kofman <yechezkelkofman@gmail.com>"

# The two .debs are bind-mounted for this one RUN, so they never end up in an image layer.
# Only these two files are mounted (D13): other changes in the build context do not re-run this step.
# apt packages come from current bookworm, not a snapshot, so rebuilds are not bit-for-bit identical (D11).
# One apt-get call: apt resolves the runtime libraries (OpenSSL, libgd, libxslt, ...) from Debian,
# and takes our local libpcre2-8-0 10.49-0echo1, which replaces Debian's 10.42 (higher version).
# curl, gettext-base (envsubst, used by 20-envsubst-on-templates.sh) and ca-certificates are the
# tools the baseline installs on purpose (`apt-mark showmanual` in the baseline); openssl comes
# with ca-certificates, as in the baseline.
RUN --mount=type=bind,source=build/out/libpcre2-8-0_10.49-0echo1_amd64.deb,target=/debs/libpcre2-8-0_10.49-0echo1_amd64.deb \
    --mount=type=bind,source=build/out/nginx_1.25.5-1echo1_amd64.deb,target=/debs/nginx_1.25.5-1echo1_amd64.deb \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends --no-install-suggests \
        /debs/libpcre2-8-0_10.49-0echo1_amd64.deb \
        /debs/nginx_1.25.5-1echo1_amd64.deb \
        ca-certificates curl gettext-base; \
    # Fail the build unless OUR packages are the installed ones.
    test "$(dpkg-query -W -f='${Version}' libpcre2-8-0)" = 10.49-0echo1; \
    test "$(dpkg-query -W -f='${Version}' nginx)" = 1.25.5-1echo1; \
    # ...and nginx really loads the 10.49 library file shipped by our package.
    lib="$(readlink -f "$(ldd /usr/sbin/nginx | awk '/libpcre2-8/ {print $3}')")"; \
    dpkg -S "$lib" | grep -q '^libpcre2-8-0:'; \
    # Hold both, so a later `apt-get upgrade` cannot swap in Debian's builds.
    apt-mark hold libpcre2-8-0 nginx; \
    # Log to the container's stdout/stderr, as the baseline does.
    ln -sf /dev/stdout /var/log/nginx/access.log; \
    ln -sf /dev/stderr /var/log/nginx/error.log; \
    rm -rf /var/lib/apt/lists/*

# Entrypoint scripts from the baseline (rootfs/, docs/baseline.md section 11).
# Modes are set here, not taken from the git checkout. Config and html come from our nginx .deb.
COPY --chmod=0755 --chown=0:0 rootfs/docker-entrypoint.sh /docker-entrypoint.sh
COPY --chmod=0755 --chown=0:0 rootfs/docker-entrypoint.d/ /docker-entrypoint.d/
# COPY --chmod also gives the /docker-entrypoint.d directory itself 0755 (checked by test/contract-diff.sh).

# Baseline has WorkingDir "" (= /) and no USER (runs as root; workers drop to nginx via nginx.conf).
ENTRYPOINT ["/docker-entrypoint.sh"]
EXPOSE 80
STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]
