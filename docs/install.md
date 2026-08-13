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
5. Writes `~/.config/imessage-proxy/service.env` with three keys.
6. Pauses once for Full Disk Access, then starts the LaunchAgent and issues your
   first administrator key.

Each build step prints one line. Pass `--verbose` to see the full output, which
is also printed automatically when a step fails.

Useful options: `--port N` (default 8765), `--prefix DIR`, `--imsg PATH` to use
your own reviewed executable, `--source DIR` or `--archive FILE` to install from
a tree you already reviewed, `--no-tests`, and `--self-test`.

## Install from a checkout

```bash
git clone https://github.com/mglaeser/imessage-proxy.git
cd imessage-proxy
make check                      # build, lint, analyze, test (macOS)
make install                    # into ~/.local
imessage-proxy bootstrap --config ~/.config/imessage-proxy/service.env --admin-name first-admin
```

`bootstrap` runs `doctor`, `prepare`, `build-host`, the Full Disk Access
checkpoint, `check-host` and `server-install` in order, then issues the first
key. Pass `--without-admin-key` to skip the credential, which is what the
installer does so it can print its summary before the key.

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

The allowlist is one recipient per line at
`~/Library/Application Support/iMessage Proxy/private/allowed-targets.txt`.
Wildcards are not supported, by design.

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
