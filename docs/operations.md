# Operations

This runbook prepares a fresh iMessage Proxy 1.0 installation. It never imports,
renames, adopts, or deletes another installation. Do not expose or cut over a real
Mac until the hostname, IPv4 network path, maintenance window, and real-Mac
acceptance tests in this guide are complete.

## 0. Choose an installation path

`scripts/install.sh` performs sections 2–9 as one guarded command. It verifies
the Mac, obtains a checksum-verified release, builds and installs the CLI, pins
Caddy by SHA-512 and both native dependencies by SHA-256, writes one private
`0600` configuration file with the exposure gate closed, and then runs the
product's own `bootstrap`:

```bash
curl -fsSL https://raw.githubusercontent.com/mglaeser/imessage-proxy/main/scripts/install.sh | bash
```

Without `--tag` it resolves this repository's latest published release and
verifies the archive against the `SHA256SUMS` asset published beside it. A
reviewed deployment should always pin the tag and digest explicitly.

It never enables public HTTPS, never accepts `--public`, and never writes the
administrator key anywhere but standard output. Reviewed deployments should pass
explicit inputs instead of answering prompts:

```bash
bash install.sh \
  --tag v1.0.0 \
  --sha256 REPLACE_WITH_REVIEWED_64_HEX_SHA256 \
  --imsg /REPLACE/WITH/REVIEWED/PATH/imsg \
  --caddy /REPLACE/WITH/REVIEWED/PATH/caddy \
  --host messages.your-domain.example \
  --email operator@your-domain.example \
  --attest
```

Use `--source DIR` or `--archive FILE` to install from an already reviewed
checkout or artifact. `--attest` additionally verifies GitHub build provenance
with `gh`.

The numbered sections below remain the authoritative manual, audit, and recovery
path. Follow them when an operator must review each step, or when the installer
reports a failure.

## 1. Fix the deployment inputs

Record and review these values outside the repository:

- exact iMessage Proxy release tag, commit, and independently calculated archive
  SHA-256;
- exact supported `imsg` version `0.13.4`, executable path, and independently
  reviewed executable SHA-256;
- host-native Caddy version `2.11.4`, executable path, and independently reviewed
  executable SHA-256;
- dedicated public hostname, its IPv4 `A` record, and ACME contact email;
- assigned Mac IPv4 address and Caddy bind choice;
- unprivileged host HTTP/HTTPS ports, defaulting to `8080` and `8443`;
- router/NAT rules mapping external TCP 80 to the host HTTP port and external TCP
  443 to the host HTTPS port;
- router, host-firewall, DNS, and ISP owners;
- macOS GUI account signed in to the intended Messages identity;
- one short-lived bootstrap administrator name;
- exact permitted send addresses and local chat IDs;
- one harmless consented send target; and
- operator, maintenance window, recovery contact, and stop criteria.

The supplied edge is IPv4-only. The hostname must not publish an `AAAA` record.
Stop if any source, digest, executable, dependency, hostname, address, mapping,
account, or network target differs from the reviewed record.

## 2. Obtain and verify the release

Use the release artifact and checksum recorded by your administration repository.
Do not resolve a moving branch or accept a checksum fetched only beside an
otherwise untrusted archive.

Example shape, with independently reviewed values:

