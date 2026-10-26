# Runtime contract: echo-nginx:1.25.5-echo1 vs nginx:1.25-bookworm

Observed on 2026-10-26, Docker 27.3.1, linux/amd64. Every fact below names the command that produced it.

- Baseline: `D=nginx@sha256:a484819eb60211f5299034ac80f6a681b06f89e65866ce91f356ed7c72af059c` (docs/baseline.md section 1)
- Ours: `echo-nginx:1.25.5-echo1`, built by `make` (= `make image`, which depends on `make debs`) from `Containerfile`
- Check: `sh test/contract-diff.sh $D echo-nginx:1.25.5-echo1` (exit 0 = only allow-listed differences)

## How the image is built

`Containerfile`, from `debian:bookworm-slim@sha256:7ff6ba31...` (same digest as `build/Dockerfile`):

1. One `apt-get install` of our two local .debs (only the two files are bind-mounted from `build/out/`, D13, so they are not left in a layer)
   plus `ca-certificates curl gettext-base`. These three are exactly the baseline's manually installed
   tools (`apt-mark showmanual` in the baseline lists them and the 5 nginx packages); `openssl` comes as
   a dependency of `ca-certificates`, as in the baseline.
2. The build fails unless `dpkg-query` reports `libpcre2-8-0 10.49-0echo1` and `nginx 1.25.5-1echo1`,
   and unless the `libpcre2-8` file that `ldd /usr/sbin/nginx` resolves belongs to our package (`dpkg -S`).
3. `apt-mark hold libpcre2-8-0 nginx`, the two log symlinks, `rm -rf /var/lib/apt/lists/*`.
4. `/docker-entrypoint.sh` and `/docker-entrypoint.d/` from `rootfs/` with `COPY --chmod=0755 --chown=0:0`.
   Config and html come from our nginx .deb (Phase 3), not copied again.
5. `ENV`, `ENTRYPOINT`, `EXPOSE`, `STOPSIGNAL`, `CMD` as in the baseline; no `USER`, no `WORKDIR`.
6. `LABEL maintainer="Yechezkel Kofman <yechezkelkofman@gmail.com>"`: same key as the baseline, our own value (D10).

Our packages inside the image:

```
$ docker run --rm --platform linux/amd64 --entrypoint sh echo-nginx:1.25.5-echo1 -c '...'
$ dpkg -l | grep -E "nginx|libpcre2"
hi  libpcre2-8-0:amd64  10.49-0echo1   amd64  New Perl Compatible Regular Expression Library- 8 bit runtime files
hi  nginx               1.25.5-1echo1  amd64  high performance web server
$ ldd /usr/sbin/nginx | grep pcre2
	libpcre2-8.so.0 => /lib/x86_64-linux-gnu/libpcre2-8.so.0
$ readlink -f /lib/x86_64-linux-gnu/libpcre2-8.so.0
/usr/lib/x86_64-linux-gnu/libpcre2-8.so.0.16.1
$ dpkg -S /usr/lib/x86_64-linux-gnu/libpcre2-8.so.0.16.1
libpcre2-8-0:amd64: /usr/lib/x86_64-linux-gnu/libpcre2-8.so.0.16.1
$ apt-mark showhold
libpcre2-8-0
nginx
$ ls -A /var/lib/apt/lists
(empty)
```

(`hi` = installed and on hold.)

## What matches

All of these come from `test/contract-diff.sh` (output in the Phase 4 report) unless stated otherwise.

