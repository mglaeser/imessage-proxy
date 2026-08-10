# Roadmap

The roadmap protects the small 1.0 architecture. New capabilities must remain
explicit resources with a clear privacy boundary; command passthrough is not a
growth strategy.

## 1.0 release gates

- [ ] Pass Objective-C warnings-as-errors, static analysis, shell/Markdown/API
  lint, native integration tests, and Caddy Unix-socket tests.
- [ ] Fuzz the bounded HTTP parser and key/idempotency state transitions.
- [ ] Validate both host-native LaunchAgents and the direct Unix socket on the
  target Mac across graceful/forced server restarts, edge restarts, logout/login,
  sleep/wake, and reboot.
- [ ] Confirm the exact `imsg 0.13.4` adapter schemas on a harmless fixture account.
- [ ] Complete external IPv4 `A` DNS, exact 80→host-HTTP/443→host-HTTPS mapping,
  ACME, firewall, authentication, scope, rate-limit, target-denial, idempotency,
  audit-privacy, and harmless-send acceptance.
- [ ] Publish signed release provenance and an independently verified archive digest.

## Candidate additions

- [ ] A bounded one-shot cross-chat cursor command upstream, followed by a REST
  catch-up resource with durable cursor semantics.
- [ ] Delivery status only after the supported dependency exposes a stable,
  non-injected one-shot JSON command.
- [ ] Contacts-assisted whois/identity lookup only after a stable mode can avoid
  unexpected Contacts permission and return a privacy-reviewed schema.
- [ ] Attachment upload/download only with isolated staging IDs, strict media/size
  validation, safe lifecycle cleanup, and no host path disclosure.
- [ ] Live events only with explicit backpressure, reconnect cursors, bounded
  subscriptions, revocation during streams, and restart acceptance.
- [ ] Reproducible release signing and notarization that preserves a stable TCC identity.

## Permanently out of scope

- disabling System Integrity Protection or TCC;
- injecting code into Messages.app or using private messaging frameworks;
- arbitrary command, database, shell, transport, or host-file access;
- anonymous or cookie-authenticated API access;
- carrier-SMS fallback or wildcard send targets;
- copying conversation databases into another runtime; and
- a second message database or application-side conversation cache.
