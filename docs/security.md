# Security model

iMessage Proxy lets remote callers read private conversations and send as the
signed-in macOS user. Treat the service as a privileged boundary, not a generic
web application. Public exposure is appropriate only when every layer below is
reviewed and tested on the target Mac.

## Protected assets

- the macOS account and Messages identity;
- conversation content and attachment metadata;
- permission to send to approved recipients and chats;
- plaintext API keys in clients and transiently at the TLS edge;
- hashed key, audit, and idempotency state;
- the exact native server binary's Full Disk Access and Automation grants;
- Caddy's ACME account and private certificate keys;
- user-owned configuration, executables, allowlist, and logs; and
- operator recovery access to the Mac, DNS, router/NAT, and firewall.

## Trust boundaries

| Boundary | Controls and limits |
| --- | --- |
| Internet to router/NAT | Dedicated IPv4 `A` path, external TCP 80/443 only, exact mapping to reviewed host ports, firewall and external acceptance |
| Internet to Caddy | Publicly trusted TLS, exact hostname, bounded headers/body/time, strict response headers, no configured access log |
| Caddy to native server | Exact `/api` proxy over one host Unix socket, original bearer header, stripped spoofable peer headers and cookies |
| API request | Hash-based key lookup, expiry, immediate revocation, scopes, same-origin browser policy, per-source/per-key rate limits |
| Route adapter | Exact method/path/query/body schemas, length/range limits, no arbitrary flags or files, exact send allowlist |
| Native server to `imsg` | Staged 0.13.4 binary pinned by SHA-256, direct argv without a shell, fixed database, process-group deadline, bounded JSON output |
| `imsg` to Messages | Read-only database access and published AppleScript sending with SMS fallback disabled |

No row is sufficient by itself. A private socket does not replace client
authentication, and a strong API key does not replace route or send-target
policy.

## Same-user edge boundary

Caddy and the native server are LaunchAgents of the same non-root Messages GUI
user. This is the hard-minimum topology, not process isolation:

- Caddy necessarily sees plaintext bearer keys and API responses while
  terminating TLS;
- the Unix socket prevents a native TCP listener but does not isolate either
  process from the other at the Unix-user boundary;
- user-only modes protect state from other local accounts, not from a compromised
  process running under the same UID; and
- staged executable/configuration checks detect reviewed drift during lifecycle
  operations, but they are not a runtime sandbox.

Treat compromise of Caddy as compromise of the service's user-level trust domain.
Rotate exposed keys, inspect user-owned state, and rebuild from reviewed artifacts.
The residual distinction is TCC: Caddy must not be granted Full Disk Access or
Messages Automation. Grant those permissions only to the exact native server
binary. Do not run either process as root.

Caddy listens on unprivileged host ports (8080/8443 by default). High ports avoid
root and packet-filter privileges; they do not make the public service less
reachable once the router maps external TCP 80/443 to them.
That mapping is exclusive for the public IPv4 address; DNS hostnames do not
create separate layer-4 port-forwarding slots. A pre-existing public ingress
must be retained behind a separately reviewed shared-edge design or moved only
through an explicit operator decision.

Automatic HTTPS redirects are disabled. Outside Caddy's transient ACME HTTP-01
challenge handling, a dedicated HTTP route uses only the validated
`IMESSAGE_PROXY_API_HOST` to construct an ordinary-port `308` target; it never
trusts the incoming Host header as redirect data and never publishes the
internal `8443` default. Unrecognized Host values fail with `421`. Routed HTTP
and HTTPS responses remove `Server`, `Alt-Svc`, and cross-origin headers and
apply the reviewed no-store, noindex, and browser-security headers. As with any
HTTP server, malformed requests rejected by the parser before routing cannot be
promised the application response schema.

## API keys

Keys use 32 cryptographically random bytes encoded as an `imp_…` base64url value.
The plaintext is returned exactly once. The database stores only its 32-byte
SHA-256 digest, a safe display prefix, metadata, expiry/revocation timestamps, and
scopes.

- Create a distinct key for each client and environment.
- Grant only `messages:read`, `messages:send`, or `admin` as needed.
- Prefer 30-90 day expiries; remote creation is capped at 365 days.
- Store keys in a password manager or the client's secret store, never source,
  screenshots, terminal history, URLs, logs, issue reports, or analytics.
- Rotate by creating and validating the replacement, then revoking the old key.
- Treat `401` uniformly; the response never reveals whether a key was unknown,
  expired, or revoked.
