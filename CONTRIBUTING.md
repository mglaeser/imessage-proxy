# Contributing to iMessage Proxy

Thank you for helping make private-network Messages automation safer. iMessage Proxy welcomes focused bug reports, documentation improvements, tests, and carefully scoped code changes.

## Before you start

- Read the [Code of Conduct](CODE_OF_CONDUCT.md).
- Search [existing issues](https://github.com/mglaeser/imessage-proxy/issues) and pull requests.
- For a substantial feature or architecture change, open a proposal issue before writing code.
- Report security concerns through the private process in [SECURITY.md](SECURITY.md).

iMessage Proxy is intentionally narrow. Features that broaden host control, weaken authentication, expose the bridge beyond loopback, bypass macOS protections, or encourage public-Internet operation are unlikely to be accepted.

## Development setup

Most source-level validation requires macOS and Xcode Command Line Tools. The integration test uses a fake `imsg` backend and does not access real conversations or send a message.

```bash
git clone https://github.com/mglaeser/imessage-proxy.git
cd imessage-proxy
make build
make test
```

Do not put real tokens, credentials, recipients, Messages databases, logs, or private infrastructure details in fixtures. Use reserved example domains and synthetic addresses.

## Making a change

1. Fork the repository and create a short-lived branch from the default branch.
2. Keep the change small and add tests for observable behavior.
3. Update the API, operations, or security documentation when a contract changes.
4. Add a concise entry under `Unreleased` in [CHANGELOG.md](CHANGELOG.md) for user-visible changes.
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

Add a body when the motivation, compatibility impact, or threat model is not obvious. Signed commits are welcome but not currently required.

## Compatibility and releases

iMessage Proxy uses Semantic Versioning, with the usual caveat that `0.x` versions may contain breaking changes. Maintainers create releases; contributors should not update the version unless a maintainer asks.

## Licensing

By contributing, you agree that your contribution is licensed under the [Apache License 2.0](LICENSE). You must have the right to submit the work. Do not copy code or documentation with incompatible terms.

## Getting help

See [SUPPORT.md](SUPPORT.md) for the right place to ask questions. Project governance and decision-making are documented in [GOVERNANCE.md](GOVERNANCE.md).
