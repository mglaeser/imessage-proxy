# Operations

This guide covers a review-first Stella 0.1.0 deployment. Stella is Alpha software: use a harmless test recipient, schedule a maintenance window, and keep a working non-Stella path to the Mac.

## Operating principles

- Run every Stella command as the non-root GUI user signed in to Messages.
- Keep the repository and runtime state separate.
- Pin the Stella revision and Caddy image digest; review both before changing them.
- Publish only on a selected private interface reachable from an authenticated LAN or VPN.
- Give every client its own credential and the minimum operational access it needs.
- Never disable TLS verification, SIP, TCC, or the outbound target allowlist to make a check pass.
- Stop on unexpected output. Stella intentionally avoids automatic deletion, reset, pruning, and retrying sends.

## 1. Preflight

Confirm the host has:

- a supported Mac with Apple Container installed and its system running;
- a non-root GUI account signed in to Messages.app;
- Xcode Command Line Tools;
- `git`, `make`, `curl`, `jq`, `openssl`, and `lsof`;
- a reviewed `imsg` installation available on `PATH`;
- a stable private interface address and matching private DNS record;
- an official Caddy image reference pinned to a reviewed SHA-256 digest;
- a client device that can reach the private address and receive the private CA securely.

Do not proceed while the Mac or API name is reachable from the public Internet.

Install the maintained `imsg` backend for the Messages user, then record its version:

```bash
brew install steipete/tap/imsg
imsg --version
```

