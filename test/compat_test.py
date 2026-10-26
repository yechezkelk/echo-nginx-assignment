#!/usr/bin/env python3
"""Compatibility test: our image (echo-nginx) against the baseline nginx:1.25-bookworm.

What "working correctly" means
    For the same request, our image returns the same response as the baseline: same status
    line, same headers in the same order (names and values), and a byte-identical body.
    Each check also has an expected status (e.g. 413, 206, 400), which the baseline must give
    too, so a check cannot pass while testing the wrong thing.

How
    For each profile, the baseline (pinned by digest) and our image run as two containers with
    the same mounts, env and command, each on its own random port on 127.0.0.1. The same
    requests go to both. One PASS or FAIL line per check; exit 1 on any FAIL. Containers are
    always removed (try/finally), also when a check fails or the test is interrupted.

Profiles
    1 stock      plain `docker run`, no mounts: GET /, GET of a missing page (404), HEAD /,
                 a Range request (206), two requests on one keep-alive connection.
    2 custom     test/fixtures/custom.conf over conf.d/default.conf: a 2 MiB body over the
                 1 MiB limit (413), a small POST (200), an 8 MiB static file in full (200),
                 malformed requests on a raw socket (400), regex locations (PCRE2 10.49 in
                 ours), plain alias locations without rewrite (index, file, 404).
    3 modules    test/fixtures/modules/nginx.conf loads xslt, image_filter and njs: an XSLT
                 transform, image_filter size and resize of a generated PNG, an njs handler.
    4 templates  test/fixtures/templates/ rendered by the entrypoint with ECHO_GREETING set:
                 the rendered config file, the entrypoint's own log lines, and a GET.
    5 debug      CMD `nginx-debug -g 'daemon off;'`: GET / and a 404.

Normalized (and why)
    - Date: the time of the response, differs between any two requests.
    - Last-Modified and ETag values: they come from file mtimes, and the html files in our
      image were installed at a different time. Only the value is replaced; the header must
      still be present in both, at the same position, and in the right format (an HTTP date,
      or "hex-hex" with the weak W/ prefix kept as it is), else the check fails.
    Nothing else is normalized. Server, Content-Type, Content-Length, Connection,
    Content-Range, Accept-Ranges, Location and every other header are compared exactly.

Not tested
    - Proving that CVE-2026-15176 or CVE-2026-103111 is fixed (phase 6). A pass here is
      not evidence that a CVE is fixed; it shows the normal paths still behave the same.
    - TLS, HTTP/2, HTTP/3, proxying, mail and stream modules, geoip modules, njs in stream.
    - Performance, concurrency and resource limits; bit-for-bit reproducibility (D11).
    - The runtime contract (user, files, ports, env, stop signal): test/contract-diff.sh.

Usage
    python3 test/compat_test.py [--baseline IMAGE] [--ours IMAGE] [--profile NAME ...]
Standard library only.
"""

import argparse
import hashlib
import http.client
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import zlib

PLATFORM = "linux/amd64"
# Pinned baseline (docs/baseline.md section 1).
BASELINE = "nginx@sha256:a484819eb60211f5299034ac80f6a681b06f89e65866ce91f356ed7c72af059c"
OURS = "echo-nginx:1.25.5-echo1"
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")

TIMEOUT = 10          # seconds, every socket operation
STARTUP_TIMEOUT = 30  # seconds, until nginx answers after `docker run`

# Formats that a normalized header value must still have.
HTTP_DATE = re.compile(
    r"^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), \d\d (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) "
    r"\d{4} \d\d:\d\d:\d\d GMT$")
# Strong ("hex-hex") or weak (W/"hex-hex", e.g. after image_filter) ETag.
ETAG = re.compile(r'^(W/)?"[0-9a-f]+-[0-9a-f]+"$')
NORMALIZE = {"date": (HTTP_DATE, "<http-date>"),
             "last-modified": (HTTP_DATE, "<http-date>"),
             "etag": (ETAG, r"\1<etag>")}  # keeps the W/ prefix: it is format, not value