```bash
set -Eeuo pipefail
readonly release_tag='v1.0.0'
readonly release_commit='REPLACE_WITH_REVIEWED_40_HEX_COMMIT'
readonly archive_sha256='REPLACE_WITH_REVIEWED_64_HEX_SHA256'
readonly archive="imessage-proxy-${release_tag#v}.tar.gz"
readonly archive_root="imessage-proxy-${release_tag#v}"

[[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$release_commit" =~ ^[0-9a-f]{40}$ ]]
[[ "$archive_sha256" =~ ^[0-9a-f]{64}$ ]]

curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
  "https://github.com/mglaeser/imessage-proxy/releases/download/${release_tag}/${archive}" \
  --output "$archive"
printf '%s  %s\n' "$archive_sha256" "$archive" | shasum -a 256 --check

archive_listing="$(mktemp)"
tar -tzf "$archive" > "$archive_listing"
[[ -s "$archive_listing" ]]
tar -tvzf "$archive" |
  awk '{type = substr($1, 1, 1); if (type != "-" && type != "d") exit 1}'
while IFS= read -r member; do
  [[ "$member" == "$archive_root/"* ]]
  canonical_member="${member%/}"
  [[ -n "$canonical_member" && "$canonical_member" != /* ]]
  case "/$canonical_member/" in
    *'//'* | *'/./'* | *'/../'*) exit 1 ;;
  esac
done < "$archive_listing"

embedded_revision="$(tar -xOzf "$archive" "$archive_root/REVISION")"
[[ "$embedded_revision" == "$release_commit" ]]
```

Inspect the archive member list before extracting. It must contain one relative
top-level directory and no absolute paths, parent traversal, links, devices, or
unexpected executable files. The example then compares the archive's exact
exported `REVISION` member byte-for-byte with the independently reviewed commit
before any project code is extracted or executed.

From a reviewed checkout:

```bash
make build
make test
make install
export PATH="$HOME/.local/bin:$PATH"
command -v imessage-proxy
```

The default prefix is `$HOME/.local`; the final command must resolve its CLI from
`$HOME/.local/bin`. Add that directory to your shell startup file or use the
absolute CLI path in future sessions. Override `PREFIX` only with an explicit
user-owned path. Installation never changes runtime state.

## 3. Obtain and pin native dependencies

Obtain the official `imsg 0.13.4` macOS executable through a reviewed supply
path. Record and verify the exact file before staging it:

```bash
IMESSAGE_PROXY_IMSG_BIN='/REPLACE/WITH/REVIEWED/PATH/imsg'
"$IMESSAGE_PROXY_IMSG_BIN" --version
shasum -a 256 "$IMESSAGE_PROXY_IMSG_BIN"
```

The version output must be exactly `0.13.4`, and the digest must match the
recorded 64-character lowercase SHA-256.

Obtain the official Caddy 2.11.4 macOS executable through a reviewed supply path.
Record its digest independently, then verify the exact file that will be staged:

```bash
IMESSAGE_PROXY_CADDY_BIN='/REPLACE/WITH/REVIEWED/PATH/caddy'
"$IMESSAGE_PROXY_CADDY_BIN" version
shasum -a 256 "$IMESSAGE_PROXY_CADDY_BIN"
```

The version must begin with `v2.11.4`, and the digest must match the recorded
64-character lowercase SHA-256. Do not use a floating package result, silently
replace the file in place, or grant this executable Full Disk Access or Messages
Automation.

Caddy runs as the same non-root GUI user as the native server. This avoids a root
daemon, but it also means Caddy shares that user's ordinary filesystem boundary.
Treat it as trusted service code.

## 4. Create private configuration

```bash
mkdir -p "$HOME/.config/imessage-proxy"
install -m 600 config/imessage-proxy.env.example \
  "$HOME/.config/imessage-proxy/service.env"
${EDITOR:-vi} "$HOME/.config/imessage-proxy/service.env"
```

Example shape:

```text
IMESSAGE_PROXY_API_HOST=messages.example.com
IMESSAGE_PROXY_ACME_EMAIL=operator@example.com
IMESSAGE_PROXY_PUBLIC_BIND=0.0.0.0
IMESSAGE_PROXY_HTTP_PORT=8080
IMESSAGE_PROXY_HTTPS_PORT=8443
IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS=no
IMESSAGE_PROXY_IMSG_BIN=/REPLACE/WITH/REVIEWED/PATH/imsg
IMESSAGE_PROXY_IMSG_SHA256=REPLACE_WITH_REVIEWED_64_HEX_SHA256
IMESSAGE_PROXY_CADDY_BIN=/REPLACE/WITH/REVIEWED/PATH/caddy
IMESSAGE_PROXY_CADDY_SHA256=REPLACE_WITH_REVIEWED_64_HEX_SHA256
```

