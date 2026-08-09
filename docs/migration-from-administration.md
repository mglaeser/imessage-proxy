# Migration from an administration repository

This guide moves an existing embedded Stella predecessor to the standalone iMessage Proxy repository at `https://github.com/mglaeser/imessage-proxy`. It uses neutral placeholders so infrastructure names, addresses, and account details never need to enter the public repository.

The migration has two separate outcomes:

1. runtime operation comes from a checksum-pinned standalone iMessage Proxy release; and
2. the administration repository stops owning copied iMessage Proxy source and references the canonical repository instead.

iMessage Proxy 0.2.0 is Alpha. Plan downtime and preserve a tested rollback path.

## What changes

| Embedded layout | Standalone iMessage Proxy |
| --- | --- |
| Host bridge source inside an infrastructure tree | `src/imessage-proxy-bridge.m` |
| Local manager script | `bin/imessage-proxy` |
| Local reverse-proxy config | `config/Caddyfile` |
| Local LaunchAgent template | `config/io.github.mglaeser.stella.plist.in` |
| Local example environment | `config/imessage-proxy.env.example` |
| Local bridge tests | `tests/test-imessage-proxy-bridge.sh` |
| Deployment-specific README | Public README plus focused documents under `docs/` |

The new source checkout contains no runtime credentials, recipient lists, caller hashes, private certificates, hostnames, or addresses.

## 0.2 rename compatibility

Version 0.2.0 changes the public repository, command, source, config, and environment names to `imessage-proxy`, `bin/imessage-proxy`, `src/imessage-proxy-bridge.m`, `config/imessage-proxy.env.example`, and `IMESSAGE_PROXY_*`. The deprecated `bin/stella` command and `STELLA_*` variables remain compatibility aliases for this transition release; conflicting canonical and legacy values fail closed.

The release deliberately keeps these runtime identities unchanged:

- home `~/Library/Application Support/Stella`;
- bridge binary `stella-bridge` and LaunchAgent label `io.github.mglaeser.stella.bridge`;
- Apple Container name `stella`; and
- host route `stella-host.container.internal`.

The public build artifact is `imessage-proxy-bridge`, but `build-host` installs it under the legacy runtime binary name. No runtime directory, private CA, TCC grant, LaunchAgent, container, route, receipt, or migration state is renamed automatically. Preserve those identities unless a later release provides an explicit, reviewed migration.

## Before the maintenance window

Inventory without printing secret contents:

- the exact embedded source revision and path;
- the old manager and LaunchAgent label;
- native bridge binary and port;
- container name, image digest, published address, and host-route name;
- bridge token, send-target list, caller hash file, and their modes;
- Caddy data/CA state and every enrolled client;
- private DNS and firewall/VPN rules;
- all provisioning, migration, monitoring, and runbook references to the embedded path.

Capture a sanitized health check and prove you can stop and restore the old service. Do not proceed without a clear way to prevent old and new bridges from listening simultaneously.

## 1. Establish the standalone source

Download a reviewed release archive and verify it against a checksum already pinned in your private desired state. Do not trust a checksum fetched alongside the archive as the only integrity decision:

```bash
readonly imessage_proxy_version='REPLACE_WITH_REVIEWED_VERSION'
readonly imessage_proxy_sha256='REPLACE_WITH_REVIEWED_SHA256'
readonly imessage_proxy_archive="imessage-proxy-$imessage_proxy_version.tar.gz"

curl --fail --location --proto '=https' --tlsv1.2 \
  "https://github.com/mglaeser/imessage-proxy/releases/download/v$imessage_proxy_version/$imessage_proxy_archive" \
  --output "$imessage_proxy_archive"
printf '%s  %s\n' "$imessage_proxy_sha256" "$imessage_proxy_archive" | shasum -a 256 --check
tar -xzf "$imessage_proxy_archive" -C "$HOME/.local/src"
ln -sfn "imessage-proxy-$imessage_proxy_version" "$HOME/.local/src/imessage-proxy"
make -C "$HOME/.local/src/imessage-proxy" build
make -C "$HOME/.local/src/imessage-proxy" test
```

Record both the version and exact archive SHA-256 in the private administration repository. GitHub releases also include a `SHA256SUMS` file and build-provenance attestation for independent verification. Do not deploy an unpinned default branch or a mutable release URL.

Create operator configuration from the standalone template outside both repositories:

