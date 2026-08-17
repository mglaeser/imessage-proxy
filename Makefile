SHELL := /bin/bash
.DEFAULT_GOAL := help

VERSION_FILE := VERSION
VERSION := $(strip $(shell sed -n '1p' "$(VERSION_FILE)" 2>/dev/null))
ifeq ($(VERSION),)
$(error VERSION is missing or empty)
endif

PREFIX ?= $(HOME)/.local
DESTDIR ?=
BINDIR ?= $(PREFIX)/bin
DATADIR ?= $(PREFIX)/share/imessage-proxy
BUILD_DIR ?= build
INSTALL_ROOT := $(abspath $(DESTDIR)$(PREFIX))
INSTALL_BINDIR := $(abspath $(DESTDIR)$(BINDIR))
INSTALL_DATADIR := $(abspath $(DESTDIR)$(DATADIR))

SOURCES := src/imessage-proxy-server.m src/api-key-store.m
HEADERS := src/api-key-store.h
# The native unit tier is built by tests/native/run.sh rather than by a rule
# here, but its sources are still ours and are listed so that lint and format
# reach them. A file absent from these lists is silently unlinted.
TEST_OBJC_SOURCES := \
	tests/native/runner.m \
	tests/native/test-api-key-store.m \
	tests/native/test-differential.m \
	tests/native/test-imessage-proxy-server.m \
	tests/native/linux/foundation-parity.m
TEST_OBJC_HEADERS := \
	tests/native/imp-test.h \
	tests/native/linux/CommonCrypto/CommonDigest.h \
	tests/native/linux/CoreFoundation/CoreFoundation.h \
	tests/native/linux/Security/Security.h \
	tests/native/linux/compat/darwin-compat.h \
	tests/native/linux/dispatch/dispatch.h \
	tests/native/linux/objc/blocks_runtime.h \
	tests/native/linux/os/log.h
TEST_C_SOURCES := \
	tests/fixtures/fake-imsg-launcher.c \
	tests/native/linux/darwin-shim.c
RELEASE_BINARY := $(BUILD_DIR)/imessage-proxy-server
DEBUG_BINARY := $(BUILD_DIR)/imessage-proxy-server-debug
SHELL_SOURCES := \
	bin/imessage-proxy \
	scripts/install.sh \
	scripts/linux-toolchain.sh \
	scripts/uninstall.sh \
	tests/native/run.sh \
	tests/test-imessage-proxy-server.sh \
	tests/test-imessage-proxy-cli.sh \
	tests/test-install-script.sh \
	tests/test-uninstall-script.sh \
	tests/test-bash-compatibility.sh \
	tests/fixtures/fake-imsg.sh
CONFIG_FILES := \
	config/io.github.mglaeser.imessage-proxy.plist.in \
	config/imessage-proxy.env.example
WEB_FILES := web/index.html web/app.js web/styles.css
JAVASCRIPT_SOURCES := web/app.js tests/test-web-ui.mjs tests/test-schema-fingerprint.mjs tests/test-native-invariants.mjs \
	tests/test-workflow-contract.mjs

CLANG ?= $(shell xcrun --find clang 2>/dev/null)
MACOS_SDK_PATH ?= $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
CPPFLAGS ?=
CFLAGS ?=
LDFLAGS ?=
STRICT ?= $(if $(CI),1,0)
# Objective-C nil coalescing and Foundation's MIN/MAX macros are intentional
# Clang extensions; keep every other pedantic diagnostic enabled.
WARNINGS := \
	-Wall \
	-Wextra \
	-Wpedantic \
	-Wno-gnu-conditional-omitted-operand \
	-Wno-gnu-statement-expression-from-macro-expansion
WERROR := $(if $(filter 1 true yes,$(STRICT)),-Werror,)
OBJCFLAGS := -fobjc-arc -fblocks $(WARNINGS) $(WERROR) -DIMESSAGE_PROXY_VERSION=\"$(VERSION)\"
SDKFLAGS := $(if $(MACOS_SDK_PATH),-isysroot "$(MACOS_SDK_PATH)",)
FRAMEWORKS := -framework Foundation -framework Security
LIBRARIES := -lsqlite3

.PHONY: all analyze build check clean debug format help install lint test test-bash-compat test-installer test-native test-schema test-uninstaller test-ui test-workflows uninstall version

all: build

build: $(RELEASE_BINARY) ## Build the optimized native server.