`IMESSAGE_PROXY_PUBLIC_BIND` must be `0.0.0.0` or one canonical IPv4 address
assigned to the Mac. Prefer the exact ingress-facing address when it is stable.
Both configured ports must be distinct unprivileged host ports in
`1024-65535`; the standard public ports stay on the external side of the router.

The hostname must already be the deliberate public name even while the exposure
gate remains `no`. Do not source this file for the one-command path. Bootstrap
parses it as data and never executes its contents.

### One-command first run

The lifecycle CLI can perform sections 5–9 as one reviewed operation. It parses
the configuration as a closed `KEY=VALUE` format without executing it; the file
must be a private, current-user-owned regular file with exactly one hard link.
Unknown, duplicate, missing, or empty values fail before lifecycle work.

```bash
imessage-proxy bootstrap \
  --config "$HOME/.config/imessage-proxy/service.env" \
  --admin-name local-bootstrap \
  --expires-in-days 30
```

The sequence is fixed: `doctor`, `prepare`, `build-host`, the interactive Full
Disk Access checkpoint, database initialization/validation, read-only bootstrap
eligibility preflight, `check-host`, a bounded Messages read smoke test,
`server-install`, and finally first-administrator creation. The native server
repeats the same read preflight from its actual LaunchAgent context before it
creates the Unix socket; therefore socket readiness proves the pinned
`imsg chats --limit 1` path works for the installed service identity. Returned
chat data is parsed against the public DTO and discarded. Neither read can send
a message or trigger Automation.

The bootstrap-only administrator label is restricted to 1–80 printable ASCII
bytes without leading or trailing spaces, allowing exact fail-fast validation
before any lifecycle work. API-created key names retain the documented Unicode
contract. The final bootstrap operation is the only one that writes to standard
output. On success, stdout is exactly one line containing the new `imp_…` key;
every path, check, warning, and progress message goes to stderr. Put the key
directly in a password manager. Do not use shell command substitution if the
terminal or automation system records output. Treat a printed candidate as valid
only when bootstrap exits with status zero. Token delivery occurs inside the
database transaction; a delivery failure rolls back without creating an
administrator, while a later commit failure can leave a printed but deliberately
unusable candidate and a clean retry path.

The checkpoint cannot grant TCC permission automatically. It prints the exact
new binary path, waits while an operator grants that binary Full Disk Access in
System Settings, and continues only after the exact acknowledgement is typed.
Messages Automation remains an intentional first-send prompt.

