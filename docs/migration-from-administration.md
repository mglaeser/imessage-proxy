# Migration from an administration repository

This guide moves an existing embedded Stella predecessor to the standalone repository at `https://github.com/mglaeser/stella`. It uses neutral placeholders so infrastructure names, addresses, and account details never need to enter the public repository.

The migration has two separate outcomes:

1. runtime operation comes from a checksum-pinned standalone Stella release; and
2. the administration repository stops owning copied Stella source and references the canonical repository instead.

Stella 0.1.1 is Alpha. Plan downtime and preserve a tested rollback path.

## What changes

| Embedded layout | Standalone Stella |
| --- | --- |
| Host bridge source inside an infrastructure tree | `src/stella-bridge.m` |
| Local manager script | `bin/stella` |
| Local reverse-proxy config | `config/Caddyfile` |
| Local LaunchAgent template | `config/io.github.mglaeser.stella.plist.in` |
| Local example environment | `config/stella.env.example` |
| Local bridge tests | `tests/test-stella-bridge.sh` |
| Deployment-specific README | Public README plus focused documents under `docs/` |

The new source checkout contains no runtime credentials, recipient lists, caller hashes, private certificates, hostnames, or addresses.

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
readonly stella_version='REPLACE_WITH_REVIEWED_VERSION'
readonly stella_sha256='REPLACE_WITH_REVIEWED_SHA256'
readonly stella_archive="stella-$stella_version.tar.gz"

curl --fail --location --proto '=https' --tlsv1.2 \
  "https://github.com/mglaeser/stella/releases/download/v$stella_version/$stella_archive" \
  --output "$stella_archive"
printf '%s  %s\n' "$stella_sha256" "$stella_archive" | shasum -a 256 --check
tar -xzf "$stella_archive" -C "$HOME/.local/src"
ln -sfn "stella-$stella_version" "$HOME/.local/src/stella"
make -C "$HOME/.local/src/stella" build
make -C "$HOME/.local/src/stella" test
```

Record both the version and exact archive SHA-256 in the private administration repository. GitHub releases also include a `SHA256SUMS` file and build-provenance attestation for independent verification. Do not deploy an unpinned default branch or a mutable release URL.

Create operator configuration from the standalone template outside both repositories:

```bash
mkdir -p "$HOME/.config/stella"
chmod 700 "$HOME/.config/stella"
install -m 600 \
  "$HOME/.local/src/stella/config/stella.env.example" \
  "$HOME/.config/stella/stella.env"
${EDITOR:-vi} "$HOME/.config/stella/stella.env"
```

Translate existing private values to the public `STELLA_*` variables. Keep `STELLA_ENABLE_ALPHA=no` until the cutover checklist is ready.

## 2. Choose runtime-state strategy

The recommended migration creates the new default Stella home and selectively transfers only reviewed values. Do not point `STELLA_HOME` at an old tree with a different layout and hope paths coincide.

Source the new environment and prepare the new layout:

```bash
cd "$HOME/.local/src/stella"
set -a
. "$HOME/.config/stella/stella.env"
set +a
bin/stella doctor
bin/stella prepare
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
- **Preserve the bridge token temporarily:** copy only the old token into `secrets/bridge.token` with mode `0600`, then rerun `bin/stella prepare` so generated environment uses it. Rotate through a planned container recreation after cutover.

Never copy a Messages database, full legacy state tree, log archive, plaintext client password, or deployment README into Stella.

Review the target list line-by-line and the caller hashes entry-by-entry. Migration is an opportunity to remove stale recipients and credentials. Do not carry forward `*` without a new documented risk decision.

## 3. Cut over the host bridge

1. Stop the old network facade so no client can send during the transition.
2. Unload the exact legacy LaunchAgent using its old runbook.
3. Confirm the old native bridge no longer listens.
4. Build and check the standalone bridge.
5. Grant Full Disk Access to the exact new binary if macOS treats it as a new TCC identity.
6. Install and inspect the new LaunchAgent.

```bash
cd "$HOME/.local/src/stella"
bin/stella build-host
bin/stella check-host
bin/stella agent-install
bin/stella agent-status
```

Do not run old and new LaunchAgents together. Do not change the new bridge from loopback binding to avoid a port collision.

## 4. Cut over the facade

The standalone manager uses its own container and host-route identity. Stop and inventory the legacy container before creating the new one. If an exact-name collision exists, resolve it during the planned cutover rather than using a random second instance.

```bash
bin/stella host-route-create
bin/stella hash-password
```

Add one newly generated hash per authorized client. Set `STELLA_ENABLE_ALPHA=yes`, source the environment again, and run:

```bash
bin/stella doctor
bin/stella create
bin/stella status
bin/stella ca-path
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

Remove the embedded implementation only after standalone acceptance. The administration repository may retain private deployment configuration and orchestration, but it should obtain Stella directly from a canonical, checksum-pinned GitHub release.

### Recommended: checksum-pinned release installer

Store a reviewed version and archive digest in private desired state. Provision a versioned source directory, verify the archive before extracting it, and then invoke commands through a stable symlink:

```bash
readonly stella_version='REPLACE_WITH_REVIEWED_VERSION'
readonly stella_sha256='REPLACE_WITH_REVIEWED_SHA256'
readonly stella_root="$HOME/.local/src"
readonly stella_checkout="$stella_root/stella-$stella_version"

# Use the verified download-and-extract sequence from section 1.
[[ "$(< "$stella_checkout/VERSION")" == "$stella_version" ]]
make -C "$stella_checkout" build
make -C "$stella_checkout" test
ln -sfn "stella-$stella_version" "$stella_root/stella"
"$stella_root/stella/bin/stella" doctor
```

Production provisioning should fail closed on a version or digest mismatch. Extract into a temporary directory before atomically changing the symlink, and keep the previous version for rollback. Update the two pins through reviewed changes, never by resolving “latest” during a provisioning run.

### Alternative: Git submodule

A submodule makes the dependency visible in the administration repository's tree and commit history:

```bash
git submodule add https://github.com/mglaeser/stella.git vendor/stella
git -C vendor/stella checkout REPLACE_WITH_REVIEWED_TAG_OR_COMMIT
git add .gitmodules vendor/stella
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

Link to Stella's public [Operations](operations.md), [API](api.md), and [Security model](security.md), while keeping deployment-specific hostnames, addresses, credentials, and recipients only in private documentation.

## 7. Remove the embedded copy

After the rollback window and a reviewed search for consumers:

1. remove only the old embedded source/config/test directory from the administration repository;
2. retain the pinned external reference and private deployment configuration;
3. run administration-repository tests and Stella's `make test`;
4. confirm no automation still calls the old manager path;
5. record the extraction and standalone version in both changelogs.

Do not delete runtime state as part of removing source. Source ownership, installed packaging files, LaunchAgent state, container state, secrets, and client trust are separate lifecycle domains.

## Migration completion checklist

- [ ] Standalone source comes only from `github.com/mglaeser/stella` at a checksum-pinned release.
- [ ] The administration repository no longer contains copied Stella implementation files.
- [ ] Private orchestration invokes `bin/stella` from the standalone checkout or installed prefix.
- [ ] Only one bridge LaunchAgent and one network facade are active.
- [ ] Runtime secrets and CA material remain outside both repositories with restrictive modes.
- [ ] Every client and allowed target has a current owner and purpose.
- [ ] Private DNS, CA trust, monitoring, restart, upgrade, and rollback procedures were tested.
- [ ] Public documents contain no deployment-specific host, user, address, domain, or secret data.
