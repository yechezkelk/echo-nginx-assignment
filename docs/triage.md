# Triage: baseline CVEs and recommended fixes (Phase 2)

Observed on 2026-10-26. Status: **recommendation only. The user picks the 2 CVEs.**
Every fact names its source (a command with trimmed output, or a URL).

> **Outcome (added in phase 7).** The user chose the 2 CVEs in `docs/decisions.md` D3: CVE-2026-103111 by bump
> (PCRE2 10.49) and CVE-2026-15176 by backport (upstream f8a2342). The expected result of the CVE-2026-15176 test was
> settled in D5 (200, empty body, plus the alert), replacing the "expect 500" guess below. The open questions in
> section 7 were settled in D3-D6. The rest of this file is kept as written: it records what we knew in phase 2.

Shorthand used below (same as `docs/baseline.md`):
`D=nginx@sha256:a484819eb60211f5299034ac80f6a681b06f89e65866ce91f356ed7c72af059c`,
`R="docker run --rm --platform linux/amd64 --entrypoint"`.

## 1. Scan summary

### Tools and DB dates (full output: `scans/scanner-info.txt`)

| Tool | Version | Vulnerability DB used for the scan |
|---|---|---|
| Trivy | 0.76.1 | DB v2, UpdatedAt 2026-10-26 07:15:18 UTC |
| Grype | 0.121.0 (Syft 1.55.0) | schema v6.1.10, built 2026-10-26T06:38:44Z |

Both scanners refreshed their DB automatically when the scan started, so the DB dates above
(section B of `scans/scanner-info.txt`) differ from the ones recorded just before the scan (section A).

### Scan commands (by digest, linux/amd64)

```
$ trivy image --platform linux/amd64 --format table -o scans/baseline-trivy.txt  $D
$ trivy image --platform linux/amd64 --format json  -o scans/baseline-trivy.json $D
$ grype --platform linux/amd64 -o table --file scans/baseline-grype.txt  $D
$ grype --platform linux/amd64 -o json  --file scans/baseline-grype.json $D
```

Both JSON files record the same image: `ImageID sha256:e784f456...a070`, RepoDigest = `$D`,
amd64 (`jq` lines in `scans/scanner-info.txt`). Trivy detected `debian 12.5` and 144 packages.

### Counts

```
$ jq '[.Results[].Vulnerabilities[]?] | length' scans/baseline-trivy.json             -> 831
$ jq '[.Results[].Vulnerabilities[]?.VulnerabilityID] | unique | length' ...           -> 531
$ jq '.matches | length' scans/baseline-grype.json                                     -> 799
$ jq '[.matches[].vulnerability.id] | unique | length' ...                             -> 500
```

| Severity | Trivy | Grype |
|---|---|---|
| Critical | 20 | 50 |
| High | 190 | 279 |
| Medium | 321 | 268 |
| Low | 263 | 38 |
| Negligible | n/a | 139 |
| Unknown | 37 | 25 |
| **Total (package x CVE)** | **831** | **799** |
| Unique CVE IDs | 531 | 500 |

(Severity counts: `jq 'group_by(.Severity)'` / `group_by(.vulnerability.severity)`.) All findings are OS
packages: Trivy has one result, `os-pkgs`. Grype has 799 matches, all of type `deb`.

### Findings on nginx packages

```
$ jq '.Results[].Vulnerabilities[]? | select(.PkgName|test("nginx"))' scans/baseline-trivy.json
(no output: Trivy reports 0 nginx findings, although it lists the 5 nginx packages with --list-all-pkgs)

$ jq '.matches[] | select(.artifact.name|test("nginx")) | ...' scans/baseline-grype.json
nginx 1.25.5-1~bookworm  CVE-2026-93479 Critical | CVE-2026-15176 Critical | CVE-2026-97205 Critical
                         CVE-2026-97629 High     | CVE-2023-44487 High     | CVE-2026-95101 Medium
                         CVE-2009-4487 Negligible| CVE-2013-0337 Negligible
(all: namespace debian:distro:debian:12, match type exact-direct-match, fix state not-fixed)
```

Why the scanners see nginx this way: our `nginx` package comes from nginx.org (`docs/baseline.md` section 5),
but its name matches Debian's own `nginx` source package. Grype applies Debian's tracker data to it:
- If Debian lists a CVE as **open** for bookworm, grype reports it, whatever the real nginx version is.
- If Debian lists it as **fixed** at `1.22.1-9+deb12uN`, `1.25.5-1~bookworm` sorts higher, so the CVE is hidden.

