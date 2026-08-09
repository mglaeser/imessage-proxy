# Roadmap

Stella's roadmap prioritizes a small, understandable security boundary over feature count. Milestones describe intent, not delivery commitments.

## Now — Alpha hardening (`0.1.x`)

- [ ] Validate installation and lifecycle on a documented macOS compatibility matrix.
- [ ] Add parser and policy regression coverage for every accepted and rejected request shape.
- [ ] Exercise install, upgrade, restart, credential rotation, and recovery paths on clean hosts.
- [ ] Document pinned dependency review and update procedures.
- [ ] Publish checksummed, reproducible source releases.
- [ ] Gather operator feedback without expanding the public-network threat boundary.

## Next — Beta readiness (`0.2.x`)

- [ ] Stabilize management commands, state paths, and configuration names.
- [ ] Add configuration schema/version detection and preflight diagnostics.
- [ ] Define compatibility guarantees for the JSON-RPC facade.
- [ ] Add upgrade tests from every supported release.
- [ ] Add structured health detail that does not reveal conversation data.
- [ ] Complete an independent threat-model and code review.

## Later — Stable (`1.0`)

- [ ] Publish a stable API and operator compatibility policy.
- [ ] Provide a documented security-release and deprecation process.
- [ ] Meet the supported-host test matrix across two consecutive releases.
- [ ] Demonstrate reliable backup-free recovery from checked-in configuration and regenerated secrets.
- [ ] Graduate only after real-world private-network operation produces no unresolved critical design issues.

## Explicitly not planned

- anonymous or public-Internet access;
- disabling SIP, TCC, or normal Messages protections;
- general macOS remote control or private-framework injection;
- attachment retrieval, arbitrary file access, or remote URL fetching;
- accepting unrestricted `imsg` RPC methods;
- storing plaintext client passwords in the repository;
- multi-tenant hosting with mutually untrusted users.

Propose roadmap changes through the [feature request form](https://github.com/mglaeser/stella/issues/new?template=feature_request.yml). Security and maintenance cost are acceptance criteria, not follow-up work.
