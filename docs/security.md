# Security model

iMessage Proxy provides remote access to highly sensitive data and the ability to send as a signed-in Messages user. Its security model assumes a well-administered Mac and a trusted private network, while still treating each API client as separately revocable.

## Assets

iMessage Proxy protects:

- message text, metadata, participants, and chat history;
- the ability to send through the user's Messages identity;
- client passwords and hashes;
- the bridge bearer token;
- the private Caddy certificate authority and key;
- the macOS account, Messages database, and GUI session;
- audit records that reveal caller activity and timing.

## Adversaries considered

The design considers:

- an unauthenticated device on the LAN or VPN;
- a former or compromised API client;
- malformed and oversized requests;
- attempts to invoke broader `imsg` capabilities or forbidden parameters;
- attempts to bypass recipient restrictions;
- accidental exposure through configuration, logs, permissive file modes, or an all-interface bind;
- compromise of the Caddy facade with no direct macOS account access.

iMessage Proxy does not claim to defend against a fully compromised macOS account, an attacker with root or physical host control, a malicious dependency running as the Messages user, or mutually hostile users sharing the same Mac.

## Controls by boundary

| Boundary | Controls |
| --- | --- |
| Network to Caddy | Explicit private-interface publish, private-range source filter, TLS, individual bcrypt-backed Basic Auth credentials, exact routes/methods, 64 KiB body cap |
| Caddy to bridge | Separate random bearer token, caller identity forwarding, bounded connection/response timeouts, container host route |
| Bridge listener | IPv4 loopback-only bind, constant-time token comparison, bounded headers/body/socket lifetime/concurrency, no query strings or chunked bodies |
| Bridge policy | Five exact RPC methods, method-specific parameter allowlists and limits, forced attachment/reaction settings, exact outbound target allowlist, forced AppleScript sends |
| Bridge to `imsg` | One sanitized JSON-RPC request over stdio, execution timeout, 4 MiB output limit, JSON-only response selection |
| Runtime state | User-owned private directories, mode-0600 secrets, separate source checkout, non-root LaunchAgent, exact live loopback-listener and authenticated configuration-digest proofs |
| Audit | Caller, method, status, and duration only; inputs and recipients are omitted |

No single row is sufficient alone. In particular, private IP filtering is defense in depth—not authentication—and a bearer token does not replace the method and target policy.

## Outbound target policy

Sending is disabled until an operator adds an exact target to `allowed-targets.txt`. Supported forms are a direct phone/email-style address, `chat_id:NUMBER`, `chat_identifier:VALUE`, or `chat_guid:VALUE`.

The simple `/v2/sessions/sms` endpoint always requests iMessage delivery. The
advanced `/v1/rpc` `send` method can explicitly request `auto` or carrier `sms`
instead. Authentication is currently not route- or method-scoped: every valid
client can use that advanced method and the deployment-wide target allowlist.
Grant a credential only when that complete capability is acceptable.

The literal `*` permits every target and materially changes the threat model. Avoid it. If a broad automation use case appears to require `*`, reconsider whether iMessage Proxy is the right boundary and document the exception outside the repository.

Read methods are not restricted by the send-target list. Any authorized API client can potentially read private conversations exposed by the allowlisted read methods. Grant credentials only to clients that may read that data.

## macOS permissions

Run iMessage Proxy as the non-root GUI user signed in to Messages. Grant Full Disk Access only to the built `stella-bridge` binary after inspecting its path and signature. Approve Messages Automation only when performing an intentional send test.

Keep System Integrity Protection and TCC enabled. iMessage Proxy does not require private-framework injection, SIP changes, a root daemon, or broad filesystem permissions for the Caddy container. A request to weaken these protections is a stop condition.

Rebuilding or relocating the bridge can affect TCC identity. Re-check permissions after an upgrade rather than copying a database or broadly granting terminal applications permanent access.

## Credentials and trust

- Use a unique high-entropy password for each client.
- Store only Caddy-compatible password hashes in `users.caddy`.
- Never reuse a third-party API credential.
- Transfer the private root CA over an authenticated channel; do not send its private key.
- Never copy `bridge.token` into a client, shell history, issue, or repository.
- Keep `facade.env`, the Caddy data directory, and backups private because they contain authentication or CA material.
- Revoke clients independently and reload the facade after changing its user file.