This gives both false positives and false negatives:
- **False positive:** CVE-2026-93479. nginx.org lists the vulnerable range as `1.31.2-1.31.6, 1.30.0-1.30.5`,
  so 1.25.5 is not affected (https://nginx.org/en/security_advisories.html).
- **Not verified:** CVE-2023-44487 (HTTP/2 rapid reset). It is likely mitigated in 1.25.3, not verified; our default config does not enable HTTP/2 (no `http2` directive, only `listen 80` and `[::]:80`), so it applies only to users who enable HTTP/2.
  Why not verified: the nginx 1.25.3 CHANGES entry "Change: improved detection of misbehaving clients when using HTTP/2"
  (https://nginx.org/en/CHANGES) does not name the CVE, and F5's advisory names no fixed nginx OSS version.
  Default config, both images (checked in phase 7): `docker run --rm --platform linux/amd64 <image> sh -c
  '/docker-entrypoint.d/10-listen-on-ipv6-by-default.sh; grep -rn "listen\|http2" /etc/nginx/nginx.conf /etc/nginx/conf.d/'`
  -> the only directives are `listen 80;` and `listen [::]:80;` in `default.conf`; no `http2` in either path.
- **False negatives:** nginx.org lists many advisories whose range includes 1.25.5, and neither scanner reports them,
  for example CVE-2024-7347, CVE-2024-32760, CVE-2024-31079, CVE-2024-35200, CVE-2024-34161, CVE-2025-23419,
  CVE-2026-42533 and CVE-2026-1642. Command:
  `grep -c '"CVE-…"' scans/baseline-trivy.json` and `jq '[.matches[]|select(.vulnerability.id==…)]|length'` -> 0 for each.
  For CVE-2024-7347, Debian marks bookworm fixed at `1.22.1-9+deb12u2`
  (https://security-tracker.debian.org/tracker/CVE-2024-7347).

So the scans are not a reliable inventory for nginx itself. The nginx candidates below come from the nginx.org list.

### Per-CVE detail (added in phase 7)

This file triages per library, not per CVE. The per-CVE detail is in `scans/rescan/findings-baseline-trivy.tsv`
(831 lines) and `scans/rescan/findings-baseline-grype.tsv` (799 lines): one line per finding, with CVE, package,
installed version, fixed-in version and severity (written by `make scan`).

Every unique CVE ID seen on either image falls in exactly one group below. Counts are unique CVE IDs (Trivy / Grype),
from `scans/rescan/counts.txt`, `gone-*.tsv` (column 3: reason) and `remaining-*.tsv` (column 2: fix available):
- **Fixed by us (8 / 8).** The PCRE2 bump: CVE-2026-103111 plus 6 more PCRE2 IDs, gone from our image (7 / 7, reasons
  `intentional` and `pcre2-bump`). The nginx backport: CVE-2026-15176 (1 / 1). Scanners still list it on our image,
  because the version stays 1.25.5, so it is closed by our VEX.
- **Fixed by newer bookworm packages (259 / 244).** Gone because our image installs current bookworm packages (D11);
  reason `newer-bookworm`. Not claimed as our work.
- **Fix available, not applied (1 / 0).** Trivy's DLA-4854-1 on `tzdata`; see Residual risk in the README.
- **No fix yet (271 / 248).** Still in our image with no fixed version: the `no` lines in `remaining-*.tsv`
  (272 / 249) minus CVE-2026-15176, which is counted under "Fixed by us". Left as residual risk.

Arithmetic, checked against `counts.txt`:
- Trivy: 8 + 259 + 1 + 271 = 539 = 531 baseline + 8 new in ours. The 8 new are all on our nginx package, because Trivy
  skips the baseline's nginx.org packages; CVE-2026-15176 is one of them. Our image: 1 + 1 + 271 = 273.
- Grype: 8 + 244 + 0 + 248 = 500 = 500 baseline + 0 new. Our image: 1 + 0 + 248 = 249.

Not a separate group: many of these IDs are on packages whose libraries nginx does not load with the default config
(section 2: module libraries such as libxml2, libxslt, libgd, and packages nginx never links, such as tar or login).
They got no work beyond the bookworm refresh and are already counted in one of the groups above.

## 2. What nginx actually loads

```
$ $R sh $D -c 'ldd /usr/sbin/nginx'
libcrypt.so.1  libpcre2-8.so.0  libssl.so.3  libcrypto.so.3  libz.so.1  libc.so.6
$ $R sh $D -c 'ldd /usr/lib/nginx/modules/<each>.so'   (trimmed)
geoip  -> libGeoIP.so.1
image_filter -> libgd.so.3 (+ png, jpeg, tiff, webp, heif, avif, freetype, ... ~50 libs)
js (http/stream) -> libxml2.so.2, libicuuc.so.72, liblzma.so.5, libz.so.1
xslt   -> libxml2.so.2, libxslt.so.1, libexslt.so.0, libgcrypt.so.20
```

The default config loads no module (`docs/baseline.md` section 6), so at runtime only the core libraries are used.

Library to package (`readlink -f` + `dpkg -S` + `dpkg-query -W` inside `$D`):

| Library | Package | Version | Trivy findings (with Debian fix) | Grype findings (fixed) |
|---|---|---|---|---|
| libpcre2-8.so.0 | libpcre2-8-0 | 10.42-1 | 7 (7): HIGH 4, MEDIUM 3 | 7 (7) |
| libssl.so.3 / libcrypto.so.3 | libssl3 | 3.0.11-1~deb12u2 | 49 (48): CRIT 1, HIGH 9 | 49 (42) |
| libz.so.1 | zlib1g | 1:1.2.13.dfsg-1 | 3 (0) | 2 (0) |
| libcrypt.so.1 | libcrypt1 | 1:4.4.33-2 | 0 | 0 |
| libc.so.6 | libc6 | 2.36-9+deb12u7 | 32 (9) | 32 (9) |
| libxml2.so.2 (modules) | libxml2 | 2.9.14+dfsg-1.3~deb12u1 | 30 (21) | 29 (20) |
| libxslt.so.1 (xslt module) | libxslt1.1 | 1.1.35-1 | 8 (5) | 7 (4) |

(Counts from `jq` grouping by `PkgName` / `artifact.name` on the two JSON files.)

## 3. Candidates

### Bump candidates

**B1. PCRE2 10.42 -> 10.49 (libpcre2-8-0).** Loaded by the core nginx binary (`ldd`). All 7 findings are
reported by both scanners through dpkg:

| CVE | Trivy sev | Upstream fixed | Trigger (from the upstream GHSA) |
|---|---|---|---|
| CVE-2026-103111 | HIGH | 10.49 | JIT match with a growable JIT stack (`pcre2_jit_stack_assign`) and an attacker-controlled pattern |
| CVE-2026-86145 | HIGH | 10.48 | `pcre2_dfa_match` |
| CVE-2026-89157 | HIGH | 10.48 | `pcre2_pattern_convert`, 32-bit only |
| CVE-2026-89161 | HIGH | 10.48 | fast-path `pcre2_jit_match` |
| CVE-2026-89156 | MEDIUM | 10.48 | JIT fallback with mismatched match mode + invalid UTF |
| CVE-2026-89158 | MEDIUM | 10.48 | `pcre2_compile_32`, 32-bit only |
| CVE-2026-89160 | MEDIUM | 10.48 | `PCRE2_UTF` + `PCRE2_MATCH_INVALID_UTF`, affected 10.34-10.47 |

Sources:
- Fixed versions and descriptions: `jq '... select(.PkgName=="libpcre2-8-0")' scans/baseline-trivy.json`.
- Triggers: https://github.com/PCRE2Project/pcre2/security/advisories/GHSA-r9hj-j2rw-4q3m,
  https://github.com/PCRE2Project/pcre2/security/advisories/GHSA-2p8c-ff85-vh9x and
  https://github.com/PCRE2Project/pcre2/security/advisories/GHSA-9qww-pwc4-77qq.
- Release notes: https://github.com/PCRE2Project/pcre2/releases (10.49 is "a security-only release, to address GHSA-r9hj-j2rw-4q3m").

- **ABI:** the soname stays `libpcre2-8.so.0`. `configure.ac` has `libpcre2_8_version` `[11:2:11]` in tag
  pcre2-10.42 and `[16:1:16]` in tag pcre2-10.49, and libtool major = current - age = 0 in both.
  The real file name changes from `libpcre2-8.so.0.11.2` to `libpcre2-8.so.0.16.1`.
  Source: `curl https://raw.githubusercontent.com/PCRE2Project/pcre2/<tag>/configure.ac | grep libpcre2_8_version`.
  The 10.47 release notes add symbol-versioning linker scripts, with no soname change mentioned.
- **Debian:** bookworm already has a fixed package: `libpcre2-8-0` from source `pcre2` `10.42-1+deb12u2`
  (bookworm security). Details are in section 5 (bump). The other 6 CVEs are fixed from `10.42-1+deb12u1`
  (Trivy `FixedVersion`). Plain `apt upgrade` would fix all 7. The assignment asks for a bump built from source,
  so we use upstream 10.49.
- **Reachability (honest caveat):** nginx 1.25.5 uses PCRE2 like this
  (https://raw.githubusercontent.com/nginx/nginx/release-1.25.5/src/core/ngx_regex.c, lines 157-176, 428, 672):
  - `pcre2_compile` with only `PCRE2_CASELESS` / `PCRE2_MULTILINE`;
  - `pcre2_match(re, s, len, 0, 0, ...)`;
  - `pcre2_jit_compile(PCRE2_JIT_COMPLETE)` only when `pcre_jit on`;
  - no `pcre2_jit_stack_assign`, no DFA, no `PCRE2_MATCH_INVALID_UTF`.

  Patterns come from the trusted config. So none of the 7 trigger paths is reachable through stock nginx on amd64.
  The vulnerable library is still shipped and mapped into every nginx process.

**B2. OpenSSL 3.0.11 -> newer (libssl3).** Loaded by the core binary for TLS (the default config has no TLS server).
There are 49 findings, many in CMS/PKCS#12/CMP code that nginx does not call. Example: CVE-2024-6119 (Trivy HIGH),
where "OpenSSL 3.0 users should upgrade to OpenSSL 3.0.15" and "TLS servers are generally not affected"
(https://openssl-library.org/news/secadv/20240903.txt). Upstream no longer offers any 3.0.x for download: the
page lists 3.5 LTS, 3.6, 4.0, 4.1 and says "All versions not listed above are out of support"
(https://openssl-library.org/source/). So a bump means a move to 3.5. The soname stays `libssl.so.3`, but it is
a feature-release jump for a library that the whole OS shares. Debian has fixes up to `3.0.22-1~deb12u2`
(Trivy fixed versions).

**B3. libxml2 / libxslt.** Used only by the xslt and njs modules, which the default config does not load. Lower value.

**B4. zlib.** There is no fix in Debian or the scanners (`FixedVersion null` for all 3). CVE-2023-45853 is in minizip,
not in `libz.so.1`, and CVE-2026-85091 covers zlib 1.3.1.2-1.3.2, not 1.2.13 (Trivy description). Not a candidate.

### Backport candidates (nginx 1.25.5, from https://nginx.org/en/security_advisories.html)

Modules compiled in come from `nginx -V` (`docs/baseline.md` section 4).

**P1. CVE-2026-15176: buffer overflow when using alias with rewrite.** Range 0.1.29-1.31.6, fixed 1.31.7+, 1.30.6+
(https://nginx.org/en/security_advisories.html).
- **Compiled in:** core http module, always built.
- **No nginx.org patch file:** for 2024+ advisories nginx.org publishes only `patch.2024.mp4.txt`
  (`curl .../security_advisories.html | grep -o 'href="[^"]*patch[^"]*"'`). The upstream commit is the official fix.

#### P1.a Upstream fix, verbatim

Commit: https://github.com/nginx/nginx/commit/f8a23425bd6840c4c36b4264edf576ba3646156f
(author Roman Arutyunyan, 2026-07-10, subject "Avoid post-rewrite URI to path mapping with alias").
Source: `curl -sSL https://github.com/nginx/nginx/commit/f8a23425bd6840c4c36b4264edf576ba3646156f.diff`, full output:

```diff
diff --git a/src/http/ngx_http_core_module.c b/src/http/ngx_http_core_module.c
index 380ee21b29..30ae6e0ec8 100644
--- a/src/http/ngx_http_core_module.c
+++ b/src/http/ngx_http_core_module.c
@@ -1987,7 +1987,7 @@ ngx_http_map_uri_to_path(ngx_http_request_t *r, ngx_str_t *path,
 
     alias = clcf->alias;
 
-    if (alias && !r->valid_location) {
+    if (alias && (!r->valid_location || r->uri_changed)) {
         ngx_log_error(NGX_LOG_ALERT, r->connection->log, 0,
                       "\"alias\" cannot be used in location \"%V\" "
                       "where URI was rewritten", &clcf->name);
```

#### P1.b The same code in nginx 1.25.5

File: https://raw.githubusercontent.com/nginx/nginx/release-1.25.5/src/http/ngx_http_core_module.c (tag release-1.25.5).
- The text below is a verbatim quote of the function head, from WebFetch of that URL. WebFetch numbered the lines
  relative to the function, so it could not give absolute line numbers.
- The absolute line numbers come from `curl -sS <same URL> | grep -n -B3 -A3 'alias && !'`, which returned
  `1884-` (blank), `1885- alias = clcf->alias;`, `1886-` (blank) and `1887: if (alias && !r->valid_location) {`.
- The two sources agree: relative line 13 is absolute line 1887, so absolute = relative + 1874.
- The other lines are numbered with that offset.

```c
1875  u_char *
1876  ngx_http_map_uri_to_path(ngx_http_request_t *r, ngx_str_t *path,
1877      size_t *root_length, size_t reserved)
1878  {
1879      u_char                    *last;
1880      size_t                     alias;
1881      ngx_http_core_loc_conf_t  *clcf;
1882
1883      clcf = ngx_http_get_module_loc_conf(r, ngx_http_core_module);
1884
1885      alias = clcf->alias;
1886
1887      if (alias && !r->valid_location) {
1888          ngx_log_error(NGX_LOG_ALERT, r->connection->log, 0,
1889                        "\"alias\" cannot be used in location \"%V\" "
1890                        "where URI was rewritten", &clcf->name);
1891          return NULL;
1892      }
1893
1894      if (clcf->root_lengths == NULL) {
```

**Does the patch context match 1.25.5?**
- The hunk covers 7 old lines starting at 1987: blank, `alias = clcf->alias;`, blank, the `-` line, and 3 lines of
  `ngx_log_error(...)`.
- In 1.25.5 the same 7 lines are 1884-1890, character for character, with the same function name in the hunk header.
- So the context matches exactly, at an **offset of -103 lines and no fuzz**. `patch` should report
  "Hunk #1 succeeded at 1884 (offset -103 lines)". Phase 3 must confirm this when it applies the patch.
- The new condition uses `r->uri_changed`, and that field exists in 1.25.5: `ngx_http_request.h:486  unsigned uri_changed:1;`
  (`curl https://raw.githubusercontent.com/nginx/nginx/release-1.25.5/src/http/ngx_http_request.h | grep -n uri_changed`).
- Cross-check on the stable branch: tag release-1.30.6 has the `+` line (`ngx_http_core_module.c:1939`), and
  release-1.30.5 still has the `-` line (`curl ... | grep -n 'alias && '`).

#### P1.c Regression test config and request

**No upstream nginx-tests test exists for this fix.** What I checked in https://github.com/nginx/nginx-tests:
- Recent commits on master (https://github.com/nginx/nginx-tests/commits/master, Jun 2 to Oct 23, 2026): no title
  mentions alias, rewrite, request_filename or uri_changed.
- `curl 'https://api.github.com/repos/nginx/nginx-tests/commits?since=2026-06-01T00:00:00Z&per_page=100' | jq ... | grep -i 'alias|rewrite|filename'`: no match.
- `rewrite.t` was last changed in 2021 (3457b853fe). Its only valid-location test (commit 5c6675b275, "added rewrite
  'break' directive test for valid location") uses `proxy_pass`, not `alias`.
- Files that contain the word `alias`, found by fetching likely files and grepping:
  - `http_location_predicate_extra.t`, `http_try_files.t`, `http_absolute_redirect.t`, `http_disable_symlinks.t`, `ssi.t` and others.
  - None of them has a location with `alias` plus a `rewrite` without `break`/`last` plus a use of `$request_filename`.
  - In `http_location_predicate_extra.t` the `rewrite` lines (85, 89) are `rewrite ^ /mapped last;`, in locations without alias.
- GitHub code search needs authentication and `gh` is not installed, so I could not search every file.
  It is possible that a test exists in a file I did not fetch.

**The only upstream config is the example in the nginx commit message** (commit f8a2342 above, not nginx-tests):

```
The following example resulted in a buffer overflow with the request
"/foo/1":

location /foo/ {
    alias /bar/;
    rewrite ^/foo/.*$ /x;
    return 200 $request_filename;
}
```

- **Request:** `GET /foo/1 HTTP/1.1`. This is a normal request: a plain path, no crafted bytes or headers.
- **What I ran:** the block above inside `server { listen 80; ... }`, as `/etc/nginx/conf.d/default.conf`.
  My only change is `"$request_filename\n"` instead of `$request_filename`, so the body ends with a newline.
  That wrapper is mine; the location block is upstream.
- **Expected on a vulnerable build:** `200`. The body is a path mapped from the rewritten URI `/x` using the length of
  the location prefix `/foo/`. The commit message says this mapping "might result in a buffer overflow if location's
  prefix was longer than the rewritten URI". The overflow is a heap write and is not visible without ASan.
- **Expected on a fixed build:** `ngx_http_map_uri_to_path()` returns NULL, so `$request_filename` cannot be evaluated.
  The error log shows `[alert] ... "alias" cannot be used in location "/foo/" where URI was rewritten` (the message
  text is in the code above).
  I expect status `500`. This is inferred from how nginx handles a failed variable in `return`, and has not been
  observed yet. Phase 6 must confirm it.
- **Observed on the baseline** (`scans/baseline-cve-2026-15176-check.txt`, image `$D`):
  ```
  $ curl -s -i http://127.0.0.1:18080/foo/1
  HTTP/1.1 200 OK
  Server: nginx/1.25.5
  Content-Length: 3

  /x
  $ docker logs ... | grep -E "alias|alert|crit|signal|GET /foo"
  172.17.0.1 - - [26/Oct/2026:08:34:18 +0000] "GET /foo/1 HTTP/1.1" 200 3 "-" "curl/7.81.0" "-"
  ```
  The result is 200 with no alert, so the baseline runs the unguarded mapping. The worker did not crash. Without ASan
  we cannot see whether memory was overwritten.

#### P1.d Scanners and VEX

- **Grype** reports CVE-2026-15176 (Critical) on `nginx 1.25.5-1~bookworm` because Debian bookworm is still marked vulnerable
  (https://security-tracker.debian.org/tracker/CVE-2026-15176).
- A backport does **not** change the nginx version string, so **grype will keep reporting CVE-2026-15176 on our
  fixed image**. It disappears only when our VEX document is applied (`grype <our image> --vex <openvex.json>`).
  That before/after pair (without VEX: listed; with VEX: gone) is the VEX demo the spec asks for.
- **Trivy** does not report CVE-2026-15176 on the baseline, and will not on our image, with or without VEX
  (section 1: Trivy has 0 nginx findings).

**P2. CVE-2024-7347: buffer overread in ngx_http_mp4_module** (severity low). Range 1.5.13-1.27.0, fixed 1.27.1+, 1.26.2+.
- **Official patch:** https://nginx.org/download/patch.2024.mp4.txt (+ `.asc`). It touches 1 file
  (`ngx_http_mp4_module.c`) in 3 hunks, +11/-3 lines. It adds an "unordered mp4 stsc chunks" check and a 64-bit cast.
  Advisory: https://mailman.nginx.org/pipermail/nginx-announce/2024/UUOCLLONPR6244YQYU65PO5LB7JDYCWM.html
- **Compiled in:** `--with-http_mp4_module`. It is reachable only with the `mp4` directive and a crafted file.
- **Not reported by either scanner** (see section 1), so a VEX file cannot make it "disappear".

**P3. CVE-2026-97629: session forgery with TLS session tickets.** Range 1.23.2-1.31.6.
- Fix: https://github.com/nginx/nginx/commit/1916f26e6ca49296568633d309777e36527e5bb2, a one-line change in
  `ngx_event_openssl.c` (`2 *` -> `keys->nelts *` in the memcpy). The same line is at 1.25.5 `ngx_event_openssl.c:4816`.
- Grype reports it (High). It needs TLS + `ssl_session_cache shared` + automatic key rotation. The F5 text says
  exploitation is "non-deterministic", so a reliable proof is hard.

**P4. CVE-2026-95101: HTTP/3 request body injection.** Range 1.25.0-1.31.6.
- Fix: https://github.com/nginx/nginx/commit/1c173a2d8767730e678c27446138d7ae5dd6fd64, +4/-1 lines in 2 files
  (`src/http/v3/ngx_http_v3_parse.c`, `src/http/v3/ngx_http_v3_parse.h`).
- `--with-http_v3_module` is compiled in. Grype reports it (Medium). A proof needs a QUIC client that can send
  unknown frames, plus TLS. Higher test effort.

Others are out of scope as primary picks:
- CVE-2026-97205 (AIO+SSI UAF): fix 6adfc05, 4 files, +53 lines. Larger change.
- CVE-2024-32760 / -31079 / -35200 / -34161 (HTTP/3): not reported by scanners, no nginx.org patch.
- CVE-2026-93479 (grype false positive) and CVE-2023-44487 (likely mitigated in 1.25.3, not verified; section 1). Candidates for VEX, not for a fix.

## 4. Ranking matrix

Legend: Y = yes / good, P = partial, N = no / poor.

| Candidate | Present in baseline | Shipped and used | Verifiable upstream fix | Provable in running container | Low compat risk | Low build effort | Scanner-visible | Small change | Rank |
|---|---|---|---|---|---|---|---|---|---|
| **B1** PCRE2 -> 10.49 (CVE-2026-103111 +6) | Y (dpkg 10.42-1) | P (core links it; CVE paths unused by nginx) | Y (release + GHSA + commit) | Y (maps shows `.so.0.16.1`; rescan) | Y (same soname) | Y (autotools, small lib) | Y (both) | Y (one version) | **1 bump** |
| B2 OpenSSL -> 3.5 | Y | P (TLS not in default config) | Y | Y | N (3.0 -> 3.5, OS-wide) | N | Y (both) | N | 2 |
| B3 libxml2/libxslt | Y | N (modules not loaded by default) | Y | P | P | P | Y | P | 3 |
| **P1** CVE-2026-15176 alias+rewrite | Y (same line in 1.25.5) | Y (core http, always built) | Y (commit f8a2342, in 1.30.6/1.31.7) | Y (baseline 200 observed; fixed: alert + error expected) | Y (only rejects an already-broken config) | Y | P (grype only; stays listed until VEX) | Y (1 line) | **1 backport** |
| P2 CVE-2024-7347 mp4 | Y | P (needs `mp4` directive) | Y (official nginx.org patch) | P (needs crafted mp4) | Y | Y | N (neither scanner) | Y (+11/-3) | 2 |
| P3 CVE-2026-97629 tickets | Y (same line) | P (TLS + shared cache) | Y (commit 1916f26) | N (non-deterministic) | Y | Y | P (grype only) | Y (1 line) | 3 |
| P4 CVE-2026-95101 HTTP/3 | Y | P (needs `listen ... quic`) | Y (commit 1c173a2) | P (needs QUIC client) | Y | Y | P (grype only) | Y (+4/-1) | 4 |

## 5. Recommended CVEs (the user decides)

### Bump: CVE-2026-103111 in PCRE2 (and the other 6 PCRE2 CVEs fixed by the same bump)

- **Affected:** `libpcre2-8-0` 10.42-1, `/usr/lib/x86_64-linux-gnu/libpcre2-8.so.0.11.2`, linked by `/usr/sbin/nginx`.
- **Exact fixed version:** PCRE2 **10.49** (released 2026-09-28). 10.48 and earlier are affected. The other 6
  PCRE2 CVEs are fixed in 10.48, so 10.49 covers all 7.
  - Advisory: https://github.com/PCRE2Project/pcre2/security/advisories/GHSA-r9hj-j2rw-4q3m
    ("Affected versions: <= 10.48", "Patched version: 10.49").
- **Upstream fix commit:** https://github.com/PCRE2Project/pcre2/commit/2b4038298072684b0fae29b15bedfb1a75bda46d
  - Zoltan Herczeg, 2026-09-21, "Fix large JIT stack allocation".
  - Changes `src/pcre2_jit_compile.c` (+19/-2) and adds a regression test in `testdata/testinput17` and `testdata/testoutput17`.
  - Source: `curl -sSL https://github.com/PCRE2Project/pcre2/commit/2b40382....patch`, header and diffstat.
- **ChangeLog / release note:** https://raw.githubusercontent.com/PCRE2Project/pcre2/pcre2-10.49/ChangeLog, entry
  "Version 10.49 28-September-2026":
  ```
  1. (GHSA-r9hj-j2rw-4q3m) Security fix to prevent an out-of-bounds write with
  arbitrary data. Applications are only affected if using the
  pcre2_jit_stack_create() and pcre2_jit_stack_assign() APIs to provide a growable
  JIT stack, and then matching against a pattern with unusually high JIT stack
  usage, such as a large number of capturing groups.
  ...
  The issue is not a regression and affects releases 10.48 and earlier.
  ```
  Release page: https://github.com/PCRE2Project/pcre2/releases/tag/pcre2-10.49 ("a security-only release, to address GHSA-r9hj-j2rw-4q3m").
- **Debian bookworm already ships a fixed package: yes.**
  - Tracker: https://security-tracker.debian.org/tracker/CVE-2026-103111, source package `pcre2`:
    - bookworm `10.42-1`: vulnerable.
    - bookworm (security) `10.42-1+deb12u2`: fixed. The fixed-version table gives bookworm `10.42-1+deb12u2`, origin **DLA-4816-1**.
    - The tracker notes cite the same upstream commit 2b40382 "(pcre2-10.49)".
  - Announcement: https://lists.debian.org/debian-lts-announce/2026/10/msg00008.html, "[SECURITY] [DLA 4816-1] pcre2
    security update", 2026-10-03, bookworm fixed version `10.42-1+deb12u2`, CVE-2026-103111.
  - This is a Debian LTS advisory (DLA), not a DSA. For trixie the tracker lists DSA-6530-1 (`10.46-1~deb13u3`).
  - Our baseline has `10.42-1`, from the 20240513 apt snapshot, so it predates this fix.
- **Why it qualifies:**
  - The core nginx binary loads this library.
  - Both scanners report it through dpkg (Trivy HIGH).
  - An upstream release has the fix, and the soname is unchanged (`.so.0`).
  - It is a small, self-contained autotools build, and the only change is the version number.

  Caveat: no PCRE2 trigger path is used by stock nginx (section 3, B1), so this removes shipped vulnerable code,
  not a reachable nginx exploit.
- **How we prove it later (phase 6):**
  1. `dpkg-query -W libpcre2-8-0` in our image shows our 10.49 package.
  2. `grep pcre2 /proc/1/maps` (master) and the same for a worker PID show `libpcre2-8.so.0.16.1`, not `0.11.2`.
  3. `ldd /usr/sbin/nginx` resolves to that file.
  4. The upstream test suite (`make check`) passes during the build. It includes the regression case that commit
     2b40382 added to `testdata/testinput17`. testinput17 covers JIT, so it runs only if the build enables JIT
     (as Debian does); phase 3 should confirm this.
  5. A Trivy/Grype rescan no longer lists the 7 PCRE2 CVEs.
  6. A regex `location ~` test in `make test` shows regex matching still works.

### Backport: CVE-2026-15176 in nginx 1.25.5 (alias + rewrite buffer overflow)

- **Affected:** nginx 1.25.5 core, `src/http/ngx_http_core_module.c`, `ngx_http_map_uri_to_path()` (line 1887).
- **Fixed in:** nginx 1.31.7 and 1.30.6 (https://nginx.org/en/security_advisories.html; https://nginx.org/en/CHANGES, 1.31.7 entry).
- **Upstream:** commit https://github.com/nginx/nginx/commit/f8a23425bd6840c4c36b4264edf576ba3646156f;
  F5 advisory https://my.f5.com/manage/s/article/K000162416 (the page did not render for WebFetch; the link comes from
  the grype record and the Debian tracker).
- **Why it qualifies:**
  - It is in code that is always compiled in.
  - The fix is one line, and the old line is identical in 1.25.5, so the patch applies with only a line offset.
  - Grype reports it as Critical and Debian bookworm is still unfixed. The backport keeps the version string, so
    grype still lists it on our image until our VEX is applied. That before/after is the VEX demo (section 3, P1.d).
  - It has a deterministic, upstream-documented reproducer: the config from the commit message (section 3, P1.c).
    There is no nginx-tests test for it.
- **How we prove it later (phase 6):**
  1. The patch file `build/patches/CVE-2026-15176.patch` is applied in the build log.
  2. Run the commit-message config with `GET /foo/1` against both images.
     - Baseline (observed): `HTTP 200`, no alert.
     - Ours (expected): the `"alias" cannot be used in location "/foo/" where URI was rewritten` alert in the error
       log, and an error status (expected 500, to be confirmed). Superseded by D5: the fixed build answers 200 with
       an empty body, plus the alert, like upstream 1.31.7.
  3. `make test` still passes for normal `alias` locations without rewrite.
  4. VEX demo with grype:
     - `grype <our image>` still lists CVE-2026-15176, because the version string is unchanged.
     - `grype <our image> --vex <openvex.json>`, with status `fixed` for CVE-2026-15176 on our nginx package, no
       longer lists it.
     - Trivy does not report this CVE either way.

## 6. Alternatives (ranked lower)

1. **CVE-2024-7347 (backport, mp4).** It has the only official nginx.org patch file for a 2024+ advisory, and the patch
   is tiny. It ranks lower because neither scanner reports it, even on the baseline, so a VEX file has nothing to suppress
   and the required before/after VEX demo is impossible with it.
   It also needs the `mp4` directive and a crafted MP4 file to prove. Good second backport if we want one.
2. **OpenSSL bump (e.g. CVE-2024-6119).** It is used by nginx for TLS and visible to both scanners. It ranks lower
   because public upstream 3.0 is out of support, so the bump would be 3.0 -> 3.5. That is a large, OS-wide change
   with a high build cost, and the nginx binary was built against 3.0.9 headers.
3. **CVE-2026-97629 (backport, session tickets).** The fix is one line and grype reports it. It ranks lower because
   the bug is non-deterministic and needs a TLS + shared session cache setup, which is hard to prove end to end.

## 7. Open questions for the user

1. **Bump method for PCRE2:** build a replacement `libpcre2-8-0` .deb from upstream 10.49, which keeps it visible to
   dpkg and the scanners (recommended)? Or link PCRE2 statically into nginx with `--with-pcre=`, which hides it from dpkg
   so the scanners would no longer see it? The first matches the agent rule "detected through dpkg".
2. **Reachability:** are you fine with a bump whose CVEs are present and loaded but not reachable through stock nginx,
   as documented above? If you prefer a reachable library CVE, OpenSSL is the option, at much higher cost.
3. **VEX scope:** should the VEX file also mark the 2 grype false positives (CVE-2026-93479, CVE-2023-44487) as
   `not_affected`? That would be an extra beyond the spec, so only with your approval.
4. **VEX demo uses grype only:** the backport does not change the nginx version string, so grype keeps reporting
   CVE-2026-15176 on our fixed image. It disappears only after our VEX is applied (`grype <image> --vex <file>`), and
   that before/after is the VEX demo the spec asks for. Trivy does not report CVE-2026-15176 at all, before or after,
   so the README would show the demo with grype and say plainly that Trivy has nothing to suppress. Is that acceptable?
5. **No upstream regression test:** nginx-tests has no test for CVE-2026-15176 (section 3, P1.c), so our test would
   use the config from the upstream commit message. Is that acceptable, or do you want a different backport that
   has an nginx-tests test?
