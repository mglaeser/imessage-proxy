# Troubleshooting

Start with read-only, metadata-only checks. Do not paste API keys, message bodies,
recipients, conversation output, private database files, or complete logs into an
issue.

```bash
imessage-proxy doctor
imessage-proxy server-status
imessage-proxy server-logs
```

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
- **"does not match the reviewed SHA-256 digest"** means the imsg download did
  not match its recorded pin. Stop and investigate rather than retrying.
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
reuses the pinned `imsg`, and leaves an already loaded service
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

## The native server does not start

Read the native server's own log first. The LaunchAgent writes its standard
output and error to a private `0600` file in state, and the CLI prints the last
100 lines:

```bash
imessage-proxy server-logs
```

`server-install`, `server-start`, and `server-restart` also print what that
start wrote when the socket never appears, so the reason usually travels with
the failure message. They print only the bytes appended by that start: nothing
truncates the log and it survives reinstalls, so `server-logs` may show lines
from earlier attempts that a failure report deliberately excludes.

Read the printed lines before anything else, because they separate three very
different faults:

- `Usage: imessage-proxy-server <serve|...>` means the LaunchAgent invoked the
  binary with the wrong arguments. The process exits 64 before it loads any
  configuration, so this is a plist defect, not a permissions or Messages
  problem. Confirm with the command below; the array must hold exactly the
  server binary followed by `serve`.
- `ERROR: ...` means configuration failed to load. The message names the
  setting; `check-host` reproduces it without launchd.
- `WARNING: the Messages read path is unavailable` means the server started and
  is serving in a degraded state. That is a Full Disk Access problem, not a
  start failure.

```bash
/usr/bin/plutil -extract ProgramArguments json -o - \
  "$HOME/Library/LaunchAgents/io.github.mglaeser.imessage-proxy.plist"
```

"wrote nothing to ... during this start" means the process never reached its own
error reporting. Either launchd could not run it, or it ran and the readiness
checks rejected it: inspect the generated plist, the exact binary path, and
`launchctl print "gui/$(id -u)/io.github.mglaeser.imessage-proxy"`.

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
binary rather than editing around it. Then restart the server:

```bash
imessage-proxy server-restart --confirm 'RESTART IMESSAGE PROXY SERVER'
imessage-proxy server-status
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

Do not grant a shell application broad access as a substitute, reset the
TCC database, or copy another machine's permission database.

## Sends are not authorized by macOS

The first intentional send may prompt for Automation access to Messages. Approve
only when the prompt identifies the exact native server binary and expected GUI
account.

If the prompt is absent or stale, inspect System Settings → Privacy & Security →
Automation. Re-check after rebuilding or relocating the server binary. Keep System
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

For sends, `403` with `target-forbidden` instead means the exact target is not
on the allowlist. Check and change it with:

```bash
imessage-proxy targets list
imessage-proxy targets add person@example.net
```

Use a canonical `+` phone handle, one no-whitespace `@` handle, or
`chat_id:POSITIVE_INTEGER`. Contact names, leading-zero chat IDs, and wildcards
are invalid, and the CLI refuses them rather than writing a file the server would
then reject whole. The allowlist is read on every send, so a change applies to
the next one and no restart is needed. Then test one harmless consented target.

A `403` on `/api/targets` itself means the key lacks `admin`. That is
deliberate: a credential that can send must not be able to add new recipients.

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

## The configured port is already in use

The server refuses to start rather than sharing the port, and says so:

```text
ERROR: the configured port is already in use
```

Find the owner, then either stop it deliberately or pick another port:

```bash
lsof -nP -iTCP:"${IMESSAGE_PROXY_PORT:-8765}" -sTCP:LISTEN
```

To move the service, edit `IMESSAGE_PROXY_PORT` in
`~/.config/imessage-proxy/service.env` and restart. Do not stop an unrelated
service without its own change plan.

## After logout, reboot, sleep, or upgrade

Validate in this order:

1. the Messages GUI account and session are active;
2. the LaunchAgent is loaded and ready;
3. the listener is bound to `127.0.0.1` and nothing else — this is the
   invariant worth checking every time, because a listener on `*` or `0.0.0.0`
   means the service is reachable from your network:

   ```bash
   lsof -nP -iTCP -sTCP:LISTEN | grep imessage-proxy
   ```

4. authenticated status and a bounded read succeed; and
5. one harmless send is tested only when the change warrants it.

Re-run these after macOS or `imsg` upgrades. If you run your own TLS proxy in
front, verify it separately; it is not part of this service.

## Safe support bundle

Before opening an issue, produce a manually reviewed summary containing only:

- iMessage Proxy, macOS, and `imsg` versions;
- CPU architecture;
- whether the LaunchAgent is loaded and the loopback listener is present;
- HTTP status and request ID for a synthetic failing request;
- the exact documented action that failed; and
- redacted diagnostics containing no keys, hashes, conversations, targets,
  participants, contact names, host addresses, or certificate/account material.

Prefer describing the error class to uploading raw logs. Follow
[SECURITY.md](../SECURITY.md) for anything that might be a vulnerability.