RESULTS = []  # (passed, line)


# ---------------------------------------------------------------- containers

def docker(*args, check=True):
    return subprocess.run(["docker", *args], capture_output=True, text=True, check=check,
                          timeout=120)


class Container:
    """One running container; always removed by stop()."""

    def __init__(self, image, label, mounts=(), env=(), cmd=()):
        self.image, self.label = image, label
        self.name = f"echo-compat-{label}-{uuid.uuid4().hex[:8]}"
        args = ["run", "-d", "--platform", PLATFORM, "--name", self.name,
                "-p", "127.0.0.1::80"]
        for src, dst in mounts:
            args += ["-v", f"{src}:{dst}:ro"]
        for e in env:
            args += ["-e", e]
        self.id = None
        self.id = docker(*args, image, *cmd).stdout.strip()
        # "docker port" prints e.g. 127.0.0.1:49153
        out = docker("port", self.id, "80/tcp").stdout.split()[0]
        self.port = int(out.rsplit(":", 1)[1])

    def wait_ready(self):
        """Wait until nginx answers any HTTP request, or fail with the container log."""
        deadline = time.time() + STARTUP_TIMEOUT
        while time.time() < deadline:
            try:
                c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
                c.request("GET", "/")
                c.getresponse().read()
                c.close()
                return
            except (OSError, http.client.HTTPException):
                time.sleep(0.3)
        raise RuntimeError(f"{self.label} ({self.image}) did not answer within "
                           f"{STARTUP_TIMEOUT}s; log:\n{self.logs()}")

    def logs(self):
        r = docker("logs", self.id, check=False)
        return r.stdout + r.stderr

    def exec(self, *cmd):
        return docker("exec", self.id, *cmd).stdout

    def stop(self):
        if self.id:
            docker("rm", "-f", self.id, check=False)


class Pair:
    """Baseline and ours, started with the same settings; removed on exit."""

    def __init__(self, args, profile, **kw):
        self.args, self.profile, self.kw = args, profile, kw
        self.base = self.ours = None

    def __enter__(self):
        try:
            self.base = Container(self.args.baseline, f"{self.profile}-base", **self.kw)
            self.ours = Container(self.args.ours, f"{self.profile}-ours", **self.kw)
            self.base.wait_ready()
            self.ours.wait_ready()
        except BaseException:
            self.__exit__()
            raise
        return self

    def __exit__(self, *exc):
        for c in (self.base, self.ours):
            if c:
                c.stop()


# ---------------------------------------------------------------- requests

class Resp:
    """What we compare: status line, ordered headers, body, plus optional extras."""

    def __init__(self, version, status, reason, headers, body, extra=None):
        self.version, self.status, self.reason = version, status, reason
        self.headers = list(headers)
        self.body = body
        self.extra = extra or {}


def from_httpresponse(r, body, extra=None):
    version = {10: "HTTP/1.0", 11: "HTTP/1.1"}.get(r.version, str(r.version))
    return Resp(version, r.status, r.reason, r.getheaders(), body, extra)


def http_request(port, method, path, headers=None, body=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=TIMEOUT)
    try:
        c.request(method, path, body=body, headers=headers or {})
        r = c.getresponse()
        return from_httpresponse(r, r.read())
    finally:
        c.close()


def keepalive_two(port):
    """Two GETs on one connection; records whether the socket was really reused."""
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=TIMEOUT)
    try:
        c.request("GET", "/")
        r1 = c.getresponse()
        b1 = r1.read()
        sock1 = c.sock
        c.request("GET", "/50x.html")
        r2 = c.getresponse()
        b2 = r2.read()
        reused = sock1 is not None and c.sock is sock1
        # Compare both responses: headers and bodies of the second one go into "extra".
        second = from_httpresponse(r2, b2)
        return from_httpresponse(r1, b1, extra={
            "connection reused": reused,
            "2nd status": second.status,
            "2nd headers": normalize(second.headers),
            "2nd body sha256": hashlib.sha256(b2).hexdigest(),
        })
    finally:
        c.close()


