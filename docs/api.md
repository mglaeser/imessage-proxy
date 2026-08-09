# API reference

iMessage Proxy 0.3.0 exposes three HTTPS routes through its Caddy facade. The API is Alpha and may change before 1.0.

The repository also ships an [OpenAPI 3.1 description](../openapi.yaml) for tooling and client generation. This document defines the method-specific policy details that the compact OpenAPI schema references; changes to either must update both.

## Conventions

Set the base URL to the private DNS name and configured port, for example:

```text
https://messages.example.internal:9443
```

External clients authenticate to Caddy with HTTP Basic Auth over TLS. Every client should have a distinct username and password. Clients must trust the private Caddy root CA and must not disable certificate verification.

Authorization is currently coarse: every valid facade client can use every read
method and can send to any target in the deployment-wide allowlist. Give
credentials only to clients that may read the exposed conversations, and revoke
each client independently.

The bearer credential between Caddy and the native bridge is an internal implementation detail. Never distribute it to API clients or send it to the HTTPS facade.

POST request bodies use UTF-8 JSON with `Content-Type: application/json`. Query strings, chunked transfer encoding, duplicate headers, bodies over 64 KiB, and headers over 16 KiB are rejected. Responses include `Cache-Control: no-store`.

## Routes

| Method | Path | Purpose | Success |
| --- | --- | --- | --- |
| `GET` | `/healthz` | Exercise the facade, bridge, `imsg`, and a minimal Messages read | `200` JSON |
| `POST` | `/v1/rpc` | Submit one allowlisted JSON-RPC 2.0 request | `200` JSON-RPC |
| `POST` | `/v2/sessions/sms` | Send one allowlisted iMessage with a compact JSON body | `204` empty body |

Other route/method combinations return `404`.

## Health

`GET /healthz` runs an internal `chats.list` request with a limit of one. A healthy response is:

```json
{
  "status": "ok",
  "version": "0.3.0"
}
```

This is a functional readiness check, not merely a process liveness check. It can fail if authentication, the bridge, Full Disk Access, `imsg`, or the Messages database is unavailable.

```bash
curl \
  --cacert /secure/path/imessage-proxy-root.crt \
  --user automation-a \
  https://messages.example.internal:9443/healthz
```

## JSON-RPC endpoint

`POST /v1/rpc` accepts one JSON-RPC 2.0 object. Batches and notifications are not supported. The object may contain only `jsonrpc`, `id`, `method`, and `params`; the first three are required. `id` must be a non-boolean number or a non-empty string of at most 256 characters, and `params` must be an object when present.

```json
{
  "jsonrpc": "2.0",
  "id": "request-1",
  "method": "messages.after",
  "params": {
    "since_rowid": 0,
    "limit": 20
  }
}
```

The sanitized `imsg` JSON-RPC response is returned verbatim. HTTP `200` means the bridge completed the exchange; callers must still inspect the JSON-RPC `error` member before treating the operation as successful.

### `chats.list`

Lists a bounded set of chats.

| Parameter | Required | Constraint |
| --- | --- | --- |
| `limit` | No | Positive integer, maximum `100` |
| `unread_only` | No | Boolean |

```json
{"jsonrpc":"2.0","id":"chats-1","method":"chats.list","params":{"limit":20}}
```

### `messages.history`

Reads a bounded history page for one chat.

| Parameter | Required | Constraint |
| --- | --- | --- |
| `chat_id` | Yes | Positive integer |
| `limit` | No | Positive integer, maximum `200` |
| `participants` | No | Array of at most `32` non-empty strings, each at most `256` characters |
| `start` | No | Non-empty string, maximum `64` characters |
| `end` | No | Non-empty string, maximum `64` characters |
| `attachments` | No | Must be absent or `false`; iMessage Proxy forces `false` |

```json
{"jsonrpc":"2.0","id":"history-1","method":"messages.history","params":{"chat_id":42,"limit":50}}
```

### `messages.after`

Reads messages after a Messages database row cursor. This is the recommended polling method.

| Parameter | Required | Constraint |
| --- | --- | --- |
| `since_rowid` | Yes | Non-negative integer |
| `chat_id` | No | Positive integer |
| `limit` | No | Positive integer, maximum `200` |
| `attachments` | No | Must be absent or `false`; forced `false` |
| `convert_attachments` | No | Must be absent or `false`; forced `false` |
| `include_reactions` | No | Must be absent or `false`; forced `false` |

```bash
curl \
  --cacert /secure/path/imessage-proxy-root.crt \
  --user automation-a \
  --header 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":"poll-1","method":"messages.after","params":{"since_rowid":0,"limit":20}}' \
  https://messages.example.internal:9443/v1/rpc
```

Persist the returned next cursor after every successful page. A cursor belongs to one Messages database; reset and reconcile it if that database is replaced or restored. Use the response's actual cursor field rather than calculating one from timestamps.

### `send`

