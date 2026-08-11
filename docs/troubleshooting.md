# Troubleshooting

Start with read-only, metadata-only checks. Do not paste API keys, message bodies,
recipients, conversation output, private database files, or complete logs into an
issue.

```bash
imessage-proxy doctor
imessage-proxy server-status
imessage-proxy edge-status
```

`edge-status` is expected to report that the LaunchAgent is not loaded before
public installation. Keep the edge stopped while changing native state:

```bash
imessage-proxy edge-stop
```

The command disables the exact GUI launchd label before unloading it. The edge
therefore remains stopped across logout/login and reboot while its plist,
certificate data, and other state remain intact. `edge-start` explicitly
re-enables the label.

## The one-command installer stops early

`scripts/install.sh` fails closed and changes nothing after the failing step. The
common causes are specific:

- **"does not support one-command installation"** means `--tag` named a release
  whose CLI predates the `bootstrap` action. Omit `--tag` to install `main`.
- **"release … is unavailable"** means that tag has no published source archive.
  Omit `--tag`, or install a reviewed checkout with `--source /path/to/checkout`.
- **"does not carry the resolved commit"** means the downloaded archive did not
  match the commit resolved from the GitHub API. Do not retry blindly.
- **"the release archive does not match …"** means the download did not match the
  published `SHA256SUMS` or your `--sha256` value. Verify the release first.
- **"does not match the reviewed SHA-256 digest"** (imsg) or **"reviewed SHA-512
  digest"** (Caddy) means a dependency download did not match its recorded pin.
  Stop and investigate rather than retrying.
- **"install the Xcode Command Line Tools first"** means the compiler is missing.
  Run `xcode-select --install` and start over.
- **"`--imsg` reports …"** means the executable you supplied is not exactly
  `0.13.4`. Omit `--imsg` to let the installer fetch the pinned build.
- **"run the installer in an interactive terminal"** means it had no TTY. Full
  Disk Access must be granted interactively, so run it from a real terminal.
- **"finish editing the existing configuration first"** means a previous run left
  placeholders in `~/.config/imessage-proxy/service.env`. Complete or remove that
  file.

Re-running the installer is safe. It reuses an already valid configuration,
reuses the pinned `imsg` and Caddy, and leaves an already loaded service
untouched.

## `imessage-proxy: command not found`