def raw_request(port, data, chunks=(), method="GET"):
    """Send raw bytes on a socket (then optional body chunks) and parse the response.
    The server may answer and close before the body is fully sent (e.g. 413): that is
    expected, so send errors are ignored and the response is read anyway."""
    s = socket.create_connection(("127.0.0.1", port), timeout=TIMEOUT)
    try:
        s.sendall(data)
        try:
            for ch in chunks:
                s.sendall(ch)
        except (BrokenPipeError, ConnectionResetError):
            pass
        r = http.client.HTTPResponse(s, method=method)
        r.begin()
        return from_httpresponse(r, r.read())
    finally:
        s.close()


# ---------------------------------------------------------------- comparison

def normalize(headers):
    out = []
    for name, value in headers:
        rule = NORMALIZE.get(name.lower())
        if rule and rule[0].match(value):
            value = rule[0].sub(rule[1], value)  # value replaced only when the format is right
        out.append((name, value))
    return out


def summary(r):
    return (f"{r.status}, {len(r.headers)} headers, body {len(r.body)} bytes "
            f"sha256 {hashlib.sha256(r.body).hexdigest()[:12]}")


def compare(base, ours):
    """Return a list of differences (empty = same)."""
    diffs = []
    if (base.version, base.status, base.reason) != (ours.version, ours.status, ours.reason):
        diffs.append(f"status line: baseline '{base.version} {base.status} {base.reason}', "
                     f"ours '{ours.version} {ours.status} {ours.reason}'")
    hb, ho = normalize(base.headers), normalize(ours.headers)
    if hb != ho:
        for i in range(max(len(hb), len(ho))):
            b = hb[i] if i < len(hb) else None
            o = ho[i] if i < len(ho) else None
            if b != o:
                diffs.append(f"header #{i + 1}: baseline {b}, ours {o}")
    if base.body != ours.body:
        i = next((k for k, (x, y) in enumerate(zip(base.body, ours.body)) if x != y),
                 min(len(base.body), len(ours.body)))
        diffs.append(f"body: baseline {len(base.body)} bytes, ours {len(ours.body)} bytes, "
                     f"first difference at byte {i}: baseline {base.body[i:i + 60]!r}, "
                     f"ours {ours.body[i:i + 60]!r}")
    for k in sorted(set(base.extra) | set(ours.extra)):
        if base.extra.get(k) != ours.extra.get(k):
            diffs.append(f"{k}: baseline {base.extra.get(k)!r}, ours {ours.extra.get(k)!r}")
    return diffs


def record(profile, name, ok, detail):
    line = f"{'PASS' if ok else 'FAIL'} [{profile}] {name}: {detail}"
    RESULTS.append((ok, line))
    print(line, flush=True)


def check(pair, name, fn, expect_status, expect_extra=None):
    """Run fn(port) against both containers and compare. Any exception is a FAIL."""
    try:
        base, ours = fn(pair.base.port), fn(pair.ours.port)
    except Exception as e:  # a timeout or a broken response must fail, not crash the run
        record(pair.profile, name, False, f"request error: {type(e).__name__}: {e}")
        return
    diffs = compare(base, ours)
    for who, r in (("baseline", base), ("ours", ours)):
        if r.status != expect_status:
            diffs.append(f"{who} status {r.status}, expected {expect_status}")
        for k, v in (expect_extra or {}).items():
            if r.extra.get(k) != v:
                diffs.append(f"{who} {k} = {r.extra.get(k)!r}, expected {v!r}")
    if diffs:
        record(pair.profile, name, False, "; ".join(diffs))
    else:
        record(pair.profile, name, True, summary(base))