- The final active administrator cannot be revoked. Local recovery creates a new
  short-lived administrator only when no active administrator remains.

Plaintext keys pass through Caddy on every request. Hash-only storage protects a
database copy from immediately revealing credentials; it does not protect keys
from a compromised client, browser tab, Caddy process, or live server process.

## Key database

The SQLite database lives in a user-owned `0700` directory and is `0600`. The
native code rejects symlinks, wrong owners, permissive modes, corrupt schema, and
unexpected schema versions. It uses bound parameters, foreign keys, trusted
schema off, defensive mode, WAL, full synchronization, a busy deadline, and
transactional schema changes.

Authentication queries the database for every request. `last_used_at` writes are
throttled to limit WAL churn. Revocation is a soft update. API listing exposes
only metadata and never a digest.

Backups do not reveal plaintext keys, but they still disclose client names,
scopes, timing, and audit history. Protect them like other private service state.
Stop the edge and native server or use a consistent SQLite backup; never copy
only one live database/WAL file.

## Sending

Sending is disabled until an exact target appears in
`private/allowed-targets.txt`. Supported lines are a canonical direct handle
(`+` plus 7-15 ASCII digits with a nonzero first digit, or one no-whitespace
and no-control-character email-like `@` handle) or
`chat_id:POSITIVE_INTEGER`. The two target types are stored and authorized
separately, contact names are rejected, and chat IDs must not contain leading
zeroes. Blank lines and comments are ignored. No wildcard is accepted.

The request accepts text only and exactly one target. Caller-controlled values
that would begin an `imsg` option token are rejected before execution. The server
forces the `imessage` service and disables automatic carrier fallback. Callers
cannot select a transport, database, local file, region, source address, or
private framework.

A required durable idempotency value prevents automatic duplicate execution.
Ambiguous outcomes remain ambiguous across restarts and are never silently
retried. Operators should inspect Messages.app before choosing to issue a new
logical send.

## Audit privacy

The native service records only operational metadata needed for incident review:
request ID, API-key ID, action, target key ID for key changes, attempted/final
outcome, HTTP status, duration, and a bounded peer-address value supplied by
Caddy.

Audit events and diagnostic logs must never contain:

- API keys, hashes, or authorization headers;
- request or response bodies;
- message text;
- recipients, chat identifiers, participants, or contact names;
- attachment names or paths; or
- raw dependency stdout/stderr.

Sensitive mutations record an attempt before execution and finalize it afterward.
A crash can therefore leave a visible ambiguous attempt instead of erasing the
evidence. Define and periodically apply an audit-retention policy appropriate to
the deployment.

Caddy request access logging is not configured. Its private operational log
rolls at 10 MiB, retains at most five compressed files, and expires files after
30 days. It can still contain hostnames, addresses, certificate events, or parser
errors. The configured encoder removes complete request objects and URI fields,
including query values. Native events use macOS unified logging rather than an
unbounded LaunchAgent file. Review and redact all operational logs before sharing.

## Browser console

The console is public static content with no privileged data embedded. All data
requests still require the key entered by the operator.

- The key is kept only in `sessionStorage` and cleared on logout or `401`.
- Logout invalidates and aborts the current request generation, then clears
  rendered key/status data so late responses cannot repopulate a signed-out page.
- It is never placed in a cookie, URL, form action, persistent browser storage,
  external service, or automatically copied to the clipboard.
- User-controlled names are inserted with `textContent`, never HTML parsing.
- Newly created keys are cleared from memory and the document when the one-time
  reveal is dismissed.
- The page loads no third-party scripts, fonts, images, frames, analytics, or
  service worker.
- A strict content-security policy limits scripts, styles, images, and connections
  to the same origin and disables all other resource classes.

Explicit authorization headers avoid ambient-cookie request forgery, but script
injection would still steal the in-tab key. The content-security policy and
dependency-free UI primarily defend that risk. The service sends no cross-origin
allowance.

## Public exposure

Public mode is opt-in and refuses example/private hostnames. Before enabling it:

1. dedicate a hostname used only by this service;
2. prove its IPv4 `A` record resolves to the intended ingress and publish no
   `AAAA` record;
3. map external TCP 80/443 exactly to the configured Mac IPv4 TCP 8080/8443 (or
   the reviewed replacement high ports);
4. restrict the router and host firewall to that path and prove the native socket
   is not a network listener;
