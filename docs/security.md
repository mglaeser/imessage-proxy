# Security model

What this service protects, what it does not, and which claims you can check
yourself.

## Shape

One process. `imessage-proxy-server` runs as a LaunchAgent of the signed-in
Messages user, binds `127.0.0.1` on one port, serves the console and `/api`, and
spawns the pinned `imsg` for reads and sends. There is no second daemon, no
certificate authority client, and no public listener.

## What it protects

| Boundary | Control |
| --- | --- |
| Any API request | Hash-based key lookup, expiry, immediate revocation, scopes, per-source and per-key rate limits |
| Browser console | Same-origin policy pinned to the loopback origin the server itself serves; CSP, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `Cache-Control: no-store` |
| Sending | Explicit recipient allowlist, the named transport and no fallback to the other, a sender identifier on every message, per-send idempotency |
| Reading | Bounded result sizes; no attachment paths, no arbitrary database access; declinable for the whole installation |
| Dependency | `imsg` pinned by SHA-256 and re-verified before every spawn |
| Audit | Privacy-safe metadata only; no message bodies, no recipients |

Request and response caps are enforced natively: 16 KiB of headers, 64 KiB of
body, and per-request read, send and socket timeouts.

## Three claims you can verify

These replace equivalents that earlier releases stated about a two-process
design. Each is checkable on your own machine.

**It listens only on loopback.** The bind address is a compile-time constant, no
setting can widen it, and the server calls `getsockname()` after `listen()` and
refuses to serve if the result is anything but `127.0.0.1` on the configured
port. Check it:

```bash
lsof -nP -iTCP -sTCP:LISTEN | grep imessage-proxy
```

Every line must read `127.0.0.1:PORT`. A `*:PORT` or `0.0.0.0:PORT` line means
something is wrong; stop the service and report it.

**The console cannot be driven from another origin.** The allowed browser origin
is derived from the port the server bound, not configured separately, so the two
cannot drift apart. A request carrying any other `Origin` is refused `403`.

**Console assets need no credential; the API always does.** The server answers
exactly four request paths — `/`, `/index.html`, `/app.js`, `/styles.css` — from
a fixed table of three filenames, before authentication, because a browser
cannot present a bearer token for its own `<script>` tag. No part of a request
is ever joined into a filesystem path, so traversal is not filtered but
unrepresentable. Everything under `/api` runs only after the bearer check:

```bash
curl -si http://127.0.0.1:8765/api/status | head -1   # HTTP/1.1 401
curl -si http://127.0.0.1:8765/ | head -1             # HTTP/1.1 200
```

## What it does not protect

**Any local process or user account on this Mac can reach the port.** A loopback
TCP socket has no owner check. The bearer key is the access control, not the
transport. Earlier releases used a `0600` Unix socket, where the kernel
restricted connections to your own processes; that boundary is gone, and it is
the direct cost of the service being reachable from a browser. On a Mac with
untrusted local users, treat the key as the only thing standing between them and
your messages.

**Transport is plain HTTP.** Nothing is encrypted on the loopback interface. If
you put a TLS terminator in front, HSTS, certificate lifecycle and any public
access control are its responsibility. The server deliberately does not send
`Strict-Transport-Security`: user agents ignore it over plain HTTP, and
asserting it for a loopback origin would poison your real hostname later.

**Full Disk Access is broad.** The grant lets the server read the whole Messages
database. Grant it to the exact binary the installer names and nothing else. It
is also the one macOS permission that is never prompted for, so nothing can
acquire it behind your back — and nothing can be repaired without you. An
installation that does not want to hand over the database can decline it and
send only; the read routes then answer `409 messages-read-disabled` and sending
is untouched.

**The sender identifier is attribution, not authentication.** Every message a key
sends ends with that key's two-to-eight-letter marker, so a recipient can tell
which automation wrote to them. It proves nothing to them: anyone able to type
those characters can imitate it, here or from any other phone. What it does
guarantee is on this side of the boundary — a key cannot quietly drop its own
marker. Only an `admin` key may suppress it, one message at a time, and any
other key that asks is refused rather than silently obeyed, so a caller is never
told a message went out unmarked when it did not.

**An SMS is not an iMessage.** `"service": "sms"` hands the text to the carrier:
no end-to-end encryption, delivery and retention by operators, and per-message
cost. The service never chooses that for you — neither transport falls back to
the other — but it will do it when a caller asks for it, so treat `messages:send`
as authority to spend money and to send unencrypted text, not only to write to
allowlisted people.

**A key is a bearer credential.** Anyone holding it has its scopes until you
revoke it. Issue narrow scopes, set short expiries, and revoke from the console
or `DELETE /api/keys/{id}`.

## Reviewing an installation

```bash
imessage-proxy doctor          # dependency pins, permissions, configuration
imessage-proxy server-status   # process, listener ownership, readiness
imessage-proxy server-logs     # what the server itself reported
```

Runtime state lives in `~/Library/Application Support/iMessage Proxy`, mode
`0700`, with the key database and allowlist at `0600`. The reviewed
configuration is `~/.config/imessage-proxy/service.env`.

## Reporting

Report vulnerabilities privately per the [Security policy](../SECURITY.md). Do
not include message bodies, recipients, keys, or private paths in a report.
