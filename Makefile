BINARY = vm
PROFILE ?= debug
BUILD_DIR = .build/$(PROFILE)
ENTITLEMENTS = Sources/VM/VM.entitlements
INSTALL_PREFIX ?= /usr/local

SWIFT = $(shell xcrun -f swift)
CODESIGN = $(shell xcrun --find codesign)

.PHONY: all build sign install clean

all: build sign

build:
	$(SWIFT) build -c $(PROFILE)

sign: build
	$(CODESIGN) --force --sign - --entitlements $(ENTITLEMENTS) $(BUILD_DIR)/$(BINARY)

install: all
	install -d $(INSTALL_PREFIX)/bin
	install $(BUILD_DIR)/$(BINARY) $(INSTALL_PREFIX)/bin/$(BINARY)

clean:
	$(SWIFT) package clean
