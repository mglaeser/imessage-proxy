# Migration from an administration repository

This guide moves an existing embedded Stella predecessor to the standalone iMessage Proxy repository at `https://github.com/mglaeser/imessage-proxy`. It uses neutral placeholders so infrastructure names, addresses, and account details never need to enter the public repository.

The migration has two separate outcomes:

1. runtime operation comes from a checksum-pinned standalone iMessage Proxy release; and
2. the administration repository stops owning copied iMessage Proxy source and references the canonical repository instead.

iMessage Proxy 0.3.0 is Alpha. Plan downtime and preserve a tested rollback path.

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

The new source checkout contains no runtime credentials, recipient lists, caller hashes, private certificates, or deployment-specific/private hostnames or addresses.

## 0.2 rename compatibility

Version 0.2.0 changes the public repository, command, source, config, and environment names to `imessage-proxy`, `bin/imessage-proxy`, `src/imessage-proxy-bridge.m`, `config/imessage-proxy.env.example`, and `IMESSAGE_PROXY_*`. The deprecated `bin/stella` command and `STELLA_*` variables remain compatibility aliases for this transition release; conflicting canonical and legacy values fail closed.

Version 0.3.0 retains that transition contract; it does not rename runtime or
migration identities automatically.

The release deliberately keeps these runtime identities unchanged:

- home `~/Library/Application Support/Stella`;
- bridge binary `stella-bridge` and LaunchAgent label `io.github.mglaeser.stella.bridge`;
- Apple Container name `stella`; and
- host route `stella-host.container.internal`.

The public build artifact is `imessage-proxy-bridge`, but `build-host` installs it under the legacy runtime binary name. No runtime path, private CA, TCC grant, LaunchAgent, container, route, receipt, or migration state is renamed automatically. This guide preserves the compatible runtime path and state boundary; its explicit default migration replaces the private CA and credentials under quiescence, followed by deliberate client enrollment. Preserve the other runtime identities unless a later release provides an explicit, reviewed migration.

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

Review a release tag, the full 40-character source commit to which it resolves,
and the release archive SHA-256 as three explicit inputs. Verify the tag-to-commit
relationship from reviewed Git metadata or build provenance, and keep the digest
in private desired state before the migration starts. A checksum downloaded
beside the archive during the same run is transport evidence, not an independent
integrity decision.

Stage the archive under a private temporary directory on the same filesystem as
the versioned install root. Before extraction, require one expected top-level
directory, an exact `VERSION` member, no absolute or parent-traversing names, and
only regular files and directories. This rejects symbolic links, hard links, and
special files before an extractor can follow them. The following is a reference
sequence; production automation should provide equivalent fail-closed checks:

