# Changelog

All notable changes to iMessage Proxy are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-08-09

### Changed

- Renamed the public project and repository from Stella to iMessage Proxy at `github.com/mglaeser/imessage-proxy`.
- Added the canonical `bin/imessage-proxy` command, `IMESSAGE_PROXY_*` environment names, `src/imessage-proxy-bridge.m` source, and `config/imessage-proxy.env.example` template.
- Renamed release, installation, test, documentation, and community metadata surfaces to `imessage-proxy`.
- Renamed native bridge diagnostic and audit-log prefixes to `imessage-proxy-bridge`; monitoring that matches the former prefix must be updated.

### Deprecated

- Deprecated the `bin/stella` command shim and `STELLA_*` environment aliases. They remain available for the 0.2.0 transition release; conflicting canonical and legacy environment values fail closed.

### Compatibility

- Preserved the runtime home `~/Library/Application Support/Stella`, `stella-bridge` binary, `io.github.mglaeser.stella.bridge` LaunchAgent identity, `stella` container, and `stella-host.container.internal` route to avoid automatic CA, TCC, container, or state migration.
- Added no automatic runtime migration; existing runtime identities and migration receipts remain valid.

## [0.1.1] - 2026-08-09

### Fixed

- Reject API facade ports that collide with the native bridge listener.
- Preserve an existing LaunchAgent plist and refuse unsafe or drifted content instead of overwriting it.
- Verify that the Apple Container host route resolves only to the configured loopback alias before facade creation or restart.

## [0.1.0] - 2026-08-09

### Added

- Standalone Stella repository layout, build tooling, CI, release automation, and project mark.
- Public architecture, API, operations, migration, troubleshooting, contribution, governance, and security documentation.
- Native Objective-C bridge bound exclusively to IPv4 loopback.
- Bearer-token authentication using constant-time comparison.
- Allowlisted JSON-RPC methods for chat listing, message history, cursor polling, sending, and send-status checks.
- Exact-target allowlist with deny-by-default outbound sending.
- Sipgate-shaped compatibility endpoint for immediate text sends.
- Caddy facade with internal TLS, per-client Basic Auth, private-range filtering, and bounded request bodies.
- LaunchAgent and Apple Container lifecycle management.
- Integration tests using a fake `imsg` RPC backend.

[Unreleased]: https://github.com/mglaeser/imessage-proxy/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/mglaeser/imessage-proxy/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/mglaeser/imessage-proxy/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/mglaeser/imessage-proxy/releases/tag/v0.1.0
