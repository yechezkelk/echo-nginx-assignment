#!/bin/sh
# Parts B, C and D: patch nginx 1.25.5 with the CVE-2026-15176 backport, build it twice
# (nginx, then nginx-debug) with the 6 dynamic modules, and package everything as one
# nginx 1.25.5-1echo1 .deb (D2).
# Usage: build-nginx.sh <download dir> <work dir> <out dir> <evidence dir> <build/ dir> <rootfs/ dir>
set -eu

DL=$1; WORK=$2; OUT=$3; EV=$4; CFG=$5; ROOTFS=$6
VER=1.25.5
PKGVER=1.25.5-1echo1
PATCH="$CFG/patches/CVE-2026-15176.patch"
mkdir -p "$WORK/orig" "$OUT" "$EV"
cd "$WORK"
tar xzf "$DL/nginx-$VER.tar.gz"
tar xzf "$DL/njs-0.8.4.tar.gz"
tar xzf "$DL/nginx-$VER.tar.gz" -C orig        # pristine copy, only to diff against
SRC="$WORK/nginx-$VER"
cd "$SRC"

# ---- Part B: apply the backport ----
# --fuzz=0: every context line must match exactly. --batch: never ask questions.
# patch exits non-zero on a reject; we also fail if it reports any fuzz or leaves a .rej file.
patch -p1 --fuzz=0 --batch --no-backup-if-mismatch < "$PATCH" > "$EV/patch-apply.log" 2>&1 \
    || { cat "$EV/patch-apply.log"; exit 1; }
cat "$EV/patch-apply.log"
if grep -qi fuzz "$EV/patch-apply.log" || [ -n "$(find . -name '*.rej')" ]; then
    echo "patch did not apply cleanly" >&2; exit 1
fi
# The fixed line must now be in the source, and the old one gone.
FIX='if (alias && (!r->valid_location || r->uri_changed)) {'
grep -nF "$FIX" src/http/ngx_http_core_module.c > "$EV/patch-fix-line.txt"
if grep -qF 'if (alias && !r->valid_location) {' src/http/ngx_http_core_module.c; then
    echo "old vulnerable line still present" >&2; exit 1
fi
cat "$EV/patch-fix-line.txt"
# The applied source diff (pristine 1.25.5 vs our tree). diff exits 1 when files differ.
(cd "$WORK" && diff -ruN "orig/nginx-$VER" "nginx-$VER" > "$EV/CVE-2026-15176.applied.diff") || [ $? -eq 1 ]

# ---- Part C: two builds from the same patched tree ----
STAGE="$WORK/stage"
mkdir -p "$STAGE"
NJS_DIR="$WORK/njs-0.8.4"; export NJS_DIR

