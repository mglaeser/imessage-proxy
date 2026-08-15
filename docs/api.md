# API

iMessage Proxy 1.0 exposes one unversioned REST surface under `/api`. The routes
documented here are the entire API. Every API request, including a status check,
requires exactly one scoped key as
`Authorization: Bearer <key>`. The service never accepts a credential in a query
parameter, cookie, JSON body, or another authorization scheme.

```bash
export IMESSAGE_PROXY_URL='https://messages.example.com'
export IMESSAGE_PROXY_API_KEY='imp_REPLACE_WITH_YOUR_KEY'
```

Use the standard header on every example:

```text
Authorization: Bearer imp_REPLACE_WITH_YOUR_KEY
```

Never disable certificate verification on a proxy you put in front. This service
itself speaks plain HTTP on loopback, so the base URL is
`http://127.0.0.1:8765` unless you changed the port.

## Scopes

| Scope | Grants |
| --- | --- |
| `messages:read` | Chats, background state, history, scheduled messages, and statistics |
| `messages:send` | Allowlisted text sends |
| `admin` | Audit, key, and recipient-allowlist administration, sending without the sender identifier, and every read/send operation |

`GET /api/status` accepts any valid key. A missing, malformed, expired, revoked,
or unknown key returns the same `401` response. A valid key without the required
scope returns `403`.

## Status

`GET /api/status` exercises the native service, the pinned `imsg` dependency,
and — on an installation that reads Messages — a minimal Messages database read.
It is a readiness check, not merely a process check.

```bash
curl --fail-with-body \
  --header "Authorization: Bearer $IMESSAGE_PROXY_API_KEY" \
  "$IMESSAGE_PROXY_URL/api/status"
```

```json
{
  "status": "ok",
  "version": "1.0.0",
  "uptime_seconds": 180,
  "messages": {
    "status": "ready",
    "dependency_version": "0.13.4"
  },
  "key": {
    "id": "48b64de5-fe25-44a7-9d4e-cdfad09f881b",
    "name": "automation-a",
    "key_prefix": "imp_PVHqRwmN",
    "scopes": ["messages:read", "messages:send"],
    "expires_at": "2026-11-07T12:00:00Z"
  }
}
```

## When reading is turned off

Reading and sending need different macOS permissions, and only one of them is
ever asked for. Sending uses Apple Events, which prompts the first time and is
granted in a dialog. Reading needs Full Disk Access, which macOS never prompts
for: an unauthorised read of `chat.db` simply fails, and a human has to add the
binary in System Settings by hand. An installation may therefore decline reading
altogether and run as a send-only service.

Where reading is off, the `messages` object of `GET /api/status` says so and
names the command that turns it back on:

```json
{
  "status": "disabled",
  "dependency_version": "0.13.4",
  "enable_with": "imessage-proxy enable-messages-read"
}
```

Every route whose answer comes out of the Messages database then refuses:

| Route | While reading is off |
| --- | --- |
| `GET /api/chats`, `/api/chats/{id}`, `/api/chats/{id}/messages`, `/api/chats/{id}/background` | `409 messages-read-disabled` |
| `GET /api/scheduled-messages` | `409 messages-read-disabled` |
| `GET /api/statistics/messages` | `409 messages-read-disabled` |
| `POST /api/messages` with `chat_id` | `409 messages-read-disabled`, because the chat must be resolved first |
| `POST /api/messages` with `recipient` | Unaffected, on either transport |

```json
{
  "type": "https://github.com/mglaeser/imessage-proxy/problems/messages-read-disabled",
  "title": "Conflict",
  "status": 409,
  "detail": "Reading Messages is turned off for this installation. Turn it on with: imessage-proxy enable-messages-read",
  "request_id": "1f825d86-1626-4a0c-a163-644a4cebd91b"
}
```

This is a decision, not an outage, which is why it is `409` and not `503`: it
answers the same way until an operator changes the installation. Every one of
those answers names `imessage-proxy enable-messages-read`, because the person
reading the detail is usually the one person who can act on it. Nothing else is
affected — keys, the allowlist, audit events and sends to a `recipient` all work
exactly as they do on a Mac that reads.

## Chats

