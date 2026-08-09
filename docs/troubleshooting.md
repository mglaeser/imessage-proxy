# Troubleshooting

Diagnose iMessage Proxy from the outside in: client TLS/authentication, Caddy facade, Apple Container host route, loopback bridge, `imsg`, then macOS privacy permissions. Changing several layers at once makes security failures harder to understand.

## First response

If a failure could send unintended messages, expose data, or indicate compromised credentials, stop the facade first:

```bash
bin/imessage-proxy stop
```

For ordinary failures, source the same private operator configuration used during installation and run:

```bash
set -a
. "$HOME/.config/imessage-proxy/imessage-proxy.env"
set +a
bin/imessage-proxy doctor
bin/imessage-proxy status
bin/imessage-proxy agent-status
```

Record iMessage Proxy, macOS, Apple Container, Caddy, and `imsg` versions. Sanitize all output before sharing it.

Version 0.3.0 retains the 0.2 transition identities: runtime home `~/Library/Application Support/Stella`, runtime binary and LaunchAgent identity `stella-bridge` / `io.github.mglaeser.stella.bridge`, container `stella`, and route `stella-host.container.internal`. Seeing those names is not by itself stale state. The deprecated `bin/stella` and `STELLA_*` forms are compatibility interfaces; use `bin/imessage-proxy` and `IMESSAGE_PROXY_*` for new diagnostics. See the [operations transition note](operations.md#rename-transition-in-020) before changing any runtime identity.

## Symptom map

| Symptom | Likely boundary | Start with |
| --- | --- | --- |
| Certificate unknown or hostname mismatch | Client ↔ Caddy TLS | CA file, URL hostname, private DNS |
| Connection refused or timeout | Interface, container, route, firewall | `status`, private bind address, host-route refresh |
| Empty/aborted response from a reachable facade | Caddy private-source filter | Source address as seen by Caddy and VPN topology |
| `401` | Client credential or internal bridge token | Retype caller credential; inspect Caddy and bridge state |
| `403` | RPC/parameter/target policy | Method, forbidden flags, exact allowlist form |
| `404` | Wrong route or HTTP method | Compare with the API route table |
| `408` | Bounded request timeout | Client upload, facade timing, bridge socket log |
| `413` or `431` | Request-size policy | Reduce body or headers; do not raise limits casually |
| `415` | SMS-style endpoint content type | Send `Content-Type: application/json` |
| `500` | Internal bridge or facade error | Bridge and facade logs, exact version, recent changes |
| `502` | `imsg` response or facade-to-bridge upstream | `check-host`, dependency version, bridge/facade logs |
| `503` from health | Messages read path | Full Disk Access, database, `imsg` |
| `504` | `imsg` or facade-to-bridge timeout | Host load, hung process, dependency/upstream health |
| Read works but send fails | Target policy or Automation permission | Allowlist, Messages sign-in, TCC Automation |
| Duplicate outbound message | Client retry logic | Stop retries; reconcile by GUID/history |

## Build failures

### Xcode toolchain not found

`make build` and `bin/imessage-proxy build-host` require macOS and Xcode Command Line Tools.

```bash
xcode-select -p
xcrun --find clang
```

Install or repair the matching Apple toolchain. Do not substitute an unreviewed compiler or remove warning flags to force a build.

### Tests cannot select a port

The integration test chooses an unused loopback port. Inspect local listeners and retry after resolving the collision:

```bash
lsof -nP -iTCP -sTCP:LISTEN
```

The test uses a fake `imsg` backend and synthetic fixtures. It should not require access to real Messages data.

### `make check` reports missing lint tools

The complete check requires `clang-format`, `shellcheck`, and `markdownlint-cli2`. Install reviewed versions and rerun `make check`. `make build` and `make test` alone do not replace the static and formatting checks used by CI.

## Preparation and configuration

### `IMESSAGE_PROXY_API_HOST must be a private DNS name`

Source the operator environment in the current shell and replace example placeholders. Use a hostname made of letters, numbers, dots, and hyphens; do not include a URL scheme, port, path, shell expression, or whitespace.

### Bind IP is not assigned

`IMESSAGE_PROXY_BIND_IP` must match an address currently assigned to the intended private interface. Re-check after DHCP, Wi-Fi/Ethernet, or VPN changes. Do not switch to `0.0.0.0`.

### Caddy image rejected

Use the official Caddy image with an immutable reviewed `sha256:` digest. Floating tags and non-official registries are intentionally rejected.

### Private file mode rejected

iMessage Proxy refuses group/world-readable secrets. Inspect without printing contents:

```bash
runtime_root="${IMESSAGE_PROXY_HOME:-$HOME/Library/Application Support/Stella}"
stat -f '%Sp %N' "$runtime_root/secrets/bridge.token" \
  "$runtime_root/secrets/allowed-targets.txt" \
  "$runtime_root/secrets/users.caddy"
```

Fix ownership first if the files do not belong to the Messages user, then set mode `0600`. Never solve the error by running iMessage Proxy as root.

## LaunchAgent and bridge

### Agent is already loaded

Use the confirmed reload action after a build or configuration change:

```bash
bin/imessage-proxy agent-reload \
  --confirm 'RELOAD IMESSAGE HOST BRIDGE'
```

The confirmation guards a process restart. Do not run a second bridge manually on the same port.

### Agent fails repeatedly

Inspect the LaunchAgent state and a bounded tail of the bridge diagnostic log:

```bash
bin/imessage-proxy agent-status
runtime_root="${IMESSAGE_PROXY_HOME:-$HOME/Library/Application Support/Stella}"
tail -n 100 "$runtime_root/state/logs/bridge.err.log"
```

Common causes are an absent runtime binary, invalid secret path or mode, missing `imsg`, a port collision, or permission denial. Audit lines should not contain message content; still sanitize user IDs, host paths, and times before sharing.

If `create` or `start` says the LaunchAgent is not ready, compare the prepared
and installed plist, then inspect the loaded path, program, state, PID, and the
listener shown by `lsof`. The facade deliberately refuses a same-label job that
is stopped, crash-looping, points elsewhere, has no unique PID, or does not
own exactly one IPv4 listener at `127.0.0.1:<bridge-port>`. It also refuses when
the running bridge's authenticated configuration digest differs from fresh
evaluations of the exact token/allowlist bytes or reviewed runtime
settings. After intentional configuration changes, use the confirmed
`agent-reload`; do not bypass the readiness gate.

### Bridge is not loopback-only

The expected listener is `127.0.0.1` on the configured bridge port:

```bash
lsof -nP -iTCP:"${IMESSAGE_PROXY_BRIDGE_PORT:-8765}" -sTCP:LISTEN
```

If any iMessage Proxy bridge listener is bound to a non-loopback address, stop it and investigate the binary/source/configuration. Do not operate the facade until the invariant is restored.

## macOS privacy controls

### Health returns `503`

Health exercises a minimal chat read. Verify:

1. Messages.app works interactively for the same GUI user.
2. `imsg` is installed and its version is the reviewed one.
3. The exact built `stella-bridge` binary has Full Disk Access.
4. The Messages database is present and readable through normal TCC controls.
5. `bin/imessage-proxy check-host` succeeds.

Do not copy the Messages database, run the service as root, disable SIP, or grant broad permissions to unrelated applications.

### Reads work but sends fail

Confirm exactly one target is selected and its representation matches `allowed-targets.txt` byte-for-byte. Then perform one intentional GUI-observed test and approve the normal Messages Automation prompt.

Rebuilding or moving `stella-bridge` may change how macOS associates TCC permission. Re-add only the exact current binary if System Settings shows a stale entry.

## Container and network

### Container is missing

`start`, `stop`, and `logs` require a previously created exact container. Run `doctor`, verify the environment and callers, then use `bin/imessage-proxy create`. Do not create an ad-hoc container with broader mounts or publishes.

### Container already exists

Use `bin/imessage-proxy status` to inspect its sanitized state and publication. `start` accepts a stopped container only when its complete reviewed definition matches the current image, prepared environment, mounts, limits, and private publication. Alpha releases do not automatically reconcile a changed container definition; see the recreation limitation in [Operations](operations.md).

### Host route fails after restart

Apple Container host routing may need an explicit refresh after a Mac restart:

```bash
bin/imessage-proxy host-route-refresh \
  --confirm 'REFRESH IMESSAGE HOST ROUTE'
bin/imessage-proxy start
```

Retest health afterward. Do not expose the native bridge on the LAN as a shortcut.

If iMessage Proxy reports that the route name resolves to the wrong alias, do not
continue with `create` or `start`. Inspect `IMESSAGE_PROXY_BRIDGE_HOST_IP`, then use the
confirmed refresh action; iMessage Proxy requires exactly one resolved IPv4 address
matching that configured alias.

### TLS trust failure

Check that:

- the URL hostname exactly matches `IMESSAGE_PROXY_API_HOST`;
- private DNS resolves that name to `IMESSAGE_PROXY_BIND_IP` from the client;
- the client uses the root certificate reported by `bin/imessage-proxy ca-path`;
- the certificate came from this deployment and its fingerprint was verified;
- the client's clock is correct.

Do not use `curl -k`. If Caddy state was regenerated, clients must deliberately trust the new root certificate.

### VPN client is rejected as outside

Caddy evaluates the source address it sees. Confirm the VPN preserves or assigns an intended private address and that no proxy rewrites it unexpectedly. Do not remove the private-range filter; correct the network design and keep authentication enabled.

## API policy failures

### Method or parameter returns `403`

Only `chats.list`, `messages.history`, `messages.after`, `send`, and `message.send_status` are accepted. Attachments, converted attachments, and reactions must be absent or `false`. Unknown fields within method parameters are rejected.

### Send target is not allowed

Direct addresses appear exactly as written. Chat selectors use a prefix:

```text
chat_id:42
chat_identifier:example-value
chat_guid:example-guid
```

After editing the list, perform the confirmed LaunchAgent reload. Avoid `*`; it removes the target guard for every authenticated client.

### Cursor returns unexpected history

`since_rowid` belongs to the local Messages database, not a wall-clock timestamp. A restored or replaced database invalidates client assumptions. Pause processing, reset the cursor deliberately, fetch a bounded page, and deduplicate at the consumer before resuming.

## Collecting a safe support bundle

There is no automatic support-bundle command because indiscriminate collection can leak conversations and secrets. Provide only:

- versions and architecture;
- exact failing iMessage Proxy command;
- HTTP status and a synthetic request shape;
- a short, manually reviewed diagnostic excerpt;
- whether each boundary in the symptom map succeeded.

Never attach `bridge.token`, `facade.env`, `users.caddy`, Caddy CA keys, the Messages database, full container inspect output, or unreviewed logs. Follow [SUPPORT.md](../SUPPORT.md), and report vulnerabilities privately under [SECURITY.md](../SECURITY.md).
