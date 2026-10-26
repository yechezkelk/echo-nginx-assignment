#!/bin/sh
# Part A: build PCRE2 10.49 from the verified tarball and package the 8-bit runtime
# library as libpcre2-8-0 10.49-0echo1 (the version bump for CVE-2026-103111).
# Usage: build-pcre2.sh <download dir> <work dir> <output dir for .deb> <evidence dir> <dev files dir>
set -eu

DL=$1; WORK=$2; OUT=$3; EV=$4; DEV=$5
VER=10.49
PKGVER=10.49-0echo1
MULTIARCH=x86_64-linux-gnu      # Debian's library dir name on amd64
mkdir -p "$WORK" "$OUT" "$EV" "$DEV"
cd "$WORK"
tar xzf "$DL/pcre2-$VER.tar.gz"
cd "pcre2-$VER"

# Same hardening flags Debian uses for its packages (-O2, stack protector, FORTIFY, relro...).
eval "$(dpkg-buildflags --export=sh)"

# Like Debian's debian/rules for amd64: JIT on, pcre2grep callouts off.
# We skip the 16/32-bit libraries and the static library: we do not ship them.
./configure --prefix=/usr --libdir=/usr/lib/$MULTIARCH \
    --enable-jit --disable-pcre2grep-callout --disable-static
make -j"$(nproc)"

# Run upstream's test suite. testinput17 (JIT) holds the regression test that
# the CVE-2026-103111 fix commit added.
make check > "$EV/pcre2-make-check.log" 2>&1 || { tail -50 "$EV/pcre2-make-check.log"; exit 1; }
grep -E '^# (TOTAL|PASS|FAIL|ERROR)' "$EV/pcre2-make-check.log"
# RunTest.log lists each upstream test; test 17 is the JIT test with the CVE regression case.
cp RunTest.log "$EV/pcre2-RunTest.log"
grep -A1 '^Test 17' "$EV/pcre2-RunTest.log" | grep -q '^  OK$' \
    || { echo "JIT test 17 did not pass" >&2; exit 1; }
grep -A1 '^Test 17' "$EV/pcre2-RunTest.log"

# Install into a staging dir (not into /), then pick the files we need.
make install DESTDIR="$WORK/root"
LIBDIR="$WORK/root/usr/lib/$MULTIARCH"
REAL=$(basename "$(readlink -f "$LIBDIR/libpcre2-8.so.0")")   # e.g. libpcre2-8.so.0.16.1

# The ABI promise: the soname must stay libpcre2-8.so.0, or nginx would not find it.
SONAME=$(objdump -p "$LIBDIR/$REAL" | awk '$1=="SONAME"{print $2}')
[ "$SONAME" = libpcre2-8.so.0 ] || { echo "unexpected soname $SONAME" >&2; exit 1; }

# JIT really compiled in? pcre2test -C prints the build options.
./pcre2test -C > "$EV/pcre2test-C.txt"
grep -q '^  Just-in-time compiler support$' "$EV/pcre2test-C.txt" \
 && grep -q 'Architecture: x86 64bit' "$EV/pcre2test-C.txt" \
    || { echo "JIT is not enabled" >&2; cat "$EV/pcre2test-C.txt"; exit 1; }

# ---- package tree: runtime library only ----
P="$WORK/pkg"
rm -rf "$P"
install -d -m 0755 "$P/DEBIAN" "$P/usr/lib/$MULTIARCH" "$P/usr/share/doc/libpcre2-8-0"
install -m 0644 "$LIBDIR/$REAL" "$P/usr/lib/$MULTIARCH/$REAL"
# Strip like Debian's dh_strip does for shared libraries.
strip --remove-section=.comment --remove-section=.note --strip-unneeded "$P/usr/lib/$MULTIARCH/$REAL"
ln -s "$REAL" "$P/usr/lib/$MULTIARCH/libpcre2-8.so.0"
# PCRE2's BSD licence asks binary copies to carry the licence text.
install -m 0644 LICENCE* "$P/usr/share/doc/libpcre2-8-0/copyright"

# Runtime dependencies, computed from the binary (dpkg-shlibdeps needs a dummy debian/control).
mkdir -p "$WORK/shl/debian"
printf 'Source: pcre2\n\nPackage: libpcre2-8-0\nArchitecture: any\n' > "$WORK/shl/debian/control"
DEPS=$(cd "$WORK/shl" && dpkg-shlibdeps -O "$P/usr/lib/$MULTIARCH/$REAL" | sed -n 's/^shlibs:Depends=//p')

cat > "$P/DEBIAN/control" <<EOF
Package: libpcre2-8-0
Source: pcre2
Version: $PKGVER
Architecture: amd64
Multi-Arch: same
Section: libs
Priority: optional
Maintainer: Yechezkel Kofman <yechezkelkofman@gmail.com>
Depends: $DEPS
Homepage: https://pcre2project.github.io/pcre2/
Description: New Perl Compatible Regular Expression Library- 8 bit runtime files
 PCRE2 $VER built from the upstream release tarball (with JIT), replacing
 Debian's 10.42 to fix CVE-2026-103111 (GHSA-r9hj-j2rw-4q3m).
EOF
# shlibs: tells dpkg-shlibdeps that anything linked against us needs >= 10.49.
echo 'libpcre2-8 0 libpcre2-8-0 (>= 10.49)' > "$P/DEBIAN/shlibs"
# Run ldconfig after install/remove, as Debian's package does.
echo 'activate-noawait ldconfig' > "$P/DEBIAN/triggers"
(cd "$P" && find usr -type f -exec md5sum {} + > DEBIAN/md5sums)
chmod 0644 "$P/DEBIAN/control" "$P/DEBIAN/shlibs" "$P/DEBIAN/triggers" "$P/DEBIAN/md5sums"

# --root-owner-group: every file is root:root in the .deb, whoever ran the build.
dpkg-deb --root-owner-group --build "$P" "$OUT/libpcre2-8-0_${PKGVER}_amd64.deb"

# Dev files (header, linker symlink, pkg-config) for the nginx build stage only; never shipped.
install -d "$DEV/usr/include" "$DEV/usr/lib/$MULTIARCH/pkgconfig" "$DEV/usr/bin"
install -m 0644 "$WORK/root/usr/include/pcre2.h" "$DEV/usr/include/"
ln -s libpcre2-8.so.0 "$DEV/usr/lib/$MULTIARCH/libpcre2-8.so"
install -m 0644 "$LIBDIR/pkgconfig/libpcre2-8.pc" "$DEV/usr/lib/$MULTIARCH/pkgconfig/"
install -m 0755 "$WORK/root/usr/bin/pcre2-config" "$DEV/usr/bin/"

# Evidence: dpkg must see our version as newer than Debian's fixed 10.42-1+deb12u2,
# otherwise apt would "upgrade" back to Debian's package. Fail the build if not.
dpkg --compare-versions "$PKGVER" gt 10.42-1+deb12u2 || { echo "version not newer" >&2; exit 1; }
{
  echo "\$ dpkg --compare-versions $PKGVER gt 10.42-1+deb12u2 && echo newer"
  dpkg --compare-versions "$PKGVER" gt 10.42-1+deb12u2 && echo newer
  echo "\$ dpkg --compare-versions $PKGVER gt 10.42-1 && echo newer"
  dpkg --compare-versions "$PKGVER" gt 10.42-1 && echo newer
  echo "soname: $SONAME  file: $REAL"
  grep -E '^PCRE2 version|Just-in-time|Architecture' "$EV/pcre2test-C.txt"
} > "$EV/pcre2-version-check.txt"
cat "$EV/pcre2-version-check.txt"
