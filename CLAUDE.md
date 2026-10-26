# Echo assignment nginx drop-in replacement

Spec: `docs/assignment.md` (source of truth). This file holds only the working rules.

## Goal
A drop-in replacement for `nginx:1.25-bookworm`, built from source, with 2 CVEs fixed:
one by a version bump, one by backporting an upstream patch. Two fixes proven end to end
beat many partial ones. Only what the spec asks for; no extras unless I approve them.

## How we work
- One phase at a time. At the end of each phase: stop, report, wait for my approval.
- Each phase has its own agent in `.claude/agents/`. Agents share state only through files.
- Every agent writes only to the paths its definition allows.
- Report format: what was done, commands run and their results, files changed, open questions.
- Explain non-obvious choices in plain words. I am learning this, so short comments in code help.
- After 2 failed attempts at the same problem: stop, summarize what you saw, and ask me.

## Phases
Run them in order. A phase is done only when its exit criteria hold; then stop and wait for my approval.

| # | Phase | Agent | Done when |
|---|---|---|---|
| 1 | Baseline | baseline-inspector | `docs/baseline.md` and `rootfs/` written, digest pinned |
| 2 | Scan and triage | cve-triage | baseline scans saved; 2 CVEs (1 bump, 1 backport) approved by me in `docs/triage.md` |
| 3 | Build | builder | `make` builds the .deb files from source, with the patch and the bump applied |
| 4 | Image | image-builder | `Containerfile` image starts; runtime contract matches `docs/baseline.md` |
| 5 | Compatibility | tester | `make test` passes against the baseline |
| 6 | Verify fixes | fix-verifier | each CVE proven fixed in the running container; rescan and VEX saved |
| 7 | Review and README | reviewer | audit against `docs/assignment.md` passes; README complete |

## Facts and proof
- Observe, never assume. Every fact in `docs/` names the command that produced it.
- Work on `linux/amd64` (`--platform linux/amd64`). Pin the baseline by digest.
- A CVE is fixed only when we can show: the vulnerable code is in the baseline, the fix
  addresses it (upstream link), our build contains it, and the running container uses it.
  A green build or a quiet scanner is not proof.

## Decisions
Log every decision I approve in `docs/decisions.md`: `## Dn: title`, then Decision, Why,
Alternatives (one line each).

## Repo hygiene
- Repo lives on the Linux filesystem, never `/mnt/c`. Line endings are LF (`.gitattributes`).
- Set file modes explicitly in builds; never inherit them from the checkout.