def check_text(profile, name, base_text, ours_text, must_contain):
    """Compare a non-HTTP output (file content, log lines) exactly; both must contain
    must_contain, so the check cannot pass on two equally wrong outputs."""
    missing = [who for who, t in (("baseline", base_text), ("ours", ours_text))
               if must_contain not in t]
    if missing:
        record(profile, name, False, f"{' and '.join(missing)} lacks {must_contain!r}")
    elif base_text == ours_text:
        record(profile, name, True, f"identical ({len(base_text.splitlines())} lines)")
    else:
        record(profile, name, False,
               f"baseline {base_text!r}, ours {ours_text!r}")


def get(path, headers=None):
    return lambda port: http_request(port, "GET", path, headers)


# ---------------------------------------------------------------- generated files

def make_png(path, width=32, height=16):
    """A small deterministic RGB PNG (gradient), so no binary file is committed."""
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff))
    rows = b"".join(b"\x00" + bytes(v for x in range(width)
                                    for v in (x * 8 % 256, y * 16 % 256, 128))
                    for y in range(height))
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)
    os.chmod(path, 0o644)  # explicit: readable by the nginx worker (uid 101)


def make_large(path, size=8 * 1024 * 1024):
    """A deterministic 8 MiB file (sha256 chain), larger than any buffer nginx uses."""
    block, out = b"echo", bytearray()
    while len(out) < size:
        block = hashlib.sha256(block).digest()
        out += block
    with open(path, "wb") as f:
        f.write(bytes(out[:size]))
    os.chmod(path, 0o644)  # explicit: readable by the nginx worker (uid 101)


# ---------------------------------------------------------------- profiles

def profile_stock(args, tmp):
    with Pair(args, "stock") as p:
        check(p, "GET /", get("/"), 200)
        check(p, "GET missing page", get("/no-such-page.html"), 404)
        check(p, "HEAD /", lambda port: http_request(port, "HEAD", "/"), 200)
        check(p, "GET / Range bytes=10-99", get("/", {"Range": "bytes=10-99"}), 206)
        check(p, "keep-alive: GET / then GET /50x.html on one connection",
              keepalive_two, 200, expect_extra={"connection reused": True})