5. verify public ACME issuance without disabling certificate validation;
6. verify the exact `imsg 0.13.4` and Caddy 2.11.4 executables and independent
   SHA-256 digests;
7. bootstrap a short-lived administrator locally and rotate it through the UI;
8. test missing, invalid, expired, revoked, and under-scoped keys from outside;
9. test target denial and one harmless consented send;
10. exercise rate limits and body/header caps; and
11. complete the real-Mac restart and rollback matrix during a maintenance window.

`edge-stop` disables the exact launchd label before unloading it, so the edge
stays stopped across login and reboot even though its plist and certificate state
remain installed. Removing the external router mappings is optional additional
containment, not a substitute for stopping the local listener.

Do not put a CDN, tunnel, load balancer, upstream proxy, public IPv6 path, or
another TLS terminator in front without redesigning trusted peer addresses,
certificate ownership, logging, and origin validation. Do not publish the host
socket, database directory, Caddy admin API, or an unauthenticated health route.

## macOS permissions

Run both processes as the non-root GUI user signed in to Messages. Grant Full
Disk Access only to the exact built and signed `imessage-proxy-server` binary.
Approve Messages Automation only for that server during an intentional test send.

Keep System Integrity Protection and TCC enabled. Stop if any instruction or
dependency asks to disable either, inject into Messages, copy the Messages
database, reset the TCC database, or run a root daemon. Rebuilding or relocating
the native binary can change its TCC identity; re-check its displayed path and
signature after every upgrade. Explicitly confirm that Caddy has not been added
to Full Disk Access or Automation.

## Dependency and supply chain

- Pin the iMessage Proxy source revision and independently verified release digest.
- Pin the exact `imsg 0.13.4` executable by independently reviewed SHA-256;
  the lifecycle CLI stages it and the native server verifies it before use.
- Pin the host-native Caddy 2.11.4 executable by independently reviewed SHA-256.
- Build the native server locally with the Apple toolchain and review its ad-hoc
  signature/path before granting permissions.
- Keep CI actions pinned by full commit and run workflow, source, shell, Markdown,
  API-contract, Caddy, static-analysis, and integration checks.
- Treat changes to dependencies, build flags, plist identities, socket paths,
  database schema, Caddy routes, bind addresses, host ports, or router mappings as
  security-sensitive.

## Known limitations

- Caddy and the native server share a macOS user and are not isolated from each
  other by a sandbox or separate UID.
- The native HTTP/1 parser becomes Internet-reachable through Caddy. Negative
  parser tests and fuzzing remain important.
- In-memory rate-limit buckets reset on native restart and are one defense layer,
  not distributed abuse protection.
- The router/NAT and IPv4-only public path are operator-managed dependencies that
  the repository cannot prove before deployment.
- Hash-only storage cannot protect a key already present in a compromised client
  or TLS edge.
- `202 Accepted` is not delivery confirmation.
- Messages.app, its local database schema, Automation behavior, and TCC prompts
  can change across macOS releases.

## Release checklist

- [ ] Source revision, release digest, and exact Caddy/`imsg` executable digests
  are pinned.
- [ ] Current code contains only the documented runtime identity and routes.
- [ ] The native process owns only the expected Unix socket and no TCP listener.
- [ ] Caddy is a non-root GUI-user LaunchAgent on reviewed unprivileged IPv4 ports.
- [ ] Caddy has neither Full Disk Access nor Messages Automation.
- [ ] External 80/443 map exactly to the reviewed host ports.
- [ ] The hostname has the intended `A` path and no `AAAA` path.
- [ ] Every `/api` resource rejects missing/invalid keys identically.
- [ ] Scope, expiry, revocation, last-admin, target, idempotency, and rate limits pass.
- [ ] Database, WAL, logs, UI, and responses contain no plaintext key at rest.
- [ ] Logs/audit contain no conversation or target data.
- [ ] Public certificate, firewall, and external reachability are observed.
- [ ] Full Disk Access and Automation refer to the exact intended server/account.
- [ ] Harmless read/send, ambiguous-outcome handling, and restart matrix pass.
- [ ] Recovery can quiesce the edge before changing native state.
- [ ] Stop keeps both exact launchd labels disabled across login/reboot, and start
  explicitly re-enables them.

Report suspected vulnerabilities privately using [SECURITY.md](../SECURITY.md).
Never include real conversations, targets, credentials, database copies, or logs
containing private metadata in a report.