```bash
(
set -Eeuo pipefail

readonly imessage_proxy_version='REPLACE_WITH_REVIEWED_VERSION'
readonly imessage_proxy_tag="v$imessage_proxy_version"
readonly imessage_proxy_revision='REPLACE_WITH_REVIEWED_40_HEX_COMMIT'
readonly imessage_proxy_sha256='REPLACE_WITH_REVIEWED_SHA256'
readonly imessage_proxy_root="$HOME/.local/src"
readonly imessage_proxy_repository='https://github.com/mglaeser/imessage-proxy'
readonly expected_root="imessage-proxy-$imessage_proxy_version"

[[ "$imessage_proxy_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$imessage_proxy_revision" =~ ^[0-9a-f]{40}$ ]]
[[ "$imessage_proxy_sha256" =~ ^[0-9a-f]{64}$ ]]
[[ "$imessage_proxy_root" == "$HOME/"* && "$imessage_proxy_root" != "$HOME" ]]
umask 077
mkdir -p "$imessage_proxy_root"
[[ -d "$imessage_proxy_root" && ! -L "$imessage_proxy_root" ]]
[[ "$(cd "$imessage_proxy_root" && pwd -P)" == "$imessage_proxy_root" ]]
[[ "$(stat -f '%Su' "$imessage_proxy_root")" == "$(id -un)" ]]
chmod 700 "$imessage_proxy_root"
stage="$(mktemp -d "$imessage_proxy_root/.imessage-proxy-stage.XXXXXX")"
archive="$stage/$expected_root.tar.gz"
mkdir "$stage/extract"
cleanup() { rm -rf -- "$stage"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

tag_ref="refs/tags/$imessage_proxy_tag^{}"
tag_record="$(git ls-remote --exit-code \
  "$imessage_proxy_repository.git" "$tag_ref")"
[[ "$tag_record" == "$imessage_proxy_revision"$'\t'"$tag_ref" ]]

curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
  "$imessage_proxy_repository/releases/download/$imessage_proxy_tag/$expected_root.tar.gz" \
  --output "$archive"
printf '%s  %s\n' "$imessage_proxy_sha256" "$archive" | shasum -a 256 --check

tar -tzf "$archive" > "$stage/members"
awk -v root="$expected_root" '
  $0 == root || index($0, root "/") == 1 {
    if ($0 ~ /(^|\/)\.\.?($|\/)/) exit 1
    count++
    next
  }
  { exit 1 }
  END { if (count == 0) exit 1 }
' "$stage/members"
grep -Fqx "$expected_root/VERSION" "$stage/members"
tar -tvzf "$archive" > "$stage/types"
awk 'substr($1, 1, 1) != "-" && substr($1, 1, 1) != "d" { exit 1 }' \
  "$stage/types"

tar --no-same-owner -xzf "$archive" -C "$stage/extract"
candidate="$stage/extract/$expected_root"
[[ -d "$candidate" && ! -L "$candidate" ]]
[[ "$(< "$candidate/VERSION")" == "$imessage_proxy_version" ]]
[[ -z "$(find "$candidate" -type l -print -quit)" ]]
make -C "$candidate" build
make -C "$candidate" test
make -C "$candidate" clean

release_dir="$imessage_proxy_root/$expected_root"
[[ ! -e "$release_dir" && ! -L "$release_dir" ]]
mv "$candidate" "$release_dir"
stable_link="$imessage_proxy_root/imessage-proxy"
[[ ! -e "$stable_link" || -L "$stable_link" ]]
next_link="$(mktemp "$imessage_proxy_root/.imessage-proxy-link.XXXXXX")"
rm -f -- "$next_link"
ln -s "$expected_root" "$next_link"
mv -fh "$next_link" "$stable_link"
[[ "$(readlink "$stable_link")" == "$expected_root" ]]
)
```

The cleanup trap deletes only the exact private staging directory returned by
`mktemp` on success or failure. The final directory rename and
stable-link replacement must stay on one filesystem so each promotion is atomic.
Never overwrite a pre-existing versioned directory: verify and reuse an exact
match or stop for inspection. Keep the directory previously selected by the
stable link until the acceptance and rollback window closes.

Record the version, reviewed tag, full source commit, and exact archive SHA-256
in the private administration repository. GitHub releases also include a
`SHA256SUMS` file and build-provenance attestation, but verify those through an
independent review path before treating them as authority. Do not deploy an
unpinned default branch, resolve `latest`, or use a mutable release URL during
provisioning.

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

The recommended migration retains the compatible runtime path while rotating
the credentials and CA stored below it. When the embedded predecessor used a
different layout, do not point `IMESSAGE_PROXY_HOME` at that tree and hope paths
coincide. If a standalone 0.1.x deployment already uses the default home, never
copy it onto itself: quiesce it, capture the bounded rollback snapshot, and
replace only the reviewed credential and CA material through the planned
rotation.

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

The default migration rotates the bridge token, every caller password, and the
private Caddy CA. Generate fresh values, review targets by hand, enroll the new
root certificate over an authenticated channel, and retain old material only in
a protected rollback snapshot for the bounded rollback window. Never make a new
deployment depend on credentials merely because they happened to exist in the
embedded tree.

