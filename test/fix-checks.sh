#!/bin/sh
# Phase 6 fix checks: prove in RUNNING containers that our two CVE fixes are present.
# Usage:  sh test/fix-checks.sh <baseline-image> <our-image> [evidence-dir]
#   evidence-dir defaults to docs/evidence/fixes (one .txt file per CVE is written there).
# Exits non-zero if any check fails. Separate from the compatibility suite (compat_test.py):
# here the baseline and ours are EXPECTED to differ.
#
# CVE-2026-15176 (backport of nginx commit f8a2342, D3/D5):
#   the example config from the upstream commit message + a plain "GET /foo/1".
#   Expected (D5): baseline 200, body "/x" (the path mapped from the rewritten URI), no alert;
#   ours 200, EMPTY body, and the alert '"alias" cannot be used in location "/foo/" where URI was rewritten'.
#   Why 200 and not 5xx in ours: the patched ngx_http_map_uri_to_path() refuses the mapping, so
#   $request_filename has no value and "return 200" sends an empty body. Upstream nginx 1.31.7 (a fixed
#   release) answers exactly the same: docs/evidence/fixes/cve-2026-15176-upstream.txt.
#   Control: a plain alias location without rewrite still answers 200 in both.
#   The check runs a third time on our image with nginx-debug (the debug binary has the patch too).
# CVE-2026-103111 (PCRE2 bump 10.42 -> 10.49, D3/D4):
#   in a running container: dpkg-query, the file `ldd /usr/sbin/nginx` resolves for libpcre2-8.so.0,
#   the package that owns it, and the pcre2 mapping in the running nginx master (/proc/1/maps).
#   Repeated on our image for /usr/sbin/nginx-debug, running as PID 1.
set -eu

