#!/bin/sh
# Phase 3 checks: install both .debs into a FRESH debian:bookworm-slim container and check
# them against docs/baseline.md. Prints every command and its output, and saves the log
# to <evidence>/verify-debs.txt (tracked in git). Exits non-zero if any check fails.
# Usage: sh build/verify-debs.sh build/out docs/evidence/build
set -eu

OUT=$(cd "${1:-build/out}" && pwd)
REPO=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "${2:-$REPO/docs/evidence/build}"
EV=$(cd "${2:-$REPO/docs/evidence/build}" && pwd)
BASE=debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8

# Baseline configure args, one per line, taken from docs/baseline.md section 4
# (the lines between "configure arguments:" and the closing ```).
sed -n '/^configure arguments:/,/^```/p' "$REPO/docs/baseline.md" \
    | sed -n 's/^  \(--.*\)$/\1/p' > "$EV/baseline-configure-args.txt"

docker run --rm --platform linux/amd64 -v "$OUT:/out:ro" -v "$EV:/evidence:ro" "$BASE" sh -c '
set -eu
FAIL=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi; }
run() { echo "\$ $*"; "$@"; }

echo "== install both packages (apt resolves the other runtime libs from Debian) =="
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    /out/libpcre2-8-0_10.49-0echo1_amd64.deb /out/nginx_1.25.5-1echo1_amd64.deb > /tmp/apt.log 2>&1 \
    || { tr -d "\r" < /tmp/apt.log; exit 1; }
# apt writes carriage returns (progress output); strip them so the evidence file stays LF-only.
tr -d "\r" < /tmp/apt.log | grep -E "libpcre2-8-0|nginx" | grep -E "^(Unpacking|Setting up|Preparing)"

echo; echo "== 1. dpkg sees libpcre2-8-0 10.49 =="
run dpkg -l libpcre2-8-0 | tail -1
V=$(dpkg-query -W -f="\${Version}" libpcre2-8-0)
check "libpcre2-8-0 version is 10.49-0echo1 (got $V)" "[ \"$V\" = 10.49-0echo1 ]"

echo; echo "== 2. nginx and nginx-debug load the 10.49 library file =="
for b in nginx nginx-debug; do
    # Load addresses "(0x...)" change on every run (ASLR); strip them so the log changes only when results do.
    echo "\$ ldd /usr/sbin/$b | grep pcre2   (load address removed)"
    ldd /usr/sbin/$b | grep pcre2 | sed "s/ (0x[0-9a-f]*)//"
    p=$(ldd /usr/sbin/$b | awk "/libpcre2-8/{print \$3}")
    echo "readlink -f $p -> $(readlink -f "$p")"
    check "$b: libpcre2-8.so.0 resolves to libpcre2-8.so.0.16.1" "[ \"\$(readlink -f $p)\" = /usr/lib/x86_64-linux-gnu/libpcre2-8.so.0.16.1 ]"
    check "$b: that file belongs to our 10.49 package" "dpkg -S \$(readlink -f $p) | grep -q ^libpcre2-8-0"
done

echo; echo "== 3. nginx -t with all 6 modules, nginx-debug -t with all 6 -debug.so =="
MODS="ngx_http_xslt_filter_module ngx_http_image_filter_module ngx_http_geoip_module ngx_stream_geoip_module ngx_http_js_module ngx_stream_js_module"
for b in nginx nginx-debug; do
    sfx=""; [ $b = nginx-debug ] && sfx="-debug"
    conf=/tmp/$b-modules.conf
    # load_module paths are relative to the prefix /etc/nginx, so this also uses the
    # /etc/nginx/modules -> /usr/lib/nginx/modules symlink (D1).
    : > $conf
    for m in $MODS; do echo "load_module modules/$m$sfx.so;" >> $conf; done
    cat /etc/nginx/nginx.conf >> $conf
    head -6 $conf
    run /usr/sbin/$b -t -c $conf
    check "$b -t with 6 modules$sfx" "/usr/sbin/$b -t -c $conf 2>/dev/null"
done
run nginx -t
check "nginx -t (default config)" "nginx -t 2>/dev/null"

echo; echo "== 4. nginx -V vs baseline =="
run nginx -V
nginx -V 2>&1 | sed -n "s/^configure arguments: //p" | sed "s/ --/\n--/g" > /tmp/ours.txt
# Allowed differences: the 5 dynamic-module args and the build path in -ffile-prefix-map.
norm() { sed -e "s|-ffile-prefix-map=[^ ]*=\.|-ffile-prefix-map=BUILDPATH=.|" \
             -e "/^--with-http_xslt_module=dynamic$/d" -e "/^--with-http_image_filter_module=dynamic$/d" \
             -e "/^--with-http_geoip_module=dynamic$/d" -e "/^--with-stream_geoip_module=dynamic$/d" \
             -e "/^--add-dynamic-module=/d" "$1"; }
