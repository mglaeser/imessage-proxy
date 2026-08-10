# Architecture

## Hard minimum

iMessage Proxy uses the smallest practical production design that preserves the
normal macOS Messages permission model and provides public HTTPS:

```text
Internet clients on TCP 80/443
    │
    │ exact router/NAT mapping over IPv4
    │ 80 → host 8080, 443 → host 8443 by default
    ▼
host-native Caddy LaunchAgent in the Messages GUI session
    ├── terminates ACME HTTPS
    ├── serves three static console files
    └── forwards /api over one private Unix socket
            │
            ▼
native REST-server LaunchAgent in the same GUI session
    ├── authenticates/scopes API keys in SQLite
    ├── validates explicit REST resources
    └── executes fixed imsg commands
            │
            ├── read-only Messages database access
            └── normal Messages.app AppleScript sends
```

There is no authentication sidecar, application runtime for the console, VM,
container, socket relay, filesystem mount, published container port, internal
TCP bridge, synthetic host DNS, packet-filter redirect, copied Messages database,
or second message store. The REST server must remain native because Messages
database access and Messages.app Automation belong to the signed-in macOS GUI
session. Caddy is also host-native because it can connect to the same socket
directly; adding a virtualization layer would add lifecycle and networking work
without creating a useful security boundary for this service.

## Components and trust

| Component | Runs as | Responsibility | Important boundary |
| --- | --- | --- | --- |
| Caddy | Messages GUI user LaunchAgent | ACME TLS, security headers, static console, bounded `/api` forwarding | Sees bearer keys in transit; must not receive Full Disk Access or Automation |
| Native server | Same GUI user LaunchAgent | HTTP parsing, API-key auth/scopes, rate limits, adapters, normalization, audit | Owns the private socket and is the only service process granted Messages permissions |
| SQLite file | User-owned private state | Key hashes, scopes, expiry/revocation, audit metadata, send idempotency | Contains no plaintext API keys or message content |
| Staged `imsg 0.13.4` | Child of native server | Reviewed local reads and normal AppleScript text sends | Exact executable is SHA-256-pinned before use; callers cannot choose commands or database paths |
| Browser console | Static same-origin files | Status and key lifecycle | Keeps a credential only in the current tab's `sessionStorage` |

Caddy and the native server share one Unix user and therefore one ordinary
filesystem/account boundary. The Unix socket prevents the REST server from
becoming a TCP listener; it does **not** isolate Caddy from other files readable
by that user. A compromised Caddy process must be treated as a compromise of the
service's user-level trust domain. TCC still provides a distinct macOS privacy
control: only the exact REST-server binary should receive Full Disk Access and
Messages Automation.

High host ports let Caddy run without root. Neither LaunchAgent requires `sudo`,
a privileged port entitlement, or a packet-filter redirect.

## Private Unix socket

The native server listens only at:

```text
~/Library/Application Support/iMessage Proxy/run/server.sock
```

The socket parent is private, non-symlinked, and owned by the Messages GUI user.
The server rejects unsafe stale-path replacement. Caddy connects to that exact
host path directly. No socket is copied, mounted, forwarded, published, or
relayed, and the native process has no TCP listener.

The socket keeps the native HTTP parser off the network and gives the lifecycle
CLI one readiness boundary. Because both processes have the same UID, its mode is
defense in depth against other local accounts rather than process isolation.

## Public network path

The supplied edge accepts IPv4 only. Caddy binds to either an explicitly assigned
host IPv4 address or `0.0.0.0` and uses unprivileged host ports, defaulting to:

```text
HTTP:  8080
HTTPS: 8443
```

The external router or NAT device must preserve the standard public service:

```text
external TCP 80  → Mac IPv4 TCP 8080
external TCP 443 → Mac IPv4 TCP 8443
```

NAT operates on the public address and port, not the HTTP hostname. This mapping
therefore claims public TCP 80/443 for every DNS name on that IPv4 address and
cannot coexist with a different ingress that already owns those ports.