### List chats

`GET /api/chats` returns at most 20 recent chats by default. `limit` accepts
`1-100`; `unread_only` accepts `true` or `false`.

```bash
curl --fail-with-body \
  --header "Authorization: Bearer $IMESSAGE_PROXY_API_KEY" \
  "$IMESSAGE_PROXY_URL/api/chats?limit=20&unread_only=true"
```

```json
{"chats":[{"id":42,"name":"Example","identifier":"person@example.net","service":"iMessage","is_group":false,"participants":["person@example.net"]}]}
```

Private account-routing fields returned by the local dependency are deliberately
removed at the API boundary.

### Get one chat

```bash
curl --fail-with-body \
  --header "Authorization: Bearer $IMESSAGE_PROXY_API_KEY" \
  "$IMESSAGE_PROXY_URL/api/chats/42"
```

The local positive chat ID is preferred for group reads and sends. It belongs to
one Messages database and is not portable to another Mac or restored database.
An unknown ID returns `404`.

### Inspect chat-background state

`GET /api/chats/{chat_id}/background` reads the pinned dependency's local
background metadata without returning a host path, remote asset URL, opaque
asset/object/channel identifier, communication-safety state, background-event row
ID, or implementation-version field. It returns only the semantic set/clear
state, a declared file size when available, safe cache-presence booleans, and the
latest set/clear timestamp.

```bash
curl --fail-with-body \
  --header "Authorization: Bearer $IMESSAGE_PROXY_API_KEY" \
  "$IMESSAGE_PROXY_URL/api/chats/42/background"
```

```json
{
  "chat_id": 42,
  "background_set": true,
  "file_size": 2048,
  "cache_exists": true,
  "watch_background_exists": false,
  "latest_event": {
    "action": "set",
    "date": "2026-08-09T12:03:00Z"
  }
}
```

Nullable fields are returned as `null` when the pinned dependency does not
provide them. An unknown chat returns `404`.

## Message history

`GET /api/chats/{chat_id}/messages` returns up to 50 messages by default and no
more than 200. Optional `start` is inclusive and `end` is exclusive. Both are
calendar-valid RFC 3339 date-times, for example `2026-08-09T10:15:00Z`. The
grammar requires uppercase `T` and `Z`, seconds from `00` through `59`, an
optional fractional part containing one to nine digits, and either `Z` or a
numeric UTC offset no greater than `14:00`. Leap seconds are not accepted. `end`
must be later than `start` when both are supplied. Invalid bounds return `400`
with the `invalid-date` problem type. A repeated `participant` filters
case-insensitive whole sender handles; each value contains `1-256` Unicode code
points and cannot begin with a hyphen or contain a comma or control character.

```bash
curl --fail-with-body \
  --header "Authorization: Bearer $IMESSAGE_PROXY_API_KEY" \
  "$IMESSAGE_PROXY_URL/api/chats/42/messages?limit=50"
```

```json
{
  "messages": [
    {
      "id": 1979,
      "chat_id": 42,
      "guid": "D6C5A028-4C63-44A4-8A4A-61D4430D7A51",
      "sender": "person@example.net",
      "is_from_me": false,
      "text": "Hello",
      "created_at": "2026-08-09T10:15:00Z",
      "attachments": [],
      "reactions": []
    }
  ]
}
```

Attachment metadata may include a safe filename, media type, UTI, byte size, and
sticker flag. Absolute host paths, converted paths, private account identifiers,
and destination routing fields are never returned.

History is sorted by `created_at` ascending, then by numeric message ID when two
rows have the same timestamp.

## Global search boundary

Cross-chat text search is not part of 1.0. The pinned dependency couples that
command to Contacts access and provides no no-Contacts mode. A remote read could
therefore trigger a TCC prompt or enumerate address-book data. Bounded history
stays available per chat without expanding that permission boundary.

## Send a message

