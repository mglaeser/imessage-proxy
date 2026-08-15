# Install and operate

The [one-liner](../README.md#get-started) covers the normal case. This page is
for reviewing what it does, installing from source, running the lifecycle by
hand, and publishing the service behind your own proxy.

## What the installer does

1. Verifies the Mac and the tools it needs.
2. Downloads the source for the resolved commit and proves the archive is that
   commit.
3. Builds the native server, installs the CLI to `~/.local`, and ad-hoc signs
   the binary.
4. Installs `imsg` 0.13.4, verified against a recorded SHA-256.
5. Writes `~/.config/imessage-proxy/service.env`.
6. Proves sending works, asks whether to read Messages as well, then starts the
   LaunchAgent and issues your first administrator key.

Each build step prints one line. Pass `--verbose` to see the full output, which
is also printed automatically when a step fails.

Useful options: `--port N` (default 8765), `--prefix DIR`, `--imsg PATH` to use
your own reviewed executable, `--source DIR` or `--archive FILE` to install from
a tree you already reviewed, `--no-tests`, and `--self-test`.

### Unattended

The installer asks two questions — the test send and Messages reading — and
answering both on the command line is what makes a run unattended. `--key-file`
takes the last thing it would otherwise put on stdout:

```bash
curl -fsSL https://raw.githubusercontent.com/mglaeser/imessage-proxy/main/scripts/install.sh | bash -s -- \
  --no-send-test --messages-read --key-file "$HOME/imessage-proxy-admin.key"
```

The file is created private to you before the key is written to it, and the run
refuses at the outset if it already exists, if its directory does not, or if the
path is not absolute — so a run that cannot deliver the key fails before it
generates one rather than after.

Full Disk Access is the one step that cannot be automated. macOS grants it only
through System Settings or an MDM configuration profile; no flag and no script
can do it, and no probe here could prove it either, since a read from the
installer would only test the terminal's own permissions. `--messages-read`
prints the steps and, because the questions were answered on the command line,
does not pause on them. Until the grant is in place `/api/status` reports
`messages-unavailable` and sending is unaffected.

## Install from a checkout

```bash
git clone https://github.com/mglaeser/imessage-proxy.git
cd imessage-proxy
make check                      # build, lint, analyze, test (macOS)
make install                    # into ~/.local
imessage-proxy bootstrap --config ~/.config/imessage-proxy/service.env --admin-name first-admin
```

`bootstrap` runs `doctor`, `prepare`, `build-host`, `check-host` and
`server-install` in order, then issues the first key. It does not ask for Full
Disk Access: sending never needs it, and demanding it before the operator has
been asked whether they want reading at all made a send-only install look
broken. Pass `--without-admin-key` to skip the credential, which is what the
installer does so it can print its summary before the key.

The first key is identified as `adm`, so every message it sends ends with
`🔖adm` over iMessage and `^adm` over SMS.

## Lifecycle

```bash
imessage-proxy server-status
imessage-proxy server-logs
imessage-proxy server-restart --confirm 'RESTART IMESSAGE PROXY SERVER'
imessage-proxy server-stop --confirm 'STOP IMESSAGE PROXY SERVER'
imessage-proxy server-start
```

Stopping durably disables the launchd label so it stays down across reboots;
`server-start` and `server-install` re-enable it explicitly.

Adopting a rebuilt binary needs `prepare`, `build-host` and `server-install`
while the service is stopped. Rebuilding re-signs the binary, and a Full Disk
Access grant is keyed to the signature, so re-grant it if `/api/status` starts
reporting `messages-unavailable`.

## Configuration

`~/.config/imessage-proxy/service.env`, mode `0600`, three keys:

```bash
IMESSAGE_PROXY_PORT=8765
IMESSAGE_PROXY_IMSG_BIN=/Users/you/.local/libexec/imessage-proxy/imsg-0.13.4/imsg
IMESSAGE_PROXY_IMSG_SHA256=<digest>
```

Only the port is meant to be edited. Change it, then
`server-restart --confirm 'RESTART IMESSAGE PROXY SERVER'`. Every action except
`bootstrap` reads this file; anything already exported wins, and
`IMESSAGE_PROXY_CONFIG` points at a different one.

The allowlist decides who this Mac may message. Manage it with the CLI:

```bash
imessage-proxy targets list
imessage-proxy targets add person@example.net
imessage-proxy targets add +15551234567
imessage-proxy targets add chat_id:42
imessage-proxy targets remove person@example.net
```

Changes take effect on the next send; nothing needs restarting. The console has
the same list under **Recipients**, and `GET`/`PUT /api/targets` expose it to
the API — all three require the `admin` scope, so a stolen `messages:send` key
can write to the people you approved but cannot add anyone new.

Underneath it is one recipient per line at
`~/Library/Application Support/iMessage Proxy/private/allowed-targets.txt`.
Wildcards are not supported, by design.

## Sending without reading

Sending and reading are separate macOS grants, and they behave differently.
Sending goes through Apple Events, which macOS prompts for at the first send.
Reading needs Full Disk Access, which macOS never prompts for: an unauthorised
read of `chat.db` simply fails, and somebody has to add the exact binary in
System Settings by hand. Handing over the whole Messages database is a real
decision, so an installation is allowed to decline it and run as a send-only
service. Turn reading on with:

```bash
imessage-proxy enable-messages-read
```

The service decides this once, when it starts, from its own environment: reading
is off when `IMESSAGE_PROXY_MESSAGES_READ` is `disabled` and on for any other
value, including no value at all, so an installation that never heard of the
setting keeps reading. A change therefore applies from the next start of the
service, not from the next request.

While reading is off:

- `GET /api/status` reports `messages.status` as `disabled` and names the
  command above in `enable_with`;
- every route that answers out of the Messages database returns `409` with
  `messages-read-disabled`, and so does a send addressed to a `chat_id`, which
  has to resolve the chat first; and
- sends to a `recipient` work normally over both iMessage and SMS, as do keys,
  the allowlist and audit events.

Turning reading on does not grant Full Disk Access; only System Settings does
that, for the exact binary the installer names.
[Troubleshooting](troubleshooting.md) separates the two symptoms: `409` is an
installation that declined reading, `503` is one that tried to read and could
not.

## Who your messages come from

Every API key carries a sender identifier of two to eight letters, and every
message that key sends ends with it — `🔖dep` over iMessage, `^dep` over SMS.
The recipient can therefore tell one automation from another, and all of them
from you typing in Messages.app. Only an administrator key can send without it,
one message at a time. Issue a key per job, keep the identifiers recognisable,
and see [API](api.md#the-sender-identifier) for the request fields.

## Publishing it

The server binds loopback and refuses to bind anything else, so publishing means
running your own terminator in front of `127.0.0.1:8765`. That component owns
TLS certificates, HSTS, and any access control you want beyond the bearer key.

A container is a reasonable way to run it — that is the one part of this system
that can be containerised, since the server itself needs Full Disk Access, Apple
Events and a GUI login session, none of which exist inside a Linux VM.

Whatever you choose, it must:

- terminate TLS and set HSTS itself, because the server will not;
- forward the `Authorization` header unchanged;
- strip any `X-API-*` header a client sends, because the server no longer trusts
  them and neither should you; and
- be the only thing with a public port.

Read [Security model](security.md) before exposing anything.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/mglaeser/imessage-proxy/main/scripts/uninstall.sh | bash
```

Add `--dry-run` to preview, `--purge --confirm 'DESTROY IMESSAGE PROXY STATE'`
to also destroy keys, the allowlist and logs, and `--include-legacy` to remove
pre-1.0 artifacts. The uninstaller also removes the public-edge LaunchAgent that
releases before this one installed, so upgrading does not leave one running.

macOS cannot revoke its own grants from a script: remove the Full Disk Access
entry by hand, and the Messages Automation entry too if you ever sent a message.
