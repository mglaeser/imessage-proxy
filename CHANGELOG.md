# Changelog

All notable changes are documented here. Version 1.0 establishes the contract
and operational model described below.

## Unreleased

### Added

- `install.sh --key-file PATH` writes the administrator key to a file instead of
  stdout. With the two questions already answerable by flag, this is the last
  thing that made an unattended run interactive: the key is redirected, never
  captured, into a file created private to you before anything is written to it.
  The run refuses at the outset if the path is not absolute, if its directory
  does not exist or is not writable, or if the file is already there — so an
  install that cannot deliver the key fails before it generates one.
- The first administrator key is identified as `adm`, so the first messages an
  installation sends end with `🔖adm` rather than the sequential `🔖aa`. Not
  reserved: a bootstrap that finds `adm` held by a revoked administrator takes
  the sequential identifier instead, and once the key is gone any key may be
  given it. Existing installations are unaffected; keys keep the identifier they
  were issued with.

- `make test-bash-compat`, a portable suite that runs the shell sources under
  every bash compatibility level from 3.2 to 5.2 and asserts the validators give
  identical answers. macOS ships bash 3.2 as `/bin/bash` and every script starts
  with `#!/usr/bin/env bash`, so the interpreter is whatever `PATH` resolves
  first; nothing verified that assumption before. It also refuses syntax bash 3.2
  lacks, and refuses a pattern substitution with a quoted replacement operand,
  which behaves differently before and after bash 4.3.

- A private install can decline to name itself. The installer's hostname and
  operator-address prompts accept Enter, which records reserved `.invalid`
  placeholders instead. Both values exist only for public HTTPS, and the CLI
  accepts the placeholders only while the exposure gate is closed, so enabling
  public HTTPS refuses to proceed until real values replace them.
- `install.sh --verbose`. Compiler command lines and install manifests are
  collapsed to one progress line each by default and printed in full when a step
  fails or `--verbose` is given, so the Full Disk Access checkpoint and the
  administrator key are no longer scrolled away by build output.
- The installer finishes with a summary: where the CLI, configuration,
  allowlist and logs are, how to reach the service over its Unix socket, what to
  do next, and the uninstall one-liner. It adds its own prefix to the shell
  startup file rather than printing instructions, idempotently, and says what it
  changed. The administrator key is still written only to standard output and is
  never captured or echoed.

### Removed

- Two unused LaunchAgent rendering helpers, `write_plist_from_template` and
  `require_no_unrendered_placeholders`. They shipped without callers, their
  comment described a mechanism the product does not use, and one of them
  carried a pattern substitution that would have emitted every value wrapped in
  literal quote characters under the bash macOS ships. Rendering is unchanged:
  it goes through `set_program_arguments`, and every render is still asserted by
  `require_rendered_program_arguments`.

### Fixed

- The README and install guide describe the installer that ships. The README
  still said the installer "asks nothing" and that Full Disk Access was the only
  manual step, which stopped being true when the test send and the Messages-read
  choice became questions and the Full Disk Access checkpoint left bootstrap;
  the install guide still listed that checkpoint in the bootstrap sequence.
- An existing installation upgrades instead of refusing to start. The sender
  identifier arrived as schema 7 with no way forward from schema 6, so the store
  refused the database every operator already had: the server would not start,
  every issued key was unreachable, and the only documented recovery discarded
  all of them. The refusal also arrived too late to act on, because `prepare`
  requires the server stopped and restages the runtime before anything opens the
  database — the working install was already dismantled by the time the message
  appeared. Schema 6 is now carried forward on first start, in one transaction,
  keeping every key's token, scopes, expiry and audit history and assigning each
  key the identifier it lacked. A schema that is genuinely unrecognised is still
  refused, but now names the recovery command instead of only stating the fact.
- A `sender_identifier` another key already holds is refused with `409`
  (`sender-identifier-taken`) rather than reported as a `503` store outage.
  The uniqueness check existed only where the service assigns an identifier, so
  a caller-supplied duplicate reached the insert and tripped the constraint;
  the retry loop there reads any constraint failure as a key-material collision
  and regenerated the token four times, which cannot resolve a duplicate
  identifier. A permanent, caller-fixable mistake was answered with a transient
  status that invites a retry which can never succeed. `docs/api.md` already
  promised the refusal.
- `service` is refused when it is present but not one of the two strings.
  `{"service": null}`, `{"service": 2}` and `{"service": ["sms"]}` were read as
  absent and silently sent over iMessage — the guess this endpoint exists not to
  make, over the field that decides what the recipient is charged and which
  marker they see. They are now `400 invalid-message`. Omitting `service`
  still means iMessage.
- The installer no longer writes an unvalidated `--prefix` into a shell startup
  file. A prefix containing a quote ended the quoting of the emitted `export
  PATH` line and left the remainder as code, which then ran in every later
  interactive shell. `--prefix` is now refused at parse time if it contains
  characters a shell would re-interpret, `ensure_path_entry` refuses one
  independently so no future caller can bypass that, and the path is emitted
  single-quoted. A prefix containing spaces still works.
- An operator address supplied with `--email` is no longer discarded when the
  hostname prompt is skipped. The two fields are validated independently, so a
  real address alongside a placeholder hostname is a coherent state.
- The completion summary names the placeholder values a private install
  recorded, so the operator can see what public HTTPS will ask them to replace.
- Every action reads the reviewed service configuration, not only `bootstrap`.
  `server-status`, `server-restart`, `check-host`, `api-key` and the `edge`
  actions read the environment alone, so on a Mac carrying the configuration the
  installer had just written they reported
  `IMESSAGE_PROXY_API_HOST must be an explicit lowercase public DNS hostname`
  for a hostname that was correct and had simply never been loaded. The file at
  `IMESSAGE_PROXY_CONFIG`, default `~/.config/imessage-proxy/service.env`, is
  now read for those actions; values already present in the environment take
  precedence, and a value that is missing is reported as missing rather than as
  malformed.

- Both LaunchAgents are rendered with the argument vector they declare. Patching
  the array by index relied on `plutil -replace ProgramArguments.N` replacing an
  element; where it inserts instead, the native agent shipped as
  `[<server binary>, "__SERVER_BIN__", "serve"]` and the server exited 64 on
  every spawn. Rendering now rebuilds the array by appending, and every render
  asserts the exact vector, so a bad vector fails `prepare` instead of becoming
  a crash loop behind a blind readiness wait.
- A failed start reports only what that start wrote to the server log. The log
  survives reinstalls and is never truncated, so an unscoped tail could present
  an earlier crash loop as the current cause; a start that wrote nothing now
  says so.
- The uninstaller no longer instructs removal of a Messages Automation entry
  that does not exist. Automation is requested at the first intentional send,
  never during installation.

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
- A single-command installer, `scripts/install.sh`, that verifies the Mac,
  obtains a checksum-verified release, builds and installs the CLI, pins Caddy
  2.11.4 by SHA-512, records both native dependency digests, writes one private
  `0600` configuration with the public-exposure gate closed, and hands off to the
  guarded product bootstrap. It never enables public exposure and keeps the first
  administrator key on standard output only.

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