Review [`imsg` upstream](https://github.com/openclaw/imsg) before upgrades; the Homebrew tap name remains `steipete/tap`.

## 2. Obtain and verify Stella

Clone the canonical repository and check out the reviewed release or full commit:

```bash
git clone https://github.com/mglaeser/stella.git
cd stella
git status --short
make build
make test
```

For the complete maintainer check suite, install the lint tools named by the Makefile and run:

```bash
make check
```

You can operate directly from the checkout with `bin/stella`. For a user-local installation that keeps runtime state untouched:

```bash
make PREFIX="$HOME/.local" install
"$HOME/.local/bin/stella" version
```

The remainder of this guide uses `bin/stella`. Substitute the installed command when appropriate.

## 3. Create operator configuration

Keep the sourced environment file outside the repository:

```bash
mkdir -p "$HOME/.config/stella"
chmod 700 "$HOME/.config/stella"
install -m 600 config/stella.env.example "$HOME/.config/stella/stella.env"
${EDITOR:-vi} "$HOME/.config/stella/stella.env"
```

Set and review:

| Variable | Purpose |
| --- | --- |
| `STELLA_API_HOST` | Private DNS name on the TLS certificate |
| `STELLA_API_PORT` | Published HTTPS port, default `9443` |
| `STELLA_BIND_IP` | Exact private address assigned to the Mac |
| `STELLA_CADDY_IMAGE` | Official Caddy image pinned by SHA-256 digest |
| `STELLA_ENABLE_ALPHA` | Explicit Alpha deployment gate; leave `no` until acceptance prerequisites are ready |

Optional advanced settings include `STELLA_HOME`, `STELLA_SOURCE_DIR`, `STELLA_CONTAINER_NAME`, `STELLA_BRIDGE_HOST`, `STELLA_BRIDGE_HOST_IP`, and `STELLA_BRIDGE_PORT`. Keep defaults unless the topology requires a reviewed change.

The example address is documentation-only. Replace every placeholder with observed deployment values. Source the file into each new operator shell:

```bash
set -a
. "$HOME/.config/stella/stella.env"
set +a
```

`STELLA_HOME` defaults to `~/Library/Application Support/Stella`. It holds secrets and private CA material; do not put it in the repository or a broadly synchronized folder.

## 4. Diagnose and prepare

Run the non-mutating preflight first:

```bash
bin/stella doctor
```

Resolve every failed required check. Then create private runtime directories, initial secrets, generated facade environment, Caddy configuration, and LaunchAgent template:

```bash
bin/stella prepare
```

Review the generated files below `~/Library/Application Support/Stella/`. Directories containing runtime or secret data should be accessible only to the user, and files in `secrets/` should be mode `0600`.

### Configure send targets

Edit `~/Library/Application Support/Stella/secrets/allowed-targets.txt`. Add one exact target per line:

```text
person@example.net
chat_id:42
chat_identifier:example-value
chat_guid:example-guid
```

An empty effective list permits reads but denies every send. Do not add `*` unless you have explicitly accepted unrestricted outbound targets.

### Configure API callers

Generate a password hash interactively:

```bash
bin/stella hash-password
```

Choose a new, high-entropy password and store it in the client's secret manager. Add only the resulting Caddy hash to `~/Library/Application Support/Stella/secrets/users.caddy`:

```text
automation-a $2a$14$REPLACE_WITH_GENERATED_HASH
```

Use a separate entry for every client. Never place plaintext passwords in this file, the environment, command arguments, or shell history.

## 5. Build and authorize the native bridge

Build an ad-hoc-signed runtime binary from the checked-out source and validate its configuration:

```bash
bin/stella build-host
bin/stella check-host
```

Inspect the generated binary and LaunchAgent paths printed by the manager. In System Settings, grant Full Disk Access to that exact `stella-bridge` binary. Do not grant it to unrelated shells or disable SIP.

Install the user LaunchAgent and verify its state:

```bash
bin/stella agent-install
bin/stella agent-status
```

The LaunchAgent must run in the Messages user's GUI domain, never as root. On the first intentional send, approve the macOS Automation prompt for Messages.app. If the prompt or read access fails, troubleshoot TCC rather than broadening filesystem permissions.

## 6. Create the private facade

Create the Apple Container host route:

```bash
bin/stella host-route-create
```

This operation may request `sudo` for Apple Container's host-routing change. Review the exact command. Never work around a route failure by changing the bridge listener to a non-loopback address.

> [!CAUTION]
> Apple Container's localhost host-routing feature can disable iCloud Private Relay, and its route may need to be recreated after a Mac restart. Confirm the behavior for the installed Apple Container release before enabling it.

After completing the security checklist, deliberately set `STELLA_ENABLE_ALPHA=yes` in the private operator configuration, source it again, and rerun `bin/stella doctor`.

Create the resource-bounded Caddy container:

```bash
bin/stella create
bin/stella status
```

`create` verifies the configured private address is assigned to the host, checks the caller file, requires the LaunchAgent and host route, and refuses an occupied port or existing Stella container.

## 7. Enroll a client

Print the Caddy root certificate path on the Mac:

```bash
bin/stella ca-path
```

Transfer the **root certificate only** to the authorized client over an authenticated channel. Never transfer the CA private key or the full Caddy data directory. Confirm the certificate fingerprint independently before trusting it.

From the client, test with certificate verification enabled; `curl` prompts for the caller password:

```bash
curl \
  --cacert /secure/path/stella-root.crt \
  --user automation-a \
  https://messages.example.internal:9443/healthz
```

Never use `--insecure` or `-k`.

## 8. Acceptance test

Before relying on Stella, verify all of the following:

1. A request without credentials fails.
2. A request with the wrong client password fails.
3. `/healthz` succeeds with a valid caller and the pinned CA.
4. A bounded `messages.after` call succeeds without attachments or reactions.
5. An unknown RPC method returns `403`.
6. A send to an unlisted synthetic target returns `403` and sends nothing.
7. One consenting, harmless allowlisted target receives one intentional test message.
8. Audit output contains caller, method, status, and duration but no content or recipient.
9. The API is unreachable from an untrusted network.
10. Stop/start and a Mac restart follow the documented recovery sequence.

Do not automatically retry an ambiguous send; inspect history or send status first.

## Routine lifecycle

| Task | Command | Notes |
| --- | --- | --- |
| Preflight | `bin/stella doctor` | Non-mutating diagnostics |
| Host config validation | `bin/stella check-host` | Checks secret files, bridge, and `imsg` |
| LaunchAgent state | `bin/stella agent-status` | Uses the current GUI user domain |
| Facade state | `bin/stella status` | Returns only the configured container entry |
| Facade logs | `bin/stella logs` | Review and sanitize before sharing |
| Stop facade | `bin/stella stop` | Preferred first incident-containment action |
| Start facade | `bin/stella start` | Requires an existing container and valid host route |
| Project version | `bin/stella version` | Compare with the pinned checkout |

After a Mac restart, refresh the exact Apple Container host route before starting or testing the facade:

```bash
bin/stella host-route-refresh \
  --confirm 'REFRESH IMESSAGE HOST ROUTE'
bin/stella start
```

The explicit confirmation is intentional. Host-route persistence and side effects can change across Apple Container releases.

## Configuration changes

### Send-target allowlist

Edit the mode-0600 `allowed-targets.txt`, review the diff manually, and reload the native bridge:

```bash
bin/stella agent-reload \
  --confirm 'RELOAD IMESSAGE HOST BRIDGE'
bin/stella agent-status
```

Test one permitted and one forbidden synthetic target after the reload.

### Client add, revoke, or password change

Generate a new hash, update `users.caddy`, and restart Caddy so it reparses the imported user file:

```bash
bin/stella stop
bin/stella start
```

Test the changed credential and confirm revoked credentials fail. Removing a caller does not rotate the bridge token or private CA.

### Bridge token rotation

Stella 0.1.0 cannot hot-rotate the bridge token. The token is loaded independently by the LaunchAgent and into immutable container environment at `create` time.

For suspected disclosure, keep the facade stopped. Generate a new token into a private temporary file, atomically replace `secrets/bridge.token`, run `prepare`, and perform the confirmed bridge reload. The existing container must then be removed and recreated so it receives the new environment. The manager deliberately has no destructive container-removal action: verify the exact configured container with `bin/stella status` and follow the installed Apple Container version's documentation to remove **only that container**. Never prune all containers or delete Stella's bind-mounted state. Finish with `bin/stella create` and the full acceptance test.

Plan this as downtime and retain a reviewed rollback value until verification completes. Do not start the old container after the bridge has adopted the new token.

## Upgrade

1. Read the release notes, changelog, security advisories, and source diff.
2. Record the current revision, configuration, dependency versions, and sanitized health result.
3. Stop the facade.
4. Check out the immutable target release or full commit.
5. Run `make check` and update a user-local installation if used.
6. Source the private operator configuration.
7. Run `bin/stella doctor`, `bin/stella prepare`, `bin/stella build-host`, and `bin/stella check-host`.
8. Reload the LaunchAgent with the exact confirmation.
9. Restart the existing facade only when its environment and container definition remain compatible.
10. Run the full acceptance test and retain the prior source revision until confidence is established.

```bash
bin/stella agent-reload \
  --confirm 'RELOAD IMESSAGE HOST BRIDGE'
bin/stella stop
bin/stella start
```

In 0.1.0, `prepare` updates bind-mounted configuration but cannot reconcile environment variables or the definition of an already-created container. If the release changes those values, use a planned, exact-container recreation as described for token rotation. This is a current Alpha limitation, not an invitation to use broad cleanup commands.

## Backup and recovery

The source is recoverable from GitHub and the bridge can be rebuilt. Do not back up or copy the Messages database as part of Stella operations.

If continuity of client trust matters, protect an encrypted backup of the Stella runtime state—especially the Caddy CA—and restrict restore access like a credential vault. Otherwise, prefer regenerating secrets and deliberately enrolling clients in a new private CA. Never commit a runtime backup.

Recovery should be reproducible from:

- a pinned Stella revision;
- reviewed operator configuration;
- regenerated or securely restored secrets;
- an explicit allowlist and caller inventory;
- normal macOS permission approval;
- the acceptance checklist above.

## Uninstall boundary

`make uninstall` removes only files installed by the Makefile under the exact `PREFIX`. It deliberately preserves runtime state, secrets, LaunchAgents, and containers:

```bash
make PREFIX="$HOME/.local" uninstall
```

Removing a running deployment is a separate, destructive operator decision. Inventory the exact LaunchAgent, container, host route, client trust, and runtime directory before acting; Stella 0.1.0 intentionally provides no one-command teardown.
