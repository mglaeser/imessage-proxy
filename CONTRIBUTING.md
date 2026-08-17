# Contributing to iMessage Proxy

Thank you for helping make remote Messages automation safer. iMessage Proxy welcomes focused bug reports, documentation improvements, tests, and carefully scoped code changes.

## Before you start

- Read the [Code of Conduct](CODE_OF_CONDUCT.md).
- Search [existing issues](https://github.com/mglaeser/imessage-proxy/issues) and pull requests.
- For a substantial feature or architecture change, open a proposal issue before writing code.
- Report security concerns through the private process in [SECURITY.md](SECURITY.md).

iMessage Proxy is intentionally narrow. Features that broaden host control, weaken API-key authentication, bypass the private Unix socket, expose host files, or bypass macOS protections are unlikely to be accepted. Public-edge changes must preserve the explicit exposure gate and complete threat model.

## Development setup

Most source-level validation requires macOS and Xcode Command Line Tools. The integration test uses a fake `imsg` backend and does not access real conversations or send a message.

```bash
git clone https://github.com/mglaeser/imessage-proxy.git
cd imessage-proxy
npm ci --ignore-scripts --no-audit --no-fund
make build
make test
npm run lint:markdown
npm run lint:openapi
```

The repository pins its Node 22/npm 10 validation tools exactly in
`package.json` and commits npm's integrity-bearing lockfile. Always install them
with lifecycle scripts disabled. Do not replace the locked commands with `npx`
or a globally resolved package.

When a tooling update is intentional, use an exact version, review both package
files, and prove that a clean, script-free install reproduces the lock:

```bash
npm install --package-lock-only --save-dev --save-exact --ignore-scripts \
  --no-audit --no-fund PACKAGE@VERSION
npm ci --ignore-scripts --no-audit --no-fund
npm run lint:markdown
npm run lint:openapi
git diff -- package.json package-lock.json
```

Do not put real tokens, credentials, recipients, Messages databases, logs, or private infrastructure details in fixtures. Use reserved example domains and synthetic addresses.

## Native unit tests on Linux

The product only runs on macOS, but the two Objective-C sources are ordinary ARC
code, and their leaf functions can be compiled and exercised anywhere. That tier
lives in `tests/native` and runs with:

```bash
make test-native
```

On macOS it uses Apple's clang and the real frameworks and needs nothing else.
On Linux it needs an Objective-C runtime and a Foundation, neither of which
Debian or Ubuntu package in a form that supports ARC, so provision them once:

```bash
bash scripts/linux-toolchain.sh
bash scripts/linux-toolchain.sh --check
```

The provisioner builds libobjc2 and GNUstep base from pinned sources and writes
everything under `$HOME/.local`. There is no `sudo`, no `apt-get install`, and
nothing is written outside `$HOME`. A cold run takes about twenty-five minutes
and about 630 MB; every stage is skipped when its output is already present, so
a second run costs seconds. `--check` proves an existing toolchain works without
building anything. CI runs the same script on `ubuntu-latest` and caches the
result on the hash of the script, so the cold build happens once per change to
it.

To iterate on one test, pass a substring. It selects registered cases by name
and self-contained suites by file name:

```bash
bash tests/native/run.sh ExecutableMetadata
```

What the tier covers: the pure-C and Foundation-light leaf functions - header
and token parsing, path and identifier validation, size and range limits, the
key store's projection and validation helpers, and the rules the HTTP layer and
the database layer are each meant to enforce identically. Every run begins with
a Foundation parity probe, and a host whose Foundation answers differently from
Apple's is refused rather than tested, because a test that passes against the
wrong Foundation reports a property the product does not have.

What it does not cover, and what still needs a Mac: the server end to end, the
Unix socket, launchd, TCC, the real Messages database, and anything that spawns
`imsg`. Those belong to `tests/test-imessage-proxy-server.sh` and the macOS CI
job, which remain the authority. Four behaviours also differ under GNUstep and
are fenced off rather than asserted on - RFC 3339 parsing and formatting, JSON
numbers beyond 2^53, sorted-key JSON output and the configuration fingerprint
built on it, and the `st_gen` and `st_flags` terms of the executable pin, which
are BSD fields Linux does not have. The parity probe prints each divergence and
the exact functions it fences off on every run.

## Making a change

1. Fork the repository and create a short-lived branch from the default branch.
2. Keep the change small and add tests for observable behavior.
3. Update the API, operations, or security documentation when a contract changes.
4. Add a concise changelog entry for user-visible changes.
5. Run the local checks.

```bash
make build
make test
```

When changing the native parser or policy layer, include negative tests for malformed requests, duplicate or forbidden fields, authentication failures, size limits, and allowlist failures. Security properties should fail closed.

## Pull requests

A good pull request:

- explains the problem and why it belongs in iMessage Proxy's scope;
- describes security and privacy impact;
- links an issue when one exists;
- contains tests and documentation appropriate to the risk;
- avoids drive-by formatting or unrelated refactors;
- has a clean, understandable commit history;
- confirms that no secrets or personal message data are included.

Maintainers may ask for a design discussion, changes, or a smaller scope. Approval from a code owner and passing required checks are needed before merge. Do not force-push after review without explaining what changed.

## Commit messages

Use an imperative subject that explains the outcome, for example:

```text
Reject duplicate authorization headers
```

Add a body when the motivation or threat model is not obvious. Signed commits
are welcome but not currently required.

## Releases

iMessage Proxy uses Semantic Versioning. Maintainers create releases;
contributors should not update the version unless a maintainer asks.
Security-sensitive schema, socket, identity, and edge changes require an
explicit, reviewed upgrade design.

A release tag must be an annotated `vMAJOR.MINOR.PATCH` tag whose version equals
`VERSION` and whose commit is already on `main`. Every required CI check must
have succeeded on that exact commit before the tag is created. Never move or
reuse a release tag.

The release workflow validates that tag object and the required check runs,
then creates the deterministic archive, checksum, provenance attestation, and
GitHub release. It deliberately does not install packages or rerun source
validation while holding release and attestation permissions; ordinary CI owns
validation and uses the reviewed lockfile.

## Licensing

By contributing, you agree that your contribution is licensed under the [Apache License 2.0](LICENSE). You must have the right to submit the work. Do not copy code or documentation with incompatible terms.

## Getting help

See [SUPPORT.md](SUPPORT.md) for the right place to ask questions. Project governance and decision-making are documented in [GOVERNANCE.md](GOVERNANCE.md).
