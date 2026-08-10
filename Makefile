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
TEST_C_SOURCES := tests/fixtures/fake-imsg-launcher.c
RELEASE_BINARY := $(BUILD_DIR)/imessage-proxy-server
DEBUG_BINARY := $(BUILD_DIR)/imessage-proxy-server-debug
SHELL_SOURCES := \
	bin/imessage-proxy \
	tests/test-caddy-edge.sh \
	tests/test-imessage-proxy-server.sh \
	tests/test-imessage-proxy-cli.sh \
	tests/fixtures/fake-imsg.sh
CONFIG_FILES := \
	config/Caddyfile \
	config/io.github.mglaeser.imessage-proxy.edge.plist.in \
	config/io.github.mglaeser.imessage-proxy.plist.in \
	config/imessage-proxy.env.example
WEB_FILES := web/index.html web/app.js web/styles.css
JAVASCRIPT_SOURCES := web/app.js tests/test-web-ui.mjs

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

.PHONY: all analyze build check clean debug help install lint test test-ui uninstall version

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

test: test-ui ## Run UI behavior plus native-server and lifecycle tests (macOS only).
	@$(MAKE) --no-print-directory _require-macos
	bash tests/test-imessage-proxy-server.sh
	bash tests/test-imessage-proxy-cli.sh

test-ui: _require-node ## Run dependency-free management-console behavior tests.
	node --test tests/test-web-ui.mjs

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
	@command -v caddy >/dev/null 2>&1 || { printf 'error: caddy is required\n' >&2; exit 127; }
	@test "$$(caddy version 2>/dev/null | awk '{print $$1}')" = v2.11.4 || { printf 'error: Caddy 2.11.4 is required for validation\n' >&2; exit 1; }
	clang-format --dry-run --Werror $(SOURCES) $(HEADERS) $(TEST_C_SOURCES)
	shellcheck $(SHELL_SOURCES)
	npm run --silent lint:markdown
	npm run --silent lint:openapi
	@for source in $(JAVASCRIPT_SOURCES); do node --check "$$source"; done
	@if [[ "$$(uname -s)" == Darwin ]]; then plutil -lint config/*.plist.in >/dev/null; fi
	@temporary="$$(mktemp -d)"; \
		trap 'rm -rf -- "$$temporary"' EXIT; \
		IMESSAGE_PROXY_API_HOST=imessage-proxy.invalid \
		IMESSAGE_PROXY_ACME_EMAIL=ci@example.invalid \
		IMESSAGE_PROXY_EDGE_LOG_PATH="$$temporary/edge.log" \
		IMESSAGE_PROXY_HTTP_PORT=8080 IMESSAGE_PROXY_HTTPS_PORT=8443 \
		IMESSAGE_PROXY_PUBLIC_BIND=127.0.0.1 \
		IMESSAGE_PROXY_SOCKET_PATH="$$temporary/server.sock" \
		IMESSAGE_PROXY_UI_DIR="$(CURDIR)/web" \
		XDG_CONFIG_HOME="$$temporary/config" XDG_DATA_HOME="$$temporary/data" \
			caddy adapt --config config/Caddyfile --adapter caddyfile --validate >/dev/null

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
		"$(INSTALL_DATADIR)/config/Caddyfile" \
		"$(INSTALL_DATADIR)/config/io.github.mglaeser.imessage-proxy.edge.plist.in" \
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