The CLI installs into `~/.local/bin`, which many shells do not search by
default. The installer prints the exact line to add when it detects this. Add it
once, then reopen the shell or re-export it:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
export PATH="$HOME/.local/bin:$PATH"
```

Until then, call the CLI by its full path, which always works:

```bash
"$HOME/.local/bin/imessage-proxy" server-status
```

`imessage-proxy start` is not an action. The lifecycle actions are `server-start`,
`server-status`, and `server-stop`; run `imessage-proxy --help` for the full list.

## `doctor` rejects `imsg`

iMessage Proxy 1.0 supports exactly `imsg 0.13.4`. A newer or older command can
change flags, JSON-line fields, error output, and send behavior.

```bash
"$IMESSAGE_PROXY_IMSG_BIN" --version
shasum -a 256 "$IMESSAGE_PROXY_IMSG_BIN"
```

Install the exact supported release for the Messages GUI user, record its
independently reviewed SHA-256, and run `doctor` again. The lifecycle CLI hashes
the file before executing it and stages that exact binary. Do not replace it in
place or point the LaunchAgent at an unreviewed binary.

## `doctor` reports no Messages database

```text
FAIL no Messages database at /Users/you/Library/Messages/chat.db
FAIL open Messages, sign in to iMessage, and exchange one message
```

The database appears once Messages has actually signed in on this Mac. Open
Messages, sign in to iMessage, exchange one message, and run `doctor` again.

Nothing here depends on the file's permissions. This project never opens the
Messages database: it passes the path to the pinned dependency, which reads it
under its own Full Disk Access grant. A `0644` file inside a `0777` directory is
accepted, because no permission shape can make the read succeed or fail — only
the dependency's own access can. Bootstrap does not probe the read path either,
because a probe run from your terminal proves it only for the terminal's
permission identity and the installed LaunchAgent has its own. `GET /api/status`
reports the running service's actual result.

So do not `chmod` anything under `~/Library/Messages` on this project's account.
That directory is TCC-protected, and `sudo` does not help: TCC attributes a
request to the responsible application rather than to the user ID, so a `sudo`
child of your terminal inherits the same refusal. If you want to tighten a
permissive directory for your own reasons, grant your terminal Full Disk Access
first — but the service does not require it.

## `doctor` rejects Caddy

The lifecycle CLI requires the exact host-native Caddy 2.11.4 executable and an
independently reviewed SHA-256:

```bash
"$IMESSAGE_PROXY_CADDY_BIN" version
shasum -a 256 "$IMESSAGE_PROXY_CADDY_BIN"
```

Confirm the environment points at an executable regular file rather than a
symlink, the version begins with `v2.11.4`, and the lowercase digest matches
`IMESSAGE_PROXY_CADDY_SHA256`. Do not update the configured digest merely to make
an unexpected file pass. Re-obtain and review the executable.

## The native server does not start

Read the native server's own log first. The LaunchAgent writes its standard
output and error to a private `0600` file in state, and the CLI prints the last
100 lines:

```bash
imessage-proxy server-logs
```

`server-install`, `server-start`, and `server-restart` also tail the last 20
lines of that file automatically when the socket never appears, so the reason
usually travels with the failure message. An empty log means the process did not
start at all: inspect the generated plist and the exact binary path.

For older events, or for structured operational metadata that never reaches
standard error, inspect a bounded window from the macOS unified-log category:

```bash
/usr/bin/log show \
  --info \
  --last 10m \
  --style compact \
  --predicate 'subsystem == "io.github.mglaeser.imessage-proxy" AND category == "native-server"'