def profile_custom(args, tmp):
    big = os.path.join(tmp, "big")
    os.mkdir(big, 0o755)
    make_large(os.path.join(big, "large.bin"))
    mounts = [(os.path.join(FIXTURES, "custom.conf"), "/etc/nginx/conf.d/default.conf"),
              (big, "/srv/big")]
    two_mib = 2 * 1024 * 1024
    with Pair(args, "custom", mounts=mounts) as p:
        check(p, "POST 2 MiB body over 1 MiB limit", lambda port: raw_request(
            port,
            b"POST /upload HTTP/1.1\r\nHost: localhost\r\n"
            b"Content-Type: application/octet-stream\r\n"
            b"Content-Length: %d\r\n\r\n" % two_mib,
            chunks=[b"x" * 65536] * (two_mib // 65536), method="POST"), 413)
        check(p, "POST small body under limit", lambda port: http_request(
            port, "POST", "/upload", body=b"x" * 1024), 200)
        check(p, "GET 8 MiB static file", get("/big/large.bin"), 200)
        check(p, "malformed: invalid Content-Length (raw socket)", lambda port: raw_request(
            port, b"GET / HTTP/1.1\r\nHost: localhost\r\nContent-Length: abc\r\n\r\n"), 400)
        check(p, "malformed: duplicate Host header (raw socket)", lambda port: raw_request(
            port, b"GET / HTTP/1.1\r\nHost: localhost\r\nHost: other\r\n\r\n"), 400)
        check(p, "malformed: bare LF and space in method (raw socket)", lambda port: raw_request(
            port, b"G ET / HTTP/1.1\nHost: localhost\n\n"), 400)
        check(p, "regex location, named + numbered captures", get("/re/hello/42"), 200)
        check(p, "regex location ~* (case-insensitive)", get("/ICASE/Abc.txt"), 200)
        check(p, "regex location, no match -> 404", get("/re/Hello/42"), 404)
        check(p, "alias: directory index", get("/alias/"), 200)
        check(p, "alias: file", get("/alias/50x.html"), 200)
        check(p, "alias: missing file", get("/alias/missing.html"), 404)
        check(p, "alias with regex capture: file", get("/ralias/index.html"), 200)


def profile_modules(args, tmp):
    img = os.path.join(tmp, "img")
    os.mkdir(img, 0o755)
    make_png(os.path.join(img, "test.png"))
    mdir = os.path.join(FIXTURES, "modules")
    mounts = [(os.path.join(mdir, "nginx.conf"), "/etc/nginx/nginx.conf"),
              (mdir, "/etc/nginx/compat"),
              (img, "/srv/img")]
    with Pair(args, "modules", mounts=mounts) as p:
        check(p, "xslt: transform page.xml", get("/xslt/page.xml"), 200)
        check(p, "image_filter size", get("/img-size/test.png"), 200)
        check(p, "image_filter resize", get("/img-resize/test.png"), 200)
        check(p, "njs: js_content handler", get("/njs?a=1&b=two"), 200)


def entrypoint_lines(log):
    # Lines written by the entrypoint scripts themselves (nginx's own lines carry
    # timestamps and pids). Kept in order.
    return "\n".join(l for l in log.splitlines()
                     if l.startswith("/docker-entrypoint") or ".sh: " in l
                     or ".envsh: " in l) + "\n"


def profile_templates(args, tmp):
    mounts = [(os.path.join(FIXTURES, "templates"), "/etc/nginx/templates")]
    env = ["ECHO_GREETING=hello-from-template"]
    with Pair(args, "templates", mounts=mounts, env=env) as p:
        conf = "/etc/nginx/conf.d/default.conf"
        check_text(p.profile, f"rendered {conf}", p.base.exec("cat", conf),
                   p.ours.exec("cat", conf), "hello-from-template")
        check_text(p.profile, "entrypoint log lines", entrypoint_lines(p.base.logs()),
                   entrypoint_lines(p.ours.logs()), "Running envsubst on /etc/nginx/templates/")
        check(p, "GET /some/path (response from rendered config)", get("/some/path"), 200)


def profile_debug(args, tmp):
    with Pair(args, "debug", cmd=["nginx-debug", "-g", "daemon off;"]) as p:
        check_text(p.profile, "process is nginx-debug",
                   p.base.exec("cat", "/proc/1/cmdline"), p.ours.exec("cat", "/proc/1/cmdline"),
                   "master process nginx-debug")
        check(p, "GET /", get("/"), 200)
        check(p, "GET missing page", get("/no-such-page.html"), 404)


PROFILES = {"stock": profile_stock, "custom": profile_custom, "modules": profile_modules,
            "templates": profile_templates, "debug": profile_debug}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--baseline", default=BASELINE)
    ap.add_argument("--ours", default=OURS)
    ap.add_argument("--profile", action="append", choices=PROFILES,
                    help="run only this profile (repeatable); default all")
    args = ap.parse_args()

    for img in (args.baseline, args.ours):
        if docker("image", "inspect", img, check=False).returncode != 0:
            print(f"ERROR: image {img} not found locally", file=sys.stderr)
            return 2
    print(f"baseline: {args.baseline}\nours:     {args.ours}", flush=True)

    tmp = tempfile.mkdtemp(prefix="echo-compat-")
    os.chmod(tmp, 0o755)  # mounted dirs must be readable by the nginx worker (uid 101)
    try:
        for name in args.profile or PROFILES:
            print(f"\n== profile: {name}", flush=True)
            try:
                PROFILES[name](args, tmp)
            except Exception as e:  # e.g. a container did not start: that profile fails
                record(name, "profile setup", False, f"{type(e).__name__}: {e}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    failed = sum(1 for ok, _ in RESULTS if not ok)
    print(f"\nRESULT: {len(RESULTS)} checks, {len(RESULTS) - failed} PASS, {failed} FAIL")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
