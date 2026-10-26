# One command builds everything:  make   (the .deb files, their checks, then the image)
# The .deb files land in build/out/ (ignored by git); the Containerfile mounts them from there.
# The build evidence lands in docs/evidence/build/ (tracked by git), so it can be committed.

PLATFORM := linux/amd64
OUT      := build/out
EVIDENCE := docs/evidence/build
# Temporary export dir (inside build/out/, so it is git-ignored too).
EXPORT   := $(OUT)/.export
IMAGE    := echo-nginx:1.25.5-echo1

.PHONY: all debs verify-debs image clean
# Run targets one at a time, in the order listed, even with `make -j`.
.NOTPARALLEL:

# verify-debs runs right after debs, so verify-debs.txt always describes the current .debs (D14).
all: debs verify-debs image

# Build both .deb files inside Docker (build/Dockerfile) and copy the results out.
# --target out picks the last, scratch stage, which holds only the .debs and evidence;
# --output type=local writes that stage's files to a temp dir instead of making an image.
# Only after the build succeeded do we move the results into place:
#   - the old .debs are replaced by the new ones in build/out/,
#   - in docs/evidence/build/ every file is deleted (also the old verify-debs.txt, so a stale one
#     can never be committed) and the new build's evidence moved in. Run `make verify-debs` next;
#     plain `make` does that for you.
# A failed build therefore leaves the previous .debs and evidence untouched.
# Modes are set explicitly (files 0644, dir 0755), not taken from the docker export.
debs:
	rm -rf $(EXPORT)
	docker build --platform $(PLATFORM) -f build/Dockerfile --target out \
		--output type=local,dest=$(EXPORT) .
	rm -f $(OUT)/*.deb
	mv $(EXPORT)/*.deb $(OUT)/
	mkdir -p $(EVIDENCE)
	find $(EVIDENCE) -maxdepth 1 -type f -delete
	mv $(EXPORT)/evidence/* $(EVIDENCE)/
	chmod 0755 $(EVIDENCE)
	chmod 0644 $(EVIDENCE)/*
	rm -rf $(EXPORT)
	ls -l $(OUT)/*.deb

# Install both .debs in a fresh debian:bookworm-slim container and run the phase 3 checks.
# Writes verify-debs.txt and baseline-configure-args.txt to docs/evidence/build/.
verify-debs:
	sh build/verify-debs.sh $(OUT) $(EVIDENCE)

# Install the two .debs into debian:bookworm-slim (Containerfile) and tag the image.
# Compare it with the baseline:  sh test/contract-diff.sh <baseline> $(IMAGE)
image: debs
	docker build --platform $(PLATFORM) -f Containerfile -t $(IMAGE) .

# Deletes only the build outputs (.debs, temp export dir); the tracked evidence stays.
clean:
	rm -rf $(EXPORT)
	rm -f $(OUT)/*.deb

# Phase 5: compare our image with the pinned baseline (docs/baseline.md section 1).
# Runs test/contract-diff.sh (runtime contract), then test/compat_test.py (HTTP behaviour).
# Does not build anything: if our image is missing it stops, so `make test` never rebuilds the .debs.
# The baseline is pulled by digest if it is not present (same bytes every time).
BASELINE := nginx@sha256:a484819eb60211f5299034ac80f6a681b06f89e65866ce91f356ed7c72af059c

.PHONY: test
test:
	@docker image inspect $(IMAGE) >/dev/null 2>&1 || { \
		echo "ERROR: image $(IMAGE) not found. Build it first with 'make' (builds the .debs and the image)." >&2; \
		exit 1; }
	@docker image inspect $(BASELINE) >/dev/null 2>&1 || docker pull --platform $(PLATFORM) $(BASELINE)
	sh test/contract-diff.sh $(BASELINE) $(IMAGE)
	python3 test/compat_test.py --baseline $(BASELINE) --ours $(IMAGE)
	# Phase 6: prove both CVE fixes in running containers; writes docs/evidence/fixes/.
	sh test/fix-checks.sh $(BASELINE) $(IMAGE)

# Phase 6: rescan the baseline (by digest) and our image in ONE run, same scanners, same DB.
# DB auto-update is switched off for this run (trivy --skip-db-update, GRYPE_DB_AUTO_UPDATE=false),
# so both images are matched against exactly the same DB; versions and DB dates go to scanner-info.txt.
# The phase 2 scans in scans/ are not touched. Then scans/rescan/ids-*.txt hold the sorted unique
# vulnerability IDs per image and scanner (jq), and diff-*.txt the per-scanner difference.
RESCAN := scans/rescan
SCAN_TRIVY := trivy image --platform $(PLATFORM) --skip-db-update --scanners vuln
SCAN_GRYPE := GRYPE_DB_AUTO_UPDATE=false grype --platform $(PLATFORM)

.PHONY: scan vex
scan:
	@docker image inspect $(IMAGE) >/dev/null 2>&1 || { echo "ERROR: build $(IMAGE) first with 'make'" >&2; exit 1; }
	@docker image inspect $(BASELINE) >/dev/null 2>&1 || docker pull --platform $(PLATFORM) $(BASELINE)
	mkdir -p $(RESCAN)
	{ echo '$$ trivy --version'; trivy --version; echo; echo '$$ grype version'; grype version; \
	  echo; echo '$$ grype db status'; grype db status; } > $(RESCAN)/scanner-info.txt
	$(SCAN_TRIVY) --format table -o $(RESCAN)/baseline-trivy.txt  $(BASELINE)
	$(SCAN_TRIVY) --format json  -o $(RESCAN)/baseline-trivy.json $(BASELINE)
	$(SCAN_TRIVY) --format table -o $(RESCAN)/ours-trivy.txt      $(IMAGE)
	$(SCAN_TRIVY) --format json  -o $(RESCAN)/ours-trivy.json     $(IMAGE)
	$(SCAN_GRYPE) -o table --file $(RESCAN)/baseline-grype.txt    $(BASELINE)
	$(SCAN_GRYPE) -o json  --file $(RESCAN)/baseline-grype.json   $(BASELINE)
	$(SCAN_GRYPE) -o table --file $(RESCAN)/ours-grype.txt        $(IMAGE)
	$(SCAN_GRYPE) -o json  --file $(RESCAN)/ours-grype.json       $(IMAGE)
	# Unique vulnerability IDs per image and scanner.
	for i in baseline ours; do \
	  jq -r '[.Results[].Vulnerabilities[]?.VulnerabilityID] | unique[]' $(RESCAN)/$$i-trivy.json > $(RESCAN)/ids-$$i-trivy.txt; \
	  jq -r '[.matches[].vulnerability.id] | unique[]' $(RESCAN)/$$i-grype.json > $(RESCAN)/ids-$$i-grype.txt; \
	done
	# "< ID" = only on the baseline (gone in ours), "> ID" = only on ours (new in ours).
	for s in trivy grype; do \
	  diff $(RESCAN)/ids-baseline-$$s.txt $(RESCAN)/ids-ours-$$s.txt | grep '^[<>]' > $(RESCAN)/diff-$$s.txt || true; \
	done
	{ echo; echo '# DB metadata as written into the JSON reports:'; \
	  for f in $(RESCAN)/*-trivy.json; do echo "$$f"; jq -c '{CreatedAt, ArtifactName, ImageID: .Metadata.ImageID, OS: .Metadata.OS}' $$f; done; \
	  for f in $(RESCAN)/*-grype.json; do echo "$$f"; jq -c '{v: .descriptor.version, built: .descriptor.db.status.built, from: .descriptor.db.status.from, image: .source.target.userInput}' $$f; done; \
	} >> $(RESCAN)/scanner-info.txt
	# Installed packages of both images (to tell "newer version" from "not installed").
	for p in "baseline $(BASELINE)" "ours $(IMAGE)"; do set -- $$p; \
	  { printf '# $$ docker run --rm --platform %s --entrypoint dpkg-query %s -W -f='"'"'$${Package} $${Version}\\n'"'"'\n' $(PLATFORM) $$2; \
	    docker run --rm --platform $(PLATFORM) --entrypoint dpkg-query $$2 -W -f='$${Package} $${Version}\n' | sort; } > $(RESCAN)/packages-$$1.txt; \
	done
	chmod 0644 $(RESCAN)/*.txt $(RESCAN)/*.json
	# Bucket every change (intentional / incidental / new in ours / remaining); counts to counts.txt.
	sh $(RESCAN)/classify.sh $(RESCAN) > $(RESCAN)/counts.txt
	cat $(RESCAN)/counts.txt

# Phase 6: OpenVEX for our 2 fixed CVEs (D6), then rescan our image with and without it.
# 1. Runs the fix checks first: no VEX unless both fixes are proven in running containers.
# 2. Reads the product purls from Trivy's package list of our image (never typed by hand), and checks
#    that grype reports the same nginx purl. Scanners match these package purls, since our image has
#    no registry digest.
# 3. Writes vex/echo-nginx.openvex.json, scans our image with --vex (same DB as `make scan`), and
#    writes the IDs the VEX removed to scans/rescan/vex-removed-{trivy,grype}.txt.
VEXDOC := vex/echo-nginx.openvex.json

vex:
	@test -f $(RESCAN)/ours-grype.json || { echo "ERROR: run 'make scan' first" >&2; exit 1; }
	sh test/fix-checks.sh $(BASELINE) $(IMAGE)
	$(SCAN_TRIVY) --list-all-pkgs --format json -o $(RESCAN)/ours-trivy-packages.json $(IMAGE)
	nginx_purl=$$(jq -r '.Results[].Packages[] | select(.Name == "nginx") | .Identifier.PURL' $(RESCAN)/ours-trivy-packages.json); \
	pcre_purl=$$(jq -r '.Results[].Packages[] | select(.Name == "libpcre2-8-0") | .Identifier.PURL' $(RESCAN)/ours-trivy-packages.json); \
	grype_nginx=$$(jq -r '[.matches[] | select(.artifact.name == "nginx") | .artifact.purl] | unique[]' $(RESCAN)/ours-grype.json); \
	echo "nginx purl: $$nginx_purl (grype: $$grype_nginx)"; echo "pcre2 purl: $$pcre_purl"; \
	case "$$nginx_purl" in pkg:deb/debian/nginx@1.25.5-1echo1\?*) ;; *) echo "ERROR: unexpected nginx purl" >&2; exit 1;; esac; \
	case "$$pcre_purl" in pkg:deb/debian/libpcre2-8-0@10.49-0echo1\?*) ;; *) echo "ERROR: unexpected pcre2 purl" >&2; exit 1;; esac; \
	[ "$$nginx_purl" = "$$grype_nginx" ] || { echo "ERROR: trivy and grype report different nginx purls" >&2; exit 1; }; \
	mkdir -p vex; \
	jq -n --arg nginx "$$nginx_purl" --arg pcre "$$pcre_purl" --arg ts "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	    -f vex/openvex.jq > $(VEXDOC)
	chmod 0755 vex; chmod 0644 vex/*
	$(SCAN_TRIVY) --vex $(VEXDOC) --format json  -o $(RESCAN)/ours-trivy-vex.json $(IMAGE)
	$(SCAN_TRIVY) --vex $(VEXDOC) --format table -o $(RESCAN)/ours-trivy-vex.txt  $(IMAGE)
	$(SCAN_GRYPE) --vex $(VEXDOC) -o json  --file $(RESCAN)/ours-grype-vex.json $(IMAGE)
	$(SCAN_GRYPE) --vex $(VEXDOC) -o table --file $(RESCAN)/ours-grype-vex.txt  $(IMAGE)
	# Findings (id, package, version) without VEX minus with VEX = what the VEX removed.
	for s in trivy grype; do \
	  if [ $$s = trivy ]; then q='.Results[].Vulnerabilities[]? | [.VulnerabilityID, .PkgName, .InstalledVersion] | @tsv'; \
	  else q='.matches[] | [.vulnerability.id, .artifact.name, .artifact.version] | @tsv'; fi; \
	  jq -r "$$q" $(RESCAN)/ours-$$s.json     | sort -u > $(RESCAN)/.a; \
	  jq -r "$$q" $(RESCAN)/ours-$$s-vex.json | sort -u > $(RESCAN)/.b; \
	  { echo "# findings on $(IMAGE) without VEX ($$(wc -l < $(RESCAN)/.a)) minus with --vex $(VEXDOC) ($$(wc -l < $(RESCAN)/.b))"; \
	    echo "# removed (comm -23):"; comm -23 $(RESCAN)/.a $(RESCAN)/.b; \
	    echo "# added (comm -13, expected none):"; comm -13 $(RESCAN)/.a $(RESCAN)/.b; } > $(RESCAN)/vex-removed-$$s.txt; \
	  cat $(RESCAN)/vex-removed-$$s.txt; \
	done
	rm -f $(RESCAN)/.a $(RESCAN)/.b
	chmod 0644 $(RESCAN)/*
