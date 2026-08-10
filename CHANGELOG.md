# Changelog

All notable changes are documented here. Version 1.0 establishes the contract
and operational model described below.

## 1.0.0 - 2026-08-09

### Added

- Unversioned, resource-oriented REST endpoints for readiness, chats, scrubbed
  chat-background state, bounded history, scheduled messages, statistics, text
  sends, privacy-safe audit events, and API-key management.
- Scoped bearer API keys with 256-bit generation, SHA-256-only SQLite storage,
  expiry, immediate revocation, final-administrator protection, and local bootstrap.
- Durable send idempotency with explicit accepted, failed, and ambiguous outcomes.
- Privacy-preserving audit metadata and bounded source/key-aware rate limiting.
- A dependency-free same-origin console with service overview, a typed API
  playground, intentional-send confirmation/idempotency, and API-key lifecycle.
- A one-command bootstrap that validates and starts the reviewed native topology,
  keeps public exposure behind two explicit gates, rolls back newly started
  services on failure, proves the Messages read path both directly and from the
  LaunchAgent, and emits only the first administrator key on stdout.
- Public ACME HTTPS through a pinned host-native Caddy 2.11.4 executable.
- Direct Caddy-to-server forwarding through one private host Unix socket.
- Exact `imsg 0.13.4` enforcement and fixed, shell-free command adapters.

### Changed

- Runtime state now uses `~/Library/Application Support/iMessage Proxy`.
- The native service is `imessage-proxy-server`, loaded as
  `io.github.mglaeser.imessage-proxy`.
- Caddy runs as a non-root GUI-user LaunchAgent on configurable unprivileged IPv4
  host ports. The public edge requires exact external TCP 80/443 mappings and an
  explicit exposure gate and confirmation.
- Stop actions durably disable their exact GUI launchd label across login/reboot;
  install, start, and restart explicitly re-enable it.
- Installation defaults to the current user's `$HOME/.local` prefix.