[ $# -ge 2 ] || { echo "usage: $0 <baseline-image> <our-image> [evidence-dir]" >&2; exit 2; }
BASE=$1
OURS=$2
OUT=${3:-docs/evidence/fixes}
PLATFORM=linux/amd64
TMP=$(mktemp -d)
FAILS=0
CONTAINERS=""
cleanup() { for c in $CONTAINERS; do docker rm -f "$c" >/dev/null 2>&1 || true; done; rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$OUT"
chmod 0755 "$OUT"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

# The location block is copied unchanged from the upstream commit message:
#   https://github.com/nginx/nginx/commit/f8a23425bd6840c4c36b4264edf576ba3646156f
# Only the surrounding "server { listen 80; }" is ours (a location needs a server block).
cat > "$TMP/cve-2026-15176.conf" <<'EOF'
server {
    listen 80;
    location /foo/ {
        alias /bar/;
        rewrite ^/foo/.*$ /x;
        return 200 $request_filename;
    }
}
EOF
# Control: a plain alias location, no rewrite. It must keep working after the fix.
cat > "$TMP/plain-alias.conf" <<'EOF'
server {
    listen 80;
    location /plain/ {
        alias /usr/share/nginx/html/;
    }
}
EOF
chmod 0644 "$TMP"/*.conf

# run_image <image> [debug] [docker run options...]: start the image with its normal entrypoint,
# and with "nginx-debug -g 'daemon off;'" instead of the default CMD when the 2nd argument is "debug".
# Prints the container id.
run_image() {
    img=$1; mode=$2; shift 2
    if [ "$mode" = debug ]; then
        docker run -d --platform "$PLATFORM" "$@" "$img" nginx-debug -g 'daemon off;'
    else
        docker run -d --platform "$PLATFORM" "$@" "$img"
    fi
}

# side_image <side> / side_mode <side>: baseline and ours run nginx; ours-debug runs our image with nginx-debug.
side_image() { if [ "$1" = baseline ]; then echo "$BASE"; else echo "$OURS"; fi; }
side_mode() { if [ "$1" = ours-debug ]; then echo debug; else echo normal; fi; }

# start <side> <conf>: run the side's image with the config mounted read-only as default.conf;
# publish port 80 on a random 127.0.0.1 port. Prints the container id.
start() {
    c=$(run_image "$(side_image "$1")" "$(side_mode "$1")" -p 127.0.0.1::80 \
        -v "$2:/etc/nginx/conf.d/default.conf:ro")
    i=0
    until docker logs "$c" 2>&1 | grep -q 'start worker process'; do
        i=$((i + 1)); [ $i -lt 100 ] || { echo "nginx did not start for $1" >&2; docker logs "$c" >&2; return 1; }
        sleep 0.2
    done
    echo "$c"
}
port() { docker port "$1" 80/tcp | head -n1 | sed 's/.*://'; }

# ---------------------------------------------------------------------------------------------
# CVE-2026-15176
# ---------------------------------------------------------------------------------------------
check_15176() {
    echo "# CVE-2026-15176 fix check, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Produced by: sh test/fix-checks.sh <baseline> <ours>"
    echo "# Upstream fix: https://github.com/nginx/nginx/commit/f8a23425bd6840c4c36b4264edf576ba3646156f"
    echo "# Config (location block unchanged from the commit message), mounted read-only as /etc/nginx/conf.d/default.conf:"
    sed 's/^/#   /' "$TMP/cve-2026-15176.conf"
    for side in baseline ours ours-debug; do
        img=$(side_image $side)
        echo
        echo "== $side: $img ($(docker image inspect "$img" --format '{{.Id}}'))"
        [ $side = ours-debug ] && echo "\$ docker run ... $img nginx-debug -g 'daemon off;'"
        c=$(start $side "$TMP/cve-2026-15176.conf"); CONTAINERS="$CONTAINERS $c"
        p=$(port "$c")
        echo "\$ curl -s -i http://127.0.0.1:<port>/foo/1"
        # -s quiet, -i include headers; the request itself is a plain GET with curl's default headers.
        curl -s -i "http://127.0.0.1:$p/foo/1" | tr -d '\r' | tee "$TMP/resp-$side"
        echo
        sleep 0.5   # let the access/error log lines reach docker logs
        echo "\$ docker logs <container> 2>&1 | grep -v ' notice\\] '   (full log minus startup notices)"
        docker logs "$c" 2>&1 | grep -v ' \[notice\] ' | tee "$TMP/log-$side"
        docker rm -f "$c" >/dev/null
        status=$(head -n1 "$TMP/resp-$side" | awk '{print $2}')
        # The body is everything after the first empty line of the curl -i output.
        body=$(awk 'b {print} /^$/ {b=1}' "$TMP/resp-$side")
        echo "status: $status  body: '$body'"
        [ "$status" = 200 ] && pass "$side: GET /foo/1 -> 200" \
                            || fail "$side: GET /foo/1 -> $status, expected 200"
        if [ $side = baseline ]; then
            [ "$body" = /x ] && pass "baseline: body is '/x' (path mapped from the rewritten URI, unguarded)" \
                             || fail "baseline: body is '$body', expected '/x'"
            if grep -q 'cannot be used in location' "$TMP/log-$side"; then
                fail "baseline: alias-after-rewrite alert logged, expected none"
            else
                pass "baseline: no alias-after-rewrite alert in the log"
            fi
        else
            [ -z "$body" ] && pass "$side: body is empty (mapping refused, no path returned)" \
                           || fail "$side: body is '$body', expected empty"
            if grep -q '\[alert\].*"alias" cannot be used in location "/foo/" where URI was rewritten' "$TMP/log-$side"; then
                pass "$side: alert '\"alias\" cannot be used in location \"/foo/\" where URI was rewritten' logged"
            else
                fail "$side: expected alias-after-rewrite alert not found in the log"
            fi
        fi
    done

    echo
    echo "== control: plain alias without rewrite (our own minimal config, no rewrite):"
    sed 's/^/#   /' "$TMP/plain-alias.conf"
    for side in baseline ours; do
        c=$(start $side "$TMP/plain-alias.conf"); CONTAINERS="$CONTAINERS $c"
        p=$(port "$c")
        echo "\$ curl -s -o /dev/null -w '%{http_code} %{size_download}' http://127.0.0.1:<port>/plain/index.html   ($side)"
        r=$(curl -s -o /dev/null -w '%{http_code} %{size_download}' "http://127.0.0.1:$p/plain/index.html")
        echo "$r"
        docker rm -f "$c" >/dev/null
        [ "${r%% *}" = 200 ] && pass "$side: plain alias -> 200" || fail "$side: plain alias -> ${r%% *}, expected 200"
    done
}

# ---------------------------------------------------------------------------------------------
# CVE-2026-103111
# ---------------------------------------------------------------------------------------------
# Runs inside the container (docker exec -e BIN=...). PID 1 is the nginx master once the entrypoint
# has exec'd it; BIN is the binary it runs (/usr/sbin/nginx or /usr/sbin/nginx-debug).
PCRE_SCRIPT='
echo "\$ dpkg-query -W libpcre2-8-0"; dpkg-query -W libpcre2-8-0
echo "\$ ldd $BIN | grep libpcre2-8   (load address removed)"
ldd $BIN | grep libpcre2-8 | sed "s/ (0x[0-9a-f]*)//"
lib=$(ldd $BIN | awk "/libpcre2-8.so.0/ {print \$3}")
echo "\$ readlink -f $lib"; real=$(readlink -f "$lib"); echo "$real"
echo "\$ dpkg -S $real"; dpkg -S "$real" 2>&1 || dpkg -S "${real#/usr}" 2>&1
echo "\$ cat /proc/1/comm; grep libpcre2-8 /proc/1/maps | awk {print \$6} | sort -u   (master of $BIN)"
cat /proc/1/comm; grep libpcre2-8 /proc/1/maps | awk "{print \"maps: \" \$6}" | sort -u
'

check_103111() {
    echo "# CVE-2026-103111 fix check (PCRE2 10.42 -> 10.49), $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Produced by: sh test/fix-checks.sh <baseline> <ours>"
    echo "# Upstream fix: PCRE2 10.49 (https://github.com/PCRE2Project/pcre2/releases,"
    echo "#   https://github.com/PCRE2Project/pcre2/security/advisories/GHSA-r9hj-j2rw-4q3m)"
    echo "# Each image runs with its normal entrypoint and default config; the commands run via docker exec."
    for side in baseline ours ours-debug; do
        img=$(side_image $side)
        if [ $side = baseline ]; then want_ver=10.42; want_file=libpcre2-8.so.0.11.2; want_pkg=10.42-1
        else want_ver=10.49; want_file=libpcre2-8.so.0.16.1; want_pkg=10.49-0echo1; fi
        if [ $side = ours-debug ]; then bin=/usr/sbin/nginx-debug; else bin=/usr/sbin/nginx; fi
        echo
        echo "== $side: $img ($(docker image inspect "$img" --format '{{.Id}}')), running $bin"
        c=$(run_image "$img" "$(side_mode $side)"); CONTAINERS="$CONTAINERS $c"
        i=0
        until docker logs "$c" 2>&1 | grep -q 'start worker process'; do
            i=$((i + 1)); [ $i -lt 100 ] || { fail "$side: nginx did not start"; break; }
            sleep 0.2
        done
        docker exec -e BIN=$bin "$c" sh -c "$PCRE_SCRIPT" | tee "$TMP/pcre-$side"
        docker rm -f "$c" >/dev/null
        ver=$(awk '$1 == "libpcre2-8-0:amd64" && NF == 2 {print $2}' "$TMP/pcre-$side")
        [ "$ver" = "$want_pkg" ] && pass "$side: dpkg libpcre2-8-0 = $ver ($want_ver)" \
                                 || fail "$side: dpkg libpcre2-8-0 = $ver, expected $want_pkg"
        grep -q "^/usr/lib/x86_64-linux-gnu/$want_file\$" "$TMP/pcre-$side" \
            && pass "$side: ldd $bin: libpcre2-8.so.0 resolves to $want_file" \
            || fail "$side: ldd $bin: libpcre2-8.so.0 does not resolve to $want_file"
        grep -q "^libpcre2-8-0:amd64: .*$want_file\$" "$TMP/pcre-$side" \
            && pass "$side: $want_file is owned by package libpcre2-8-0 (version above)" \
            || fail "$side: $want_file not owned by libpcre2-8-0"
        # The running nginx master has exactly this file mapped (not just linked on disk).
        grep -q "^maps: .*/$want_file\$" "$TMP/pcre-$side" \
            && pass "$side: running $bin (PID 1) maps $want_file" \
            || fail "$side: running $bin (PID 1) does not map $want_file"
    done
}

check_15176  > "$TMP/15176.out" 2>&1 || true
check_103111 > "$TMP/103111.out" 2>&1 || true
# Count failures from the recorded output (one FAIL line per failed check).
FAILS=$(cat "$TMP/15176.out" "$TMP/103111.out" | grep -c '^FAIL' || true)
{
    cat "$TMP/15176.out"
    echo; echo "RESULT: $(grep -c '^PASS' "$TMP/15176.out") passed, $(grep -c '^FAIL' "$TMP/15176.out" || true) failed"
} > "$OUT/cve-2026-15176.txt"
{
    cat "$TMP/103111.out"
    echo; echo "RESULT: $(grep -c '^PASS' "$TMP/103111.out") passed, $(grep -c '^FAIL' "$TMP/103111.out" || true) failed"
} > "$OUT/cve-2026-103111.txt"
chmod 0644 "$OUT"/*.txt
cat "$OUT/cve-2026-15176.txt"; echo; cat "$OUT/cve-2026-103111.txt"
echo
echo "fix-checks: $FAILS failed (evidence in $OUT/)"
[ "$FAILS" -eq 0 ]
