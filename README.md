<!-- markdownlint-disable MD033 -->
<p align="center">
  <img src="docs/assets/imessage-proxy.svg" width="112" height="112" alt="iMessage Proxy: a star inside a message bubble">
</p>
<h1 align="center">iMessage Proxy</h1>
<p align="center">
  <strong>A small, security-first iMessage proxy for macOS and private networks.</strong>
</p>
<p align="center">
  <a href="https://github.com/mglaeser/imessage-proxy/actions/workflows/ci.yml"><img src="https://github.com/mglaeser/imessage-proxy/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <a href="https://github.com/mglaeser/imessage-proxy/releases"><img src="https://img.shields.io/github/v/release/mglaeser/imessage-proxy?display_name=tag&amp;sort=semver" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/mglaeser/imessage-proxy" alt="Apache-2.0 license"></a>
  <a href="ROADMAP.md"><img src="https://img.shields.io/badge/status-alpha-f59e0b" alt="Status: Alpha"></a>
  <a href="docs/operations.md"><img src="https://img.shields.io/badge/platform-macOS-111827?logo=apple" alt="Platform: macOS"></a>
</p>
<!-- markdownlint-enable MD033 -->

iMessage Proxy exposes a deliberately narrow Messages interface to explicitly authorized clients on a trusted LAN or VPN. A native, loopback-only bridge validates every request before handing an allowlisted operation to [`imsg`](https://github.com/openclaw/imsg). A Caddy facade supplies TLS and per-client authentication at the private-network boundary.

> [!WARNING]
> iMessage Proxy is **Alpha software**. It handles private conversations and can send messages as the signed-in macOS user. Review the threat model, test with a harmless recipient, and keep it off the public Internet.

## Why iMessage Proxy?

- **Small attack surface.** Five read/send RPC methods; everything else is rejected.
- **Deny-by-default sending.** Exact recipients or chats must be placed on a local allowlist.
- **Two authentication boundaries.** Clients authenticate to Caddy; Caddy authenticates separately to the loopback bridge.
- **Private by construction.** The native service binds to `127.0.0.1`, while the facade is intended only for a private LAN or VPN.
- **Bounded payloads.** Request, response, method, attachment, and text limits are enforced at the bridge boundary.
- **Useful audit trails.** Logs identify caller, method, outcome, and duration without recording message contents or recipients.
- **macOS-native permissions.** Messages access stays inside the signed-in user's GUI session and normal TCC controls remain enabled.

## How it works

```mermaid
flowchart LR
    client["Authorized client"] -->|"HTTPS + client credentials"| caddy["Caddy facade<br/>Apple Container"]
    caddy -->|"Private bearer token"| bridge["iMessage Proxy bridge<br/>127.0.0.1"]
    bridge -->|"Validated JSON-RPC over stdio"| imsg["imsg"]
    imsg --> db["Messages database<br/>read"]
    imsg --> app["Messages.app<br/>send"]
```

The facade is the only network-facing component. The bridge is not a general-purpose Messages server: it strips or rejects unsupported parameters and forces sends through the normal AppleScript transport. See [Architecture](docs/architecture.md) and [Security model](docs/security.md).

## Scope

iMessage Proxy currently supports:

- health checks that exercise the `imsg` read path;
- listing chats and reading bounded message history;
- cursor-based polling for new messages;
- sending text to an explicitly allowed address or chat;
- checking a sent message's status;
- an immediate-send, Sipgate-shaped compatibility endpoint.

iMessage Proxy intentionally does **not** provide anonymous access, Internet exposure, attachments, webhooks, reactions, contact access, remote URL fetching, message mutation, typing indicators, private framework injection, or scheduled sending.

## Requirements

- a Mac supported by [Apple Container](https://github.com/apple/container), with the Container CLI installed and running;
- a non-root macOS GUI user signed in to Messages;
- Xcode Command Line Tools (`xcode-select --install`);
- [`imsg`](https://github.com/openclaw/imsg) installed for that user;
- Git, Make, OpenSSL, `jq`, and `curl`;
- private DNS and a LAN/VPN path between clients and the Mac;
- a reviewed Caddy image pinned by SHA-256 digest.

iMessage Proxy has not yet published a broad macOS compatibility matrix. Treat upgrades to macOS, Apple Container, `imsg`, or Caddy as security-sensitive changes and re-run the smoke tests.

## Quick start

Clone and verify the source:

```bash
git clone https://github.com/mglaeser/imessage-proxy.git
cd imessage-proxy
make build
make test
```

Create a local configuration from the public example and replace every placeholder:

```bash
cp config/imessage-proxy.env.example imessage-proxy.env
chmod 600 imessage-proxy.env
${EDITOR:-vi} imessage-proxy.env
set -a
. ./imessage-proxy.env
set +a
```

Prepare local state, validate the native bridge, and inspect the generated LaunchAgent before installing it:

```bash
bin/imessage-proxy prepare
bin/imessage-proxy build-host
bin/imessage-proxy check-host
bin/imessage-proxy agent-install
bin/imessage-proxy agent-status
```

Then create the private host route, generate a caller password hash, and start the facade. Each operation prints its prerequisites; do not bypass its confirmation gates.

```bash
bin/imessage-proxy host-route-create
bin/imessage-proxy hash-password
bin/imessage-proxy create
bin/imessage-proxy status
```

The complete, review-first procedure is in [Operations](docs/operations.md). Existing installations extracted from another administration repository should follow the [migration guide](docs/migration-from-administration.md).

## 0.2 compatibility contract

Version 0.2.0 adopts the descriptive `imessage-proxy` project, repository, command, source, configuration, and `IMESSAGE_PROXY_*` environment names. To keep existing private CAs, macOS TCC grants, LaunchAgents, containers, and migration receipts valid, this transition release deliberately retains these runtime identities:

- deprecated command shim `bin/stella`;
- deprecated `STELLA_*` environment aliases;
- runtime home `~/Library/Application Support/Stella`;
- LaunchAgent label `io.github.mglaeser.stella.bridge`;
- runtime bridge binary `stella-bridge`;
- Apple Container name `stella`; and
- host route `stella-host.container.internal`.

The source and public build artifact are named `imessage-proxy-bridge`, while `build-host` installs the runtime binary as `stella-bridge` for TCC continuity. Version 0.2.0 performs no automatic runtime-state or identity migration. Do not rename or move those resources during an upgrade; use the canonical names for new configuration and automation, and treat conflicting canonical and legacy environment values as an error.

## First request

Export the private API origin and use the Caddy root CA—never `curl -k`. `curl` prompts for the caller's password:

```bash
export IMESSAGE_PROXY_URL=https://messages.example.internal:9443

curl \
  --cacert /secure/path/imessage-proxy-root.crt \
  --user automation-a \
  "$IMESSAGE_PROXY_URL/healthz"
```

Read a bounded page after cursor zero:

```bash
curl \
  --cacert /secure/path/imessage-proxy-root.crt \
  --user automation-a \
  --header 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":"poll-1","method":"messages.after","params":{"since_rowid":0,"limit":20}}' \
  "$IMESSAGE_PROXY_URL/v1/rpc"
```

For production-like automation, store the returned cursor durably and use a distinct credential for every client. See the full [API reference](docs/api.md) and machine-readable [OpenAPI 3.1 description](openapi.yaml).

## Repository layout

```text
.
├── bin/imessage-proxy                       # lifecycle and deployment manager
├── bin/stella                               # deprecated compatibility shim
├── config/Caddyfile                         # authenticated TLS facade
├── config/io.github.mglaeser.stella.plist.in # retained runtime identity
├── config/imessage-proxy.env.example
├── docs/                                    # design and operator guides
├── openapi.yaml                             # machine-readable HTTPS API contract
├── src/imessage-proxy-bridge.m              # native loopback bridge
└── tests/test-imessage-proxy-bridge.sh       # integration-focused shell tests
```

## Project status

The current version is **0.2.0** and the maturity level is **Alpha**. Interfaces, state layout, and operator commands may change before 1.0. Changes are recorded in the [changelog](CHANGELOG.md), and intended milestones live in the [roadmap](ROADMAP.md).

## Community and security

- Read [Contributing](CONTRIBUTING.md) before opening a pull request.
- Use [GitHub Discussions](https://github.com/mglaeser/imessage-proxy/discussions) for usage questions.
- Report vulnerabilities privately according to [Security](SECURITY.md)—not in a public issue.
- Project decisions and maintainer responsibilities are described in [Governance](GOVERNANCE.md).
- Participation is governed by our [Code of Conduct](CODE_OF_CONDUCT.md).

## License and non-affiliation

Licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attribution information.

iMessage Proxy is an independent open-source project. It is not affiliated with, endorsed by, or sponsored by Apple Inc. iMessage and macOS are trademarks of Apple Inc. Use of those names describes interoperability only.