# Build 1: nginx
sh "$CFG/nginx-configure.sh"
make -j"$(nproc)"
install -m 0755 objs/nginx "$STAGE/nginx"
for so in objs/*.so; do install -m 0644 "$so" "$STAGE/$(basename "$so")"; done

# Build 2: nginx-debug. `make clean` deletes objs/ and the Makefile, so nothing from
# build 1 is reused (njs rebuilds its libnjs.a too, because the Makefile is new).
make clean
sh "$CFG/nginx-configure.sh" --with-debug
make -j"$(nproc)"
install -m 0755 objs/nginx "$STAGE/nginx-debug"
# Same names as the baseline: ngx_http_geoip_module.so -> ngx_http_geoip_module-debug.so
for so in objs/*.so; do
    b=$(basename "$so" .so)
    install -m 0644 "$so" "$STAGE/$b-debug.so"
done
[ "$(ls "$STAGE"/*.so | wc -l)" -eq 12 ] || { ls "$STAGE"; echo "expected 12 modules" >&2; exit 1; }

# Strip, as the baseline's files are stripped (same options as Debian's dh_strip).
strip --remove-section=.comment --remove-section=.note "$STAGE/nginx" "$STAGE/nginx-debug"
strip --remove-section=.comment --remove-section=.note --strip-unneeded "$STAGE"/*.so

# ---- Part D: package tree, every mode set explicitly ----
P="$WORK/pkg"
rm -rf "$P"
install -d -m 0755 "$P/DEBIAN" "$P/usr/sbin" "$P/usr/lib/nginx/modules" \
    "$P/etc/nginx/conf.d" "$P/usr/share/nginx/html" "$P/usr/share/doc/nginx" \
    "$P/var/cache/nginx" "$P/var/log/nginx"
install -m 0755 "$STAGE/nginx" "$STAGE/nginx-debug" "$P/usr/sbin/"
install -m 0644 "$STAGE"/*.so "$P/usr/lib/nginx/modules/"
# Config and html from rootfs/ (copied from the baseline image in phase 1).
for f in fastcgi_params mime.types nginx.conf scgi_params uwsgi_params; do
    install -m 0644 "$ROOTFS/etc/nginx/$f" "$P/etc/nginx/$f"
done
install -m 0644 "$ROOTFS/etc/nginx/conf.d/default.conf" "$P/etc/nginx/conf.d/default.conf"
install -m 0644 "$ROOTFS/usr/share/nginx/html/50x.html" "$ROOTFS/usr/share/nginx/html/index.html" \
    "$P/usr/share/nginx/html/"
# D1: the symlink is made here, not kept in git. Absolute target, like the baseline.
ln -s /usr/lib/nginx/modules "$P/etc/nginx/modules"
# nginx's and njs's BSD licences ask binary copies to carry the licence text.
{ cat "$SRC/LICENSE"; echo; echo "njs 0.8.4:"; cat "$WORK/njs-0.8.4/LICENSE"; } > "$P/usr/share/doc/nginx/copyright"
chmod 0644 "$P/usr/share/doc/nginx/copyright"

# Runtime dependencies, computed from the 14 ELF files. Our libpcre2-8-0 is installed in this
# build stage and its shlibs file says ">= 10.49", so that is what appears here.
mkdir -p "$WORK/shl/debian"
printf 'Source: nginx\n\nPackage: nginx\nArchitecture: any\n' > "$WORK/shl/debian/control"
DEPS=$(cd "$WORK/shl" && dpkg-shlibdeps -O "$P/usr/sbin/nginx" "$P/usr/sbin/nginx-debug" \
       "$P"/usr/lib/nginx/modules/*.so | sed -n 's/^shlibs:Depends=//p')
echo "$DEPS" | grep -qF 'libpcre2-8-0 (>= 10.49)' || { echo "Depends lacks libpcre2-8-0 (>= 10.49): $DEPS" >&2; exit 1; }

cat > "$P/DEBIAN/control" <<EOF
Package: nginx
Version: $PKGVER
Architecture: amd64
Section: httpd
Priority: optional
Maintainer: Yechezkel Kofman <yechezkelkofman@gmail.com>
Depends: $DEPS
Homepage: https://nginx.org
Description: high performance web server
 nginx $VER built from source with the CVE-2026-15176 fix backported from upstream
 commit f8a2342, linked against PCRE2 10.49. Includes nginx-debug and the xslt,
 image_filter, geoip (http, stream) and njs (http, stream) dynamic modules.
EOF
# conffiles: dpkg will not overwrite a user's edited config on upgrade (same list as the baseline's /etc/nginx part).
(cd "$P" && find etc/nginx -type f | sort | sed 's|^|/|') > "$P/DEBIAN/conffiles"
install -m 0755 "$CFG/scripts/nginx.postinst" "$P/DEBIAN/postinst"
(cd "$P" && find usr etc var -type f -exec md5sum {} + > DEBIAN/md5sums)
chmod 0644 "$P/DEBIAN/control" "$P/DEBIAN/conffiles" "$P/DEBIAN/md5sums"

dpkg-deb --root-owner-group --build "$P" "$OUT/nginx_${PKGVER}_amd64.deb"

# ---- evidence from the build stage ----
"$STAGE/nginx" -V > "$EV/nginx-V.txt" 2>&1
"$STAGE/nginx-debug" -V > "$EV/nginx-debug-V.txt" 2>&1
# Strip the load addresses "(0x...)": they change on every run (ASLR), the results do not.
ldd "$STAGE/nginx" | sed 's/ (0x[0-9a-f]*)//' > "$EV/ldd-nginx-buildstage.txt"
# ldd shows the soname path; readlink shows the real file behind it (must be .so.0.16.1 = 10.49).
echo "readlink -f libpcre2-8.so.0: $(readlink -f "$(awk '/libpcre2-8/{print $3}' "$EV/ldd-nginx-buildstage.txt")")" \
    >> "$EV/ldd-nginx-buildstage.txt"
cat "$EV/nginx-V.txt" "$EV/nginx-debug-V.txt"
grep pcre2 "$EV/ldd-nginx-buildstage.txt"
