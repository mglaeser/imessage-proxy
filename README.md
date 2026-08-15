<!-- markdownlint-disable MD033 -->
<p align="center">
  <img src="docs/assets/imessage-proxy.svg" width="112" height="112" alt="iMessage Proxy: a message bubble handing off to a forward chevron">
</p>
<h1 align="center">iMessage Proxy</h1>
<p align="center">
  <strong>A small, security-first REST API and console for Messages.app.</strong>
</p>
<p align="center">
  <a href="https://github.com/mglaeser/imessage-proxy/actions/workflows/ci.yml"><img src="https://github.com/mglaeser/imessage-proxy/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <a href="https://github.com/mglaeser/imessage-proxy/releases"><img src="https://img.shields.io/github/v/release/mglaeser/imessage-proxy?display_name=tag&amp;sort=semver" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/mglaeser/imessage-proxy" alt="Apache-2.0 license"></a>
  <a href="docs/install.md"><img src="https://img.shields.io/badge/platform-macOS-111827?logo=apple" alt="Platform: macOS"></a>
</p>
<!-- markdownlint-enable MD033 -->

One process on your Mac reads conversations and sends messages — iMessage or
SMS — over a REST API, with a browser console for day-to-day use. It listens on
`127.0.0.1` unless you name another address, authenticates every request with a
scoped revocable key, sends only to recipients you have allowlisted, and marks
every message it sends with the key that sent it.

## Get started

On the Mac that is signed in to Messages:

```bash
curl -fsSL https://raw.githubusercontent.com/mglaeser/imessage-proxy/main/scripts/install.sh | bash
```

It asks two questions — whether to send a test message, and whether to read your
Messages database as well — then prints your administrator key and the console
URL. Sending never needs Full Disk Access; only reading does, and the installer
prints those steps if you say yes.

Answer both on the command line and nothing is asked, which is what an
unattended install needs. `--key-file` puts the key somewhere private instead of
on stdout:

```bash
curl -fsSL https://raw.githubusercontent.com/mglaeser/imessage-proxy/main/scripts/install.sh | bash -s -- \
  --no-send-test --messages-read --key-file "$HOME/imessage-proxy-admin.key"
```

Full Disk Access still has to be granted by hand afterwards: macOS has no way to
grant it from a script.

## Send your first message

Allow one recipient, then send to them:

```bash
imessage-proxy targets add person@example.net

curl --fail-with-body \
  --request POST \
  --header "Authorization: Bearer $IMESSAGE_PROXY_API_KEY" \
  --header "Idempotency-Key: $(uuidgen)" \
  --header 'Content-Type: application/json' \
  --data '{"recipient":"person@example.net","text":"Hello from iMessage Proxy"}' \
  http://127.0.0.1:8765/api/messages
```

```json
{"operation_id":"7B740A82-2149-43DB-BE37-6F3D28711A47","state":"accepted"}
```

`202 Accepted` means Messages.app accepted the command; it is not delivery
confirmation. Each logical send needs an idempotency key.

