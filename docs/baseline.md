# Baseline: nginx:1.25-bookworm (linux/amd64)

Observed on 2026-10-26, Docker 27.3.1. Every fact below names the command that produced it.
Output is trimmed to what matters.

In the commands below, `$D` is the pinned digest from section 1, and
`R="docker run --rm --platform linux/amd64 --entrypoint"` (so the stock entrypoint does not run).

## 1. Image digest

```
$ docker pull --platform linux/amd64 nginx:1.25-bookworm
Digest: sha256:a484819eb60211f5299034ac80f6a681b06f89e65866ce91f356ed7c72af059c
$ docker image inspect --format '{{index .RepoDigests 0}}' nginx:1.25-bookworm
nginx@sha256:a484819eb60211f5299034ac80f6a681b06f89e65866ce91f356ed7c72af059c
$ docker image inspect --format '{{.Os}}/{{.Architecture}}' nginx:1.25-bookworm
linux/amd64
```

From here on: `D=nginx@sha256:a484819eb60211f5299034ac80f6a681b06f89e65866ce91f356ed7c72af059c`

## 2. OS

```
$ $R cat $D /etc/os-release
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
VERSION_ID="12"
VERSION_CODENAME=bookworm
ID=debian
```

Debian apt sources are pinned to a snapshot date (comment lines in the file):

```
$ $R cat $D /etc/apt/sources.list.d/debian.sources
# http://snapshot.debian.org/archive/debian/20240513T000000Z
URIs: http://deb.debian.org/debian
Suites: bookworm bookworm-updates
# http://snapshot.debian.org/archive/debian-security/20240513T000000Z
URIs: http://deb.debian.org/debian-security
Suites: bookworm-security
```

## 3. nginx version

```
$ $R nginx $D -v
nginx version: nginx/1.25.5
```

## 4. Configure arguments

```
$ $R nginx $D -V
nginx version: nginx/1.25.5
built by gcc 12.2.0 (Debian 12.2.0-14)
built with OpenSSL 3.0.9 30 May 2023 (running with OpenSSL 3.0.11 19 Sep 2023)
TLS SNI support enabled
configure arguments:
  --prefix=/etc/nginx
  --sbin-path=/usr/sbin/nginx
  --modules-path=/usr/lib/nginx/modules
  --conf-path=/etc/nginx/nginx.conf
  --error-log-path=/var/log/nginx/error.log
  --http-log-path=/var/log/nginx/access.log
  --pid-path=/var/run/nginx.pid
  --lock-path=/var/run/nginx.lock
  --http-client-body-temp-path=/var/cache/nginx/client_temp
  --http-proxy-temp-path=/var/cache/nginx/proxy_temp
  --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp
  --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp
  --http-scgi-temp-path=/var/cache/nginx/scgi_temp
  --user=nginx
  --group=nginx
  --with-compat
  --with-file-aio
  --with-threads
  --with-http_addition_module
  --with-http_auth_request_module
  --with-http_dav_module
  --with-http_flv_module
  --with-http_gunzip_module
  --with-http_gzip_static_module
  --with-http_mp4_module
  --with-http_random_index_module
  --with-http_realip_module
  --with-http_secure_link_module
  --with-http_slice_module
  --with-http_ssl_module
  --with-http_stub_status_module
  --with-http_sub_module
  --with-http_v2_module
  --with-http_v3_module
  --with-mail
  --with-mail_ssl_module
  --with-stream
  --with-stream_realip_module
  --with-stream_ssl_module
  --with-stream_ssl_preread_module
  --with-cc-opt='-g -O2 -ffile-prefix-map=/data/builder/debuild/nginx-1.25.5/debian/debuild-base/nginx-1.25.5=. -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -fPIC'
  --with-ld-opt='-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie'
```

(The single `configure arguments:` line was split one argument per line by hand; content unchanged.)

Note: the binary was built against OpenSSL 3.0.9 but runs with the system OpenSSL 3.0.11.

## 5. nginx packages and their source

```
$ $R sh $D -c 'dpkg -l | grep nginx'
ii  nginx                     1.25.5-1~bookworm        amd64  high performance web server
ii  nginx-module-geoip        1.25.5-1~bookworm        amd64  nginx GeoIP dynamic modules
ii  nginx-module-image-filter 1.25.5-1~bookworm        amd64  nginx image filter dynamic module
ii  nginx-module-njs          1.25.5+0.8.4-3~bookworm  amd64  nginx njs dynamic modules
ii  nginx-module-xslt         1.25.5-1~bookworm        amd64  nginx xslt dynamic module

$ $R sh $D -c 'apt-cache policy nginx'
nginx:
  Installed: 1.25.5-1~bookworm
  Candidate: 1.25.5-1~bookworm
  Version table:
 *** 1.25.5-1~bookworm 100
        100 /var/lib/dpkg/status

$ $R sh $D -c 'dpkg-query -W -f "${Package} ${Maintainer}\n" nginx'
nginx NGINX Packaging <nginx-packaging@f5.com>
```

`apt-cache policy` shows only `/var/lib/dpkg/status`: the package repo is no longer configured
in the image. The image build history shows where it came from and that the repo was removed:

```
$ docker history --no-trunc --format '{{.CreatedBy}}' $D   (filtered)
echo "deb [signed-by=$NGINX_GPGKEY_PATH] https://nginx.org/packages/mainline/debian/ bookworm nginx" >> /etc/apt/sources.list.d/nginx.list
...
rm -rf /var/lib/apt/lists/* /etc/apt/sources.list.d/nginx.list
```

