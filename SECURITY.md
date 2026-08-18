# Security policy

iMessage Proxy exposes private Messages data to authenticated HTTPS clients. Security reports are treated as a priority.

## Supported versions

Only the latest stable release on the default branch receives security updates.

| Version | Supported |
| --- | --- |
| Latest `1.x` release | Yes |
| Older releases | No |
| Unreleased forks | No |

## Reporting a vulnerability

**Do not open a public issue, discussion, or pull request for a suspected vulnerability.**

Use [GitHub's private vulnerability reporting](https://github.com/mglaeser/imessage-proxy/security/advisories/new). Include, where possible:

- the affected version or commit;
- the macOS and `imsg` versions;
- a concise description of the impact and trust boundary crossed;
- minimal reproduction steps or a proof of concept;
- whether message contents, credentials, recipients, or host access may have been exposed;
- any suggested mitigation.

Do not include real conversations, access tokens, passwords, phone numbers, email addresses, private hostnames, or private IP addresses. Replace them with synthetic values.

If private vulnerability reporting is unavailable, contact the repository owner through the private contact method listed on the [maintainer's GitHub profile](https://github.com/mglaeser). Ask for a secure reporting channel before sending sensitive details.

## What to expect

Maintainers aim to:

- acknowledge a report within 3 business days;
- provide an initial assessment within 7 business days;
- share progress at least every 14 days while remediation is active;
- coordinate disclosure and credit with the reporter;
- publish a GitHub Security Advisory when users need to take action.

These are targets, not guarantees for an unfunded project. Please give maintainers a reasonable opportunity to investigate and release a fix before public disclosure.

## Scope

Examples of in-scope issues include:

- bypassing API-key authentication, scope, expiry, or revocation;
- reaching the API without a valid bearer key, or from an origin the server did not bind;
- invoking an unsupported dependency command or caller-selected argument;
- bypassing the outbound target allowlist;
- leaking message content, recipients, credentials, or secrets into logs;
- request smuggling, parsing confusion, or size-limit bypasses;
- command, path, configuration, or LaunchAgent injection;
- unsafe file permissions or secret persistence;
- bypassing send idempotency or causing unintended duplicate sends;
- escaping the same-origin console policy; and
- unintended public exposure while the explicit gate is disabled.

Social engineering, denial of service requiring physical host access, vulnerabilities exclusively in unsupported dependencies, and findings that require disabling documented macOS security controls are generally out of scope. Dependency vulnerabilities that change iMessage Proxy's exposure are still valuable reports.

## Safe-harbor intent

Good-faith research that respects privacy, uses accounts and devices you own or are authorized to test, avoids persistence and service disruption, and follows this policy will not be pursued by the project. This statement does not bind third parties and is not legal advice.

## Operator response

If compromise is suspected:

1. Stop public ingress locally with `imessage-proxy edge-stop`; verify its
   launchd label remains disabled, and optionally remove the external mappings as
   defense in depth.
2. Preserve sanitized logs and version information.
3. Revoke and replace every affected API key from a trusted administrator.
4. Review the send-target allowlist, audit metadata, and the address the
   listener is bound to.
5. Update to a fixed release before restoring service.

See [Security model](docs/security.md) for preventive controls and [Install and operate](docs/install.md) for rotation and recovery procedures.
