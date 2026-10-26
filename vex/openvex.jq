# OpenVEX template for our 2 fixed CVEs (D6). Used by `make vex`:
#   jq -n --arg nginx <purl> --arg pcre <purl> --arg ts <UTC time> -f vex/openvex.jq
# The purls are read by `make vex` from the scanner JSON, never typed by hand.
{
  "@context": "https://openvex.dev/ns/v0.2.0",
  "@id": "urn:echo-nginx:vex:1.25.5-echo1",
  "author": "Yechezkel Kofman",
  "timestamp": $ts,
  "version": 1,
  "statements": [
    {
      "vulnerability": { "name": "CVE-2026-15176" },
      "products": [ { "@id": $nginx } ],
      "status": "fixed",
      "status_notes": "Backport of upstream nginx commit f8a23425bd6840c4c36b4264edf576ba3646156f (build/patches/CVE-2026-15176.patch); the version string stays 1.25.5. Proven in a running container: docs/evidence/fixes/cve-2026-15176.txt, same result as the fixed upstream nginx 1.31.7: docs/evidence/fixes/cve-2026-15176-upstream.txt. Patched line in our build: docs/evidence/build/patch-fix-line.txt."
    },
    {
      "vulnerability": { "name": "CVE-2026-103111" },
      "products": [ { "@id": $pcre } ],
      "status": "fixed",
      "status_notes": "PCRE2 bumped from 10.42 to upstream 10.49, built from source as libpcre2-8-0 10.49-0echo1. Proven in a running container (dpkg-query, ldd, readlink, /proc/1/maps): docs/evidence/fixes/cve-2026-103111.txt. Build: docs/evidence/build/pcre2-version-check.txt."
    }
  ]
}
