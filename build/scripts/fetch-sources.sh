#!/bin/sh
# Download the upstream sources, then prove they are the real ones:
#   1. sha256 must match build/checksums.sha256 (recorded once, by hand),
#   2. the GPG signature must be made by the expected upstream release key.
# Usage: fetch-sources.sh <download dir> <dir with checksums.sha256 and keys/> <evidence dir>
set -eu

DL=$1
CFG=$2
EV=$3
mkdir -p "$DL" "$EV"
cd "$DL"

# -f: fail on HTTP errors, -L: follow GitHub's redirects to its download CDN
get() { curl -fsSL --retry 3 -o "$1" "$2"; }

PCRE2=https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.49
get pcre2-10.49.tar.gz      "$PCRE2/pcre2-10.49.tar.gz"
get pcre2-10.49.tar.gz.sig  "$PCRE2/pcre2-10.49.tar.gz.sig"
get nginx-1.25.5.tar.gz     https://nginx.org/download/nginx-1.25.5.tar.gz
get nginx-1.25.5.tar.gz.asc https://nginx.org/download/nginx-1.25.5.tar.gz.asc
get njs-0.8.4.tar.gz        https://github.com/nginx/njs/archive/refs/tags/0.8.4.tar.gz

# 1. Checksums. --strict also fails on badly formatted lines, so we drop the comments first.
grep -v '^#' "$CFG/checksums.sha256" | sha256sum -c --strict - | tee "$EV/sha256-check.txt"

# 2. Signatures. gpgv only trusts the keyring we give it, so the key files in build/keys/
#    are the trust anchor. We also check the primary key fingerprint in the VALIDSIG status line,
#    so a key file swapped for another one would still fail.
#    PCRE2 key: listed in PCRE2's SECURITY.md ("Releases from 10.45 onwards ... Nicholas Wilson").
#    nginx key: https://nginx.org/keys/arut.key, listed on https://nginx.org/en/pgp_keys.html.
export GNUPGHOME="$(mktemp -d)"
verify() { # verify <key file> <expected primary fingerprint> <signature> <file>
    gpg --batch --quiet --dearmor < "$CFG/keys/$1" > "$GNUPGHOME/k.gpg"
    gpgv --status-fd 3 --keyring "$GNUPGHOME/k.gpg" "$3" "$4" 3> "$GNUPGHOME/status" 2>> "$EV/signature-check.txt"
    grep -q "^\[GNUPG:\] VALIDSIG .* $2\$" "$GNUPGHOME/status" \
        || { echo "signature on $4 is not from key $2" >&2; exit 1; }
    echo "OK: $4 signed by primary key $2" >> "$EV/signature-check.txt"
}
: > "$EV/signature-check.txt"
verify pcre2-nicholas-wilson.asc  A95536204A3BB489715231282A98E77EB6F24CA8 pcre2-10.49.tar.gz.sig  pcre2-10.49.tar.gz
verify nginx-roman-arutyunyan.asc 43387825DDB1BB97EC36BA5D007C8D7C15D87369 nginx-1.25.5.tar.gz.asc nginx-1.25.5.tar.gz
# njs: upstream publishes no signature for 0.8.4 (tag 0.8.4 is a plain, unsigned git tag),
# so the sha256 above is its only check.
echo "njs-0.8.4.tar.gz: no upstream signature published; checked by sha256 only" >> "$EV/signature-check.txt"
cat "$EV/signature-check.txt"