Preservation is an advanced exception for a deployment where coordinated client
re-enrollment is not currently possible. Stop the facade and bridge first so no
writer or client is using the state, take an encrypted permission-preserving
snapshot, and verify the exact source, destination, ownership, modes, and CA
fingerprint before startup. Copy only the reviewed bridge token or Caddy data
needed for the exception; do not copy the whole runtime tree. Record an owner
and deadline for the deferred rotation. Never use preserved and replacement
credentials or CAs concurrently.

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

Add one newly generated hash per authorized client. Set
`IMESSAGE_PROXY_ENABLE_ALPHA=yes`, source the environment again, and run:

```bash
bin/imessage-proxy doctor
```

Then choose exactly one path based on the recorded container definition:

- **Compatible existing container:** this path is limited to the advanced
  preservation exception where the reviewed bridge token, immutable
  environment, and mounts already match. Keep the stopped `stella` container
  and run `bin/imessage-proxy start`, followed by
  `bin/imessage-proxy status`.
- **Rotated, incompatible, or absent container:** the default token rotation
  makes an existing container's immutable environment incompatible. If it
  exists, remove only the exact stopped `stella` container using the reviewed
  Apple Container procedure. Confirm that name is absent, then run
  `bin/imessage-proxy create` and `bin/imessage-proxy status`. The manager
  deliberately provides no delete or prune action.

`create` must refuse while the retained container exists. Do not remove a compatible container merely to make that command succeed.

After the selected path has started Caddy and `status` reports the expected container, print the active root certificate path:

```bash
bin/imessage-proxy ca-path
```

With the default CA rotation, securely enroll the new root certificate on each
client and verify its fingerprint. For an advanced preservation exception,
verify that the served fingerprint is exactly the reviewed retained CA. Update
private DNS only after the new endpoint passes a direct health check. Never
overlap two active endpoints accepting sends for the same clients.

## 5. Acceptance and rollback gate

Run the complete checklist in [Operations](operations.md), including
unauthorized access, forbidden method, forbidden recipient, bounded read, one
agreed test send, receiver confirmation of the actual Messages sender identity,
private-network reachability, and sanitized logs.

Choose the recovery path from observed facts rather than applying an
unconditional rollback:

- **Failure before mutation:** abort and leave the old service unchanged. Remove
  only the validated staging directory; no runtime rollback is necessary.
- **Fully observed, reversible mutation:** stop the new facade, keep both stacks
  quiesced, and restore the exact old LaunchAgent, facade, DNS, credentials, and
  client CA state from the reviewed rollback plan. Confirm health and one
  non-sending read before reopening automation.
- **Uncertain partial failure:** contain access, stop any facade whose identity is
  known, preserve receipts and sanitized observations, and require an operator
  to inventory listeners, processes, container definition, LaunchAgent, route,
  DNS, credentials, and CA trust. Do not retry cutover, roll forward, or restore
  the predecessor until that inventory establishes one coherent state.

Do not delete old source or state until the rollback window closes. Never attempt rollback by running both stacks concurrently.

## 6. Update the administration repository

Remove the embedded implementation only after standalone acceptance. The administration repository may retain private deployment configuration and orchestration, but it should obtain iMessage Proxy directly from a canonical, checksum-pinned GitHub release.

### Recommended: immutable release installer

Store the reviewed version, tag, full commit, and archive digest in private
desired state. Provision a versioned source directory with the private staging
and archive validation sequence from section 1, and invoke commands through the
stable symlink only after the candidate has built and passed its tests:

```bash
readonly imessage_proxy_version='REPLACE_WITH_REVIEWED_VERSION'
readonly imessage_proxy_tag="v$imessage_proxy_version"
readonly imessage_proxy_revision='REPLACE_WITH_REVIEWED_40_HEX_COMMIT'
readonly imessage_proxy_sha256='REPLACE_WITH_REVIEWED_SHA256'
readonly imessage_proxy_root="$HOME/.local/src"
readonly imessage_proxy_checkout="$imessage_proxy_root/imessage-proxy-$imessage_proxy_version"

# Use the verified private-stage, archive-validation, build, and promotion
# sequence from section 1. It must bind the tag and provenance to the full
# commit and independently verify the archive digest.
[[ "$(< "$imessage_proxy_checkout/VERSION")" == "$imessage_proxy_version" ]]
"$imessage_proxy_root/imessage-proxy/bin/imessage-proxy" doctor
```