`POST /api/messages` accepts exactly one `recipient` or positive `chat_id`, plus
`text` containing `1-4000` Unicode code points. A recipient contains `1-256`
Unicode code points and must be either `+` followed by 7-15 ASCII digits whose
first digit is nonzero, or an email-like handle containing exactly one `@`.
Whitespace, control characters, leading hyphens, and contact names are rejected.
The recipient must exactly match the typed allowlist. Text may contain tabs and
line breaks; other control characters and a leading hyphen are rejected because
the pinned dependency parses dash-prefixed values as options. An allowlisted but
unknown `chat_id` returns `404` without sending. Sending to a `recipient` needs
nothing read from Messages; sending to a `chat_id` resolves the chat first, so
it returns `409` where [reading is turned off](#when-reading-is-turned-off).

Every logical send needs an `Idempotency-Key` containing `8-128` ASCII letters,
digits, periods, underscores, tildes, or hyphens. Generate the value before the
first attempt and persist it beside the calling job. Reusing it with the same
request returns the stored outcome; reusing it with different content returns
`409`. The transport and the marker decision are part of the request, so
replaying one key as an SMS, or with the marker suppressed, is a conflict rather
than a replay of what was sent the first time.

```bash
curl --fail-with-body \
  --request POST \
  --header "Authorization: Bearer $IMESSAGE_PROXY_API_KEY" \
  --header "Idempotency-Key: $(uuidgen)" \
  --header 'Content-Type: application/json' \
  --data '{"recipient":"person@example.net","text":"Hello"}' \
  "$IMESSAGE_PROXY_URL/api/messages"
```

Or target one reviewed local chat:

```json
{"chat_id":42,"text":"Hello group"}
```

An exact line must exist in `allowed-targets.txt`:

```text
person@example.net
chat_id:42
```

The allowlist has no wildcard. An empty file disables sending without disabling
reads or key administration.

### Choosing the transport

`service` is `imessage` (the default) or `sms`. The chosen transport is the one
used and the only one tried: an iMessage that cannot go as an iMessage fails as
an iMessage, and nothing silently becomes a carrier message with carrier costs
and no encryption. A caller therefore always knows which transport carried its
message, and so which marker the recipient saw.

```json
{"recipient":"+15551234567","text":"Hello","service":"sms"}
```

Omitting `service` means `imessage`. Sending it as anything other than one of the
two strings — `null`, a number, a list — is `400` (`invalid-message`) rather than
the default, because a caller who sent the field meant to choose, and the field
decides both what the recipient is charged and which marker they see.

A `chat_id` names an existing conversation, which already has a service. Asking
for the other one returns `409` with `chat-service-mismatch` rather than
switching transport behind your back. That code replaced `not-imessage-chat`,
which could only ever mean one thing while iMessage was the only transport.

### The sender identifier

Every key has a `sender_identifier`: two to eight roman letters, unique across
keys. Every message the key sends ends with it, so the person receiving one can
tell which automation wrote to them, and tell all of them from you typing in
Messages.app.

```text
iMessage   Deploy 41 finished 🔖dep
SMS        Deploy 41 finished ^dep
```

The two markers differ because the transports do. An SMS segment holds 160
characters while the text stays inside the GSM-7 alphabet and 70 as soon as one
character falls outside it, so an emoji in the marker would more than halve the
room for the message and charge for it on every message. `^` is in GSM-7.
iMessage has no such alphabet, so it carries the clearer glyph, the bookmark
emoji `U+1F516`, at no cost.

Only an administrator may send an unmarked message, and only by asking for it on
that one message:

```json
{"recipient":"person@example.net","text":"Hello","sender_identifier":false}
```

Any key without `admin` that sends `sender_identifier` at all — `true` or
`false` — is refused with `403` and `identifier-required`. The field is refused
rather than ignored: a caller that believed it had suppressed the marker must
not be told its message went out as requested when it went out marked. So for
every other key the identifier is not a default to override; there is no request
shape that removes it.

### Managing the allowlist

`GET /api/targets` returns the current list and `PUT /api/targets` replaces it.
Both require `admin`, not `messages:send`: a credential that can send must not
be able to widen the set of people it may send to. The same list is editable on
the host with `imessage-proxy targets`, and in the console under **Recipients**.

```json
{"targets": ["+15551234567", "chat_id:42", "person@example.net"]}
```

`PUT` takes the whole list rather than a change to it, so two administrators
editing at once cannot merge into a set neither approved. Up to 500 unique
entries are accepted, each validated exactly as a send validates its target; one
invalid entry rejects the request whole. The file is replaced atomically and
re-read on the next send, so a change is effective immediately and no restart is
needed.

A successful command returns `202`:

```json
{
  "operation_id": "7B740A82-2149-43DB-BE37-6F3D28711A47",
  "state": "accepted",
  "message_id": 1979,
  "guid": "D6C5A028-4C63-44A4-8A4A-61D4430D7A51"
}
```

`message_id` and `guid` are present only when the inserted row is observable.
Accepted does not mean delivered. A deadline after Messages may have received the
command is recorded as ambiguous; the server never automatically executes that
idempotency key again. Inspect Messages.app before making a deliberate new send
with a new key.

## Scheduled messages

`GET /api/scheduled-messages?limit=50` reads future Send Later rows without
changing them. `limit` accepts `1-100`. A macOS database without scheduling
columns fails explicitly instead of returning an ambiguous empty list.

```bash
curl --fail-with-body \
  --header "Authorization: Bearer $IMESSAGE_PROXY_API_KEY" \
  "$IMESSAGE_PROXY_URL/api/scheduled-messages?limit=50"
```

## Statistics

`GET /api/statistics/messages` returns aggregate logical-message counts. Optional
parameters are a positive `chat_id`, an IANA `time_zone` identifier recognized
by the Mac (for example, `UTC` or `Europe/Vienna`), and `include_media=true`.
The time zone must be `UTC` or an exact, case-sensitive entry in macOS's
`NSTimeZone.knownTimeZoneNames` set and is limited to 64 UTF-8 bytes. Invalid
names return `400` with the `invalid-time-zone` problem type.

The response is a closed schema: total/sent/received counts; chat, sender,
service, and date breakdowns; the resolved time zone; and either `null` or
explicit attachment totals and type/chat breakdowns in `media`. Unknown
dependency fields and private host paths are dropped. An unknown `chat_id`
returns `404`. Totals cover the complete selected database scope; every
breakdown array is deterministically capped at the first 100 rows in the pinned
dependency's order. The required
`truncated_dimensions` array contains only upstream dimensions that exceeded
100 rows, in the fixed order `chats`, `senders`, `services`, `dates`,
`media.types`, `media.chats`. It is empty when every dimension is complete.

```bash
curl --fail-with-body \
  --header "Authorization: Bearer $IMESSAGE_PROXY_API_KEY" \
  "$IMESSAGE_PROXY_URL/api/statistics/messages?time_zone=Europe%2FVienna&include_media=true"
```

## Audit events

`GET /api/audit-events` requires `admin` and returns newest-first operational
metadata. `limit` defaults to `100` and accepts `1-1000`. Each event contains a
request ID, nullable caller/target key IDs, observed source address (`local` for
a direct socket caller or `invalid` when rejected proxy metadata cannot be
parsed), action, attempted/final phase, nullable status and duration, and
creation time. It never contains a credential, hash, message, recipient, conversation, or
dependency output.

```bash
curl --fail-with-body \
  --header "Authorization: Bearer $IMESSAGE_PROXY_API_KEY" \
  "$IMESSAGE_PROXY_URL/api/audit-events?limit=100"
```

## API-key administration

### List metadata

`GET /api/keys` returns metadata for active, expired, and revoked keys,
newest-created first. Key storage and this response are both capped at 1000
rows. It never returns a plaintext credential or hash. Each row carries the
key's `sender_identifier` and a `sender_identifier_assigned` flag, which is
`true` when the service chose the identifier and `false` when the administrator
creating the key named it. That list is also how you find out which key wrote a
message a recipient is asking about.

```bash
curl --fail-with-body \
  --header "Authorization: Bearer $IMESSAGE_PROXY_API_KEY" \
  "$IMESSAGE_PROXY_URL/api/keys"
```

### Create

`POST /api/keys` accepts a display name, one or more unique scopes, an expiry of
`1-1461` days (four years), and an optional `sender_identifier`. The default
expiry is 90 days.
Leading and trailing whitespace is removed from the name; the normalized value
must encode to `1-80` UTF-8 bytes and contain no Unicode control characters.
Storage is capped at 1000 keys. Before enforcing that cap, creation deletes at
most 100 expired or revoked keys that no idempotency record still references; if
the store remains full, creation returns `409`. Historical audit rows retain the
event while their deleted caller reference becomes null.

```bash
curl --fail-with-body \
  --request POST \
  --header "Authorization: Bearer $IMESSAGE_PROXY_API_KEY" \
  --header 'Content-Type: application/json' \
  --data '{"name":"automation-a","scopes":["messages:read","messages:send"],"expires_in_days":90,"sender_identifier":"aut"}' \
  "$IMESSAGE_PROXY_URL/api/keys"
```

Name the [sender identifier](#the-sender-identifier) when the recipients of this
key's messages should recognise it, and omit it to have the shortest unused one
assigned. Either way the key has one, `sender_identifier_assigned` records which
of the two happened, and it does not change for the life of the key. An
identifier any key on record still holds is refused with `409`
(`sender-identifier-taken`), revoked and expired keys included, because a marker
that has meant two different senders is worse than no marker. Choose another, or
omit the field and take the assigned one.

The first administrator, the one the installer issues, is `adm` rather than the
first sequential pair. It is not reserved: once that key is gone the identifier
can be taken like any other, and a bootstrap that finds it already held by a
revoked administrator takes the sequential one instead.

The response returns the new `imp_…` credential once. Store it immediately; it
cannot be recovered from the database later. Its `Location` header identifies
the metadata-only `GET /api/keys/{key_id}` resource:

```bash
curl --fail-with-body \
  --header "Authorization: Bearer $IMESSAGE_PROXY_API_KEY" \
  "$IMESSAGE_PROXY_URL/api/keys/48B64DE5-FE25-44A7-9D4E-CDFAD09F881B"
```

The detail response has the same non-secret shape as an item from `GET /api/keys`;
unknown key IDs return `404`.

### Revoke

```bash
curl --fail-with-body \
  --request DELETE \
  --header "Authorization: Bearer $IMESSAGE_PROXY_API_KEY" \
  "$IMESSAGE_PROXY_URL/api/keys/48B64DE5-FE25-44A7-9D4E-CDFAD09F881B"
```

Revocation is immediate and returns `204`. It is a soft, auditable state change.
The final active administrator key cannot be revoked. Rotate by creating and
testing a replacement before revoking the old key.

## Errors

API errors produced after routing use `application/problem+json`. Native-service
problems include a request ID suitable for matching the privacy-reviewed macOS
unified-log category:

```json
{
  "type": "https://github.com/mglaeser/imessage-proxy/problems/insufficient-scope",
  "title": "Forbidden",
  "status": 403,
  "detail": "The API key does not grant this operation.",
  "request_id": "1f825d86-1626-4a0c-a163-644a4cebd91b"
}
```

| Status | Meaning |
| --- | --- |
| `400` | Invalid path/query/body/header contract |
| `401` | Missing or unusable bearer key |
| `403` | Missing scope, disallowed browser origin, non-allowlisted target, or a non-admin key asking to send unmarked |
| `404` | Authenticated resource does not exist |
| `408` | Client request transfer exceeded its deadline |
| `409` | Idempotency/send-state conflict, chat/service mismatch, reading turned off, key-capacity limit, or final-admin protection |
| `413` | Body exceeds 64 KiB |
| `415` | JSON endpoint received another media type |
| `429` | Per-source or per-key rate limit exceeded |
| `431` | Headers exceed 16 KiB |
| `502` | The bounded dependency command failed or returned invalid output |
| `503` | Messages readiness or native capacity is unavailable |
| `504` | The dependency command exceeded its deadline |

`Retry-After` accompanies `429`; `WWW-Authenticate: Bearer` accompanies `401`.
Unknown `/api` routes authenticate before returning `404`, so route discovery
does not create an unauthenticated side channel.

The server can reject a malformed connection before the API route exists - for
example, an over-limit request header receives a plain `431`. Such pre-routing
responses cannot carry the API problem schema or its complete response-header
set, and they perform no API operation.

If you put your own proxy in front, it may also answer before the request ever
reaches this service. Those responses are its concern, not this API's.