| Item | Value (identical in both) | How checked |
|---|---|---|
| Entrypoint | `["/docker-entrypoint.sh"]` | `docker image inspect --format '{{json .Config.Entrypoint}}'` |
| Cmd | `["nginx","-g","daemon off;"]` | same, `.Config.Cmd` |
| User | `""` (root; workers drop to `nginx` via `nginx.conf`) | same, `.Config.User` |
| WorkingDir | `""` (= `/`) | same, `.Config.WorkingDir` |
| ExposedPorts | `{"80/tcp":{}}` | same, `.Config.ExposedPorts` |
| StopSignal | `"SIGQUIT"` | same, `.Config.StopSignal` |
| Env | `PATH=...`, `NGINX_VERSION=1.25.5`, `NJS_VERSION=0.8.4`, `NJS_RELEASE=3~bookworm`, `PKG_RELEASE=1~bookworm` (same order) | same, `.Config.Env` |
| Files | 34 entries under `/etc/nginx`, `/usr/share/nginx`, `/docker-entrypoint.sh`, `/docker-entrypoint.d`, `/usr/sbin/nginx*`, `/usr/lib/nginx/modules`: same paths, types, modes, owners, symlink targets (incl. `/etc/nginx/modules -> /usr/lib/nginx/modules`, D1) | `find ... -printf "%M %u:%g %y %p %l\n"` with `--entrypoint sh`, then `diff` |
| File contents | the 13 config, html and entrypoint files are byte-identical | `find /etc/nginx /usr/share/nginx /docker-entrypoint.sh /docker-entrypoint.d -type f \| sort \| xargs sha256sum` in both images, `diff` empty (one-off check, not in the script) |
| nginx user | `uid=101(nginx) gid=101(nginx) groups=101(nginx)` | `id nginx` |
| Log symlinks | `access.log -> /dev/stdout`, `error.log -> /dev/stderr`, `lrwxrwxrwx root:root` | `stat -c "%A %U:%G"` + `readlink` |
| Config test | `nginx -t`: syntax is ok, test is successful | `nginx -t` |
| Tools on PATH | `curl`, `envsubst`/`gettext`, `openssl`, `update-ca-certificates`, ... all present | list of every file in each `$PATH` dir, `diff` |
| Entrypoint at start | logs `Enabled listen on IPv6 in /etc/nginx/conf.d/default.conf` | `docker logs` of a running container |
| IPv6 listener | `[::]:80` in LISTEN state | `/proc/net/tcp6`: local `000...000:0050`, state `0A` (no `ss`/`netstat` in either image) |
| HTTP | `GET /` returns 200 | `docker exec <c> curl -s -o /dev/null -w '%{http_code}' http://localhost/` |
| Stop | `docker stop` sends SIGQUIT, nginx logs `signal 3 (SIGQUIT) received`, exit code 0 within ~1 s | `docker stop`, `docker inspect --format '{{.State.ExitCode}}'`, `docker logs` |

Image size (`docker image inspect --format '{{.Size}}'`):

| Image | Bytes | MiB |
|---|---|---|
| baseline | 187,659,947 | 179 |
| ours | 186,465,139 | 178 |
| difference | -1,194,808 (-0.64%) | |

## Intentional differences (allow-listed in the script, printed as INFO)

| Difference | Seen by | Decision |
|---|---|---|
| Packages `nginx-module-geoip`, `nginx-module-image-filter`, `nginx-module-njs`, `nginx-module-xslt` are missing; their 12 `.so` files are in our `nginx` package at the same paths and modes | `dpkg-query -W -f '${Package}\n'` diff | D2 |
| `njs` command (njs CLI) is missing | `$PATH` command diff | D9 |
| `libedit2` is missing (only the njs CLI needs it) | `dpkg-query` diff | D9 |

Other D9 packaging differences (no init scripts, systemd units, `/etc/default`, logrotate, man pages) are
outside the paths the contract compares and do not show up in any check.

## Other intentional differences (not failing; Labels printed as INFO, the rest outside the script's checks)

| Difference | Evidence | Decision |
|---|---|---|
| Label `maintainer` is `Yechezkel Kofman <yechezkelkofman@gmail.com>`; baseline has `NGINX Docker Maintainers <docker-maint@nginx.com>` | `docker image inspect --format '{{json .Config.Labels}}'` | D10: same key, but copying the value would claim NGINX maintains our image |
| 68 Debian packages present in both images have newer versions in ours, e.g. `libssl3`/`openssl` 3.0.11-1~deb12u2 -> 3.0.22-1~deb12u2, `libc6` 2.36-9+deb12u7 -> +deb12u14, `curl` 7.88.1-10+deb12u5 -> +deb12u15, `libxml2` ~deb12u1 -> ~deb12u6 | `dpkg-query -W -f '${Package} ${Version}\n'` in both, `join`, versions unequal: 68 lines | D11: base image pinned by digest, apt packages from current bookworm (the baseline's apt was frozen at the 2024-05-13 snapshot, docs/baseline.md section 2), so rebuilds are not bit-for-bit identical |
| `nginx -V` header: `built by gcc 12.2.0 (Debian 12.2.0-14+deb12u1)`, `built with OpenSSL 3.0.22` (baseline: `12.2.0-14`, `3.0.9`) | `nginx -V 2>&1 \| head -3` | D11 (Phase 3 builds with current bookworm); configure arguments were compared in Phase 3 (`build/verify-debs.sh`) |
| `ENV PKG_RELEASE=1~bookworm` while our package release is `1echo1` | `.Config.Env` vs `dpkg-query -W nginx` | D12: baseline value kept for compatibility |
