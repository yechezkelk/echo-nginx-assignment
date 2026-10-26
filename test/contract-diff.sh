#!/bin/sh
# Compare the runtime contract of two images (docs/baseline.md, docs/runtime-contract.md).
# Usage:  sh test/contract-diff.sh <baseline-image> <our-image>
# e.g.    sh test/contract-diff.sh \
#           nginx@sha256:a484819eb60211f5299034ac80f6a681b06f89e65866ce91f356ed7c72af059c \
#           echo-nginx:1.25.5-echo1
# Exits non-zero on any difference that is not in the allow-list below.
# Allow-listed differences are printed as INFO, never hidden.
set -eu

[ $# -eq 2 ] || { echo "usage: $0 <baseline-image> <our-image>" >&2; exit 2; }
BASE=$1
OURS=$2
PLATFORM=linux/amd64
TMP=$(mktemp -d)
FAILS=0
CONTAINERS=""
cleanup() { for c in $CONTAINERS; do docker rm -f "$c" >/dev/null 2>&1 || true; done; rm -rf "$TMP"; }
trap cleanup EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
info() { echo "INFO: $*"; }

# Intentional differences, one per line:  <check>|<diff line as printed below>|<decision>: <why>
# A diff line starts with "< " (only in the baseline) or "> " (only in ours).
ALLOW="$TMP/allow"
cat > "$ALLOW" <<'EOF'
packages|< nginx-module-geoip|D2: the 4 module packages are merged into our single nginx package
packages|< nginx-module-image-filter|D2: the 4 module packages are merged into our single nginx package
packages|< nginx-module-njs|D2: the 4 module packages are merged into our single nginx package
packages|< nginx-module-xslt|D2: the 4 module packages are merged into our single nginx package
packages|< libedit2|D9: we do not ship the njs CLI, the only user of libedit2
commands|< njs|D9: we do not ship the njs CLI
EOF

# compare <check> <file-baseline> <file-ours>: every diff line must be allow-listed.
compare() {
    check=$1
    if diff "$2" "$3" > "$TMP/diff"; then
        pass "$check: identical ($(wc -l < "$2") lines)"
        return
    fi
    grep '^[<>]' "$TMP/diff" | while IFS= read -r line; do
        why=$(awk -F'|' -v c="$check" -v l="$line" '$1 == c && $2 == l { print $3 }' "$ALLOW")
        if [ -n "$why" ]; then echo "INFO: $check: $line   [allowed, $why]"
        else echo "FAIL: $check: $line"; fi
    done > "$TMP/result"
    cat "$TMP/result"
    n=$(grep -c '^FAIL' "$TMP/result" || true)
    FAILS=$((FAILS + n))
    [ "$n" -eq 0 ] && pass "$check: only allow-listed differences"
    return 0
}

# run <image> <command>: run a shell command with --entrypoint, so the entrypoint
# scripts (which edit default.conf) never run first.
run() { docker run --rm --platform "$PLATFORM" --entrypoint sh "$1" -c "$2"; }

echo "== baseline: $BASE"
echo "== ours:     $OURS"
docker image inspect "$BASE" "$OURS" --format '{{.Id}}  {{.Os}}/{{.Architecture}}' >/dev/null

echo; echo "== 1. image config (docker image inspect --format '{{json .Config.<Field>}}')"
for f in Entrypoint Cmd User WorkingDir ExposedPorts StopSignal Env; do
    b=$(docker image inspect "$BASE" --format "{{json .Config.$f}}")
    o=$(docker image inspect "$OURS" --format "{{json .Config.$f}}")
    if [ "$b" = "$o" ]; then pass "$f = $o"; else fail "$f: baseline $b, ours $o"; fi
done
# Labels are not part of the contract in docs/baseline.md; shown so nothing is hidden.
# Same "maintainer" key on purpose, with our own value (D10).
info "Labels (not in the contract; maintainer value differs on purpose, D10): baseline $(docker image inspect "$BASE" --format '{{json .Config.Labels}}'), ours $(docker image inspect "$OURS" --format '{{json .Config.Labels}}')"

echo; echo "== 2. files: mode owner:group type path [symlink target] (find -printf, entrypoint bypassed)"
FIND='find /etc/nginx /usr/share/nginx /docker-entrypoint.sh /docker-entrypoint.d /usr/sbin/nginx* /usr/lib/nginx/modules -printf "%M %u:%g %y %p %l\n" | sort -k4'
run "$BASE" "$FIND" > "$TMP/fs.base"
run "$OURS" "$FIND" > "$TMP/fs.ours"
compare files "$TMP/fs.base" "$TMP/fs.ours"

echo; echo "== 3. user, log symlinks, nginx -t"
b=$(run "$BASE" 'id nginx'); o=$(run "$OURS" 'id nginx')
if [ "$b" = "$o" ]; then pass "id nginx = $o"; else fail "id nginx: baseline '$b', ours '$o'"; fi
LOGS='for f in /var/log/nginx/access.log /var/log/nginx/error.log; do echo "$(stat -c "%A %U:%G" $f) $f -> $(readlink $f)"; done'
run "$BASE" "$LOGS" > "$TMP/logs.base"
run "$OURS" "$LOGS" > "$TMP/logs.ours"
cat "$TMP/logs.ours"
compare log-symlinks "$TMP/logs.base" "$TMP/logs.ours"
for img in "$BASE" "$OURS"; do
    if out=$(run "$img" 'nginx -t 2>&1'); then pass "nginx -t in $img: $(echo "$out" | tr '\n' ' ')"
    else fail "nginx -t in $img: $out"; fi
done

echo; echo "== 4. installed packages (dpkg-query) and commands on PATH"
run "$BASE" 'dpkg-query -W -f "\${Package}\n" | sort' > "$TMP/pkgs.base"
run "$OURS" 'dpkg-query -W -f "\${Package}\n" | sort' > "$TMP/pkgs.ours"
compare packages "$TMP/pkgs.base" "$TMP/pkgs.ours"
CMDS='for d in $(echo $PATH | tr : " "); do ls -1 $d 2>/dev/null; done | sort -u'
run "$BASE" "$CMDS" > "$TMP/cmds.base"
run "$OURS" "$CMDS" > "$TMP/cmds.ours"
compare commands "$TMP/cmds.base" "$TMP/cmds.ours"

echo; echo "== 5. running container: entrypoint, IPv6 listener, GET /, docker stop"
for img in "$BASE" "$OURS"; do
    echo "-- $img"
    c=$(docker run -d --platform "$PLATFORM" "$img")
    CONTAINERS="$CONTAINERS $c"
    # Wait (max 15 s) until nginx has started its workers.
    i=0
    until docker logs "$c" 2>&1 | grep -q 'start worker process'; do
        i=$((i + 1)); [ $i -le 30 ] || break; sleep 0.5
    done
    if docker logs "$c" 2>&1 | grep -q 'Enabled listen on IPv6'; then
        pass "entrypoint logged: $(docker logs "$c" 2>&1 | grep 'Enabled listen on IPv6')"
    else fail "entrypoint did not log 'Enabled listen on IPv6'"; docker logs "$c" 2>&1 | head -20; fi
    # /proc/net/tcp6: local address :: port 0x0050 (80), state 0A = LISTEN. No ss/netstat in the images.
    if docker exec "$c" awk '$2 == "00000000000000000000000000000000:0050" && $4 == "0A" {f=1} END {exit !f}' /proc/net/tcp6; then
        pass "listening on [::]:80 (/proc/net/tcp6)"
    else fail "no listener on [::]:80"; docker exec "$c" cat /proc/net/tcp6; fi
    code=$(docker exec "$c" curl -s -o /dev/null -w '%{http_code}' http://localhost/ || true)
    if [ "$code" = 200 ]; then pass "GET / -> $code"; else fail "GET / -> $code"; fi
    start=$(date +%s)
    docker stop "$c" >/dev/null
    secs=$(( $(date +%s) - start ))
    rc=$(docker inspect "$c" --format '{{.State.ExitCode}}')
    sig=$(docker logs "$c" 2>&1 | grep -c 'signal 3 (SIGQUIT) received' || true)
    # Exit code 0 and nginx saw SIGQUIT = graceful shutdown; 137 would mean SIGKILL after the timeout.
    if [ "$rc" = 0 ] && [ "$sig" -ge 1 ]; then pass "docker stop: exit code $rc, SIGQUIT received, ${secs}s"
    else fail "docker stop: exit code $rc, SIGQUIT log lines $sig, ${secs}s"; fi
done

echo; echo "== 6. image size (docker image inspect --format '{{.Size}}'), for information"
bs=$(docker image inspect "$BASE" --format '{{.Size}}')
os=$(docker image inspect "$OURS" --format '{{.Size}}')
info "baseline $bs bytes ($((bs / 1048576)) MiB)"
info "ours     $os bytes ($((os / 1048576)) MiB), $(awk -v b="$bs" -v o="$os" 'BEGIN { printf "%+d bytes, %+.2f%%", o - b, (o - b) * 100 / b }') vs baseline"

echo
if [ "$FAILS" -eq 0 ]; then echo "RESULT: contract matches (only allow-listed differences)"; exit 0
else echo "RESULT: $FAILS unexpected difference(s)"; exit 1; fi