```

The category contains privacy-reviewed operational metadata, not request bodies
or dependency output. The server log is mode `0600` and can contain private
paths, including the account's home directory. Redact request/key IDs,
addresses, hostnames, and private paths from both sources before sharing
excerpts.

Common causes:

- the generated plist points at a missing or rebuilt binary;
- the API-key database, target file, or parent directory is a symlink, has the
  wrong owner, or permits group/world access;
- the configured dependency path/version changed;
- the Unix socket path exceeds the platform limit;
- a live process already owns the socket; or
- a stale socket is not safely attributable to the current user.

Run `imessage-proxy check-host` while the edge is stopped. Never delete an
unknown socket until ownership and process state are proven. If the server was
previously installed but is unloaded, use `server-start`; it explicitly
re-enables the launchd label. If the staged plist or binary intentionally changed,
reinstall or use the documented confirmed restart path while the edge remains
stopped.

An unreadable Messages database is not in that list. It no longer prevents the
server from starting; see the next section.

## The service runs but status reports `messages-unavailable`

```json
{
  "type": "https://github.com/mglaeser/imessage-proxy/problems/messages-unavailable",
  "title": "Service Unavailable",
  "status": 503,
  "detail": "The Messages read path is unavailable.",
  "request_id": "1f825d86-1626-4a0c-a163-644a4cebd91b"
}
```

`GET /api/status` answers with that problem document when the pinned
`imsg chats --limit 1` read fails. The service itself is healthy: the socket
exists, API keys authenticate, and key administration works. Only the routes that
read conversations are affected. The server log records the same condition once
at startup as a `WARNING` line, and the unified log records it as
`messages_read_unavailable`.

The cause is almost always Full Disk Access. Confirm the current binary and the
grant that covers it:

```bash
imessage-proxy server-logs
ls -l "$HOME/Library/Application Support/iMessage Proxy/state/bin/imessage-proxy-server"
```

In System Settings → Privacy & Security → Full Disk Access, the entry must point
at that exact path and be enabled. Remove a stale entry and add the current
binary rather than editing around it. Then restart the server with the edge
stopped:

```bash
imessage-proxy edge-stop
imessage-proxy server-restart --confirm 'RESTART IMESSAGE PROXY SERVER'
imessage-proxy server-status
imessage-proxy edge-start
```

Two macOS behaviors explain why a Mac can pass every interactive check and still
land in this state.

First, macOS attributes file access to the responsible process, not only to the
binary performing the read. Anything you run from your terminal has Terminal or
iTerm as its responsible process, so a read can succeed on the strength of the
terminal's own Full Disk Access. The identical binary started by launchd is its
own responsible process and needs its own entry. The two are different
permission identities, so a check run interactively could agree or disagree with
the service for reasons unrelated to the service. That is why `bootstrap` no
longer probes the read path before installing, and why the running service
reports it instead.

Second, a Full Disk Access grant is keyed to the code signature. `build-host`
re-signs the server binary, so re-running it can invalidate a grant that worked
before. After any rebuild, re-check that the entry still refers to the current
binary.

An install that stopped with `ERROR: Messages read-path preflight failed` came
from an older version, which refused to install whenever that interactive probe
failed. Reinstall from `main` to get the current behavior, in which the service
installs, issues the key, and reports the condition through `GET /api/status`.

## Full Disk Access fails

Symptoms include readiness failure, database-open errors, or empty reads despite
visible Messages conversations.

1. Confirm the exact runtime binary path:

   ```bash
   ls -l "$HOME/Library/Application Support/iMessage Proxy/state/bin/imessage-proxy-server"
   codesign --display --verbose=4 \
     "$HOME/Library/Application Support/iMessage Proxy/state/bin/imessage-proxy-server"
   ```

2. In System Settings → Privacy & Security → Full Disk Access, grant that exact
   server binary access.
3. Keep the edge stopped and restart the server with its exact confirmation. The
   server runs a bounded `imsg chats --limit 1` read at startup but serves
   regardless of the outcome, so check the result rather than the socket: a
   `503 messages-unavailable` answer from `GET /api/status`, or a `WARNING` line
   in `imessage-proxy server-logs`, means the installed LaunchAgent identity
   still cannot read Messages.
4. Prove the socket and authenticated status before starting the edge again.

Do not grant a shell application or Caddy broad access as a substitute, reset the
TCC database, or copy another machine's permission database.

## Sends are not authorized by macOS

The first intentional send may prompt for Automation access to Messages. Approve
only when the prompt identifies the exact native server binary and expected GUI
account.

If the prompt is absent or stale, inspect System Settings → Privacy & Security →
Automation. Re-check after rebuilding or relocating the server binary. Caddy
does not send messages and must not have Automation permission. Keep System
Integrity Protection enabled.

## The API always returns `401`

Verify the client sends one exact header:

```text
Authorization: Bearer imp_…
```

The key must not contain quotes, a trailing newline, or shell prompt text. It may
also be expired or revoked; these conditions deliberately look identical. Use a
different active administrator to inspect key metadata. If no active
administrator remains, run the local bootstrap command on the Mac.

The console clears its tab key after `401`. Sign in again with the correct key;
do not move it to persistent browser storage.

## The API returns `403`

For reads, the key needs `messages:read`; sends need `messages:send`; key
management needs `admin`. Administrator keys include all operations.

For sends, `403` can instead mean the exact target is missing from:

```text
~/Library/Application Support/iMessage Proxy/private/allowed-targets.txt
```

Use a canonical `+` phone handle, one no-whitespace `@` handle, or
`chat_id:POSITIVE_INTEGER`, one per line. Contact names, leading-zero chat IDs,
and wildcards are invalid. Apply an intentional policy change outside-in:

```bash
imessage-proxy edge-stop
imessage-proxy check-host
imessage-proxy server-restart \
  --confirm 'RESTART IMESSAGE PROXY SERVER'
