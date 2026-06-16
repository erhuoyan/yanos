# yanos.mk — YanOS build wrapper
# Include the original Talos Makefile and override branding variables.
# Usage:
#   make -f yanos.mk yanctl               # build YanOS CLI (current platform)
#   make -f yanos.mk yanctl-all           # build all platforms
#   make -f yanos.mk yanos-iso            # build YanOS ISO
#   make -f yanos.mk yanos-gendata        # write gendata for local builds
#   make -f yanos.mk                      # default: build yanctl

YANOS_VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
YANOS_SHA     ?= $(shell git rev-parse --short=8 HEAD 2>/dev/null || echo "unknown")
YANOS_NAME    := YanOS

# Branding overrides
export USERNAME := erhuoyan
export REGISTRY ?= ghcr.io

# Platform detection
HOST_OS   := $(shell uname -s | tr '[:upper:]' '[:lower:]')
HOST_ARCH := $(shell uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')

YANCTL_PLATFORMS := linux-amd64 linux-arm64 darwin-amd64 darwin-arm64

# Default target
.DEFAULT_GOAL := yanctl

# --- gendata injection (required before Go build) ---

GENDATA_DIR := pkg/machinery/gendata/data

.PHONY: yanos-gendata
yanos-gendata:
	@mkdir -p $(GENDATA_DIR)
	@echo -n "$(YANOS_NAME)"    > $(GENDATA_DIR)/name
	@echo -n "$(YANOS_VERSION)" > $(GENDATA_DIR)/tag
	@echo -n "$(YANOS_SHA)"     > $(GENDATA_DIR)/sha
	@echo -n "$(USERNAME)"      > $(GENDATA_DIR)/username
	@echo -n "$(REGISTRY)"      > $(GENDATA_DIR)/registry

# --- yanctl builds ---

.PHONY: yanctl
yanctl: yanos-gendata
	@echo "Building yanctl $(YANOS_VERSION) ($(HOST_OS)/$(HOST_ARCH))..."
	CGO_ENABLED=0 GOOS=$(HOST_OS) GOARCH=$(HOST_ARCH) \
		go build -tags grpcnotrace -ldflags "-s -w" \
		-o _out/yanctl ./cmd/yanctl
	@echo "→ _out/yanctl"

.PHONY: yanctl-all
yanctl-all: yanos-gendata
	@mkdir -p _out
	@for platform in $(YANCTL_PLATFORMS); do \
		os=$${platform%%-*}; \
		arch=$${platform##*-}; \
		echo "Building yanctl-$${platform}..."; \
		CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch \
			go build -tags grpcnotrace -ldflags "-s -w" \
			-o _out/yanctl-$$platform ./cmd/yanctl; \
	done
	@echo "→ _out/yanctl-{$(YANCTL_PLATFORMS)}"

# --- full system builds (require Docker) ---

.PHONY: yanos-iso
yanos-iso:
	$(MAKE) iso USERNAME=erhuoyan NAME="$(YANOS_NAME)"

.PHONY: yanos-installer
yanos-installer:
	$(MAKE) installer USERNAME=erhuoyan NAME="$(YANOS_NAME)"

# --- utilities ---

.PHONY: yanos-version
yanos-version:
	@echo "$(YANOS_NAME) $(YANOS_VERSION)"

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
