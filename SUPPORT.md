# Support

iMessage Proxy is community-maintained security-sensitive software. Support is best-effort; there is no service-level agreement or guaranteed response time.

## Where to ask

- **Usage and design questions:** start a [GitHub Discussion](https://github.com/mglaeser/imessage-proxy/discussions).
- **Reproducible bugs:** use the [bug report form](https://github.com/mglaeser/imessage-proxy/issues/new?template=bug_report.yml).
- **Feature proposals:** use the [feature request form](https://github.com/mglaeser/imessage-proxy/issues/new?template=feature_request.yml).
- **Security vulnerabilities:** follow [SECURITY.md](SECURITY.md) and report privately.

Please search existing issues, discussions, [Install and operate](docs/install.md), and [Troubleshooting](docs/troubleshooting.md) first.

## Information to include

Provide:

- iMessage Proxy version or commit;
- macOS architecture and version;
- `imsg` version;
- the exact iMessage Proxy command and sanitized error;
- expected and observed behavior;
- whether the native server, LaunchAgent, or client boundary is failing;
- minimal reproduction steps.

Redact API keys, hashes, Messages content, recipients, user names, device names, hostnames, IP addresses, request IDs tied to private logs, and filesystem paths that reveal identity. Prefer a minimal synthetic reproduction.

## Boundaries

The project cannot provide personalized infrastructure administration, Apple account recovery, Messages or carrier support, incident-response retainers, or help bypassing TCC, SIP, authentication, allowlists, the public-exposure gate, or the native server's socket-only network boundary.

iMessage Proxy is not affiliated with Apple Inc. For macOS, Messages, or Apple Account support, use [Apple Support](https://support.apple.com/).
