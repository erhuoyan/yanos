# yanos.mk — YanOS build wrapper
# Include the original Talos Makefile and override branding variables.
# Usage:
#   make -f yanos.mk yanctl          # build YanOS CLI
#   make -f yanos.mk yanos-iso       # build YanOS ISO
#   make -f yanos.mk                 # default: build yanctl

YANOS_VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

# Branding overrides
export USERNAME := erhuoyan
export REGISTRY ?= ghcr.io

# Default target
.DEFAULT_GOAL := yanctl

.PHONY: yanctl
yanctl:
	@echo "Building yanctl $(YANOS_VERSION)..."
	cd cmd/yanctl && CGO_ENABLED=0 go build -ldflags "-s -w" -o ../../_out/yanctl .
	@echo "→ _out/yanctl"

.PHONY: yanos-iso
yanos-iso:
	$(MAKE) iso USERNAME=erhuoyan

.PHONY: yanos-installer
yanos-installer:
	$(MAKE) installer USERNAME=erhuoyan

.PHONY: yanos-version
yanos-version:
	@echo "YanOS $(YANOS_VERSION)"

.PHONY: yanos-diff
yanos-diff:
	@echo "=== YanOS diff from upstream ==="
	@git diff upstream/main --stat 2>/dev/null || echo "(upstream remote not configured)"

.PHONY: yanos-sync
yanos-sync:
	@echo "=== Syncing from upstream ==="
	git fetch upstream
	@echo "Upstream commits ahead:"
	@git log main..upstream/main --oneline | head -10
	@echo ""
	@echo "Run 'git merge upstream/main' to merge."
