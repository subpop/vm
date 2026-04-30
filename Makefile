BINARY = vm
PROFILE ?= debug
BUILD_DIR = .build/$(PROFILE)
ENTITLEMENTS = Sources/VM/VM.entitlements
INSTALL_PREFIX ?= /usr/local

SWIFT = $(shell xcrun --find swift)
CODESIGN = $(shell xcrun --find codesign)
PKGBUILD = $(shell xcrun --find pkgbuild)
NOTARYTOOL = $(shell xcrun --find notarytool)
STAPLER = $(shell xcrun --find stapler)

# Distribution / .pkg / GitHub release (see `make help`)
DIST_DIR = dist
PKG_STAGING = $(DIST_DIR)/pkgroot
PKG_ID ?= app.subpop.vm
# Developer ID Application identity string, e.g. "Developer ID Application: Your Name (TEAMID)".
# Export SIGN_IDENTITY (e.g. direnv); command-line overrides env.
SIGN_IDENTITY ?=
# Developer ID Installer identity string; export INSTALLER_SIGN_IDENTITY the same way.
INSTALLER_SIGN_IDENTITY ?=
# Keychain profile from: xcrun notarytool store-credentials --keychain-profile "<name>"
NOTARY_PROFILE ?=
# Semantic version for the .pkg (no "v" prefix), e.g. 1.2.0 — required for `make release`
VERSION ?=
RELEASE_TAG = v$(VERSION)
PKG_FILE = $(DIST_DIR)/$(BINARY)-$(VERSION).pkg
# Branch used when `gh release create` creates a new tag (default: current branch; use main if detached)
RELEASE_TARGET ?= $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
# Optional extra flags for gh release create, e.g. GH_RELEASE_EXTRA=--draft
GH_RELEASE_EXTRA ?=
# Top ## … section in this file is used as the GitHub release body for github-release
CHANGELOG ?= CHANGELOG.md

.DEFAULT_GOAL := help

.PHONY: help help-release all build build-release build-debug install clean \
	stage-pkg pkg notarize-pkg github-release release

help:
	@echo "VM — Swift package targets"
	@echo ""
	@echo "Targets:"
	@echo "  help              Show this message (default when you run make with no target)."
	@echo "  all               Build a signed debug binary (same as build-debug)."
	@echo "  build             Swift build for PROFILE (default debug), then codesign the binary."
	@echo "  build-release     build with PROFILE=release."
	@echo "  build-debug       build with PROFILE=debug."
	@echo "  install           Install the built binary to INSTALL_PREFIX/bin (runs all first)."
	@echo "  clean             swift package clean and remove $(DIST_DIR)/."
	@echo "  stage-pkg         Lay out pkg root under $(PKG_STAGING) and sign vm (needs SIGN_IDENTITY)."
	@echo "  pkg               Produce $(DIST_DIR)/$(BINARY)-<version>.pkg (needs VERSION, INSTALLER_SIGN_IDENTITY)."
	@echo "  notarize-pkg      Submit the pkg to Apple notary service and staple (needs NOTARY_PROFILE)."
	@echo "  github-release    Create a GitHub release vVERSION with the stapled pkg (needs gh; notes from CHANGELOG)."
	@echo "  release           stage-pkg → pkg → notarize-pkg → github-release."
	@echo "  help-release      Same as help (release flow is documented above)."
	@echo ""
	@echo "Common variables:"
	@echo "  PROFILE           Swift configuration for build (default: debug). Example: make build PROFILE=release"
	@echo "  INSTALL_PREFIX    Install destination prefix (default: $(INSTALL_PREFIX))."
	@echo "  SIGN_IDENTITY     Developer ID Application string (env or make arg); required for build/install/pkg."
	@echo "  INSTALLER_SIGN_IDENTITY  Developer ID Installer string; required for pkg."
	@echo "  VERSION           Semantic version for the pkg, e.g. 1.2.0 (no v prefix)."
	@echo "  PKG_ID            Bundle id for the pkg (default: $(PKG_ID))."
	@echo "  NOTARY_PROFILE    notarytool keychain profile name."
	@echo "  RELEASE_TARGET    Branch for gh release create when the tag is new (default: current branch)."
	@echo "  GH_RELEASE_EXTRA  Extra flags for gh release create, e.g. --draft."
	@echo "  CHANGELOG         Path to changelog (default: CHANGELOG.md); top ## section → release notes."
	@echo ""
	@echo "Example:  make release VERSION=1.2.0 NOTARY_PROFILE=notary-vm"
	@echo "          (with SIGN_IDENTITY / INSTALLER_SIGN_IDENTITY set via env or the command line)"

