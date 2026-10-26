SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
SCRATCH ?= /tmp/lake-of-fire-posthog-events-build
PREBUILT_FLAGS := $(shell swift test --help 2>/dev/null | awk '/--disable-experimental-prebuilts/ {print "--disable-experimental-prebuilts"; exit}')

.PHONY: test build audit manifests
manifests:
	python3 LakeOfFire/scripts/render-manifests.py --check

test: manifests
	swift test --scratch-path "$(SCRATCH)" $(PREBUILT_FLAGS) 2>&1 | xcsift --warnings --exit-on-failure

build: manifests
	swift build -c release --scratch-path "$(SCRATCH)" $(PREBUILT_FLAGS) 2>&1 | xcsift --warnings --exit-on-failure

audit: manifests
	swift package describe --type json | python3 LakeOfFire/scripts/audit-package.py
