# Operations

This guide covers a review-first iMessage Proxy 0.3.0 deployment. iMessage Proxy is Alpha software: use a harmless test recipient, schedule a maintenance window, and keep an independent way to access the Mac.

## Operating principles

- Run every iMessage Proxy command as the non-root GUI user signed in to Messages.
- Keep the repository and runtime state separate.
- Pin the iMessage Proxy revision and Caddy image digest; review both before changing them.
- Publish only on a selected private interface reachable from an authenticated LAN or VPN.
- Give every client its own credential, and enroll it only if it may use the
  complete current read API plus the deployment-wide send allowlist.
- Never disable TLS verification, SIP, TCC, or the outbound target allowlist to make a check pass.
- Stop on unexpected output. iMessage Proxy intentionally avoids automatic deletion, reset, pruning, and retrying sends.

### Automated orchestration

Treat automated mutation as a state machine, not as a command that can be
blindly rerun:

- Acquire a private exclusive lock owned by the deployment user. Refuse
  symbolic links, unexpected ownership or modes, and a competing lock holder.
- Validate the pinned release, current receipt, stable source link, runtime
  resources, and listener state before the lock and again immediately after
  acquiring it. Never turn an inventory error into an observation of absence.
- Atomically create a mode-`0600`, metadata-only receipt in `in_progress` before
  the first mutation. Store only its schema, timestamps, immutable release pins,
  sanitized observations, and resource identities—never credentials, message
  data, recipients, or private key material.
- Allow only `in_progress` to `failed_observation_required` or
  `pending_acceptance`, and `pending_acceptance` to `accepted`. Write a complete
  temporary receipt in the same private directory, set its mode, sync it as
  supported, and atomically replace the prior file; never edit one in place.
- Make `accepted` a separate explicit action after the complete acceptance
  test. An invalid receipt, `in_progress`, or `failed_observation_required`
  requires human observation and blocks retry, rollback automation, and a
  second deployment. Keep a failed receipt as durable evidence rather than
  transitioning it backward; any later recovery needs a separately reviewed
  generation. Ambiguity is not a safe retry condition.

The administration system chooses its private lock and receipt paths. Do not
publish deployment users, addresses, private artifact pins, or receipt paths in
this repository.

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

## 2. Obtain and verify iMessage Proxy

