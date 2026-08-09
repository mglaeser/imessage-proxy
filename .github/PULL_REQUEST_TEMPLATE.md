## Summary

<!-- What problem does this solve, and why does it belong in iMessage Proxy? -->

## Changes

<!-- Describe the smallest meaningful set of changes. -->

## Security and privacy impact

<!-- Consider authentication, network exposure, message data, recipients, logs, secrets, TCC/SIP, and the send allowlist. Write "None" only after reviewing them. -->

## Validation

<!-- List exact checks performed and relevant environments. -->

- [ ] `make build`
- [ ] `make test`
- [ ] Manual validation described below, if applicable

## Compatibility and operations

<!-- Note API/config/state changes, migration needs, and rollback. -->

## Checklist

- [ ] The change is focused and linked to an issue or explains why no issue is needed.
- [ ] New behavior has positive and negative tests.
- [ ] User-facing changes are documented and added to `CHANGELOG.md` under `Unreleased`.
- [ ] No real messages, recipients, credentials, private hosts, private IPs, or personal logs are included.
- [ ] Security properties fail closed and no macOS protection is weakened.
- [ ] I have the right to contribute this work under Apache-2.0.
