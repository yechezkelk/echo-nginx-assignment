# Decisions

## D1: Create the /etc/nginx/modules symlink in the build, not in git
Decision: `rootfs/` keeps only regular files; the build creates `/etc/nginx/modules -> /usr/lib/nginx/modules`.
Why: the link dangles on the host (its target holds binaries we build), and git symlinks break on some checkouts.
Alternatives: commit the symlink in `rootfs/` (rejected: dangling, checkout-dependent).

## D2: Full drop-in scope, one nginx package
Decision: ship the baseline's full file set: `nginx`, `nginx-debug`, all 6 dynamic modules and their 6 `-debug.so` copies.
Both binaries (and their modules) come from one configure script and the same patches; they differ only by `--with-debug`.
File modes match the baseline: binaries 0755, module `.so` files 0644.
The baseline's 4 module packages (geoip, image-filter, njs, xslt) become part of our single nginx package: an intentional difference.
Why: a drop-in must not drop files users may rely on; one shared configure keeps the two builds from drifting apart.
Alternatives: nginx binary only (rejected: not a full drop-in); separate module packages (rejected: more packaging, no runtime gain).

## D3: Fix pair: CVE-2026-15176 by backport, CVE-2026-103111 by bump
Decision: backport upstream nginx commit f8a2342 (alias + rewrite check) to 1.25.5; bump PCRE2 from 10.42 to 10.49, built from upstream source.
Why: both are present and loaded in the baseline, have a small verifiable upstream fix, and keep the ABI (soname `libpcre2-8.so.0`); see `docs/triage.md`.
Alternatives: CVE-2024-7347 mp4 backport (not seen by scanners); OpenSSL bump (needs 3.5, large change); CVE-2026-97629 backport (hard to prove).

## D4: Ship PCRE2 10.49 as a replacement libpcre2-8-0 .deb
Decision: build a `libpcre2-8-0` 10.49 .deb so dpkg and the scanners see the new version; Phase 3 must make sure our package is the one installed, not Debian's.
Why: the bump must stay visible to dpkg and scanners. Debian already fixed this CVE in `10.42-1+deb12u2` (DLA-4816-1), so the README must say `apt` would also clear it.
Alternatives: link PCRE2 statically with `--with-pcre=` (rejected: hides it from dpkg and scanners); take Debian's 10.42-1+deb12u2 (rejected: not our bump).

