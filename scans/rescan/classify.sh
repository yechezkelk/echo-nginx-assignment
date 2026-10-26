#!/bin/sh
# Put every vulnerability-ID change between the baseline and our image into one bucket, per scanner.
# Usage: sh scans/rescan/classify.sh [dir]   (dir defaults to scans/rescan; run by `make scan`)
# Inputs (written by `make scan`): {baseline,ours}-{trivy,grype}.json, packages-{baseline,ours}.txt.
# Outputs per scanner S:
#   findings-{baseline,ours}-S.tsv  one line per finding: id  package  installed  fixed-in  severity  (jq)
#   gone-S.tsv       IDs only on the baseline: id  bucket  reason  baseline-packages
#   new-S.tsv        IDs only on ours:         id  package  installed  fixed-in  severity
#   remaining-S.tsv  IDs on ours:              id  fix-available(yes/no)  packages
# Buckets for gone IDs:
#   intentional  our 2 CVEs (D3)
#   incidental   pcre2-bump (only libpcre2-8-0 was affected), newer-bookworm (D11: same package, newer
#                version in ours), not-installed (package not in our image: D2 module packages, D9 libedit2)
#   other        anything else (e.g. same package version); printed, never hidden
set -eu
D=${1:-scans/rescan}
OURS_CVES="CVE-2026-15176 CVE-2026-103111"

for i in baseline ours; do
    jq -r '.Results[].Vulnerabilities[]? | [.VulnerabilityID, .PkgName, .InstalledVersion, (.FixedVersion // ""), .Severity] | @tsv' \
        "$D/$i-trivy.json" | sort -u > "$D/findings-$i-trivy.tsv"
    jq -r '.matches[] | [.vulnerability.id, .artifact.name, .artifact.version, (.vulnerability.fix.versions | join(",")), .vulnerability.severity] | @tsv' \
        "$D/$i-grype.json" | sort -u > "$D/findings-$i-grype.tsv"
done

for s in trivy grype; do
    # gone: in baseline, not in ours. awk reads: the ours package list, the ours IDs, then baseline findings.
    awk -F'\t' -v ours_cves="$OURS_CVES" '
        FILENAME ~ /packages-ours/ { if ($0 !~ /^#/) { split($0, a, " "); ver[a[1]] = a[2] }; next }
        FILENAME ~ /findings-ours/ { inours[$1] = 1; next }
        {
            if ($1 in inours) next
            id = $1; pkg = $2
            if (index(" " ours_cves " ", " " id " ")) r = "intentional"
            else if (pkg == "libpcre2-8-0") r = "pcre2-bump"
            else if (!(pkg in ver)) r = "not-installed"
            else if (ver[pkg] != $3) r = "newer-bookworm"
            else r = "other"
            if (index(" " reasons[id] " ", " " r " ") == 0) reasons[id] = (reasons[id] == "" ? r : reasons[id] " " r)
            p = pkg "@" $3
            if (index(" " pkgs[id] " ", " " p " ") == 0) pkgs[id] = (pkgs[id] == "" ? p : pkgs[id] " " p)
        }
        END {
            for (id in reasons) {
                b = (reasons[id] == "intentional") ? "intentional" : (reasons[id] ~ /other/ ? "other" : "incidental")
                print id "\t" b "\t" reasons[id] "\t" pkgs[id]
            }
        }' "$D/packages-ours.txt" "$D/findings-ours-$s.tsv" "$D/findings-baseline-$s.tsv" | sort > "$D/gone-$s.tsv"

    # new: in ours, not in baseline.
    awk -F'\t' 'NR == FNR { inbase[$1] = 1; next } !($1 in inbase)' \
        "$D/findings-baseline-$s.tsv" "$D/findings-ours-$s.tsv" > "$D/new-$s.tsv"

    # remaining: every ID still on ours; "yes" if any of its findings names a fixed version.
    awk -F'\t' '{ if ($4 != "") fix[$1] = 1; else if (!($1 in fix)) fix[$1] = 0
                  p = $2 "@" $3; if (index(" " pk[$1] " ", " " p " ") == 0) pk[$1] = (pk[$1] == "" ? p : pk[$1] " " p) }
        END { for (id in fix) print id "\t" (fix[id] ? "yes" : "no") "\t" pk[id] }' \
        "$D/findings-ours-$s.tsv" | sort > "$D/remaining-$s.tsv"
done
chmod 0644 "$D"/*.tsv

# Short count table (also pasted into summary.md).
for s in trivy grype; do
    echo "== $s"
    echo "unique IDs: baseline $(cut -f1 "$D/findings-baseline-$s.tsv" | sort -u | wc -l), ours $(cut -f1 "$D/findings-ours-$s.tsv" | sort -u | wc -l)"
    echo "gone, by bucket:";  cut -f2 "$D/gone-$s.tsv" | sort | uniq -c
    echo "gone, by reason:";  cut -f3 "$D/gone-$s.tsv" | sort | uniq -c
    echo "new in ours: $(cut -f1 "$D/new-$s.tsv" | sort -u | wc -l) IDs"
    echo "remaining: $(wc -l < "$D/remaining-$s.tsv") IDs, fix available: $(awk -F'\t' '$2 == "yes"' "$D/remaining-$s.tsv" | wc -l), no fix: $(awk -F'\t' '$2 == "no"' "$D/remaining-$s.tsv" | wc -l)"
done