To include section 10 and make the console/API reachable at the reviewed public
origin, first complete the pre-start portion of the
[public exposure gate](#public-exposure-gate), prepare every immediate acceptance
test, set `IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS=yes` in the private file, and run:

```bash
imessage-proxy bootstrap \
  --config "$HOME/.config/imessage-proxy/service.env" \
  --admin-name local-bootstrap \
  --expires-in-days 30 \
  --public \
  --confirm 'EXPOSE IMESSAGE PROXY PUBLICLY'
```

The public edge must become ready before the key is created. Without `--public`,
the config gate must be `no` and the command leaves the edge stopped. Bootstrap
does not create DNS, router/NAT, firewall, certificate exceptions, SIP changes,
or TCC database changes. The numbered manual procedure below remains the
authoritative recovery and verification path.

## 5. Verify host prerequisites

The numbered sections below are the manual lifecycle path. Load the reviewed
private configuration without printing its values:

```bash
set -a
. "$HOME/.config/imessage-proxy/service.env"
set +a
```

Run as the non-root GUI user signed in to Messages:

```bash
imessage-proxy doctor
"$IMESSAGE_PROXY_IMSG_BIN" --version
```

The dependency version must be exactly `0.13.4`. `doctor` validates both native
dependency files and digests, the public hostname, ACME email, IPv4 bind, host
ports, required macOS commands, and that the public gate is exactly `yes` or
`no`.

Keep System Integrity Protection and TCC enabled. Do not grant broad terminal
applications permanent Full Disk Access as a shortcut. Confirm the Mac is not
configured to sleep or log out unexpectedly during the maintenance window.

## 6. Prepare fresh state and build

```bash
imessage-proxy prepare
imessage-proxy build-host
```

`prepare` hashes before executing and then copies the exact reviewed `imsg` and
Caddy executables, Caddyfile, console, and both LaunchAgent definitions into
private state. It does not start either service. The default state root is:

```text
~/Library/Application Support/iMessage Proxy/
├── private/
│   ├── allowed-targets.txt
│   └── api-keys.sqlite3        # created during bootstrap
├── run/
│   └── server.sock             # created by the native server
└── state/
    ├── bin/
    │   ├── caddy
    │   ├── imsg
    │   └── imessage-proxy-server
    ├── caddy/
    │   ├── Caddyfile
    │   ├── config/
    │   ├── data/
    │   └── ui/
    ├── logs/
    │   └── edge.log             # private Caddy log; 10 MiB rolling cap
    ├── io.github.mglaeser.imessage-proxy.edge.plist
    └── io.github.mglaeser.imessage-proxy.plist
```

Inspect the rendered plists and exact executable paths. Check the server's
signature. Native operational events use the bounded macOS unified-log store;
the LaunchAgents do not append unbounded stdout/stderr files:

```bash
codesign --display --verbose=4 \
  "$HOME/Library/Application Support/iMessage Proxy/state/bin/imessage-proxy-server"
```

Grant Full Disk Access only to that exact server binary in System Settings. A
rebuild or path change can invalidate the permission identity. Do not grant Full
Disk Access or Automation to the staged Caddy executable.

## 7. Bootstrap the first administrator

The bootstrap command works only when no active administrator exists:

```bash
imessage-proxy api-key bootstrap-admin \
  --name local-bootstrap \
  --expires-in-days 30
```

It prints one `imp_…` credential once. Store it immediately in a password
manager. Avoid shell arguments, environment files, clipboard history,
screenshots, issue trackers, and chat.

Then validate all native configuration:

```bash
imessage-proxy check-host
```

The check verifies private state, schema, native binary version, dependency path
and exact version, allowed-target syntax, origin, deadlines, and socket path. It
does not start a service.

## 8. Configure permitted sends

Edit the generated file:

```bash
${EDITOR:-vi} "$HOME/Library/Application Support/iMessage Proxy/private/allowed-targets.txt"
```

Add only consented exact values:

```text
person@example.net
+14155551212
chat_id:42
```

Direct phone targets must be `+` followed by 7-15 ASCII digits with a nonzero
first digit. Direct email-like handles contain exactly one `@` and no whitespace
or control characters. Contact names, noncanonical chat IDs, leading-zero chat
IDs, and wildcards make configuration validation fail.

There is no wildcard. Keep the file empty for a read-only deployment. Never put
message content or private key material in it.

## 9. Start and validate the native server

```bash
imessage-proxy server-install
imessage-proxy server-status
```

`server-install` installs the LaunchAgent, explicitly enables its GUI launchd
label, and starts it as the current user. It creates only the private Unix socket.
Verify ownership and type without printing private files:

```bash
stat -f '%HT %Su %Lp %N' \
  "$HOME/Library/Application Support/iMessage Proxy/run/server.sock"
lsof -nP -U | grep 'iMessage Proxy/run/server.sock'
```

Confirm the server binary has no TCP listener:

```bash
server_pid="$(pgrep -x imessage-proxy-server)"
lsof -nP -a -p "$server_pid" -iTCP -sTCP:LISTEN
```

The last command must print no listener. Prove authenticated readiness directly
over the socket:

```bash
curl --fail-with-body \
  --unix-socket "$HOME/Library/Application Support/iMessage Proxy/run/server.sock" \
  --header "Authorization: Bearer $IMESSAGE_PROXY_API_KEY" \
  http://localhost/api/status
```

If the first intentional send triggers an Automation prompt, confirm the exact
server binary/account and approve only control of Messages. Stop if the identity
differs.

## Public exposure gate

Keep `IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS=no` until every pre-start item is
complete and recorded:

- [ ] A real dedicated hostname has exactly the intended IPv4 `A` path and no
  `AAAA` record.
- [ ] External TCP 80 maps exactly to the configured Mac IPv4 HTTP port.
- [ ] External TCP 443 maps exactly to the configured Mac IPv4 HTTPS port.
- [ ] Router, host firewall, upstream ISP, and any carrier-grade NAT behavior are
  understood; the exact external test path is ready.
- [ ] No unrelated process owns either configured host port.
- [ ] The exact `imsg 0.13.4` and Caddy 2.11.4 executables and SHA-256 digests
  were reviewed.
- [ ] Caddy will run as the GUI user without root, Full Disk Access, or
  Automation.
- [ ] Missing, invalid, expired, revoked, and under-scoped key tests are prepared.
- [ ] Exact-target rejection and one harmless send are prepared.
- [ ] Rate, body, header, and timeout tests are prepared.
- [ ] The operator has local recovery access and the exact `edge-stop` command
  ready.
- [ ] The maintenance window, recovery owner, and stop criteria are active.

Immediately after the edge starts, complete and record every runtime acceptance
item below. Stop the edge at the first failure:

- [ ] The native process owns one private Unix socket and no TCP listener.
- [ ] The bootstrap key is stored and a second administrator can be created.
- [ ] External TLS, static console, authentication, scopes, and every intended
  network path pass while unintended paths remain closed.
- [ ] Exact-target rejection and one harmless send pass without SMS fallback.
- [ ] Rate, body, header, and timeout bounds pass.
- [ ] `edge-stop` disables the label across login/reboot without deleting state.
- [ ] Server/edge restarts, login, reboot, sleep/wake, and address changes pass on
  the real target Mac.

Do not add a CDN, tunnel, upstream proxy, alternate TLS terminator, or public IPv6
path as a shortcut. Each changes trusted source addresses, certificate ownership,
logging, or origin validation and needs a separate architecture review.

## 10. Install the public edge

Source the reviewed configuration, enable the gate only for the approved
deployment, and install Caddy's LaunchAgent:

```bash
export IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS=yes
imessage-proxy edge-install --confirm 'EXPOSE IMESSAGE PROXY PUBLICLY'
imessage-proxy edge-status
imessage-proxy edge-logs
```

`edge-install` verifies the staged Caddy version/digest and configuration, checks
that the native socket is ready and both host ports are free, installs the edge
LaunchAgent, explicitly enables its launchd label, and starts it. Readiness is
not a transient launchd state: the CLI attributes both exact TCP listeners to
the Caddy PID, verifies the explicit `308` HTTP redirect points to the ordinary
public HTTPS origin without the internal port, completes a locally routed HTTPS
request with normal certificate validation, and repeats the check before
reporting success. Caddy runs directly on macOS as the current GUI user, serves
the console, and proxies `/api` to the local socket.

`edge.log` rolls at 10 MiB, retains at most five compressed files, and removes
files older than 30 days. Review before sharing: diagnostic logs must not contain
an authorization header, key, body, or query. No request access log is configured.

## 11. Acceptance from outside

Use a client that does not share the Mac's LAN or DNS assumptions. Public clients
use ordinary ports; never add `:8443` to the external URL.

### TLS and static console

```bash
curl --silent --show-error --dump-header - --output /dev/null \
  "http://$IMESSAGE_PROXY_API_HOST/api/status"
curl --fail --show-error --head "https://$IMESSAGE_PROXY_API_HOST/"
```

Confirm the HTTP result is `308` with exactly
`Location: https://HOST/api/status`: it must contain neither the internal HTTPS
port nor an incoming alternate Host value. Confirm it and the HTTPS response omit
`Server`, `Alt-Svc`, and cross-origin headers and include no-store, noindex, HSTS,
content-security policy, frame denial, no-sniff, no-referrer, and
permissions-policy headers. Confirm the HTTPS connection arrived through
external TCP 443 and the reviewed mapping to the Mac's configured HTTPS port.
Source contains no external scripts, fonts, images, analytics, or service worker.

### Authentication

```bash
curl --silent --output /dev/null --write-out '%{http_code}\n' \
  "https://$IMESSAGE_PROXY_API_HOST/api/status"
```

Expect `401`. Repeat with an invalid key, expired test key, revoked test key, and
a valid key without the requested scope. Confirm no case reveals key state beyond
the documented `401`/`403` distinction.

### Readiness and bounded reads

```bash
curl --fail-with-body \
  --header "Authorization: Bearer $IMESSAGE_PROXY_API_KEY" \
  "https://$IMESSAGE_PROXY_API_HOST/api/status"

curl --fail-with-body \
  --header "Authorization: Bearer $IMESSAGE_PROXY_API_KEY" \
  "https://$IMESSAGE_PROXY_API_HOST/api/chats?limit=1"
```

Do not capture real response bodies in a shared transcript.

### Key lifecycle

Use the console to create a 1-day read-only key, copy it deliberately, refresh
the page, verify the plaintext is no longer available, exercise status, revoke it,
and verify immediate `401`. Create and test a replacement administrator before
the local bootstrap key expires.

### Target and send

Verify a non-allowlisted target returns `403` without invoking Messages. Then send
one harmless agreed message with a fresh idempotency key. Confirm the intended
Messages account and thread, and verify neither logs nor audit metadata contain
text or target. Repeat the same idempotency key/body and prove no second message
appears. Reuse it with different text and expect `409`.

### Bounds

Verify oversized body/header rejection, wrong media type, unsupported method/path,
cross-origin browser denial, request and send rate limits, native concurrency
limit, and command deadline. Never load-test a personal Messages account without
a separate explicit plan.

## 12. Lifecycle and restart acceptance

Start inside-out and stop outside-in. To restart the native server safely:

```bash
imessage-proxy edge-stop
imessage-proxy server-restart \
  --confirm 'RESTART IMESSAGE PROXY SERVER'
imessage-proxy server-status
imessage-proxy edge-start
imessage-proxy edge-status
```

To restart only Caddy after a reviewed edge change:

```bash
imessage-proxy edge-restart \
  --confirm 'RESTART IMESSAGE PROXY EDGE'
```

For each event, observe behavior before, during, and after:

1. edge stop/start;
2. edge stop, server restart, socket validation, edge start;
3. GUI logout/login;
4. Mac reboot;
5. sleep/wake; and
6. LAN address or router restart/change.

The CLI refuses a server stop or restart while the edge is loaded. `edge-stop`
and confirmed `server-stop` disable their exact GUI launchd labels before
unloading them; they remain stopped across logout/login and reboot while plists
and state stay intact. Install, start, and restart explicitly re-enable the
corresponding label. Do not bypass these guards. Re-run external certificate,
authentication, read, and harmless-send acceptance when the event could affect
those paths.

## 13. Routine key operations

- Review key names, scopes, expiry, revocation, and last-use metadata regularly.
- Review bounded `GET /api/audit-events` results with an administrator key; keep
  source addresses and key identifiers inside the incident-response boundary.
- Create replacements before expiry and revoke unused keys.
- Investigate unexpected source rate limits or last-use time.
- Keep administrator keys out of unattended clients.
- Keep the local bootstrap path available, but use it only when no active
  administrator remains.
- Apply an audit retention policy without exporting conversation data.

## 14. Upgrades

Treat every upgrade as a new security review:

1. verify release provenance and both native executable pins;
2. read source, API, database, Caddy, and LaunchAgent changes;
3. enter the maintenance window and run `edge-stop`;
4. run the confirmed `server-stop` and prove both LaunchAgents are absent;
5. back up consistent private and Caddy certificate state;
6. install the reviewed source without deleting runtime state;
7. run `prepare` and inspect both generated plist/config/UI diffs;
8. run `build-host` and re-check the exact server signature/path;
9. re-check Full Disk Access for the server and absence of it for Caddy;
10. run `check-host` and native tests;
11. run `server-install` and prove the recreated socket;
12. run `edge-start`; and
13. repeat external acceptance and the relevant restart tests.

Never downgrade or reinterpret a newer database schema with older code. If a
release cannot open the exact current schema, leave the edge stopped and restore
one coherent reviewed backup rather than editing SQLite manually.

## 15. Backup and recovery

The important service-owned state is the API-key/audit/idempotency database,
target allowlist, Caddy certificate data, and reviewed configuration. Conversation
data remains owned by Messages and the macOS backup policy.

For a consistent service backup:

1. run `imessage-proxy edge-stop`;
2. run `imessage-proxy server-stop --confirm 'STOP IMESSAGE PROXY SERVER'`;
3. verify no database writers remain;
4. copy the private and Caddy state with ownership and modes preserved;
5. encrypt and inventory the backup; and
6. recover inside-out with `server-start`, socket validation, then `edge-start`;
   both commands explicitly re-enable their launchd labels.

Do not copy only a live SQLite main file without its WAL state. Do not print or
archive a plaintext API key. Restoring key metadata does not recover keys whose
plaintext clients lost.

## 16. Incident containment

If a key is suspected compromised:

1. revoke it immediately with an administrator key;
2. if administrator access is uncertain, run `edge-stop` locally and prove the
   durable disabled state; optionally remove the external router mappings as
   defense in depth;
3. preserve privacy-safe audit and bounded Caddy diagnostic logs;
4. inspect scope, source, last use, send attempts, and idempotency state;
5. rotate affected clients and the administrator used for response; and
6. restore the edge only after external acceptance passes.

If the native binary, Mac account, or Caddy edge is suspected compromised, stop
the edge durably, optionally remove the external mappings, preserve exact state
for investigation, rotate all keys from a trusted build, review the Messages
account, and treat user-readable service state plus live bearer keys as exposed.
Do not erase executables, databases, or logs before deciding what evidence is
required.

## 17. Decommission

`scripts/uninstall.sh` reverses section 0. It stops and removes both
LaunchAgents, clears the persistent launchd disable record each stop action
writes, and deletes the CLI, the installed assets, the pinned `imsg` and Caddy
payloads, and the private configuration file.

```bash
bash scripts/uninstall.sh --dry-run
bash scripts/uninstall.sh
```

Run `--dry-run` first. It prints every path it would remove and changes nothing.

Runtime state is preserved by default. API keys, the send allowlist,
certificates, and logs remain, so a later installation adopts them instead of
issuing new credentials. That default matters after an incident: section 16
requires preserving evidence before erasing databases or logs.

Destroying state is a separate, explicit decision and cannot be undone:

```bash
bash scripts/uninstall.sh --purge --confirm 'DESTROY IMESSAGE PROXY STATE'
```

`--purge` refuses any runtime root whose final path component is not
`iMessage Proxy` or `imessage-proxy`, so a stray `IMESSAGE_PROXY_HOME` cannot
redirect the deletion. Every removal target must also be a normalized path
strictly below `HOME`, and shared parents such as `~/.local/bin` and
`~/Library/Application Support` are refused outright. `~/.local/bin/imsg` is
removed only when it still points into the installed payload; an executable you
placed there yourself is reported and kept.

Add `--include-legacy` to also remove pre-1.0 Stella-era artifacts: the
`io.github.mglaeser.stella.bridge` agent, the `stella` CLI, and — with
`--purge` — its runtime directory.

The lifecycle CLI still exposes no reset or state-removal action. Decommission
is deliberately a separate script, so the running service can never destroy its
own credentials.

Two removals macOS reserves for a human. Delete the Full Disk Access and
Automation entries for the removed server binary in System Settings; a stale
entry points at a binary that no longer exists and will confuse a later
installation. Also drop any `PATH` line for the install prefix from your shell
startup file, and remove a trusted Caddy local CA only after reviewing what else
depends on it.