```bash
mkdir -p "$HOME/.config/imessage-proxy"
chmod 700 "$HOME/.config/imessage-proxy"
install -m 600 \
  "$HOME/.local/src/imessage-proxy/config/imessage-proxy.env.example" \
  "$HOME/.config/imessage-proxy/imessage-proxy.env"
${EDITOR:-vi} "$HOME/.config/imessage-proxy/imessage-proxy.env"
```

Translate existing private values to the public `IMESSAGE_PROXY_*` variables. Keep `IMESSAGE_PROXY_ENABLE_ALPHA=no` until the cutover checklist is ready.

## 2. Choose runtime-state strategy

The recommended extraction prepares the retained default runtime home and selectively transfers only reviewed values when the embedded predecessor used a different layout. Do not point `IMESSAGE_PROXY_HOME` at an unrelated old tree and hope paths coincide. If an existing standalone 0.1.x deployment already uses the default home, preserve it in place instead of copying it onto itself.

Source the new environment and prepare the new layout:

```bash
cd "$HOME/.local/src/imessage-proxy"
set -a
. "$HOME/.config/imessage-proxy/imessage-proxy.env"
set +a
bin/imessage-proxy doctor
bin/imessage-proxy prepare
```

The default destination is `~/Library/Application Support/Stella`:

```text
secrets/bridge.token
secrets/allowed-targets.txt
secrets/users.caddy
state/caddy/data/
```

Choose deliberately:

- **Rotate credentials and CA:** safest when client re-enrollment is practical. Keep newly generated token and Caddy state; recreate caller passwords and review targets by hand.
- **Preserve client trust:** transfer the existing Caddy data directory through an encrypted, permission-preserving process and verify it before startup. This also preserves a sensitive CA private key.
- **Preserve the bridge token temporarily:** copy only the old token into `secrets/bridge.token` with mode `0600`, then rerun `bin/imessage-proxy prepare` so generated environment uses it. Rotate through a planned container recreation after cutover.

Never copy a Messages database, full legacy state tree, log archive, plaintext client password, or deployment README into iMessage Proxy.

Review the target list line-by-line and the caller hashes entry-by-entry. Migration is an opportunity to remove stale recipients and credentials. Do not carry forward `*` without a new documented risk decision.

## 3. Cut over the host bridge

1. Stop the old network facade so no client can send during the transition.
2. Unload the exact legacy LaunchAgent using its old runbook.
3. Confirm the old native bridge no longer listens.
4. Build and check the standalone bridge.
5. Verify Full Disk Access for the exact installed `stella-bridge` runtime binary, reauthorizing only if macOS requests it.
6. Install and inspect the new LaunchAgent.

```bash
cd "$HOME/.local/src/imessage-proxy"
bin/imessage-proxy build-host
bin/imessage-proxy check-host
bin/imessage-proxy agent-install
bin/imessage-proxy agent-status
```

Do not run old and new LaunchAgents together. Do not change the new bridge from loopback binding to avoid a port collision.

## 4. Cut over the facade

The standalone manager retains container `stella` and host route `stella-host.container.internal`. It does not silently adopt or reconcile an existing container definition. Stop and inventory the exact legacy container before the cutover. Never create a random second instance to bypass a name collision.

```bash
bin/imessage-proxy host-route-create
bin/imessage-proxy hash-password
```

Add one newly generated hash per authorized client when credentials are being rotated. Set `IMESSAGE_PROXY_ENABLE_ALPHA=yes`, source the environment again, and run:

```bash
bin/imessage-proxy doctor
```

Then choose exactly one path based on the recorded container definition:

- **Compatible existing container:** keep the stopped `stella` container and run `bin/imessage-proxy start`, followed by `bin/imessage-proxy status`. This preserves its immutable creation-time environment and mounts.
- **Incompatible or absent container:** if it exists, remove only the exact stopped `stella` container using the reviewed Apple Container procedure. Confirm that name is absent, then run `bin/imessage-proxy create` and `bin/imessage-proxy status`. The manager deliberately provides no delete or prune action.

`create` must refuse while the retained container exists. Do not remove a compatible container merely to make that command succeed.

After the selected path has started Caddy and `status` reports the expected container, print the active root certificate path:

```bash
bin/imessage-proxy ca-path
```

If the CA changed, securely enroll the new root certificate on each client and verify its fingerprint. Update private DNS only after the new endpoint passes a direct health check. Never overlap two active endpoints accepting sends for the same clients.

## 5. Acceptance and rollback gate