Two things about that message are worth knowing before the first one goes out.
It went by iMessage because that is the default; add `"service":"sms"` to send
it over the carrier instead, and nothing ever falls back from one to the other.
And it arrived tagged with the sending key's identifier, so whoever receives it
can tell which automation wrote to them: a key identified as `aut` ends its
messages with `🔖aut` over iMessage and `^aut` over SMS. The administrator key
the installer prints is normally `adm`, so that first message ends with `🔖adm`
— unless a revoked administrator still holds it, in which case the next free
identifier is assigned and `GET /api/keys` reports it. Only an
administrator key can send without the tag, one message at a time. See
[the sender identifier](docs/api.md#the-sender-identifier).

## Console and API

Open **<http://127.0.0.1:8765>** and paste an administrator key. The console
shows service health, runs every endpoint with typed inputs, and manages keys.
Your key lives only in that tab's `sessionStorage`; the page uses no cookies,
analytics, third-party assets, or service worker.

| Method | Resource | Scope | Purpose |
| --- | --- | --- | --- |
| `GET` | `/api/status` | any valid key | Service and Messages readiness |
| `GET` | `/api/chats` | `messages:read` | List recent or unread chats |
| `GET` | `/api/chats/{id}` | `messages:read` | Chat metadata and participants |
| `GET` | `/api/chats/{id}/messages` | `messages:read` | Bounded chat history |
| `GET` | `/api/chats/{id}/background` | `messages:read` | Scrubbed background state |
| `GET` | `/api/scheduled-messages` | `messages:read` | Future Send Later rows |
| `GET` | `/api/statistics/messages` | `messages:read` | Message and media statistics |
| `POST` | `/api/messages` | `messages:send` | Send an allowlisted iMessage or SMS |
| `GET` | `/api/targets` | `admin` | List who may be messaged |
| `PUT` | `/api/targets` | `admin` | Replace who may be messaged |
| `GET` | `/api/audit-events` | `admin` | Bounded privacy-safe request metadata |
| `GET` `POST` | `/api/keys` | `admin` | List keys, or create and reveal one once |
| `GET` `DELETE` | `/api/keys/{id}` | `admin` | Read metadata, or revoke immediately |

Examples and error semantics: [API](docs/api.md) and the
[OpenAPI 3.1 contract](openapi.yaml).

## Requirements

- macOS, with a non-root GUI user signed in to Messages;
- Full Disk Access for the native server binary, which the installer names —
  only for reading conversations, which an installation may decline and still
  send;
- Messages Automation permission, requested at your first send;
- Xcode Command Line Tools and `curl`; and
- [`imsg`](https://github.com/openclaw/imsg) **0.13.4**, pinned by digest and
  installed for you. Supply your own reviewed executable with `--imsg`.

## Everyday commands

```bash
imessage-proxy server-status    # is it healthy?
imessage-proxy server-logs      # what did it say?
imessage-proxy api-key bootstrap-admin --name laptop   # issue another key
imessage-proxy server-restart --confirm 'RESTART IMESSAGE PROXY SERVER'
```

`imessage-proxy --help` lists every action. Change the port by editing
`IMESSAGE_PROXY_PORT` in `~/.config/imessage-proxy/service.env` and restarting.

## Uninstall

Remove the service and keep your keys, allowlist and logs:

```bash
curl -fsSL https://raw.githubusercontent.com/mglaeser/imessage-proxy/main/scripts/uninstall.sh | bash
```

Remove everything, including keys, the allowlist and logs:

```bash
curl -fsSL https://raw.githubusercontent.com/mglaeser/imessage-proxy/main/scripts/uninstall.sh | bash -s -- --purge --confirm 'DESTROY IMESSAGE PROXY STATE'
```

When the script is piped to `bash`, its options have to come after `-s --`;
without that separator `bash` reads them as its own and the script never sees
them. `--purge` also needs the exact phrase above, and asks once more on the
terminal before destroying anything. Add `--yes` to skip that question, or
`--dry-run` to see what any run would remove without removing it.

## Reaching it from elsewhere

The service binds loopback unless you name another address — `install.sh --bind
ADDRESS`, or the question the guided install asks. Doing so puts the API on that
network in plain HTTP, with the API key the only thing protecting it, so it suits
a network you trust and nothing more. For anything else, put your own TLS
terminator in front of `127.0.0.1:8765` — a reverse proxy, a container, or a
tunnel — and make it responsible for certificates, HSTS and access control. That boundary is deliberately yours:
shipping it would mean shipping a second daemon, a certificate authority
client, and a public port. See [Install and operate](docs/install.md).

## Scope and non-goals

The 1.0 surface covers stable, non-injected `imsg` capabilities that make sense
across a security boundary: chat discovery, bounded history, scrubbed
chat-background state, scheduled-message inspection, statistics, and text sends
over iMessage or SMS.

It intentionally does not expose live infinite streams, Contacts-assisted
identity lookup, attachment paths or uploads, arbitrary databases, UI-driven
reactions, read receipts, typing indicators, message mutation, chat management,
rich effects, stickers, polls, private frameworks, or code injection. Those need different privacy, streaming, upload, or macOS security
models; they are not hidden generic commands.

Cross-chat text search is excluded too: the pinned dependency couples it to
Contacts access with no no-Contacts mode, so a remote read could trigger a TCC
prompt or enumerate your address book.

## Repository layout

```text
.
├── bin/imessage-proxy                         # lifecycle CLI
├── config/io.github.mglaeser.imessage-proxy.plist.in
├── src/api-key-store.{h,m}                    # SQLite keys, audit, idempotency
├── src/imessage-proxy-server.m                # loopback REST server and console
├── scripts/install.sh                         # one-command install and first run
├── scripts/uninstall.sh                       # guarded removal, state opt-in
├── web/                                       # dependency-free management console
├── openapi.yaml                               # public API contract
└── tests/                                     # native, portable, and lifecycle tests
```

## Community and security

- Read [Contributing](CONTRIBUTING.md) before opening a pull request.
- Use [GitHub Discussions](https://github.com/mglaeser/imessage-proxy/discussions) for usage questions.
- Report vulnerabilities privately per the [Security policy](SECURITY.md), and
  see [Security model](docs/security.md) for what the service does and does not
  protect.
- Decisions and maintainer duties: [Governance](GOVERNANCE.md).
- Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
- Stuck? [Troubleshooting](docs/troubleshooting.md).

Licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for
attribution. iMessage Proxy is independent software, not affiliated with,
endorsed by, or sponsored by Apple Inc. iMessage and macOS are trademarks of
Apple Inc.; their names describe interoperability only.