Basic Auth is safe only inside correctly verified TLS. `curl -k`, disabled hostname validation, or a casually distributed private CA turns credentials and conversations into interception targets.

## Network placement

Publish the facade only on a stable private interface and private DNS name. The facade admits Caddy's built-in private ranges plus RFC 6598 (`100.64.0.0/10`) for authenticated CGNAT/VPN peers; every caller still needs its own credential. Do not add public DNS, router port forwarding, generic reverse tunnels, public ingress, CDN proxying, or Internet-facing load balancers.

VPN access is acceptable only when the VPN authenticates devices/users, preserves an intended private source address, and restricts routing to authorized clients. Host firewall and network segmentation remain recommended even though Caddy authenticates every request.

Apple Container's host-route mechanism is part of the trusted path and can change across host upgrades or restarts. Creating the localhost route disables iCloud Private Relay, and a Mac restart removes the associated packet-filter rule. Refresh and retest the exact mapping using iMessage Proxy's confirmed operation; an uncertain route state is not proof that it is absent. Do not automate an unobserved delete/recreate cycle or replace loopback binding with `0.0.0.0` to work around routing trouble.

## Dependencies and supply chain

- Obtain iMessage Proxy from `https://github.com/mglaeser/imessage-proxy`; resolve the reviewed tag to an independently recorded full commit, and verify the release archive against an independently recorded digest and provenance before deployment.
- Review release notes and diffs before upgrading Alpha software.
- Build the native bridge from the checked-out source with the local Apple toolchain.
- Use the official Caddy image pinned to an immutable SHA-256 digest, not a floating tag.
- Install `imsg` from a trusted upstream channel and re-run API tests on update.
- Protect the repository with required review and CI, especially for `src/`, `bin/`, `config/`, and workflows.
- Treat changes to dependencies, build flags, install paths, LaunchAgent identity, or Caddy routing as security-sensitive.

## Data retention and logging

iMessage Proxy does not maintain a second message database. Reads come from the existing Messages database through `imsg`, and API responses are not cached by the bridge. Caddy and client software may have their own logging or buffering; configure them not to record Authorization headers or bodies.

Native audit lines intentionally contain only a sanitized client ID, allowed/rejected method, HTTP status, and duration. Before sharing logs, still review them for usernames, paths, hostnames, and timestamps that may be sensitive.

## Known limitations

- The project is Alpha and does not yet have an independent security audit or broad host compatibility matrix.
- Client authorization is coarse: a valid facade client can use every read method and every target allowed globally. There are currently no per-client scopes.
- The native HTTP implementation is intentionally small and supports a limited subset of HTTP/1.1.
- Caddy's internal CA requires manual, secure trust distribution and lifecycle planning.
- The availability and semantics of `imsg` and macOS Messages can change outside iMessage Proxy's release cycle.
- Private-network filtering relies on the source address seen by Caddy and must be retested when proxies or VPN topology change.
- iMessage Proxy does not provide delivery exactly-once semantics. Clients must reconcile ambiguous sends.

## Deployment acceptance checklist

- [ ] The source revision and Caddy digest were reviewed and pinned.
- [ ] The Mac, GUI user, private interface, DNS name, and VPN/LAN path are explicit.
- [ ] The native bridge is confirmed listening only on `127.0.0.1`.
- [ ] The facade is unreachable from untrusted networks and requires valid credentials.
- [ ] Every client has a distinct password and trusts only the intended private CA.
- [ ] The send allowlist contains only agreed test targets and does not contain `*`.
- [ ] A forbidden method, forbidden parameter, and unlisted recipient were each rejected.
- [ ] The consenting recipient confirmed that the test arrived from the intended Messages sender identity shown by their client.
- [ ] Logs contain no bodies, message text, recipient, raw password, or token.
- [ ] Full Disk Access and Automation apply only to the intended user and binary.
- [ ] Restart, upgrade, credential revocation, and incident-stop procedures were rehearsed.

## Vulnerability reporting

Report suspected vulnerabilities privately using [SECURITY.md](../SECURITY.md). Never include real conversations or credentials in a report.
