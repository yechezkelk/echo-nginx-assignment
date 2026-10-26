# echo-nginx: a drop-in `nginx:1.25-bookworm`, rebuilt from source with 2 CVEs fixed

**What.** `echo-nginx:1.25.5-echo1` replaces `nginx:1.25-bookworm` (pinned as
`nginx@sha256:a484819eb60211f5299034ac80f6a681b06f89e65866ce91f356ed7c72af059c`, linux/amd64).
nginx 1.25.5 and PCRE2 are compiled from upstream source in a clean `debian:bookworm-slim`.

**Result.**
- **CVE-2026-103111** (PCRE2) fixed by a **version bump**, 10.42 to 10.49.
- **CVE-2026-15176** (nginx alias + rewrite buffer overflow) fixed by **backporting** upstream commit
  [`f8a2342`](https://github.com/nginx/nginx/commit/f8a23425bd6840c4c36b4264edf576ba3646156f) onto 1.25.5.
- Both are proven in the running container, not only in the build.
- The runtime contract (entrypoint, cmd, user, ports, env, files, stop signal) matches the baseline.
- `make test` compares HTTP behaviour against the baseline.
- A VEX document makes the backported CVE disappear from both scanners.

**Run it.**

```sh
make                 # build the .debs from source, check them, build the image
make test            # contract diff + HTTP compatibility test + both CVE fix checks
docker run --rm -p 8080:80 echo-nginx:1.25.5-echo1
```

## Contents

- [Build instructions](#build-instructions)
- [Image size](#image-size)
- [Fixed CVEs](#fixed-cves)
- [Rescan: where the other CVEs went](#rescan-where-the-other-cves-went)
- [VEX](#vex)
- [Residual risk](#residual-risk)
- [Surprises](#surprises)
- [AI usage](#ai-usage)
- [Further reading](#further-reading)

## Build instructions

**Requirements:** Docker with BuildKit (observed with Docker 27.3.1), `make`, `python3` (standard library only), `jq`.
`make scan` and `make vex` also need Trivy and Grype (observed: Trivy 0.76.1, Grype 0.121.0, `scans/rescan/scanner-info.txt`).
The build downloads upstream sources, so it needs network access.

| Command | What it does | Writes | Time (fresh clone) |
|---|---|---|---|
| `make` | `debs`, `verify-debs`, `image`, in that order. Builds `libpcre2-8-0_10.49-0echo1` and `nginx_1.25.5-1echo1` inside [`build/Dockerfile`](build/Dockerfile). Every source is checked by sha256, and by GPG where upstream signs it. Installs both .debs into a fresh `debian:bookworm-slim` and checks them. Builds the image from [`Containerfile`](Containerfile). | `.deb` files in `build/out/` (git-ignored); evidence in [`docs/evidence/build/`](docs/evidence/build/); image `echo-nginx:1.25.5-echo1` | 134 s, partly cached (see below) |
| `make test` | [`test/contract-diff.sh`](test/contract-diff.sh) (runtime contract), then [`test/compat_test.py`](test/compat_test.py) (HTTP behaviour, 5 profiles), then [`test/fix-checks.sh`](test/fix-checks.sh) (both CVE fixes). Exits non-zero on any mismatch. Does not build; stops if the image is missing. | [`docs/evidence/fixes/`](docs/evidence/fixes/) | 35 s |
| `make scan` | Rescans the baseline and our image with Trivy and Grype in one run, with the DB update switched off so both images use the same DB. Sorts every change into buckets. | [`scans/rescan/`](scans/rescan/) | 46 s |
| `make vex` | Re-runs the fix checks. Writes the OpenVEX file from the scanners' own package purls. Rescans our image with `--vex` and records what it removed. Needs `make scan` first. | [`vex/echo-nginx.openvex.json`](vex/echo-nginx.openvex.json), `scans/rescan/*-vex.*` | 22 s |
| `make clean` | Deletes the .deb files only; tracked evidence stays. | | |

**Fresh-checkout run.** The repo was cloned into a temporary directory on the Linux filesystem, and `make`, `make test`,
`make scan` and `make vex` were run there with `time`. All four exited 0.
- Times and notes: [`docs/evidence/runs/timings.txt`](docs/evidence/runs/timings.txt).
  This run was at commit `c2db4b4`. Later commits changed `build/verify-debs.sh` (it now strips carriage returns
  from its log), the docs and the script file modes; they did not change the build steps or the tests.
- Full `make test` output: [`docs/evidence/runs/make-test.txt`](docs/evidence/runs/make-test.txt).
  - The contract matches (only allow-listed differences).
  - The compatibility test passes 28 of 28 checks.
  - The fix checks pass 16 of 16 (8 per CVE) (at c2db4b4; nginx-debug checks added later, now 11 + 12 = 23, see docs/evidence/fixes/).
- The rescan in the clone gave byte-identical unique-ID lists and bucket counts.
- **The `make` time is not a cold build.** The apt installs and the PCRE2 stage came from the local Docker build cache.
  Downloading and verifying the sources, the nginx compile (85 s) and the image ran fresh.
  A build with an empty cache takes longer.

**What `make test` covers.** "Working correctly" means: for the same request, our image returns the same status line,
the same headers in the same order and a byte-identical body as the baseline.
Only `Date`, and the values of `Last-Modified` and `ETag`, are normalized.
The 5 profiles (28 checks in the run above) are described in the docstring of [`test/compat_test.py`](test/compat_test.py):
- stock: root, 404, HEAD, Range, keep-alive;
- custom config: 413 on a large body, malformed requests, regex and alias locations;
- dynamic modules: xslt, image_filter, njs;
- entrypoint templates;
- `nginx-debug`.

The same docstring lists what is not tested: TLS, HTTP/2 and HTTP/3, proxying, mail and stream.

`make test` rewrites the tracked files in [`docs/evidence/fixes/`](docs/evidence/fixes/) with fresh timestamps and ports, by design (D16), so `git status` shows them as modified after a run.

## Image size

From `docker image inspect --format '{{.Size}}'` ([`docs/runtime-contract.md`](docs/runtime-contract.md), [`docs/baseline.md`](docs/baseline.md) section 10):

| Image | Bytes | MiB |
|---|---|---|
| `nginx:1.25-bookworm` (baseline) | 187,659,947 | 179 |
| `echo-nginx:1.25.5-echo1` (ours) | 186,465,139 | 178 |
| Difference | -1,194,808 (-0.64%) | |

## Fixed CVEs

| CVE | Severity | Component | Method | Evidence |
|---|---|---|---|---|
| CVE-2026-103111 | High (Trivy HIGH, Grype High) | PCRE2, package `libpcre2-8-0`, loaded by `/usr/sbin/nginx` | **Bump** 10.42-1 to 10.49 (upstream source, our own .deb) | [fix check](docs/evidence/fixes/cve-2026-103111.txt), [make check](docs/evidence/build/pcre2-make-check.log), [version check](docs/evidence/build/pcre2-version-check.txt), [signatures](docs/evidence/build/signature-check.txt), [triage](docs/triage.md) |
| CVE-2026-15176 | Critical (Grype); HIGH (Trivy, ours only) | nginx 1.25.5 core, `ngx_http_map_uri_to_path()` in `src/http/ngx_http_core_module.c` | **Backport** of upstream `f8a2342` | [patch](build/patches/CVE-2026-15176.patch), [patch log](docs/evidence/build/patch-apply.log), [patched line](docs/evidence/build/patch-fix-line.txt), [fix check](docs/evidence/fixes/cve-2026-15176.txt), [upstream 1.31.7 check](docs/evidence/fixes/cve-2026-15176-upstream.txt), [triage](docs/triage.md) |

Severities: `jq` on `scans/baseline-trivy.json`, `scans/baseline-grype.json` and `scans/rescan/ours-trivy.json`.
Trivy does not report CVE-2026-15176 on the baseline (see [Surprises](#surprises)).

### CVE-2026-103111 (PCRE2, bump): the 4-part proof

1. **Vulnerable code in the baseline.** `dpkg-query` shows `libpcre2-8-0 10.42-1`.
   The running nginx master maps `libpcre2-8.so.0.11.2` ([fix check](docs/evidence/fixes/cve-2026-103111.txt)).
2. **The fix addresses it.** PCRE2 10.49 is a security-only release for
   [GHSA-r9hj-j2rw-4q3m](https://github.com/PCRE2Project/pcre2/security/advisories/GHSA-r9hj-j2rw-4q3m)
   ("Affected versions: <= 10.48"). The fix is commit
   [`2b40382`](https://github.com/PCRE2Project/pcre2/commit/2b4038298072684b0fae29b15bedfb1a75bda46d).
3. **Our build contains it.**
   - The tarball is checked by sha256 and its GPG signature ([sha256](docs/evidence/build/sha256-check.txt), [signatures](docs/evidence/build/signature-check.txt)).
   - `pcre2test -C` reports `10.49 2026-09-28` with JIT.
   - The upstream suite passes: `TOTAL: 4, PASS: 4`. Its RunTest includes test 17 (JIT), where `2b40382` added its regression case.
   - The soname stays `libpcre2-8.so.0` ([version check](docs/evidence/build/pcre2-version-check.txt)).
4. **The running container uses it.**
   - `ldd /usr/sbin/nginx` resolves to `libpcre2-8.so.0.16.1`, owned by `libpcre2-8-0 10.49-0echo1`.
   - The running nginx (PID 1) maps that file. The same holds for `nginx-debug` run as PID 1.
     Result: 12 passed, 0 failed ([fix check](docs/evidence/fixes/cve-2026-103111.txt)).
   - Both scanners no longer report the CVE on our image ([`scans/rescan/summary.md`](scans/rescan/summary.md)).

### CVE-2026-15176 (nginx, backport): the 4-part proof

1. **Vulnerable code in the baseline.** nginx 1.25.5 has the unguarded line `if (alias && !r->valid_location)`
   at `ngx_http_core_module.c:1887` ([triage](docs/triage.md), section P1.b).
   With the config from the upstream commit message, the baseline answers `GET /foo/1` with `200`, body `/x` and no alert:
   it maps the rewritten URI ([fix check](docs/evidence/fixes/cve-2026-15176.txt)).
2. **The fix addresses it.** Upstream commit
   [`f8a2342`](https://github.com/nginx/nginx/commit/f8a23425bd6840c4c36b4264edf576ba3646156f),
   "Avoid post-rewrite URI to path mapping with alias", adds `|| r->uri_changed` to that check.
   It ships in nginx 1.30.6 and 1.31.7 ([nginx.org advisories](https://nginx.org/en/security_advisories.html)).
3. **Our build contains it.** The upstream diff is applied unchanged ([`build/patches/CVE-2026-15176.patch`](build/patches/CVE-2026-15176.patch)).
   The log shows `Hunk #1 succeeded at 1884 (offset -103 lines)`, with no fuzz ([patch log](docs/evidence/build/patch-apply.log)).
   Line 1887 of the built source now reads `if (alias && (!r->valid_location || r->uri_changed))` ([patched line](docs/evidence/build/patch-fix-line.txt)).
4. **The running container uses it.**
   - Same config and request on our image: `200` with an empty body, and the alert
     `"alias" cannot be used in location "/foo/" where URI was rewritten` in the log.
   - A plain alias without rewrite still returns `200` with 615 bytes on both images.
   - `nginx-debug` in our image gives the same fixed response and alert.
     Result: 11 passed, 0 failed ([fix check](docs/evidence/fixes/cve-2026-15176.txt)).
   - The official fixed nginx 1.31.7, pinned by digest, gives the identical response
     ([upstream check](docs/evidence/fixes/cve-2026-15176-upstream.txt), D5).
     This was a one-off manual check, recorded in D5; it is not part of `make test` (D17).

The overflow itself is a heap write that is not visible without ASan. The proof is that the vulnerable code path
is now refused, exactly as upstream refuses it.

## Rescan: where the other CVEs went

Source: [`scans/rescan/summary.md`](scans/rescan/summary.md) and [`counts.txt`](scans/rescan/counts.txt).
Both images were scanned in one `make scan` run with the same scanner versions and DB.

Two units are used below, and they are never mixed:
- **unique CVE IDs**: each CVE counted once, however many packages it hits;
- **findings**: one per (CVE, package) pair, which is what a scanner's table lists.

| Count | Trivy baseline | Trivy ours | Grype baseline | Grype ours |
|---|---|---|---|---|
| **Unique CVE IDs** | 531 | 273 | 500 | 249 |
| **Findings** (CVE x package) | 831 | 464 | 799 | 445 |

**Why Trivy shows 8 new IDs on ours (unique CVE IDs), all on `nginx 1.25.5-1echo1`.** Trivy skips the baseline's
nginx.org packages as third-party ([`trivy-third-party-check.txt`](scans/rescan/trivy-third-party-check.txt)), but not ours.
So these 8 are not new risk: Grype reports the same 8 on the baseline.

| CVE | Explanation |
|---|---|
| CVE-2026-15176 | Our backported fix; removed by VEX |
| CVE-2026-93479 | False positive: nginx.org lists 1.31.2-1.31.6 and 1.30.0-1.30.5 as affected, not 1.25.5 ([triage](docs/triage.md)); not in VEX (D6) |
| CVE-2023-44487 | HTTP/2 rapid reset: likely mitigated in 1.25.3, not verified; our default config does not enable HTTP/2 (no `http2` directive, only `listen 80` and `[::]:80`), so it applies only to users who enable HTTP/2 ([triage](docs/triage.md)); not in VEX (D6) |
| CVE-2026-97205, CVE-2026-97629, CVE-2026-95101 | Real for 1.25.5, not backported: [residual risk](#residual-risk) |
| CVE-2009-4487, CVE-2013-0337 | Debian lists them as open, with no fix |

The buckets below count **unique CVE IDs**:

| Bucket (unique CVE IDs) | Trivy | Grype |
|---|---|---|
| **Intentional**, our work (CVE-2026-103111 gone) | 1 | 1 |
| **Incidental:** newer bookworm packages (D11), *not claimed as our work* | 259 | 244 |
| **Incidental:** other PCRE2 CVEs cleared by the same bump | 6 | 6 |
| **New in ours** | 8 | 0 |
| **Remaining in ours** (of which a fix is available) | 273 (1) | 249 (0) |

Check, in unique CVE IDs: Trivy 531 - 266 + 8 = 273; Grype 500 - 251 + 0 = 249.

- **Intentional.** CVE-2026-103111 is gone in both scanners.
  CVE-2026-15176 stays listed without VEX, because the backport keeps version 1.25.5. That is what the VEX is for.
- **Incidental, PCRE2 bump.** CVE-2026-86145, -89156, -89157, -89158, -89160 and -89161 were only on `libpcre2-8-0 10.42-1`.
- **Incidental, newer bookworm packages.** Our image installs current bookworm packages, so all 68 shared packages
  with a different version are newer in ours: 66 Debian updates plus our two packages.
  The most frequent among the cleared IDs: openssl/libssl3, libexpat1, libgnutls30, libxml2, perl-base, curl.
  **We did not fix these; we only did not freeze the old versions** ([D11](docs/decisions.md)).
- **Remaining.** Only one remaining unique ID has a fix: Trivy's DLA-4854-1 (see [Residual risk](#residual-risk)).
- **New in ours.** The 8 Trivy IDs are explained right under the counts table above.

## VEX

[`vex/echo-nginx.openvex.json`](vex/echo-nginx.openvex.json) (OpenVEX, generated by `make vex` from [`vex/openvex.jq`](vex/openvex.jq)).

- **Covers:** 2 statements, both `fixed`. Only our two CVEs are included (D6):
  - CVE-2026-15176 on `pkg:deb/debian/nginx@1.25.5-1echo1?arch=amd64&distro=debian-12.15`;
  - CVE-2026-103111 on `pkg:deb/debian/libpcre2-8-0@10.49-0echo1?arch=amd64&distro=debian-12.15`.
- **Purls are not typed by hand.** They are read from Trivy's package list of our image, and checked against Grype's.
- **Before / after** on our image, counted in **findings** (CVE x package), not unique CVE IDs.
  These are the same scans as the "Findings, ours" row in the [rescan table](#rescan-where-the-other-cves-went).
  Sources: [`vex-removed-trivy.txt`](scans/rescan/vex-removed-trivy.txt), [`vex-removed-grype.txt`](scans/rescan/vex-removed-grype.txt).

  | Findings on our image | without `--vex` | with `--vex` | removed | added |
  |---|---|---|---|---|
  | Trivy | 464 | 463 | `CVE-2026-15176 nginx 1.25.5-1echo1` | none |
  | Grype | 445 | 444 | `CVE-2026-15176 nginx 1.25.5-1echo1` | none |

  CVE-2026-15176 disappears **only** with `--vex`. Grype lists it under `ignoredMatches` with `vex-status: fixed`.
- **CVE-2026-103111** is not reported on our image even without VEX, because 10.49 is a fixed version.
  The VEX has nothing to remove for it.

## Residual risk

| What is still there | Why | What I'd do next |
|---|---|---|
| **3 real nginx CVEs** in 1.25.5: CVE-2026-97205 (AIO + SSI use-after-free, Grype Critical), CVE-2026-97629 (TLS session tickets, Grype High), CVE-2026-95101 (HTTP/3 body injection, Grype Medium) | Out of scope: the spec asks for 2 CVEs done end to end. Each needs a specific setup: AIO + SSI, TLS with a shared session cache, or `listen ... quic`. CVE-2026-97629 is non-deterministic, so it is hard to prove ([triage](docs/triage.md), section 3). | Backport upstream [`1916f26`](https://github.com/nginx/nginx/commit/1916f26e6ca49296568633d309777e36527e5bb2) (one line) and [`1c173a2`](https://github.com/nginx/nginx/commit/1c173a2d8767730e678c27446138d7ae5dd6fd64) (+4/-1), then `6adfc05` (+53 lines). Or move to a supported nginx line. |
| **nginx advisories the scanners do not see**, e.g. CVE-2024-7347 (mp4) | Neither scanner evaluates the nginx.org package correctly ([triage](docs/triage.md), section 1). | Track nginx CVEs against the nginx.org advisory list, not the scanners. |
| **tzdata, DLA-4854-1** (Trivy; fixed in `2026e-0+deb12u1`) | The only remaining ID with a fix available ([summary](scans/rescan/summary.md)). | A plain rebuild picks it up (D11). |
| **PCRE2 JIT bug was not reachable through stock nginx** | CVE-2026-103111 needs `pcre2_jit_stack_assign`, a growable JIT stack, and an attacker-controlled pattern. nginx 1.25.5 calls `pcre2_jit_compile` only with `pcre_jit on`, never assigns a JIT stack, and takes patterns only from the trusted config ([triage](docs/triage.md), B1). The bump removes vulnerable code that was shipped and loaded, not a reachable nginx exploit. | Nothing more for nginx. Other programs in the image that use PCRE2 benefit. |
| **Debian already fixes CVE-2026-103111** in `10.42-1+deb12u2` ([DLA-4816-1](https://lists.debian.org/debian-lts-announce/2026/10/msg00008.html)) | We bumped to upstream 10.49 because the spec asks for a version bump built from source (D4). A plain `apt` upgrade would also clear this CVE. | In production, prefer Debian's patched package unless we need a newer upstream. |
| **Rebuilds are not bit-for-bit identical** | Base images are pinned by digest, but `apt-get install` takes current bookworm packages (D11). This is why 68 packages are newer than in the baseline, and why the scan counts can change between builds. | Pin apt to a `snapshot.debian.org` date, and bump that date on purpose. |
| **Remaining OS-package CVEs with no fix** (unique CVE IDs: Trivy 272 of 273, Grype 249 of 249, [`counts.txt`](scans/rescan/counts.txt)) | No fix is available in bookworm yet. The largest remaining packages are libheif1, curl/libcurl4, libtiff6 and libc6 ([summary](scans/rescan/summary.md)). heif and tiff are among the libraries of the image_filter module, which the default config does not load ([triage](docs/triage.md), section 2). | Rebuild regularly to pick up Debian fixes as they land. |
| **1 Grype false positive** (CVE-2026-93479) and **CVE-2023-44487** (HTTP/2 rapid reset: likely mitigated in 1.25.3, not verified; our default config does not enable HTTP/2 (no `http2` directive, only `listen 80` and `[::]:80`), so it applies only to users who enable HTTP/2) stay in the reports | Marking them in VEX would be an extra beyond the spec (D6). | Add `not_affected` VEX statements with the justification from [triage](docs/triage.md). |

## Surprises

- **The scanners do not see the nginx.org package properly.** The baseline's nginx comes from nginx.org,
  but its package name matches Debian's own `nginx`.
  - Trivy skips the package as third-party, so it reports 0 nginx findings on the baseline.
  - Grype applies Debian's tracker data to it. This gives a false positive (CVE-2026-93479), an unverified match
    (CVE-2023-44487, see the [rescan](#rescan-where-the-other-cves-went) table),
    and false negatives for real advisories in range such as CVE-2024-7347 ([triage](docs/triage.md), section 1).
  - So the scans are not an inventory for nginx itself. Our nginx candidates came from the nginx.org advisory list instead.
  - The same effect explains the 8 "new" Trivy findings on our image.
- **A guessed 500 versus upstream's 200.** Triage predicted that the fixed nginx would answer the CVE-2026-15176
  reproducer with `500`. Ours answered `200` with an empty body and the alert.
  - The check stopped on the unexpected result instead of being adjusted to match.
  - Running the official fixed nginx 1.31.7 gave the identical response, so the expectation is now based on
    upstream's real behaviour ([`cve-2026-15176-upstream.txt`](docs/evidence/fixes/cve-2026-15176-upstream.txt), D5).
  - Why 200: `return 200` keeps its status when the variable mapping is refused.
- **Evidence written to a git-ignored folder.** The first build wrote its evidence next to the .debs in
  `build/out/`, which is git-ignored. It would never have reached git, so the README would have had nothing to link to.
  It now goes to the tracked `docs/evidence/build/`, and every `make debs` replaces it, so it cannot go stale (D14).

### What I'd do differently with more time

- Backport the 3 remaining nginx CVEs (CVE-2026-97205, CVE-2026-97629, CVE-2026-95101; see [Residual risk](#residual-risk)).
- Pin apt to `snapshot.debian.org` for reproducible builds.
- Script the nginx 1.31.7 comparison (D17).
- Add `not_affected` VEX statements for the false positive(s), once each is verified.
- Bind the VEX to the image digest after pushing the image to a registry.

## AI usage

I built this with **Claude Code**, using one instruction file and one agent per phase:

- [`CLAUDE.md`](CLAUDE.md): working rules for every session: one phase at a time with my approval
  in between, what counts as a fixed CVE, and repo hygiene.
- [`.claude/agents/`](.claude/agents/): seven single-purpose agents (baseline-inspector, cve-triage,
  builder, image-builder, tester, fix-verifier, reviewer). Each one has a narrow task, a fixed list
  of paths it may write to, and a fixed report format. Agents share state only through files in
  the repo (`docs/baseline.md`, `docs/triage.md`, `docs/decisions.md`), so a fresh session can
  pick up any phase.
- Every decision I approved is logged in [`docs/decisions.md`](docs/decisions.md) (D1 to D17) with
  the alternatives I rejected.

**Where it helped**
- Mining roughly 800 scanner findings per scanner with `jq`, and spotting early that neither
  scanner evaluates the nginx.org package in the baseline, so nginx CVEs had to be checked
  against nginx.org directly.
- Finding a one-line upstream fix for CVE-2026-15176 and showing that its context matches the
  1.25.5 source before anything was built.
- Writing the build, packaging and test scripts, and re-running every agent's claims in a second,
  independent check before reporting to me.
- Proving that each test can fail (for example a changed body limit makes the compatibility
  test fail) before trusting it.

**Where it hurt, and how it was caught**
- **A guessed result.** Triage predicted that the fixed nginx would answer 500 for the
  CVE-2026-15176 check. Ours answered 200 with an empty body and the alert. Because the agent was
  told to stop on an unexpected result rather than adjust the test, it stopped. Running the same
  check against the official fixed nginx 1.31.7 showed the identical response, so the expectation
  in D5 is now based on what upstream actually does.
- **Wrong claims in reports.** One report said the backported CVE would disappear from the rescan
  on its own; it can't, since the version string doesn't change, which is what the VEX is for.
  Another described the baseline's apt sources as pinned to a snapshot, while its own output
  showed the snapshot lines were comments. Both were caught by reading the evidence, not the summary.
- **Evidence that would never reach git.** The first build wrote its evidence to a git-ignored
  folder. Moved to `docs/evidence/` (D14), with the checks re-run on every `make` so the
  evidence can't go stale, and random `ldd` load addresses stripped so it only changes when the
  results do.
- **Tooling.** The automatic permission check of Claude Code's auto mode returned no verdict
  twice, so I switched to approving each command by hand. A network outage blocked the upstream
  comparison; the agent stopped under the two-failures rule instead of skipping the check.
- An agent's signature check created a file outside the paths it was allowed to write to.
- **Safeguards.** The CVE-2026-15176 check uses only upstream's own config and a normal request, so no crafted
  input was needed (in a previous attempt, generating a malformed test file was blocked by the model's safeguards).

**Kept with me:** the choice of CVEs, the scope of the drop-in (D2), and the approval of every
phase and decision.

## Further reading

| Document | Contents |
|---|---|
| [`docs/decisions.md`](docs/decisions.md) | Every approved decision, D1 to D17, with the alternatives that were rejected |
| [`docs/runtime-contract.md`](docs/runtime-contract.md) | Baseline vs ours: what matches and every intentional difference |
| [`docs/triage.md`](docs/triage.md) | Baseline scan counts, what nginx loads, all candidates and why these 2 were chosen |
| [`docs/baseline.md`](docs/baseline.md) | Verified facts about the original image: digest, configure arguments, packages, layout, size |
| [`docs/assignment.md`](docs/assignment.md) | The assignment, transcribed |

**Repo layout:**
- `build/`: build Dockerfile, scripts, source checksums and keys, and `patches/` (one patch per backported CVE).
- `Containerfile`: the final image.
- `test/`: contract diff, compatibility test and fix checks.
- `scans/`: baseline scans (phase 2) and `rescan/` (phase 6).
- `vex/`: the OpenVEX document.
- `rootfs/`: entrypoint files copied from the baseline.
