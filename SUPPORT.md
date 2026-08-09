# Support

Stella is community-maintained Alpha software. Support is best-effort; there is no service-level agreement or guaranteed response time.

## Where to ask

- **Usage and design questions:** start a [GitHub Discussion](https://github.com/mglaeser/stella/discussions).
- **Reproducible bugs:** use the [bug report form](https://github.com/mglaeser/stella/issues/new?template=bug_report.yml).
- **Feature proposals:** use the [feature request form](https://github.com/mglaeser/stella/issues/new?template=feature_request.yml).
- **Security vulnerabilities:** follow [SECURITY.md](SECURITY.md) and report privately.

Please search existing issues, discussions, [Operations](docs/operations.md), and [Troubleshooting](docs/troubleshooting.md) first.

## Information to include

Provide:

- Stella version or commit;
- macOS architecture and version;
- Apple Container, Caddy, and `imsg` versions;
- the exact Stella command and sanitized error;
- expected and observed behavior;
- whether the bridge, LaunchAgent, facade, or client boundary is failing;
- minimal reproduction steps.

Redact tokens, password hashes, Messages content, recipients, user names, device names, private DNS names, IP addresses, and filesystem paths that reveal identity. Prefer a minimal synthetic reproduction.

## Boundaries

The project cannot provide personalized infrastructure administration, Apple account recovery, Messages or carrier support, incident-response retainers, or help bypassing TCC, SIP, authentication, allowlists, or private-network requirements.

Stella is not affiliated with Apple Inc. For macOS, Messages, or Apple Account support, use [Apple Support](https://support.apple.com/).