## D5: Regression test for CVE-2026-15176 uses the upstream commit-message config
Decision: test with the config from commit f8a2342's message and a plain `GET /foo/1`; fixed = status 200, empty body and the `[alert] "alias" cannot be used in location "/foo/" where URI was rewritten` log line; vulnerable (baseline) = 200, body `/x`, no alert.
Why: the fixed upstream nginx 1.31.7 (pinned `nginx@sha256:37c8e9baaff4b18b238c6da45db97b0f944d92ec815f714b5aa83cfd9d97b09b`) answers exactly like ours (docs/evidence/fixes/cve-2026-15176-upstream.txt); the earlier "expect 500" was an unobserved guess, while `return 200` keeps its status when the mapping is refused.
Alternatives: require a 5xx (rejected: upstream's fixed release returns 200); write our own config (rejected: not upstream).

## D6: VEX covers only our 2 fixed CVEs
Decision: the VEX file lists only CVE-2026-15176 and CVE-2026-103111 as fixed.
Why: the spec asks for VEX on our fixes; marking scanner false positives would be an extra.
Alternatives: also mark Grype false positives CVE-2026-93479 and CVE-2023-44487 `not_affected` (rejected: beyond spec).
Updated in phase 7: CVE-2023-44487 is now 'likely mitigated in 1.25.3, not verified', not a false positive (see triage section 1).

## D7: Commit full scan JSON as evidence
Decision: every phase commits the scanners' full JSON output in `scans/`, next to the text tables.
Why: the JSON is the evidence; anyone can recount the numbers in `docs/` with `jq`.
Alternatives: commit only text tables and a summary (rejected: the counts could not be rechecked).

## D8: njs 0.8.4 source from the GitHub tag archive
Decision: build njs from the GitHub archive of tag 0.8.4 (commit 3fb0ee5e907c), pinned by sha256 in `build/checksums.sha256`; it is unsigned, so no signature check.
Why: nginx.org publishes no njs tarball (`curl -sSI https://nginx.org/download/njs-0.8.4.tar.gz` returns 404); its install page points to github.com/nginx/njs.
Alternatives: drop the njs modules (rejected: breaks drop-in, D2); git clone the tag (rejected: same trust, harder to pin by hash).

## D9: Packaging scope of our nginx .deb
Decision: leave out init scripts, systemd units, `/etc/default`, logrotate, man pages, the njs CLI and the Provides/Conflicts/Replaces fields; create user nginx (101:101) in `postinst`, not `preinst`; add `/var/cache/nginx`, `/var/log/nginx` and copyright files. These are intentional differences from the baseline.
Why: the left-out files do nothing in a container; `nginx -t` needs the two dirs; the BSD licences require the copyright files.
Alternatives: copy the baseline's full packaging (rejected: extras beyond spec with no runtime effect).

## D10: Image label names us as maintainer
Decision: set the `maintainer` label (same key as the baseline) to `Yechezkel Kofman <yechezkelkofman@gmail.com>`.
Why: copying the baseline value would claim NGINX maintains our image; keeping the key keeps tools that read it working.
Alternatives: copy the baseline label (rejected: false claim); no label (rejected: drops a key the baseline has).

## D11: apt packages come from current bookworm, not a snapshot
Decision: the base image is pinned by digest, but `apt-get install` takes current bookworm packages, so rebuilds are not bit-for-bit identical; 68 shared packages are newer than in the baseline.
Why: current bookworm carries the latest security fixes (e.g. OpenSSL 3.0.22 vs 3.0.11); the baseline's 2024-05-13 snapshot would bring back older, vulnerable libraries.
Alternatives: pin apt to the baseline's 2024-05-13 snapshot (rejected: older libraries); pin to a newer snapshot date (rejected: extra beyond spec).

## D12: Keep ENV PKG_RELEASE=1~bookworm
Decision: keep the baseline value `PKG_RELEASE=1~bookworm`, although our nginx package release is `1echo1`; documented as an intentional difference.
Why: drop-in compatibility; scripts that read the variable see the same value as in the baseline.
Alternatives: set `PKG_RELEASE=1echo1` (rejected: changes the env contract).

## D13: Bind-mount only the two .deb files in the Containerfile
Decision: the install step mounts `build/out/libpcre2-8-0_10.49-0echo1_amd64.deb` and `build/out/nginx_1.25.5-1echo1_amd64.deb`, not all of `build/out/`.
Why: changes to other files (e.g. build evidence) no longer invalidate the cache and re-run `apt-get update`.
Alternatives: mount all of `build/out/` (rejected: needless rebuilds).

## D14: Build evidence is tracked in docs/evidence/build/
Decision: `make debs` and `make verify-debs` write their evidence to the tracked `docs/evidence/build/`; the .deb files stay in git-ignored `build/out/`, and `make clean` deletes only the .debs. Update: `make debs` deletes all old evidence, including `verify-debs.txt`, and the default `make` runs `debs`, `verify-debs`, `image` in that order, so `verify-debs.txt` always matches the current .debs.
Why: `build/out/` is git-ignored, so the Phase 3 evidence never reached git and the README had nothing to link to; a kept `verify-debs.txt` could describe older .debs and be committed stale.
Alternatives: un-ignore `build/out/evidence/` (rejected: evidence mixed with build outputs that `make` deletes); commit the .debs too (rejected: large binaries in git); keep `verify-debs.txt` across `make debs` (rejected: could go stale).

## D15: `nginx -V` configure arguments differ from the baseline in two ways
Decision: accept two intentional differences in `nginx -V` (seen with `docker run --rm <image> nginx -V` on both images, then `diff`): the `-ffile-prefix-map=` build path is `/work/nginx-1.25.5` (baseline: `/data/builder/debuild/nginx-1.25.5/debian/debuild-base/nginx-1.25.5`), and ours lists 5 extra arguments: `--with-http_xslt_module=dynamic`, `--with-http_image_filter_module=dynamic`, `--with-http_geoip_module=dynamic`, `--with-stream_geoip_module=dynamic`, `--add-dynamic-module=/work/njs-0.8.4/nginx`.
Why: the build path is only where the source sat during the build and has no runtime effect; the 5 module arguments appear because we build the 6 dynamic modules in the same configure run as nginx (D2), while upstream builds them in separate module packages.
Alternatives: copy the baseline build path (rejected: fakes a path we did not use); build the modules in a separate configure run to hide the arguments (rejected: breaks D2's single shared configure).

## D16: `make test` rewrites tracked evidence, by design
Decision: `make test` keeps writing its fix-check output to the tracked `docs/evidence/fixes/`, so each run leaves new timestamps and ports there; the README says so.
Why: the committed evidence is always the output of a real run, and the README links to it.
Alternatives: write to an untracked directory by default (rejected: the linked evidence would no longer come from `make test`).

## D17: The nginx 1.31.7 comparison stays a manual check
Decision: the comparison with the fixed upstream nginx 1.31.7 (`docs/evidence/fixes/cve-2026-15176-upstream.txt`, D5) stays a one-off manual run, not scripted in `test/` or the Makefile; the README says so.
Why: the spec does not ask for it; it only confirmed D5's expected result once.
Alternatives: add a third-image option to `test/fix-checks.sh` or a `make upstream-check` target (rejected: extra beyond spec).