norm /evidence/baseline-configure-args.txt > /tmp/base.n; norm /tmp/ours.txt > /tmp/ours.n
echo "\$ diff baseline ours (after removing allowed differences)"
diff /tmp/base.n /tmp/ours.n && echo "(no difference)"
check "nginx -V matches baseline apart from module args and build path" "diff -q /tmp/base.n /tmp/ours.n >/dev/null"
echo "allowed differences, as found:"; diff /evidence/baseline-configure-args.txt /tmp/ours.txt | grep "^[<>]" || true
nginx-debug -V 2>&1 | sed -n "s/^configure arguments: //p" | sed "s/ --/\n--/g" > /tmp/debug.txt
echo "\$ diff nginx-args nginx-debug-args"; diff /tmp/ours.txt /tmp/debug.txt || true
check "nginx-debug = nginx args + --with-debug only" "[ \"\$(diff /tmp/ours.txt /tmp/debug.txt | grep ^[\<\>])\" = \"> --with-debug\" ]"

echo; echo "== 5. file modes and owners (baseline: binaries 0755, .so 0644, config/html 0644, dirs 0755, root:root) =="
run sh -c "stat -c \"%a %U:%G %n\" /usr/sbin/nginx /usr/sbin/nginx-debug /usr/lib/nginx/modules/*.so \
    /etc/nginx /etc/nginx/conf.d /etc/nginx/*.* /etc/nginx/*_params /etc/nginx/conf.d/default.conf \
    /usr/lib/nginx /usr/lib/nginx/modules /usr/share/nginx /usr/share/nginx/html /usr/share/nginx/html/* \
    /var/cache/nginx /var/log/nginx"
run ls -l /etc/nginx/modules
check "binaries 0755 root:root" "[ \"\$(stat -c %a:%U:%G /usr/sbin/nginx /usr/sbin/nginx-debug | sort -u)\" = 755:root:root ]"
check "12 modules, all 0644 root:root" "[ \$(ls /usr/lib/nginx/modules/*.so | wc -l) -eq 12 ] && [ \"\$(stat -c %a:%U:%G /usr/lib/nginx/modules/*.so | sort -u)\" = 644:root:root ]"
check "config + html files 0644 root:root" "[ \"\$(find /etc/nginx /usr/share/nginx -type f -exec stat -c %a:%U:%G {} + | sort -u)\" = 644:root:root ]"
# Only the dirs our package ships: `nginx -t` above already made /var/cache/nginx/*_temp (0700, nginx), as upstream nginx does.
DIRS=$(dpkg -L nginx | while read -r d; do if [ -d "$d" ] && [ ! -L "$d" ]; then echo "$d"; fi; done)
check "all $(echo "$DIRS" | wc -l) dirs in the package are 0755 root:root" "[ \"\$(stat -c %a:%U:%G $(echo $DIRS) | sort -u)\" = 755:root:root ]"
check "/etc/nginx/modules -> /usr/lib/nginx/modules" "[ \"\$(readlink /etc/nginx/modules)\" = /usr/lib/nginx/modules ]"
# readelf is not in bookworm-slim; install binutils only now, after the package checks above.
apt-get install -y -qq --no-install-recommends binutils >/dev/null 2>&1
echo "\$ readelf -S <file> | grep -c .symtab   (0 = no symbol table = stripped)"
for f in /usr/sbin/nginx /usr/sbin/nginx-debug /usr/lib/nginx/modules/*.so; do echo "$(readelf -S $f | grep -c " .symtab") $f"; done
check "binaries and 12 modules are stripped" "[ \"\$(for f in /usr/sbin/nginx /usr/sbin/nginx-debug /usr/lib/nginx/modules/*.so; do readelf -S \$f | grep -c \" .symtab\"; done | sort -u)\" = 0 ]"
check "libpcre2-8.so.0.16.1 is stripped" "[ \$(readelf -S /usr/lib/x86_64-linux-gnu/libpcre2-8.so.0.16.1 | grep -c \" .symtab\") -eq 0 ]"

echo; echo "== 6. nginx user and group (baseline: uid=101(nginx) gid=101(nginx) groups=101(nginx)) =="
run id nginx
run getent passwd nginx
run getent group nginx
check "id nginx matches baseline" "[ \"\$(id nginx)\" = \"uid=101(nginx) gid=101(nginx) groups=101(nginx)\" ]"
check "passwd line matches baseline" "[ \"\$(getent passwd nginx)\" = \"nginx:x:101:101:nginx user:/nonexistent:/bin/false\" ]"

echo; echo "== 7. dpkg owns /etc/nginx/* as conffiles =="
CF=$(dpkg-query -W -f="\${Conffiles}\n" nginx); echo "$CF"
N=$(echo "$CF" | grep -c "^ /etc/nginx/")
check "6 conffiles under /etc/nginx (got $N)" "[ $N -eq 6 ]"
run dpkg-query -W -f="\${Package} \${Version}\n" nginx libpcre2-8-0

echo; [ $FAIL -eq 0 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
' 2>&1 | tee "$EV/verify-debs.txt"
# `tee` hides docker's exit code; get it back from the log.
grep -q '^ALL CHECKS PASSED$' "$EV/verify-debs.txt"
# Set modes explicitly, like the evidence from `make debs`.
chmod 0644 "$EV/verify-debs.txt" "$EV/baseline-configure-args.txt"