The public hostname has an `A` record for the intended ingress. The built-in
deployment does not support a public `AAAA` path. Publishing one could route
clients around the reviewed IPv4 mapping, so it must remain absent unless an
independent IPv6 design is reviewed and implemented.

ACME validation, the HTTP-to-HTTPS redirect, and ordinary clients depend on the
external 80/443 mapping. Caddy's generated redirects are disabled. Outside
Caddy's transient ACME HTTP-01 challenge handling, the explicit HTTP route
redirects only the configured hostname with `308`; it builds `Location` from
that reviewed hostname and the request URI, so the host's internal HTTPS port
can never appear. Other HTTP Host values receive `421`. Both routed responses
remove `Server`, `Alt-Svc`, and cross-origin headers and carry the same no-store,
noindex, and security-header policy as HTTPS responses. An upstream CDN, tunnel,
reverse proxy, or TLS terminator would change the source-address, certificate,
logging, and origin boundaries and is not part of this architecture.

## Request path

1. A client connects to the dedicated hostname on public TCP 443.
2. The router maps that connection to Caddy's configured host IPv4 HTTPS port.
3. Caddy terminates TLS and applies header, body, and time bounds plus strict
   security response headers.
4. Only `/api` and `/api/*` are forwarded to the native Unix socket. Static
   console files are served directly; other paths fail closed.
5. Caddy removes client-supplied cookies and `X-API-*` headers, supplies the
   observed peer address, and preserves the original bearer header.
6. The native server parses a bounded HTTP/1 request and validates the exact
   `Authorization: Bearer …` credential against a SHA-256 digest in SQLite.
7. It checks expiry, revocation, route scope, origin policy, and rate limits.
8. The route adapter validates only its documented path/query/body fields and
   constructs a fixed `imsg` argument vector without a shell.
9. The child process runs inside a deadline and isolated process group with
   bounded stdout/stderr. A send has one end-to-end 180-second budget;
   idempotency work and chat validation consume that same budget rather than
   starting independent nested deadlines. The edge waits 195 seconds for native
   response headers, its connection write deadline is 200 seconds, and the
   native LaunchAgent has 210 seconds to exit, preserving a deliberate outer
   timeout margin at every layer. Every JSON-line record must parse and match the
   adapter's expected shape.
10. The server removes host paths and private routing fields, then returns its
    own REST schema. It never relays command diagnostics to the caller.
11. An audit event records request ID, key ID, operation, outcome, status, and
    duration—not message content, recipients, conversations, credentials, or
    hashes.

## Authentication and authorization

The edge does not replace client identity with a shared internal secret. Caddy
preserves the original bearer header over the socket, and the native server
authenticates every API request directly.

Keys contain 256 random bits and are revealed only at creation. SQLite stores a
32-byte SHA-256 digest plus metadata and normalized scopes. High-entropy keys do
not need a slow password hash; a fast digest permits bounded lookup without
making an offline guessing attack practical. Authentication checks current state
on every request, so revocation is immediate.

Three scopes keep the model understandable:

- `messages:read` for every read resource;
- `messages:send` for exact-allowlist text sends; and
- `admin`, which includes all operations and key lifecycle management.

The final active administrator cannot be revoked. A local bootstrap command is
available only when no active administrator exists.

## Durable send idempotency

A remote timeout can occur after Messages.app has accepted a command. Blindly
retrying would risk a duplicate. `POST /api/messages` therefore requires an
`Idempotency-Key`.

Before invoking `imsg`, the server stores the authenticated key ID, idempotency
value, canonical request digest, operation ID, and `pending` state. It then
records one of:

- `accepted`, with the normalized response;
- `failed`, when execution conclusively failed; or
- `ambiguous`, when the process outcome cannot prove whether Messages accepted it.

The same key/body returns the stored result. The same key with different content
returns a conflict. Pending or ambiguous records are never executed again
automatically. This state lives beside the API-key database so a process restart
cannot erase the duplicate-send boundary.