Sends text through Messages.app. iMessage Proxy requires exactly one target selector.

| Parameter | Required | Constraint |
| --- | --- | --- |
| `text` | Yes | String containing `1`–`4000` characters |
| `to` | One target | Non-empty address string, maximum `256` characters |
| `chat_id` | One target | Positive integer |
| `chat_identifier` | One target | Non-empty string, maximum `256` characters |
| `chat_guid` | One target | Non-empty string, maximum `256` characters |
| `service` | No | `auto`, `imessage`, or `sms`; normalized to lowercase |
| `region` | No | String, maximum `16` characters |

Unlike the simple endpoint below, this advanced RPC may request carrier SMS via
`service: "sms"` or let Messages choose via `service: "auto"`. Client
credentials are not scoped per route or method.

The target's exact allowlist representation must appear in `allowed-targets.txt`:

```text
person@example.net
chat_id:42
chat_identifier:example-value
chat_guid:example-guid
```

A line containing only `*` deliberately disables target restriction. It is not recommended. The bridge always replaces the transport with `applescript`; callers cannot select a private or injected transport.

```bash
curl \
  --cacert /secure/path/imessage-proxy-root.crt \
  --user automation-a \
  --header 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":"send-1","method":"send","params":{"to":"person@example.net","text":"iMessage Proxy test","service":"imessage"}}' \
  https://messages.example.internal:9443/v1/rpc
```

Do not automatically retry a send after an ambiguous timeout. Reconcile using the returned GUID or message history to avoid duplicates.

### `message.send_status`

Looks up the status of one sent message.

| Parameter | Required | Constraint |
| --- | --- | --- |
| `guid` | Yes | Non-empty string, maximum `256` characters |

```json
{"jsonrpc":"2.0","id":"status-1","method":"message.send_status","params":{"guid":"example-guid"}}
```

## Simple SMS-style endpoint

`POST /v2/sessions/sms` is an easy-to-use endpoint for immediate iMessage
sends without a JSON-RPC envelope. Its small JSON body works like sending an
SMS: provide the required opaque `smsId` value, recipient, and message. The endpoint always forces
the `imessage` service and normal AppleScript transport; it is not a carrier SMS
gateway and exposes no provider-side account, caller-ID, balance, history, or
scheduling surface.

The request must use `Content-Type: application/json` and contain only:

| Field | Required | Constraint |
| --- | --- | --- |
| `smsId` | Yes | Opaque string, maximum `64` characters; validated and discarded, never logged or returned, and not used for correlation, deduplication, or idempotency |
| `recipient` | Yes | Non-empty string, maximum `256` characters; must be exactly allowlisted |
| `message` | Yes | String containing `1`–`460` characters |
| `sendAt` | No | Legacy immediate marker; omit it in new requests, or use numeric `-1`; scheduled timestamps are rejected |

Success returns `204 No Content`, which means Messages.app accepted the send
command—not that the recipient received it. Do not automatically retry after an
ambiguous timeout; reconcile through message history to avoid duplicate sends.

```bash
curl \
  --cacert /secure/path/imessage-proxy-root.crt \
  --user automation-a \
  --header 'Content-Type: application/json' \
  --data '{"smsId":"request-1","recipient":"person@example.net","message":"Hello from iMessage Proxy"}' \
  https://messages.example.internal:9443/v2/sessions/sms
```

Use a distinct iMessage Proxy credential for every client. Never reuse a
password or token from another service.

## Errors

Bridge-generated errors use a small JSON object:

```json
{"error":"send target is not allowed"}
```

| HTTP status | Meaning |
| --- | --- |
| `400` | Malformed HTTP/JSON, invalid parameter, unsupported transfer style, or scheduled send |
| `401` | Missing or invalid credentials at an authentication boundary |
| `403` | RPC method, parameter, or send target is forbidden |
| `404` | Route or HTTP method not found |
| `408` | The bounded HTTP request timed out at the facade or bridge |
| `413` | Request body exceeds 64 KiB |
| `415` | A POST endpoint is not using JSON content type |
| `431` | Headers exceed 16 KiB |
| `500` | The bridge or facade encountered an internal error |
| `502` | `imsg` failed or returned an invalid response, an SMS-style send failed, or the facade could not use the bridge upstream |
| `503` | Functional health failed, the bridge concurrency limit is full, or the facade/upstream is temporarily unavailable |
| `504` | The bridge's `imsg` deadline or the facade's wait for the bridge expired |

Caddy can reject a request before it reaches the bridge; its error body is not part of iMessage Proxy's JSON error contract. Clients should primarily branch on HTTP status and treat bodies as diagnostic text.

## Stability

During Alpha, additions and breaking changes may occur in minor releases. The method allowlist, parameter limits, authentication boundaries, target policy, and response forwarding rules are compatibility-sensitive. Consult [CHANGELOG.md](../CHANGELOG.md) before upgrading.
