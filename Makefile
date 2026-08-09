SHELL := /bin/bash
.DEFAULT_GOAL := help

VERSION_FILE := VERSION
VERSION := $(strip $(shell sed -n '1p' "$(VERSION_FILE)" 2>/dev/null))
ifeq ($(VERSION),)
$(error VERSION is missing or empty)
endif
PREFIX ?= /usr/local
DESTDIR ?=
BINDIR ?= $(PREFIX)/bin
DATADIR ?= $(PREFIX)/share/imessage-proxy
BUILD_DIR ?= build
INSTALL_ROOT := $(abspath $(DESTDIR)$(PREFIX))
INSTALL_BINDIR := $(abspath $(DESTDIR)$(BINDIR))
INSTALL_DATADIR := $(abspath $(DESTDIR)$(DATADIR))

SOURCE := src/imessage-proxy-bridge.m
RELEASE_BINARY := $(BUILD_DIR)/imessage-proxy-bridge
DEBUG_BINARY := $(BUILD_DIR)/imessage-proxy-bridge-debug
SHELL_SOURCES := \
	bin/imessage-proxy \
	bin/stella \
	tests/test-imessage-proxy-bridge.sh \
	tests/test-imessage-proxy-cli.sh \
	tests/fixtures/fake-imsg.sh
CONFIG_FILES := \
	config/Caddyfile \
	config/io.github.mglaeser.stella.plist.in \
	config/imessage-proxy.env.example

CLANG ?= $(shell xcrun --find clang 2>/dev/null)
MACOS_SDK_PATH ?= $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
CPPFLAGS ?=
CFLAGS ?=
LDFLAGS ?=
STRICT ?= $(if $(CI),1,0)
WARNINGS := -Wall -Wextra -Wpedantic
WERROR := $(if $(filter 1 true yes,$(STRICT)),-Werror,)
OBJCFLAGS := -fobjc-arc -fblocks $(WARNINGS) $(WERROR) -DIMESSAGE_PROXY_VERSION=\"$(VERSION)\"
SDKFLAGS := $(if $(MACOS_SDK_PATH),-isysroot "$(MACOS_SDK_PATH)",)
FRAMEWORKS := -framework Foundation

.PHONY: all analyze build check clean debug help install lint test uninstall version

all: build

build: $(RELEASE_BINARY) ## Build an optimized iMessage Proxy bridge.

$(RELEASE_BINARY): $(SOURCE) $(VERSION_FILE) Makefile
	@$(MAKE) --no-print-directory _require-macos
	@mkdir -p "$(BUILD_DIR)"
	"$(CLANG)" $(SDKFLAGS) $(CPPFLAGS) $(CFLAGS) $(OBJCFLAGS) -O2 $(LDFLAGS) $(FRAMEWORKS) -o "$@" "$<"

debug: $(DEBUG_BINARY) ## Build a bridge with debug symbols and assertions.

$(DEBUG_BINARY): $(SOURCE) $(VERSION_FILE) Makefile
	@$(MAKE) --no-print-directory _require-macos
	@mkdir -p "$(BUILD_DIR)"
	"$(CLANG)" $(SDKFLAGS) $(CPPFLAGS) $(CFLAGS) $(OBJCFLAGS) -O0 -g3 -DDEBUG=1 $(LDFLAGS) $(FRAMEWORKS) -o "$@" "$<"

analyze: ## Run Clang's static analyzer.
	@$(MAKE) --no-print-directory _require-macos
	"$(CLANG)" --analyze $(SDKFLAGS) $(CPPFLAGS) $(CFLAGS) $(OBJCFLAGS) -Xanalyzer -analyzer-output=text "$(SOURCE)"

test: ## Run the integration and lifecycle test suites (macOS only).
	@$(MAKE) --no-print-directory _require-macos
	bash tests/test-imessage-proxy-bridge.sh
	bash tests/test-imessage-proxy-cli.sh

