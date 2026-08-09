# Governance

Stella uses a maintainer-led, contribution-friendly governance model. The goal is clear accountability while the project is small, with a path to shared stewardship as the contributor community grows.

## Roles

### Contributors

Anyone who reports issues, improves documentation, reviews changes, or submits code is a contributor. Contributors are expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md) and the workflow in [CONTRIBUTING.md](CONTRIBUTING.md).

### Maintainers

Maintainers have repository write access and are responsible for:

- triaging issues and pull requests;
- protecting the project's security boundaries and intentionally narrow scope;
- reviewing and merging changes;
- maintaining releases and security advisories;
- applying the Code of Conduct;
- documenting material technical and governance decisions.

Current code ownership is recorded in [.github/CODEOWNERS](.github/CODEOWNERS). Code ownership identifies review responsibility; it does not grant unilateral ownership of contributors' work.

## Decisions

Routine, reversible decisions are made through issue and pull-request review. Maintainers seek rough consensus and give more weight to evidence, tests, security impact, and long-term maintenance cost than to vote counts.

Changes that expand the trust boundary, add an API capability, alter authentication, change secret storage, or break compatibility should begin with a public proposal. The proposal should document alternatives, risks, migration, and rollback. A maintainer records the decision in the issue or pull request.

During an active vulnerability response, maintainers may work privately and merge a minimal fix before a public design discussion.

## Becoming a maintainer

An existing maintainer may nominate a contributor who has demonstrated sustained, constructive participation; sound security judgment; respectful review; and reliable follow-through. Existing maintainers decide by consensus. The new maintainer's access and code-ownership entry are added transparently.

## Inactivity and removal

Maintainers may step down at any time. Access may be removed for prolonged inactivity, an unresolved conflict of interest, repeated failure to protect project users, or a Code of Conduct enforcement outcome. Whenever privacy permits, governance changes are recorded publicly.

## Project assets and succession

Maintainers steward the GitHub repository, release credentials, package names, and security channels for the community. At least two trusted maintainers should hold recovery access once the project has that many maintainers. If the sole maintainer becomes unavailable, established contributors should use a public issue to coordinate a good-faith continuation or fork.

## Amendments

Governance changes use the same public pull-request process as other material project changes. Security-sensitive contact or recovery details may remain private.