Run the complete checklist in [Operations](operations.md), including unauthorized access, forbidden method, forbidden recipient, bounded read, one agreed test send, private-network reachability, and sanitized logs.

Rollback if any security invariant fails:

1. Stop the new facade.
2. Keep the new bridge stopped/unloaded if its state is uncertain.
3. Restore the old LaunchAgent and facade using the pre-migration runbook.
4. Restore private DNS and client CA settings if they changed.
5. Confirm health and one non-sending read before reopening automation.

Do not delete old source or state until the rollback window closes. Never attempt rollback by running both stacks concurrently.

## 6. Update the administration repository

Remove the embedded implementation only after standalone acceptance. The administration repository may retain private deployment configuration and orchestration, but it should obtain iMessage Proxy directly from a canonical, checksum-pinned GitHub release.

### Recommended: checksum-pinned release installer

Store a reviewed version and archive digest in private desired state. Provision a versioned source directory, verify the archive before extracting it, and then invoke commands through a stable symlink:

```bash
readonly imessage_proxy_version='REPLACE_WITH_REVIEWED_VERSION'
readonly imessage_proxy_sha256='REPLACE_WITH_REVIEWED_SHA256'
readonly imessage_proxy_root="$HOME/.local/src"
readonly imessage_proxy_checkout="$imessage_proxy_root/imessage-proxy-$imessage_proxy_version"

# Use the verified download-and-extract sequence from section 1.
[[ "$(< "$imessage_proxy_checkout/VERSION")" == "$imessage_proxy_version" ]]
make -C "$imessage_proxy_checkout" build
make -C "$imessage_proxy_checkout" test
ln -sfn "imessage-proxy-$imessage_proxy_version" "$imessage_proxy_root/imessage-proxy"
"$imessage_proxy_root/imessage-proxy/bin/imessage-proxy" doctor
```

Production provisioning should fail closed on a version or digest mismatch. Extract into a temporary directory before atomically changing the symlink, and keep the previous version for rollback. Update the two pins through reviewed changes, never by resolving “latest” during a provisioning run.

### Alternative: Git submodule

A submodule makes the dependency visible in the administration repository's tree and commit history:

```bash
git submodule add https://github.com/mglaeser/imessage-proxy.git vendor/imessage-proxy
git -C vendor/imessage-proxy checkout REPLACE_WITH_REVIEWED_TAG_OR_COMMIT
git add .gitmodules vendor/imessage-proxy
```

Provisioning must use `git submodule update --init --recursive` and must never assume the submodule follows the latest default branch. Choose this option only if the repository's deployment tooling already handles submodules reliably.

### References to replace

Search the administration repository for the old directory, filenames, LaunchAgent label, container name, environment variables, and service commands:

```bash
rg -n 'OLD_COMPONENT_PATH|OLD_MANAGER_NAME|OLD_LAUNCH_LABEL|OLD_CONTAINER_NAME' .
```

Update:

- install and migration scripts;
- host provisioning and desired-state checks;
- monitoring and health-check commands;
- backup/restore and incident runbooks;
- dependency inventories and license notices;
- documentation links.

Link to iMessage Proxy's public [Operations](operations.md), [API](api.md), and [Security model](security.md), while keeping deployment-specific hostnames, addresses, credentials, and recipients only in private documentation.

## 7. Remove the embedded copy

After the rollback window and a reviewed search for consumers:

1. remove only the old embedded source/config/test directory from the administration repository;
2. retain the pinned external reference and private deployment configuration;
3. run administration-repository tests and iMessage Proxy's `make test`;
4. confirm no automation still calls the old manager path;
5. record the extraction and standalone version in both changelogs.

Do not delete runtime state as part of removing source. Source ownership, installed packaging files, LaunchAgent state, container state, secrets, and client trust are separate lifecycle domains.

## Migration completion checklist

- [ ] Standalone source comes only from `github.com/mglaeser/imessage-proxy` at a checksum-pinned release.
- [ ] The administration repository no longer contains copied iMessage Proxy implementation files.
- [ ] Private orchestration invokes `bin/imessage-proxy` from the standalone checkout or installed prefix.
- [ ] Only one bridge LaunchAgent and one network facade are active.
- [ ] Runtime secrets and CA material remain outside both repositories with restrictive modes.
- [ ] Every client and allowed target has a current owner and purpose.
- [ ] Private DNS, CA trust, monitoring, restart, upgrade, and rollback procedures were tested.
- [ ] Public documents contain no deployment-specific host, user, address, domain, or secret data.
