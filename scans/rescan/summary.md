# Rescan: baseline vs our image (Phase 6)

Observed 2026-10-26. Produced by `make scan` (scans, ID lists, `classify.sh`) and `make vex`; every number can
be recounted from the files in this directory. Phase 2 scans in `scans/` are unchanged.

- Baseline: `nginx@sha256:a484819eb60211f5299034ac80f6a681b06f89e65866ce91f356ed7c72af059c` (debian 12.5)
- Ours: `echo-nginx:1.25.5-echo1` (ImageID `sha256:6563287b...84a8`, debian 12.15)

## Scanners and DB (`scanner-info.txt`)
| Tool | Version | DB |
|---|---|---|
| Trivy | 0.76.1 | v2, UpdatedAt 2026-10-26 07:15:18 UTC |
| Grype | 0.121.0 (Syft 1.55.0) | v6.1.10, built 2026-10-26T06:38:44Z |

Same versions and DB as phase 2. DB auto-update was off for every scan in this run (`trivy --skip-db-update`,
`GRYPE_DB_AUTO_UPDATE=false`). The baseline rescan gives exactly the phase 2 ID lists (`cmp` of the `jq` ID lists).

## Before / after
| | Trivy baseline | Trivy ours | Grype baseline | Grype ours |
|---|---|---|---|---|
| Findings | 831 | 464 | 799 | 445 |
| Unique IDs | 531 | 273 | 500 | 249 |
| Critical / High | 20 / 190 | 3 / 91 | 50 / 279 | 20 / 124 |
| Medium / Low | 321 / 263 | 157 / 185 | 268 / 38 | 123 / 20 |
| Negligible / Unknown | n/a / 37 | n/a / 28 | 139 / 25 | 135 / 23 |

## Buckets (`counts.txt`; per-ID lists in `gone-*.tsv`, `new-*.tsv`, `remaining-*.tsv`)
| Bucket | Trivy | Grype |
|---|---|---|
| Intentional (gone) | 1 | 1 |
| Incidental: newer bookworm packages (D11) | 259 | 244 |
| Incidental: PCRE2 bump | 6 | 6 |
| Incidental: package not in ours / other | 0 / 0 | 0 / 0 |
| New in ours | 8 | 0 |
| Remaining (fix available) | 273 (1) | 249 (0) |

Check: Trivy 531 - 266 + 8 = 273; Grype 500 - 251 + 0 = 249.

- **Intentional.**
  - CVE-2026-103111 is gone in both scanners (`docs/evidence/fixes/cve-2026-103111.txt`).
  - CVE-2026-15176 stays without VEX, because the backport keeps version 1.25.5 (`docs/evidence/fixes/cve-2026-15176.txt`).
- **PCRE2 bump.** CVE-2026-86145, -89156, -89157, -89158, -89160 and -89161 were only on libpcre2-8-0 10.42-1.
- **Newer bookworm packages.**
  - All 68 packages with a different version are newer in ours (`dpkg --compare-versions`): 66 bookworm updates,
    plus our own nginx and libpcre2-8-0.
  - Most frequent among the gone IDs: openssl/libssl3, libexpat1, libgnutls30, libxml2, perl-base, curl.
- **Remaining.**
  - Only Trivy's DLA-4854-1 (tzdata 2026c, fixed in 2026e-0+deb12u1) has a fix; a rebuild picks it up.
  - Largest remaining packages: libheif1, curl/libcurl4, libtiff6, libc6.
- **New in ours: 8, all Trivy, all on nginx 1.25.5-1echo1.**
  - Why: Trivy skips the baseline's nginx.org packages as third-party (`trivy-third-party-check.txt`), but not ours.
  - Grype reports the same 8 on the baseline.
  - Per ID:
    - CVE-2026-15176: our fix; removed by VEX.
    - CVE-2026-93479 and CVE-2023-44487: false positives (`docs/triage.md`); not in VEX (D6).
    - CVE-2026-97205, CVE-2026-97629 and CVE-2026-95101: real for 1.25.5 and not backported, so residual risk.
    - CVE-2009-4487 and CVE-2013-0337: Debian lists them as open with no fix.

## VEX (`vex/echo-nginx.openvex.json`)
- **Statements:** 2, both `fixed`.
  - CVE-2026-15176 on `pkg:deb/debian/nginx@1.25.5-1echo1?arch=amd64&distro=debian-12.15`.
  - CVE-2026-103111 on `pkg:deb/debian/libpcre2-8-0@10.49-0echo1?arch=amd64&distro=debian-12.15`.
- **Purls:** read from `ours-trivy-packages.json`; Grype's nginx purl was checked to be identical.
- **Removed** (`vex-removed-*.txt`, `comm -23` of findings without vs with `--vex`):
  - Trivy 464 -> 463, Grype 445 -> 444.
  - Only `CVE-2026-15176 nginx 1.25.5-1echo1` was removed in both, and nothing was added.
  - Grype lists it under `ignoredMatches` with `vex-status: fixed`.
- **CVE-2026-103111** is not reported on ours even without VEX (10.49 is fixed), so VEX has nothing to remove for it.
