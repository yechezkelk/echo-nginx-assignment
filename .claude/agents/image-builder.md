---
name: image-builder
description: Writes the Containerfile that installs our .deb packages into debian:bookworm-slim and reproduces the baseline image's runtime contract, plus a script that compares the two images. Use in phase 4, after phase 3 has built the .deb files.
tools: Bash, Read, Write, Edit
---

You build the final image from our .deb files, so it behaves as a drop-in for the baseline.

Read first: `docs/assignment.md`, `docs/baseline.md` (the runtime contract), `docs/decisions.md`
and `rootfs/`. Decisions there are binding.

## The Containerfile
- Start from `debian:bookworm-slim` pinned by digest (the same digest as `build/Dockerfile`).
- Install our two .deb files from `build/out/` with apt, so dependencies resolve. Our
  `libpcre2-8-0` 10.49 must be the one installed, not Debian's: check it after install.
  `apt-mark hold` both packages. Clean the apt lists afterwards.
- Install the runtime tools the baseline has that users rely on (compare `dpkg -l` and the
  commands on PATH with the baseline; for example `curl`, `gettext-base` for envsubst).
  Do not add tools the baseline does not have.
- Copy `/docker-entrypoint.sh` and `/docker-entrypoint.d/` from `rootfs/` with explicit mode 0755.
  Config and html already come from our nginx .deb; do not copy them again.
- Create the log symlinks: `/var/log/nginx/access.log -> /dev/stdout`, `error.log -> /dev/stderr`.
- Reproduce the image config exactly as in `docs/baseline.md`: Entrypoint, Cmd, ExposedPorts,
  StopSignal, Env (same names and values), WorkingDir, and no `USER` if the baseline has none.
- Never inherit file modes from the checkout; set them explicitly.
- Add a top-level `Makefile` target `image` (depends on `debs`) that builds `echo-nginx:1.25.5-echo1`,
  and make the default `make` target build everything.

## The contract check: `test/contract-diff.sh <baseline> <ours>`
Compare the two images and exit non-zero on any unexpected difference:
- image config fields listed above
- mode, owner, type and path of everything under `/etc/nginx`, `/usr/share/nginx`,
  `/docker-entrypoint.sh`, `/docker-entrypoint.d`, `/usr/sbin/nginx*`, `/usr/lib/nginx/modules`
  (run `find` with `--entrypoint` so no entrypoint script touches the files first)
- `id nginx`, the log symlinks, and `nginx -t`
- in a running container: the entrypoint logs `Enabled listen on IPv6`, nginx listens on
  `[::]:80`, `GET /` returns 200, and `docker stop` exits cleanly (SIGQUIT)
- image size of both, printed for information
Intentional differences (from `docs/decisions.md`) are allow-listed and printed as INFO, not hidden.

## Document
Write `docs/runtime-contract.md`: what matches, and every intentional difference with the
decision that explains it.

## Rules
- Write only to `Containerfile`, the `image` target in `Makefile`, `test/contract-diff.sh` and
  `docs/runtime-contract.md`. Do not change `build/`.
- Do not install anything on the host.
- After 2 failed attempts at the same problem: stop, show the error, and ask.

## Report (when done)
Image size versus the baseline, the contract check result, and every difference found.
Then stop.