## Data ownership

iMessage Proxy does not copy, cache, or index conversation content. Read requests
open the existing Messages database through `imsg`; response bodies live only for
the request lifetime. The service's SQLite file contains operational metadata:

- API-key digests and lifecycle fields;
- scopes;
- privacy-preserving audit events; and
- idempotency request digests and normalized outcomes.

It never stores plaintext keys, message bodies, recipients, chat identifiers,
attachment paths, or complete dependency output. Caddy receives plaintext bearer
keys transiently because it terminates TLS. Access logging is deliberately not
configured, but Caddy remains a trusted process because it handles live requests
and shares the same macOS user.

## Public edge

Caddy's native executable is pinned by exact version and independently reviewed
SHA-256. It runs as the non-root Messages GUI user with its admin API disabled.
Its configuration:

- uses the dedicated hostname and normal public ACME certificate;
- uses an explicit, fixed-host HTTP-to-HTTPS redirect and rejects other HTTP
  Host values without reflecting them;
- serves the dependency-free console and proxies only `/api`;
- listens on configurable unprivileged IPv4 host ports;
- removes server/protocol advertisement headers and applies no-store, noindex,
  HSTS, a strict content-security policy, clickjacking denial, no-sniff,
  no-referrer, and a restrictive permissions policy;
- rejects API bodies above 64 KiB and configures a 12 KiB header budget so the
  Go parser's fixed read tolerance remains close to a 16 KiB effective ceiling;
- removes request objects and URIs from runtime error logs and returns a
  privacy-safe problem response for routed edge failures;
- serves only HTTP/1.1 and HTTP/2 over TCP, with HTTP/3/UDP disabled; and
- leaves source/key-aware rate limiting to the native server.

No cross-origin policy is enabled. Browser requests with an `Origin` must match
the exact configured public origin. API keys are explicit headers rather than
ambient cookies, but same-origin enforcement reduces browser abuse and keeps the
console's threat model small.

## Capability boundary

The adapters cover the stable `imsg 0.13.4` commands that fit a remote service:
chats, chat detail, bounded history, scrubbed chat-background state, future
scheduled rows, statistics, and plain iMessage text sending.

The server does not expose arbitrary command selection. It excludes infinite
watch processes, Contacts-assisted whois/identity lookup, host file paths,
uploads, carrier SMS, UI automation reactions, private-framework features, code
injection, read/typing mutations, rich content, message mutation, and chat
administration. Adding any of those requires architecture and threat-model
review.

The dependency's cross-chat text search is excluded because version 0.13.4 can
request and enumerate Contacts while running it and provides no no-Contacts
mode. A remotely triggered address-book prompt or lookup is outside this service's
minimum TCC and data boundary.

## Startup and shutdown order

Start inside-out:

1. validate private state and pinned native dependencies;
2. install or start the server LaunchAgent, explicitly re-enabling its launchd
   label, and prove its socket responds;
3. install or start the Caddy edge LaunchAgent, explicitly re-enabling its label,
   and prove its listeners; and
4. run authenticated end-to-end checks through the external IPv4 path.

Stop outside-in:

1. stop Caddy so no new public work arrives;
2. let in-flight native work finish or reach its bounded outcome; and
3. restart or stop the server only after the public edge is quiescent.

The lifecycle CLI refuses a server stop or restart while the edge is loaded. Each
stop command disables its exact GUI launchd label before unloading it, so the
stopped service stays stopped across logout/login and reboot without deleting its
plist or state. Install, start, and restart explicitly re-enable the relevant
label. A server restart recreates the socket, so validate it before starting
Caddy again.

## Fresh-state boundary

Version 1.0 intentionally starts in
`~/Library/Application Support/iMessage Proxy`. It does not discover, copy,
rename, reinterpret, or delete another installation's runtime state, credentials,
certificates, permissions, routes, or receipts. Git history preserves earlier
implementation evidence; current code has one identity and one topology.