imessage-proxy server-status
imessage-proxy edge-start
```

Then test one harmless consented target.

## A send returns `409`

The idempotency value was reused with different content, or its prior attempt is
pending/ambiguous. Never change the body while retaining the same value.

For an ambiguous attempt, inspect the intended thread in Messages.app. If the
message did not appear and a human chooses to try again, make a new logical send
with a new idempotency value. The server will not decide that automatically.

## A send returns `504`

The bounded dependency command exceeded its deadline. The outcome may be
ambiguous if Messages received the command before the deadline. Treat it exactly
like an unresolved idempotency record: do not blindly retry.

## Caddy cannot connect to the Unix socket

Stop the edge and prove the host service directly:

```bash
imessage-proxy edge-stop
imessage-proxy server-status
stat -f '%HT %Su %Lp %N' \
  "$HOME/Library/Application Support/iMessage Proxy/run/server.sock"

curl --silent --output /dev/null --write-out '%{http_code}\n' \
  --unix-socket "$HOME/Library/Application Support/iMessage Proxy/run/server.sock" \
  http://localhost/api/status
```

The last command should return `401`. Caddy connects to that host path directly;
there is no mount, relay, network route, or internal TCP bridge to repair. If the
socket check succeeds, inspect the staged Caddy configuration and bounded logs:

```bash
imessage-proxy edge-logs
```

Confirm Caddy's LaunchAgent uses the same exact socket path. Run `prepare` again
only from the reviewed source/environment after stopping both the edge and the
native server; `prepare` refuses to replace staged state while either LaunchAgent
is loaded. Never expose the native server on a TCP address or broaden filesystem
permissions as a workaround.

## Certificate issuance fails

Confirm:

- the configured hostname is exact and public;
- its `A` record resolves to the intended IPv4 ingress and no `AAAA` record is
  published;
- external TCP 80 maps to the configured Mac IPv4 HTTP port;
- external TCP 443 maps to the configured Mac IPv4 HTTPS port;
- the router, host firewall, upstream ISP, and carrier-grade NAT posture permit
  inbound traffic;
- no unrelated host process owns either configured high port;
- the system clock is correct;
- Caddy's user-owned data directory is writable and persistent; and
- bounded Caddy logs show the exact hostname, not an example value.

Test from a genuinely external IPv4 client. Do not use an insecure client flag,
a private-certificate fallback, a copied certificate from another hostname, or
direct public port 8443. Leave the public gate off until normal ACME issuance
works through external 80/443.

An ordinary HTTP request to the configured hostname must return `308` with an
exact `https://HOST/path` location, never `:8443`. A different Host value must
return `421`, not a redirect. Both routed responses omit `Server`, `Alt-Svc`, and
cross-origin headers and retain the reviewed no-store, noindex, and security
headers. If they do not, stop the edge and compare the staged Caddyfile and
LaunchAgent with the reviewed source; do not add a second redirecting proxy.

## The console loads but status does not

Static files are intentionally public, while every API request requires a key.
Check the browser has the expected public origin and that the key remains in this
tab's session. Cross-origin use is unsupported.

Inspect browser network status without copying authorization headers. `401`
means sign in again; `403` means scope; `502/503/504` means the native/Messages
path needs operator attention.

If the content-security policy blocks a new third-party dependency, remove the
dependency. The console is designed to be entirely self-contained.

The API playground never accepts arbitrary URLs or headers. A validation message
before any network request means one of its typed inputs is outside the published
contract. HTTP problem responses are shown as literal bounded JSON. For a send,
closing the confirmation makes no request; retrying an unchanged attempt after a
transport failure intentionally reuses its in-tab idempotency key. Sign out to
abort pending playground work and clear every rendered request and response.

## Rate limiting (`429`)

Honor `Retry-After`. Repeated `401` attempts can trigger source-based limits;
authenticated clients also have per-key limits, with lower budgets for sends and
key changes.