lint: ## Check Objective-C, shell, Markdown, and LaunchAgent files.
	@command -v clang-format >/dev/null 2>&1 || { printf 'error: clang-format is required\n' >&2; exit 127; }
	@command -v shellcheck >/dev/null 2>&1 || { printf 'error: shellcheck is required\n' >&2; exit 127; }
	@command -v markdownlint-cli2 >/dev/null 2>&1 || { printf 'error: markdownlint-cli2 is required\n' >&2; exit 127; }
	@command -v caddy >/dev/null 2>&1 || { printf 'error: caddy is required\n' >&2; exit 127; }
	clang-format --dry-run --Werror "$(SOURCE)"
	shellcheck $(SHELL_SOURCES)
	markdownlint-cli2
	@if [[ "$$(uname -s)" == Darwin ]]; then plutil -lint config/*.plist.in >/dev/null; fi
	@temporary="$$(mktemp -d)"; \
		trap 'rm -rf -- "$$temporary"' EXIT; \
		caddy hash-password --plaintext imessage-proxy-ci-validation > "$$temporary/password.hash"; \
		printf 'imessage-proxy-ci %s\n' "$$(< "$$temporary/password.hash")" > "$$temporary/users.caddy"; \
		STELLA_API_HOST=imessage-proxy.invalid \
		STELLA_API_PORT=9443 \
		STELLA_BRIDGE_HOST=127.0.0.1 \
		STELLA_BRIDGE_PORT=8765 \
		STELLA_BRIDGE_TOKEN="$$(openssl rand -hex 32)" \
		STELLA_USERS_FILE="$$temporary/users.caddy" \
		XDG_CONFIG_HOME="$$temporary/config" \
		XDG_DATA_HOME="$$temporary/data" \
			caddy adapt --config config/Caddyfile --adapter caddyfile --validate >/dev/null

check: lint build analyze test ## Run all checks used by CI.

install: build ## Install the CLI and read-only source/configuration assets.
	@case "$(INSTALL_ROOT)" in ''|/|.) printf 'error: refusing unsafe PREFIX/DESTDIR\n' >&2; exit 2;; esac
	@for path in "$(INSTALL_BINDIR)" "$(INSTALL_DATADIR)"; do \
		case "$$path" in "$(INSTALL_ROOT)"/*) ;; *) printf 'error: install path escapes PREFIX: %s\n' "$$path" >&2; exit 2;; esac; \
	done
	install -d "$(INSTALL_BINDIR)" "$(INSTALL_DATADIR)/src" "$(INSTALL_DATADIR)/config"
	install -m 0755 bin/imessage-proxy "$(INSTALL_BINDIR)/imessage-proxy"
	install -m 0755 bin/stella "$(INSTALL_BINDIR)/stella"
	install -m 0644 "$(VERSION_FILE)" "$(INSTALL_DATADIR)/VERSION"
	install -m 0644 "$(SOURCE)" "$(INSTALL_DATADIR)/src/imessage-proxy-bridge.m"
	install -m 0644 $(CONFIG_FILES) "$(INSTALL_DATADIR)/config/"

uninstall: ## Remove only files installed by this Makefile; preserve all runtime state.
	@case "$(INSTALL_ROOT)" in ''|/|.) printf 'error: refusing unsafe PREFIX/DESTDIR\n' >&2; exit 2;; esac
	@for path in "$(INSTALL_BINDIR)" "$(INSTALL_DATADIR)"; do \
		case "$$path" in "$(INSTALL_ROOT)"/*) ;; *) printf 'error: install path escapes PREFIX: %s\n' "$$path" >&2; exit 2;; esac; \
	done
	rm -f -- "$(INSTALL_BINDIR)/imessage-proxy" "$(INSTALL_BINDIR)/stella"
	rm -f -- \
		"$(INSTALL_DATADIR)/VERSION" \
		"$(INSTALL_DATADIR)/src/imessage-proxy-bridge.m" \
		"$(INSTALL_DATADIR)/config/Caddyfile" \
		"$(INSTALL_DATADIR)/config/io.github.mglaeser.stella.plist.in" \
		"$(INSTALL_DATADIR)/config/imessage-proxy.env.example"
	-rmdir "$(INSTALL_DATADIR)/src" "$(INSTALL_DATADIR)/config" "$(INSTALL_DATADIR)" 2>/dev/null
	@printf 'Runtime state, secrets, LaunchAgents, and containers were not changed.\n'

clean: ## Remove repository-local build outputs.
	@case "$(abspath $(BUILD_DIR))" in "$(CURDIR)"/*) ;; *) printf 'error: BUILD_DIR must be inside the repository\n' >&2; exit 2;; esac
	rm -f -- "$(RELEASE_BINARY)" "$(DEBUG_BINARY)"
	-rmdir "$(BUILD_DIR)" 2>/dev/null

version: ## Print the project version.
	@printf '%s\n' "$(VERSION)"

help: ## Show available targets.
	@printf 'iMessage Proxy %s\n\nUsage:\n  make <target> [STRICT=1] [PREFIX=/usr/local]\n\nTargets:\n' "$(VERSION)"
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST) | sort

.PHONY: _require-macos
_require-macos:
	@[[ "$$(uname -s)" == Darwin ]] || { printf 'error: this target requires macOS\n' >&2; exit 1; }
	@[[ -n "$(CLANG)" && -x "$(CLANG)" ]] || { printf 'error: install the Xcode Command Line Tools\n' >&2; exit 127; }
	@[[ -n "$(MACOS_SDK_PATH)" && -d "$(MACOS_SDK_PATH)" ]] || { printf 'error: cannot find the macOS SDK\n' >&2; exit 127; }