help-release: help

all: build-debug

build:
	$(SWIFT) build -c $(PROFILE)
	$(CODESIGN) --force --options runtime --timestamp \
		--sign "$(SIGN_IDENTITY)" \
		--entitlements $(ENTITLEMENTS) \
		$(BUILD_DIR)/$(BINARY)

build-release: PROFILE := release
build-release: build

build-debug: PROFILE := debug
build-debug: build

install: all
	install -d $(INSTALL_PREFIX)/bin
	install $(BUILD_DIR)/$(BINARY) $(INSTALL_PREFIX)/bin/$(BINARY)

clean:
	$(SWIFT) package clean
	rm -rf $(DIST_DIR)

# --- Release: signed .pkg, notarization, GitHub ---
# Prerequisites: Developer ID certs, notarytool store-credentials, gh auth login — see make help.

# Signed binary suitable for notarization (hardened runtime + secure timestamp)
stage-pkg: PROFILE := release
stage-pkg: build-release
	@test -n "$(SIGN_IDENTITY)" || (echo "SIGN_IDENTITY is required (Developer ID Application)" >&2; exit 1)
	mkdir -p $(PKG_STAGING)/usr/local/bin
	install -m755 $(BUILD_DIR)/$(BINARY) $(PKG_STAGING)/usr/local/bin/$(BINARY)
	$(CODESIGN) --force --options runtime --timestamp \
		--sign "$(SIGN_IDENTITY)" \
		--entitlements $(ENTITLEMENTS) \
		$(PKG_STAGING)/usr/local/bin/$(BINARY)

pkg: stage-pkg
	@test -n "$(INSTALLER_SIGN_IDENTITY)" || (echo "INSTALLER_SIGN_IDENTITY is required (Developer ID Installer)" >&2; exit 1)
	@test -n "$(VERSION)" || (echo "VERSION is required (e.g. VERSION=1.2.0)" >&2; exit 1)
	mkdir -p $(DIST_DIR)
	$(PKGBUILD) \
		--root $(PKG_STAGING) \
		--identifier $(PKG_ID) \
		--version $(VERSION) \
		--install-location / \
		--sign "$(INSTALLER_SIGN_IDENTITY)" \
		$(PKG_FILE)

notarize-pkg: pkg
	@test -n "$(NOTARY_PROFILE)" || (echo "NOTARY_PROFILE is required (notarytool keychain profile name)" >&2; exit 1)
	$(NOTARYTOOL) submit $(PKG_FILE) --keychain-profile "$(NOTARY_PROFILE)" --wait
	$(STAPLER) staple $(PKG_FILE)

github-release: notarize-pkg
	@command -v gh >/dev/null 2>&1 || (echo "gh (GitHub CLI) is not installed" >&2; exit 1)
	@notes=$$(mktemp) && awk '/^## /{if (h) exit; h=1} h' $(CHANGELOG) > "$$notes" \
		&& test -s "$$notes" \
		&& gh release create $(RELEASE_TAG) $(PKG_FILE) \
			--title "$(RELEASE_TAG)" \
			--notes-file "$$notes" \
			--target "$(RELEASE_TARGET)" \
			$(GH_RELEASE_EXTRA) \
		; ec=$$?; rm -f "$$notes"; exit $$ec

# Full pipeline: release .pkg → notarize → GitHub release with .pkg attached
release: github-release
	@echo "Published $(RELEASE_TAG) with $(PKG_FILE)"