So: the packages are the nginx.org mainline packages (maintainer NGINX Packaging, F5), not
Debian's own `nginx` package.

## 6. Binaries and modules

```
$ $R sh $D -c 'ls -l /usr/sbin/nginx* /usr/lib/nginx/modules/'
-rwxr-xr-x 1 root root 1545744 Apr 16  2024 /usr/sbin/nginx
-rwxr-xr-x 1 root root 1729136 Apr 16  2024 /usr/sbin/nginx-debug

/usr/lib/nginx/modules/:
-rw-r--r-- 1 root root   20232 Apr 16  2024 ngx_http_geoip_module-debug.so
-rw-r--r-- 1 root root   20232 Apr 16  2024 ngx_http_geoip_module.so
-rw-r--r-- 1 root root   27568 Apr 16  2024 ngx_http_image_filter_module-debug.so
-rw-r--r-- 1 root root   27568 Apr 16  2024 ngx_http_image_filter_module.so
-rw-r--r-- 1 root root 1006280 May  1  2024 ngx_http_js_module-debug.so
-rw-r--r-- 1 root root 1002184 May  1  2024 ngx_http_js_module.so
-rw-r--r-- 1 root root   23400 Apr 16  2024 ngx_http_xslt_filter_module-debug.so
-rw-r--r-- 1 root root   23400 Apr 16  2024 ngx_http_xslt_filter_module.so
-rw-r--r-- 1 root root   19864 Apr 16  2024 ngx_stream_geoip_module-debug.so
-rw-r--r-- 1 root root   19864 Apr 16  2024 ngx_stream_geoip_module.so
-rw-r--r-- 1 root root  984360 May  1  2024 ngx_stream_js_module-debug.so
-rw-r--r-- 1 root root  980264 May  1  2024 ngx_stream_js_module.so
```

Six dynamic modules (geoip http/stream, image_filter, js http/stream, xslt), each with a `-debug` twin.
`/etc/nginx/modules` is a symlink to `/usr/lib/nginx/modules` (`ls -la /etc/nginx`).
The default config does not load any of them:

```
$ grep -rn load_module rootfs/etc/
(no output)
```

## 7. Image config

```
$ docker image inspect $D --format '...'
Entrypoint=["/docker-entrypoint.sh"]
Cmd=["nginx","-g","daemon off;"]
User=""
WorkingDir=""
ExposedPorts={"80/tcp":{}}
StopSignal="SIGQUIT"
Env=["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
     "NGINX_VERSION=1.25.5","NJS_VERSION=0.8.4","NJS_RELEASE=3~bookworm","PKG_RELEASE=1~bookworm"]
```

`User=""` means the container starts as root; the master process then drops workers to
`nginx` via `user  nginx;` in `/etc/nginx/nginx.conf` (line 2, `grep -n '^user' rootfs/etc/nginx/nginx.conf`).
`WorkingDir=""` means the working directory is `/`.

## 8. nginx user and group

```
$ $R id $D nginx
uid=101(nginx) gid=101(nginx) groups=101(nginx)
```

## 9. Log files

```
$ $R ls $D -l /var/log/nginx/
lrwxrwxrwx 1 root root 11 May 14  2024 access.log -> /dev/stdout
lrwxrwxrwx 1 root root 11 May 14  2024 error.log -> /dev/stderr
```

Related directory:

```
$ $R sh $D -c 'ls -ld /var/cache/nginx'
drwxr-xr-x 2 root root 4096 Apr 16  2024 /var/cache/nginx
```

## 10. Image size

```
$ docker image inspect --format '{{.Size}}' $D
187659947
```

187,659,947 bytes (about 179 MiB) uncompressed, as reported by the local Docker 27.3.1 store.

## 11. Runtime contract copied to rootfs/

```
$ C=$(docker create --platform linux/amd64 $D)
$ docker cp $C:/etc/nginx            rootfs/etc/
$ docker cp $C:/usr/share/nginx      rootfs/usr/share/
$ docker cp $C:/docker-entrypoint.sh rootfs/
$ docker cp $C:/docker-entrypoint.d  rootfs/
$ docker rm $C
```

Copied: 13 regular files (5 shell scripts, 6 config files, 2 HTML pages) and one symlink
(`/etc/nginx/modules -> /usr/lib/nginx/modules`). The symlink was then removed from `rootfs/`
(it dangles on the host); the build creates it instead (D1 in `docs/decisions.md`).
`find rootfs -type f -exec file {} +` shows only "ASCII text", "POSIX shell script" and
"HTML document"; `find rootfs -name '*.so'` finds nothing.

Modes in the image (`ls -la` inside the image): all owned root:root; scripts 0755, other files
0644, directories 0755. The Containerfile must set these explicitly.

Integrity: `sha256sum` of the host copies equals `sha256sum` run inside the image on the same
paths (`diff` of both lists was empty). Digest and hashes are in `rootfs/PROVENANCE.txt`.

Entrypoint scripts in the image:

```
$ $R sh $D -c 'ls -l /docker-entrypoint.d'
-rwxr-xr-x 1 root root 2125 10-listen-on-ipv6-by-default.sh
-rwxr-xr-x 1 root root  336 15-local-resolvers.envsh
-rwxr-xr-x 1 root root 3018 20-envsubst-on-templates.sh
-rwxr-xr-x 1 root root 4619 30-tune-worker-processes.sh
```