Production provisioning should fail closed on any version, tag, commit,
provenance, member-layout, type, or digest mismatch. Update all pins through a
reviewed change and retain the previously selected versioned directory; never
resolve `latest` or a default branch during a provisioning run.

### Alternative: Git submodule

A submodule makes the dependency visible in the administration repository's tree and commit history:

```bash
git submodule add https://github.com/mglaeser/imessage-proxy.git vendor/imessage-proxy
git -C vendor/imessage-proxy fetch origin REPLACE_WITH_REVIEWED_TAG
test "$(git -C vendor/imessage-proxy rev-parse 'REPLACE_WITH_REVIEWED_TAG^{commit}')" = \
  'REPLACE_WITH_REVIEWED_40_HEX_COMMIT'
git -C vendor/imessage-proxy checkout --detach \
  REPLACE_WITH_REVIEWED_40_HEX_COMMIT
git add .gitmodules vendor/imessage-proxy
```

Provisioning must use `git submodule update --init --recursive`, verify the
recorded commit before executing it, and never assume the submodule follows the
latest default branch. Choose this option only if the repository's deployment
tooling already handles submodules and independent source-review evidence
reliably.

### Automated orchestration contract

An automated cutover needs durable state beyond a process exit code:

1. Acquire a private exclusive migration lock that is owned by the deployment
   user and cannot be followed through a symbolic link. A competing lock holder
   is a hard stop, not a reason to bypass the lock.
2. Before acquiring the lock and again immediately afterward, revalidate the
   release pins, active stable link, existing receipt, legacy and replacement
   runtime identities, listeners, and mutation prerequisites. The second check
   closes the race between initial observation and exclusive ownership.
3. Before the first mutation, atomically write a mode-`0600`, metadata-only
   receipt in state `in_progress`. It may contain a schema version, timestamps,
   artifact pins, sanitized booleans, and observed resource identities; it must
   never contain tokens, passwords, message content, recipients, or CA private
   material.
4. Permit only monotonic transitions: `in_progress` to either
   `failed_observation_required` or `pending_acceptance`, then
   `pending_acceptance` to `accepted`. Write a complete temporary file in the
   same private directory, set its mode, sync it as supported, and atomically
   replace the receipt. Never edit a receipt in place.
5. Make acceptance a separate explicit operation after human and receiver
   checks. An invalid receipt, `in_progress`, or
   `failed_observation_required` blocks both retry and automatic rollback until
   an operator reconciles actual state. Never transition a failed receipt
   backward; retain it as evidence and perform any later recovery under a
   separately reviewed generation. Ambiguity is not absence.

Keep deployment-specific lock and receipt paths, users, addresses, and private
release pins in the administration repository, not in this public guide.

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
- [ ] The reviewed tag resolves to the recorded full commit and the archive matches an independently recorded SHA-256.
- [ ] Archive members were validated before private extraction, and the candidate passed build and tests before atomic promotion.
- [ ] The administration repository no longer contains copied iMessage Proxy implementation files.
- [ ] Private orchestration invokes `bin/imessage-proxy` from the standalone checkout or installed prefix.
- [ ] Only one bridge LaunchAgent and one network facade are active.
- [ ] Runtime secrets and CA material remain outside both repositories with restrictive modes.
- [ ] Every client and allowed target has a current owner and purpose.
- [ ] The receiver confirmed both the intentional test message and the actual Messages sender identity.
- [ ] Private DNS, CA trust, monitoring, restart, upgrade, and rollback procedures were tested.
- [ ] Public documents contain no deployment-specific host, user, address, domain, or secret data.