Do not retry in a tight loop or spread attempts across credentials. Investigate
unexpected traffic, fix client polling, and remember in-memory counters reset on
native restart. Confirm the router is performing ordinary port forwarding rather
than proxying every connection from one address; a proxy would invalidate the
documented source-address model.

## A configured host port is already in use

Inspect the exact configured ports, which default to 8080 and 8443:

```bash
lsof -nP -iTCP:"${IMESSAGE_PROXY_HTTP_PORT:-8080}" -sTCP:LISTEN
lsof -nP -iTCP:"${IMESSAGE_PROXY_HTTPS_PORT:-8443}" -sTCP:LISTEN
```

Do not stop or reconfigure an unrelated service without its own change plan. Do
not move Caddy to privileged host TCP 80/443; correct the reviewed high-port or
router mapping plan and repeat external acceptance.

## The edge does not install or start

`edge-install` deliberately refuses to continue when:

- the public-exposure gate is not exactly `yes`;
- the hostname, ACME email, IPv4 bind, or high ports are invalid;
- the staged Caddy version/digest or Caddyfile differs from reviewed state;
- the UI or edge LaunchAgent is missing or stale;
- the native socket is not ready;
- a configured host port already has a listener; or
- the edge LaunchAgent is already loaded.

Run `doctor`, `server-status`, and `edge-logs`; compare the current environment
with the maintenance record. If edge inputs intentionally changed, stop the edge,
stop the native server with its exact confirmation, run `prepare` from reviewed
source, and inspect the result. Then run `build-host`, `check-host`,
`server-install`, and `edge-install` with its exact public-exposure confirmation.
Do not edit a loaded LaunchAgent or weaken validation.

If startup prints `URGENT: automatic public-edge rollback could not confirm
containment`, do not assume the listener stopped. Remove or disable the external
port mappings, disconnect the Mac from the untrusted network if necessary, and
inspect both the launchd label and configured ports locally. Restore exposure
only after `launchctl` reports the label absent and `lsof` reports neither port
listening.

## The public mapping is unreachable

Verify each hop rather than opening more services:

1. Caddy owns the configured host IPv4 high ports.
2. The Mac firewall permits the reviewed inbound path to those ports.
3. The router maps external 80→host HTTP and 443→host HTTPS exactly.
4. The hostname's `A` record reaches that router and has no competing IPv6 path.
5. The ISP permits inbound 80/443 and does not place the site behind unconfigured
   carrier-grade NAT.
6. An external IPv4 client reaches the hostname on ordinary HTTPS port 443.

Do not publish the server socket, add a second Caddy instance, add a tunnel, or
expose high ports directly to public clients as a diagnostic shortcut.

## After logout, reboot, sleep, or upgrade

Validate in this order:

1. the Messages GUI account/session is active;
2. the exact native server LaunchAgent and socket are ready;
3. the native process has no TCP listener;
4. the Caddy LaunchAgent owns only the configured IPv4 high ports;
5. the router's exact external 80/443 mappings remain active;
6. the public certificate and security headers are correct;
7. authenticated status and a bounded read succeed; and
8. one harmless send is tested only when the change warrants it.

Re-run the real-Mac restart matrix after macOS, Caddy, `imsg`, router, firewall,
or address changes. Stop the edge if any state is uncertain.

## Safe support bundle

Before opening an issue, produce a manually reviewed summary containing only:

- iMessage Proxy, macOS, Caddy, and `imsg` versions;
- CPU architecture;
- whether both processes, the socket, and expected IPv4 listeners are present
  (omit paths that reveal the username);
- whether the exact external port mappings were validated, without disclosing
  private or public addresses;
- HTTP status and request ID for a synthetic failing request;
- the exact documented action that failed; and
- redacted diagnostics containing no keys, hashes, conversations, targets,
  participants, contact names, host addresses, or certificate/account material.

Prefer describing the error class to uploading raw logs. Follow
[SECURITY.md](../SECURITY.md) for anything that might be a vulnerability.