$(RELEASE_BINARY): $(SOURCES) $(HEADERS) $(VERSION_FILE) Makefile
	@$(MAKE) --no-print-directory _require-macos
	@mkdir -p "$(BUILD_DIR)"
	"$(CLANG)" $(SDKFLAGS) $(CPPFLAGS) $(CFLAGS) $(OBJCFLAGS) -O2 $(LDFLAGS) \
		$(FRAMEWORKS) $(LIBRARIES) -o "$@" $(SOURCES)

debug: $(DEBUG_BINARY) ## Build the native server with debug symbols and assertions.

$(DEBUG_BINARY): $(SOURCES) $(HEADERS) $(VERSION_FILE) Makefile
	@$(MAKE) --no-print-directory _require-macos
	@mkdir -p "$(BUILD_DIR)"
	"$(CLANG)" $(SDKFLAGS) $(CPPFLAGS) $(CFLAGS) $(OBJCFLAGS) -O0 -g3 -DDEBUG=1 \
		$(LDFLAGS) $(FRAMEWORKS) $(LIBRARIES) -o "$@" $(SOURCES)

analyze: ## Run Clang's static analyzer.
	@$(MAKE) --no-print-directory _require-macos
	@set -e; for source in $(SOURCES); do \
		"$(CLANG)" --analyze $(SDKFLAGS) $(CPPFLAGS) $(CFLAGS) $(OBJCFLAGS) \
			-Xanalyzer -analyzer-output=text -Xanalyzer -analyzer-werror "$$source"; \
	done

test: test-ui test-schema test-workflows test-installer test-uninstaller test-bash-compat test-native ## Run UI, schema, workflow, script, native, native-server, and lifecycle tests (macOS only).
	@$(MAKE) --no-print-directory _require-macos
	bash tests/test-imessage-proxy-server.sh
	bash tests/test-imessage-proxy-cli.sh

test-installer: ## Run portable one-command installer behavior tests.
	bash tests/test-install-script.sh

test-uninstaller: ## Run portable uninstaller behavior tests.
	bash tests/test-uninstall-script.sh

test-bash-compat: ## Run portable interpreter-compatibility tests across bash 3.2-5.2 semantics.
	bash tests/test-bash-compatibility.sh

# Deliberately not guarded by _require-macos. The point of this tier is that the
# leaf functions of a macOS-only product can be exercised on a Linux runner, and
# a target that refused to run anywhere but a Mac would hand back the coverage
# it was written to win. On Linux, provision the toolchain first with
# scripts/linux-toolchain.sh; run.sh names that remedy when it is missing.
test-native: ## Run the native unit tests (Linux or macOS).
	bash tests/native/run.sh

test-schema: _require-node ## Verify the key-store schema fingerprint and the native invariants.
	node --test tests/test-schema-fingerprint.mjs tests/test-native-invariants.mjs

test-ui: _require-node ## Run dependency-free management-console behavior tests.
	node --test tests/test-web-ui.mjs

# actionlint validates each workflow on its own, which cannot see that one
# workflow waits for a check another workflow stopped producing. This target
# reads across all of them.
test-workflows: _require-node ## Verify the release gate waits only on checks some workflow produces.
	node --test tests/test-workflow-contract.mjs

.PHONY: _require-node
_require-node:
	@command -v node >/dev/null 2>&1 || { printf 'error: Node.js is required\n' >&2; exit 127; }
	@node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major !== 22 || minor < 12) { console.error(`error: Node.js >=22.12.0 <23 is required; found $${process.versions.node}`); process.exit(1); }'