For an operated deployment, record a reviewed release tag, the full
40-character commit to which it resolves, and the release archive SHA-256 in
independent desired state. Use the private staging, member validation, build,
test, and atomic stable-link promotion procedure in
[Migration from an administration repository](migration-from-administration.md#1-establish-the-standalone-source).
That procedure rejects escaping or link entries before extraction and retains
the previously selected versioned directory for rollback. Do not obtain
production code from a default branch, a `latest` URL, or a checksum fetched
alongside the artifact as the only integrity decision.

For source review or development, initialize a detached checkout and prove that
the reviewed tag resolves to the recorded commit before executing it:

```bash
(
set -Eeuo pipefail
readonly imessage_proxy_tag='REPLACE_WITH_REVIEWED_TAG'
readonly imessage_proxy_revision='REPLACE_WITH_REVIEWED_40_HEX_COMMIT'

[[ "$imessage_proxy_revision" =~ ^[0-9a-f]{40}$ ]]
mkdir imessage-proxy
cd imessage-proxy
git init
git remote add origin https://github.com/mglaeser/imessage-proxy.git
git fetch --depth=1 origin \
  "refs/tags/$imessage_proxy_tag:refs/tags/$imessage_proxy_tag"
test "$(git rev-parse "$imessage_proxy_tag^{commit}")" = \
  "$imessage_proxy_revision"
git checkout --detach "$imessage_proxy_revision"
git status --short
make build
make test
)
```

For the complete maintainer check suite, install the lint tools named by the Makefile and run:

```bash
make check
```

You can operate directly from the verified candidate with
`bin/imessage-proxy`. For a user-local installation that keeps runtime state
untouched, install only after the candidate passes its tests:

```bash
make PREFIX="$HOME/.local" install
"$HOME/.local/bin/imessage-proxy" version
```

Installed project assets live under `$PREFIX/share/imessage-proxy`; runtime state remains separate. The remainder of this guide uses `bin/imessage-proxy`. Substitute the installed command when appropriate.

### Rename transition in 0.2.0

The canonical command and environment prefix are `bin/imessage-proxy` and `IMESSAGE_PROXY_*`. The deprecated `bin/stella` shim and `STELLA_*` aliases remain available for this transition release. Do not define both forms with different values; ambiguity is rejected instead of choosing one silently.

Version 0.3.0 continues the 0.2 transition and does not automatically rename or move runtime resources. It retains:

- runtime home `~/Library/Application Support/Stella`;
- runtime bridge binary `stella-bridge` and LaunchAgent label `io.github.mglaeser.stella.bridge`;
- Apple Container name `stella`; and
- host route `stella-host.container.internal`.

The repository source and public build artifact are named
`imessage-proxy-bridge`; `build-host` installs that code as the legacy-named
runtime binary to preserve macOS TCC approval. Retaining the runtime path avoids
an unreviewed path and TCC migration, but iMessage Proxy never treats that as
permission to preserve old credentials silently. Plan credential and CA
rotation explicitly for a migration or recovery, and translate operator
automation to the canonical command and environment names separately.

If version 0.1.x was installed with `make install`, its read-only package assets live under the separate prefix path `share/stella`. From the exact retained 0.1.x source checkout, run its `make uninstall` before installing the current release, then run the current install command. The old uninstaller does not touch runtime state. Current installers deliberately do not delete an unknown pre-existing `share/stella` tree; if the old checkout is unavailable, inspect that tree and remove only verified 0.1.x package files through a separately reviewed cleanup.

## 3. Create operator configuration

Keep the sourced environment file outside the repository:

```bash
mkdir -p "$HOME/.config/imessage-proxy"
chmod 700 "$HOME/.config/imessage-proxy"
install -m 600 config/imessage-proxy.env.example "$HOME/.config/imessage-proxy/imessage-proxy.env"
${EDITOR:-vi} "$HOME/.config/imessage-proxy/imessage-proxy.env"
```

Set and review:

| Variable | Purpose |
| --- | --- |
| `IMESSAGE_PROXY_API_HOST` | Private DNS name on the TLS certificate |
| `IMESSAGE_PROXY_API_PORT` | Published HTTPS port, default `9443` |
| `IMESSAGE_PROXY_BIND_IP` | Exact private address assigned to the Mac |
| `IMESSAGE_PROXY_CADDY_IMAGE` | Official Caddy image pinned by SHA-256 digest |
| `IMESSAGE_PROXY_ENABLE_ALPHA` | Explicit Alpha deployment gate; leave `no` until acceptance prerequisites are ready |

Optional advanced settings include `IMESSAGE_PROXY_HOME`, `IMESSAGE_PROXY_SOURCE_DIR`, `IMESSAGE_PROXY_CONTAINER_NAME`, `IMESSAGE_PROXY_BRIDGE_HOST`, `IMESSAGE_PROXY_BRIDGE_HOST_IP`, and `IMESSAGE_PROXY_BRIDGE_PORT`. Keep defaults unless the topology requires a reviewed change.

The example address is documentation-only. Replace every placeholder with observed deployment values. Source the file into each new operator shell:

```bash
set -a
. "$HOME/.config/imessage-proxy/imessage-proxy.env"
set +a
```

`IMESSAGE_PROXY_HOME` defaults to `~/Library/Application Support/Stella`. It holds secrets and private CA material; do not put it in the repository or a broadly synchronized folder.

For a migration or recovery, the default is a fresh bridge token, fresh
per-client passwords, and a new private Caddy CA followed by authenticated
client enrollment and independent fingerprint confirmation. Keep replaced
material only in a protected, bounded rollback snapshot.

Preserving credentials or the CA is an advanced continuity exception. First
quiesce both facade and bridge, create an encrypted permission-preserving
snapshot, and verify the exact state root, ownership, modes, and CA fingerprint.
Restore only reviewed material, record an owner and deadline for rotation, and
never allow preserved and replacement identities to accept traffic at the same
time.

## 4. Diagnose and prepare

Run the non-mutating preflight first:

```bash
bin/imessage-proxy doctor
```

`doctor` validates the toolchain plus sourced static API, route, image, private
bind, and Alpha-gate settings, reporting independent setting failures together.
It does not claim that generated files,
LaunchAgent state, route resolution, listeners, or container topology are
already ready; their owning lifecycle actions verify those live states before
mutation. Resolve every failed required check. Then create private runtime
directories, initial secrets, generated facade environment, Caddy configuration,
and LaunchAgent template:

```bash
bin/imessage-proxy prepare
```

`prepare` creates missing material but deliberately does not rotate an existing
token or CA. An existing token must be exactly 64 lowercase hexadecimal bytes
with at most one trailing newline; any other byte shape is rejected before it
can be copied into the facade environment. For a migration or recovery with an existing runtime home, keep the
facade and bridge quiesced and complete the reviewed rotation or advanced
preservation procedure before relying on the generated configuration. Do not
delete live state ad hoc merely to make `prepare` generate replacements.

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
bin/imessage-proxy hash-password
```

Choose a new, high-entropy password and store it in the client's secret manager. Add only the resulting Caddy hash to `~/Library/Application Support/Stella/secrets/users.caddy`:

```text
automation-a $2a$14$REPLACE_WITH_GENERATED_HASH
```

Use a separate entry for every client. Never place plaintext passwords in this file, the environment, command arguments, or shell history.

## 5. Build and authorize the native bridge

Build an ad-hoc-signed runtime binary from the checked-out source and validate its configuration:

```bash
bin/imessage-proxy build-host
bin/imessage-proxy check-host
```

Inspect the generated binary and LaunchAgent paths printed by the manager. In System Settings, grant Full Disk Access to that exact `stella-bridge` binary. Do not grant it to unrelated shells or disable SIP.

Install the user LaunchAgent and verify its state:

```bash
bin/imessage-proxy agent-install
bin/imessage-proxy agent-status
```

The LaunchAgent must run in the Messages user's GUI domain, never as root. On the first intentional send, approve the macOS Automation prompt for Messages.app. If the prompt or read access fails, troubleshoot TCC rather than broadening filesystem permissions.

`agent-install` never overwrites an unexpected plist. It reuses an existing
target only when it is a private, regular file whose bytes exactly match the
generated legacy-identity plist; inspect any refusal before using the separately
confirmed reload workflow.

The confirmed reload refuses to stop a same-label job whose loaded plist or
program identity differs. If the replacement cannot become ready, automatic
rollback may execute the previous plist only when that backup independently
matches the complete reviewed schema. Otherwise the prior file is preserved at
the reported private backup path for manual inspection and is not bootstrapped.

Before `create` or `start` can expose the facade, the manager rechecks that the
prepared plist still has the complete reviewed program, environment, limits,
and log-path definition; the active plist matches it byte for byte; the loaded
job reports the exact plist and bridge executable; one stable running PID
exists; and that PID owns exactly one TCP listener, at
`127.0.0.1:<bridge-port>`. It also compares a bearer-authenticated digest of the
configuration loaded by that process with fresh, isolated evaluations of the
exact token and allowlist file bytes, paths, and bounded runtime settings. The
digest response exposes none of those values, its internal route is not
published by Caddy, and expected state is sampled on both sides of the live
request. A stale configuration, wildcard/IPv6/extra listener, same-label,
crash-looping, replaced, or ambiguous job is not treated as ready.

## 6. Create the private facade

Create the Apple Container host route:

```bash
bin/imessage-proxy host-route-create
```

This operation may request `sudo` for Apple Container's host-routing change. Review the exact command. Never work around a route failure by changing the bridge listener to a non-loopback address.

iMessage Proxy verifies that the route's DNS name resolves only to
`IMESSAGE_PROXY_BRIDGE_HOST_IP`. An existing name with a different mapping is refused;
repair it only through the explicit `host-route-refresh` confirmation.

> [!CAUTION]
> Apple Container's localhost host-routing feature can disable iCloud Private Relay, and its route may need to be recreated after a Mac restart. Confirm the behavior for the installed Apple Container release before enabling it.

After completing the security checklist, deliberately set
`IMESSAGE_PROXY_ENABLE_ALPHA=yes` in the private operator configuration, source
it again, and rerun `bin/imessage-proxy doctor` to confirm that the static
settings and gate are valid. The following `create` command independently
enforces the generated files and observed runtime prerequisites.

Create the resource-bounded Caddy container:

```bash
bin/imessage-proxy create
bin/imessage-proxy status
```

`create` accepts only an assigned RFC 1918 or RFC 6598 IPv4 address. The facade's
source filter admits the same client ranges (plus Caddy's loopback and IPv6 ULA
ranges), then still requires an individual credential. `create` also
checks the caller file, requires the LaunchAgent and exact route DNS mapping,
and refuses colliding API/bridge ports, an occupied API port, or the existing
legacy-named `stella` container.

`status` deliberately prints only the container name, lifecycle state, and
sanitized published-port fields. Raw inventory is projected at the subprocess
boundary, so it never returns the container environment, bridge token, mounts,
or other unbounded inspection data.

`start` fails closed unless the existing container matches the reviewed image
digest, default runtime/network/DNS/process-security shape, resource limits,
read-only mode, exact mounts and tmpfs, entrypoint and arguments, bounded
environment (including the prepared token without printing it), and configured
private publication. It then revalidates the LaunchAgent identity, stable PID,
exact loopback-only listener ownership, live configuration fingerprint, and host
route before starting a stopped container.

## 7. Enroll a client

Print the Caddy root certificate path on the Mac:

```bash
bin/imessage-proxy ca-path
```

Transfer the **root certificate only** to the authorized client over an authenticated channel. Never transfer the CA private key or the full Caddy data directory. Confirm the certificate fingerprint independently before trusting it.

From the client, test with certificate verification enabled; `curl` prompts for the caller password:

```bash
curl \
  --cacert /secure/path/imessage-proxy-root.crt \
  --user automation-a \
  https://messages.example.internal:9443/healthz
```

Never use `--insecure` or `-k`.

## 8. Acceptance test

Before relying on iMessage Proxy, verify all of the following:

1. A request without credentials fails.
2. A request with the wrong client password fails.
3. `/healthz` succeeds with a valid caller and the pinned CA.
4. A bounded `messages.after` call succeeds without attachments or reactions.
5. An unknown RPC method returns `403`.
6. A send to an unlisted synthetic target returns `403` and sends nothing.
7. One consenting, harmless allowlisted target receives one intentional test
   message and confirms the actual Messages sender account or handle is the
   expected identity.
8. Audit output contains caller, method, status, and duration but no content or recipient.
9. The API is unreachable from an untrusted network.
10. Stop/start and a Mac restart follow the documented recovery sequence.

Do not automatically retry an ambiguous send; inspect history or send status first.

## Routine lifecycle

| Task | Command | Notes |
| --- | --- | --- |
| Static preflight | `bin/imessage-proxy doctor` | Non-mutating toolchain, settings, bind, and Alpha-gate diagnostics |
| Host config validation | `bin/imessage-proxy check-host` | Checks secret files, bridge, and `imsg` |
| LaunchAgent state | `bin/imessage-proxy agent-status` | Uses the current GUI user domain |
| Facade state | `bin/imessage-proxy status` | Returns only the configured container entry |
| Facade logs | `bin/imessage-proxy logs` | Review and sanitize before sharing |
| Stop facade | `bin/imessage-proxy stop` | Preferred first incident-containment action |
| Start facade | `bin/imessage-proxy start` | Requires an existing container and valid host route |
| Project version | `bin/imessage-proxy version` | Compare with the pinned checkout |

After a Mac restart, refresh the exact Apple Container host route before starting or testing the facade:

```bash
bin/imessage-proxy host-route-refresh \
  --confirm 'REFRESH IMESSAGE HOST ROUTE'
bin/imessage-proxy start
```

The explicit confirmation is intentional. Host-route persistence and side effects can change across Apple Container releases.

## Configuration changes

### Send-target allowlist

Edit the mode-0600 `allowed-targets.txt`, review the diff manually, and reload the native bridge:

```bash
bin/imessage-proxy agent-reload \
  --confirm 'RELOAD IMESSAGE HOST BRIDGE'
bin/imessage-proxy agent-status
```

Test one permitted and one forbidden synthetic target after the reload.

### Client add, revoke, or password change

Generate a new hash, update `users.caddy`, and restart Caddy so it reparses the imported user file:

```bash
bin/imessage-proxy stop
bin/imessage-proxy start
```

Test the changed credential and confirm revoked credentials fail. Removing a caller does not rotate the bridge token or private CA.

### Bridge token rotation

iMessage Proxy currently cannot hot-rotate the bridge token. The token is loaded independently by the LaunchAgent and into immutable container environment at `create` time.

For suspected disclosure, keep the facade stopped. Generate a new token into a private temporary file, atomically replace `secrets/bridge.token`, run `prepare`, and perform the confirmed bridge reload. The existing container must then be removed and recreated so it receives the new environment. The manager deliberately has no destructive container-removal action: verify the exact configured container with `bin/imessage-proxy status` and follow the installed Apple Container version's documentation to remove **only that container**. Never prune all containers or delete the bind-mounted runtime state. Finish with `bin/imessage-proxy create` and the full acceptance test.

Plan this as downtime and retain a reviewed rollback value until verification completes. Do not start the old container after the bridge has adopted the new token.

## Upgrade

1. Read the release notes, changelog, security advisories, and source diff.
2. Record the current immutable release pins, configuration, dependency
   versions, runtime identities, and sanitized health result.
3. Obtain the target through the verified archive procedure, extract it only
   into a private stage, validate its members and `VERSION`, and run the complete
   `make check` suite before promoting its versioned directory. Keep the stable
   link on the current release during these checks.
4. Stop the facade and record that its expected listener is absent.
5. Atomically select the already-tested target while retaining the prior
   versioned directory. Update a user-local installation if used.
6. Source the private operator configuration.
7. Run `bin/imessage-proxy doctor`, `bin/imessage-proxy prepare`,
   `bin/imessage-proxy build-host`, and `bin/imessage-proxy check-host`.
8. Reload the LaunchAgent with the exact confirmation.
9. Restart the existing facade only when its environment and container
   definition remain compatible.
10. Run the full acceptance test, including receiver confirmation of the actual
    Messages sender identity, before recording acceptance or removing the prior
    version.

```bash
bin/imessage-proxy agent-reload \
  --confirm 'RELOAD IMESSAGE HOST BRIDGE'
```

Only after the exact compatibility check in step 9 succeeds, restart the facade
that was stopped in step 4:

```bash
bin/imessage-proxy start
```

During Alpha, `prepare` updates bind-mounted configuration but cannot reconcile environment variables or the definition of an already-created container. If the release changes those values, use a planned, exact-container recreation as described for token rotation. This is a current limitation, not an invitation to use broad cleanup commands.

### Failure and rollback decision

Choose from observed state:

- **Failure before mutation:** leave the active release and runtime untouched,
  discard only the validated private stage, and investigate. No rollback is
  needed.
- **Fully observed, reversible mutation:** quiesce the facade and bridge, restore
  the exact prior stable source selection and any matching reviewed runtime,
  DNS, credential, and client-trust state, then repeat non-sending checks before
  reopening access. Never activate old and new stacks together.
- **Uncertain partial failure:** contain network access, preserve receipts and
  sanitized diagnostics, and inventory the actual stable link, processes,
  listeners, LaunchAgent, container definition, route, DNS, credentials, and CA
  trust. Record `failed_observation_required` and do not automatically retry,
  roll forward, or roll back until an operator establishes one coherent state.

A delivered message cannot be rolled back. If a send result is ambiguous,
inspect history and confirm with the receiver; do not repeat it as part of
recovery.

## Backup and recovery

The source is recoverable from GitHub and the bridge can be rebuilt. Do not back up or copy the Messages database as part of iMessage Proxy operations.

Prefer regenerating the bridge token and caller credentials, issuing a new
private CA, and deliberately enrolling clients. If continuity of client trust
makes preservation unavoidable, treat it as an advanced exception: quiesce the
facade and bridge before capturing an encrypted, permission-preserving runtime
backup—especially the Caddy CA—and restrict restore access like a credential
vault. Never capture live changing state, commit a runtime backup, or restore it
alongside replacement credentials or CA material.

Recovery should be reproducible from:

- a pinned iMessage Proxy revision;
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

Removing a running deployment is a separate, destructive operator decision. Inventory the exact LaunchAgent, container, host route, client trust, and runtime directory before acting; iMessage Proxy intentionally provides no one-command teardown during Alpha.