lint: _require-node ## Check Objective-C, shell, Markdown, JavaScript, and configuration files.
	@command -v clang-format >/dev/null 2>&1 || { printf 'error: clang-format is required\n' >&2; exit 127; }
	@command -v shellcheck >/dev/null 2>&1 || { printf 'error: shellcheck is required\n' >&2; exit 127; }
	@command -v npm >/dev/null 2>&1 || { printf 'error: npm is required\n' >&2; exit 127; }
	@test -x node_modules/.bin/markdownlint-cli2 && test -x node_modules/.bin/redocly || { \
		printf 'error: run npm ci --ignore-scripts --no-audit --no-fund to install locked validation tools\n' >&2; exit 127; }
	clang-format --dry-run --Werror $(SOURCES) $(HEADERS) $(TEST_C_SOURCES) $(TEST_OBJC_SOURCES) $(TEST_OBJC_HEADERS)
	shellcheck $(SHELL_SOURCES)
	npm run --silent lint:markdown
	npm run --silent lint:openapi
	@for source in $(JAVASCRIPT_SOURCES); do node --check "$$source"; done
	@if [[ "$$(uname -s)" == Darwin ]]; then plutil -lint config/*.plist.in >/dev/null; fi

format: ## Rewrite Objective-C sources in the project's clang-format style.
	@command -v clang-format >/dev/null 2>&1 || { printf 'error: clang-format is required\n' >&2; exit 127; }
	clang-format -i $(SOURCES) $(HEADERS) $(TEST_C_SOURCES) $(TEST_OBJC_SOURCES) $(TEST_OBJC_HEADERS)

check: lint build analyze test ## Run every local check used by CI.

install: build ## Install the CLI and read-only source, configuration, and UI assets.
	@case "$(INSTALL_ROOT)" in ''|/|.) printf 'error: refusing unsafe PREFIX/DESTDIR\n' >&2; exit 2;; esac
	@for path in "$(INSTALL_BINDIR)" "$(INSTALL_DATADIR)"; do \
		case "$$path" in "$(INSTALL_ROOT)"/*) ;; *) printf 'error: install path escapes PREFIX: %s\n' "$$path" >&2; exit 2;; esac; \
	done
	install -d "$(INSTALL_BINDIR)" "$(INSTALL_DATADIR)/src" "$(INSTALL_DATADIR)/config" "$(INSTALL_DATADIR)/web"
	install -m 0755 bin/imessage-proxy "$(INSTALL_BINDIR)/imessage-proxy"
	install -m 0644 "$(VERSION_FILE)" "$(INSTALL_DATADIR)/VERSION"
	install -m 0644 $(SOURCES) $(HEADERS) "$(INSTALL_DATADIR)/src/"
	install -m 0644 $(CONFIG_FILES) "$(INSTALL_DATADIR)/config/"
	install -m 0644 $(WEB_FILES) "$(INSTALL_DATADIR)/web/"

uninstall: ## Remove only files installed by this Makefile; preserve all runtime state.
	@case "$(INSTALL_ROOT)" in ''|/|.) printf 'error: refusing unsafe PREFIX/DESTDIR\n' >&2; exit 2;; esac
	@for path in "$(INSTALL_BINDIR)" "$(INSTALL_DATADIR)"; do \
		case "$$path" in "$(INSTALL_ROOT)"/*) ;; *) printf 'error: install path escapes PREFIX: %s\n' "$$path" >&2; exit 2;; esac; \
	done
	rm -f -- "$(INSTALL_BINDIR)/imessage-proxy"
	rm -f -- \
		"$(INSTALL_DATADIR)/VERSION" \
		"$(INSTALL_DATADIR)/src/imessage-proxy-server.m" \
		"$(INSTALL_DATADIR)/src/api-key-store.m" \
		"$(INSTALL_DATADIR)/src/api-key-store.h" \
		"$(INSTALL_DATADIR)/config/io.github.mglaeser.imessage-proxy.plist.in" \
		"$(INSTALL_DATADIR)/config/imessage-proxy.env.example" \
		"$(INSTALL_DATADIR)/web/index.html" \
		"$(INSTALL_DATADIR)/web/app.js" \
		"$(INSTALL_DATADIR)/web/styles.css"
	-rmdir "$(INSTALL_DATADIR)/src" "$(INSTALL_DATADIR)/config" "$(INSTALL_DATADIR)/web" "$(INSTALL_DATADIR)" 2>/dev/null
	@printf 'Runtime state, API keys, logs, certificates, and LaunchAgents were not changed.\n'

clean: ## Remove repository-local build outputs.
	@case "$(abspath $(BUILD_DIR))" in "$(CURDIR)"/*) ;; *) printf 'error: BUILD_DIR must be inside the repository\n' >&2; exit 2;; esac
	rm -f -- "$(RELEASE_BINARY)" "$(DEBUG_BINARY)"
	rm -rf -- "$(BUILD_DIR)/native"
	-rmdir "$(BUILD_DIR)" 2>/dev/null

version: ## Print the project version.
	@printf '%s\n' "$(VERSION)"

help: ## Show available targets.
	@printf 'iMessage Proxy %s\n\nUsage:\n  make <target> [STRICT=1] [PREFIX=%s]\n\nTargets:\n' "$(VERSION)" "$(HOME)/.local"
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST) | sort

.PHONY: _require-macos
_require-macos:
	@[[ "$$(uname -s)" == Darwin ]] || { printf 'error: this target requires macOS\n' >&2; exit 1; }
	@[[ -n "$(CLANG)" && -x "$(CLANG)" ]] || { printf 'error: install the Xcode Command Line Tools\n' >&2; exit 127; }
	@[[ -n "$(MACOS_SDK_PATH)" && -d "$(MACOS_SDK_PATH)" ]] || { printf 'error: cannot find the macOS SDK\n' >&2; exit 127; }
