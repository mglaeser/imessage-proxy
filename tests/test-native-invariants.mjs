// Static checks over the Objective-C sources that catch, on Linux, the mistakes
// that otherwise only surface on the macOS runner - or worse, at runtime.
//
// These are not a substitute for compiling. They exist because three separate
// defects in one afternoon were invisible to every local check and cost a full
// CI round trip each: a selector that gained parameters while two call sites
// kept the old one, a column index that pointed at the wrong column after the
// projection grew, and a schema constant that drifted from the DDL beside it.
// Each is mechanical, each is checkable by reading the source, and each broke
// something a compiler either could not see or reported only after ten minutes.
//
// A check belongs here only if it would have failed on a real bug. Nothing here
// asserts style.

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const store = await readFile(new URL("../src/api-key-store.m", import.meta.url), "utf8");
const server = await readFile(new URL("../src/imessage-proxy-server.m", import.meta.url), "utf8");
const header = await readFile(new URL("../src/api-key-store.h", import.meta.url), "utf8");

// Objective-C selectors are the parameter labels in order. Two call sites kept
// initWithUUID:...:createdAt: after it gained senderIdentifier:, which the
// compiler caught - but only after a push, and only for the sites it could see.
function selectorsOf(text, method) {
  const found = [];
  const pattern = new RegExp(`\\b${method}:`, "g");
  let match;
  while ((match = pattern.exec(text)) !== null) {
    // Walk forward collecting `label:` tokens until the message or signature ends.
    const tail = text.slice(match.index, match.index + 2000);
    const end = tail.search(/[;{]|\]\s*;/);
    const segment = end === -1 ? tail : tail.slice(0, end);
    const labels = Array.from(segment.matchAll(/(?:^|[\s\[])([A-Za-z_][A-Za-z0-9_]*):/g), (m) => m[1]);
    found.push(labels.join(":"));
  }
  return found;
}

test("every record initializer call site uses the current selector", () => {
  const selectors = new Set([...selectorsOf(store, "initWithUUID"), ...selectorsOf(header, "initWithUUID")]);
  assert.ok(selectors.size > 0, "the record initializer must be present");
  for (const selector of selectors) {
    assert.ok(
      selector.includes("senderIdentifier") && selector.includes("senderIdentifierAssigned"),
      `a call site or declaration still uses the pre-identifier selector: ${selector}`,
    );
  }
  assert.equal(selectors.size, 1, `all initWithUUID: uses must agree, found: ${[...selectors].join(" | ")}`);
});

test("the api-key column count matches the projection it indexes", () => {
  // Anything selected after IMP_API_KEY_COLUMNS is read at this offset. When the
  // projection gained two columns and the offset did not, authentication read
  // sender_identifier as the key hash and every request became a 503.
  const macro = store.match(/#define IMP_API_KEY_COLUMNS[\s\S]*?\n\n/);
  assert.ok(macro, "IMP_API_KEY_COLUMNS must be defined");
  const columns = (macro[0].match(/"([^"]*)"/g) ?? [])
    .map((literal) => literal.slice(1, -1))
    .join("")
    .split(",")
    .filter(Boolean);
  const declared = Number(store.match(/kIMPAPIKeyColumnCount = (\d+)/)?.[1]);
  assert.ok(columns.length > 0, "the projection must list columns");
  assert.equal(declared, columns.length,
    `kIMPAPIKeyColumnCount is ${declared} but the projection has ${columns.length}: ${columns.join(",")}`);
  // The reader indexes these positionally, so order is part of the contract.
  assert.equal(columns[0], "uuid");
  assert.equal(columns[columns.length - 1], "last_used_at");
});

test("every column the record reader indexes exists in the table", () => {
  const ddl = store.match(/static const char \*const kIMPAPIKeysDDL =[\s\S]*?";/)?.[0] ?? "";
  const macro = store.match(/#define IMP_API_KEY_COLUMNS[\s\S]*?\n\n/)?.[0] ?? "";
  const columns = (macro.match(/"([^"]*)"/g) ?? [])
    .map((literal) => literal.slice(1, -1))
    .join("")
    .split(",")
    .filter(Boolean);
  for (const column of columns) {
    assert.ok(ddl.includes(column), `the projection selects ${column}, which api_keys does not declare`);
  }
});

test("the read-disabled gate names every database-backed route", () => {
  // A route that reads Messages but is missing from the gate answers 503 with no
  // explanation on an installation that deliberately declined Full Disk Access,
  // instead of the 409 that says how to turn reading on.
  const gate = server.match(/static BOOL RequestReadsMessages\(IMPHTTPRequest \*request\)[\s\S]*?\n}/)?.[0];
  assert.ok(gate, "RequestReadsMessages must exist");
  for (const route of ["/api/chats", "/api/scheduled-messages", "/api/statistics/messages"]) {
    assert.ok(gate.includes(route), `the read gate does not cover ${route}`);
  }
  // Sending is Apple Events, not a database read, and must stay available.
  assert.ok(!/isEqualToString:@"\/api\/messages"/.test(gate),
    "sending must not be gated on Full Disk Access: it uses Apple Events");
});

test("the refusal always carries the command that lifts it", () => {
  // A caller told only "disabled" cannot act. Every place the server reports the
  // mode must name the command, because the operator reading it is the one
  // person who can change it.
  const command = "imessage-proxy enable-messages-read";
  const refusals = server.match(/messages-read-disabled[\s\S]{0,400}?\);/g) ?? [];
  assert.ok(refusals.length >= 2, "both the read routes and chat_id sends must report the mode");
  for (const refusal of refusals) {
    assert.ok(refusal.includes(command), `a messages-read-disabled response omits "${command}"`);
  }
  assert.ok(server.includes(`@"enable_with": @"${command}"`), "GET /api/status must publish the enable command");
});

test("the sender identifier cannot be omitted or duplicated", () => {
  const ddl = store.match(/static const char \*const kIMPAPIKeysDDL =[\s\S]*?";/)?.[0] ?? "";
  assert.match(ddl, /sender_identifier TEXT NOT NULL UNIQUE/,
    "an unattributable or ambiguous key must be impossible in the schema, not merely discouraged");
  assert.match(ddl, /NOT sender_identifier GLOB '\*\[\^a-z\]\*'/, "the identifier must be roman letters only");
});

test("only an administrator may suppress the identifier", () => {
  // The parameter is refused for anyone else rather than ignored: a caller that
  // believed it had suppressed the marker must not be told the send succeeded
  // as requested.
  const guard = server.match(/identifierOptOutPresent && !\[actor hasScope:IMPAPIKeyScopeAdmin\][\s\S]{0,500}?;\n/);
  assert.ok(guard, "a non-admin opt-out must be refused explicitly");
  assert.ok(guard[0].includes("identifier-required"), "the refusal must use the identifier-required problem code");
  assert.ok(/Problem\(403/.test(guard[0]), "suppression by a non-admin key must be a 403");
});

test("the SMS marker stays inside GSM-7", () => {
  // An emoji forces UCS-2 on SMS, cutting the segment from 160 characters to 70
  // and roughly tripling what a message costs to send. iMessage has no such
  // cost, which is why the two transports use different markers.
  const suffix = server.match(/sendAsSMS \? @"[^"]*" : @"[^"]*"/)?.[0];
  assert.ok(suffix, "the per-transport marker must be chosen at the send");
  const [sms, imessage] = suffix.match(/@"([^"]*)"/g).map((literal) => literal.slice(2, -1));
  assert.equal(sms, "^", "the SMS marker must be a GSM-7 character");
  assert.match(imessage, /^\\U[0-9A-F]{8}$/, "the iMessage marker must be an escaped code point, not a raw byte");
});

test("a chosen sender identifier is refused before the insert, not by the constraint", () => {
  // Left to the UNIQUE constraint, a duplicate reaches createKeyLockedNamed's
  // retry loop, which reads any constraint failure as a key-material collision
  // and regenerates the token four times - none of which changes the identifier.
  // The caller then gets 503 "key-store-unavailable" for a permanent mistake,
  // and a client obeying that status retries forever.
  assert.match(store, /SELECT 1 FROM api_keys WHERE sender_identifier=\? LIMIT 1/,
    "an explicitly chosen identifier must be checked against the table before the insert");
  const check = store.match(/if \(ok && !identifierAssigned\) \{[\s\S]{0,200}?\}/)?.[0];
  assert.ok(check, "the check must run only for a caller-supplied identifier");
  assert.ok(check.includes("refuseTakenSenderIdentifier"), "the supplied identifier must be the one checked");
  assert.match(store, /IMPAPIKeyStoreErrorSenderIdentifierTaken,\s*\n?\s*@"That sender identifier already belongs/,
    "a taken identifier must have its own error code, not the capacity Conflict");
  assert.match(header, /IMPAPIKeyStoreErrorSenderIdentifierTaken/, "the error code must be declared in the header");
  // 409 with the capacity reason would tell an operator to delete a key.
  assert.match(server, /@"sender-identifier-taken"/, "the refusal must reach the caller as its own problem code");
  const mapping = server.match(/BOOL identifierTaken = storeError\.code == IMPAPIKeyStoreErrorSenderIdentifierTaken;[\s\S]{0,400}?;\n/);
  assert.ok(mapping, "key creation must map the taken-identifier error");
  assert.ok(/\? 409 : 503|409 : 503/.test(mapping[0]) || mapping[0].includes("409"),
    "a taken identifier must be a 409, not a 503 that invites a retry");
});

test("a service that is present but not a string is refused, not defaulted", () => {
  // "service":null or "service":2 is a caller who meant to choose. Reading it as
  // absent picks iMessage, which is the guess this endpoint promises never to
  // make - over the field that decides carrier cost and which marker is sent.
  assert.match(server, /BOOL servicePresent = \[body\.allKeys containsObject:@"service"\]/,
    "the send route must distinguish an absent service from an unusable one");
  const parse = server.match(/NSString \*requestedService =[\s\S]{0,300}?;\n/)?.[0];
  assert.ok(parse, "the service must be parsed from the body");
  assert.ok(parse.includes("servicePresent"), "a present-but-non-string service must not fall back to the default");
  assert.ok(/[?:]\s*nil/.test(parse), "an unusable service must resolve to nil so validService refuses it");
  assert.ok(parse.indexOf("nil") < parse.indexOf('@"imessage"'),
    "the default belongs on the absent branch, not the unusable one");
});

test("the previous schema is carried forward rather than refused", () => {
  // Refusing it costs an operator every key they have issued, and the refusal
  // arrives only after prepare has already replaced the server that was working.
  const migratable = store.match(/static const int kIMPMigratableSchemaVersion = (\d+);/);
  const current = store.match(/static const int kIMPSchemaVersion = (\d+);/);
  assert.ok(migratable && current, "both schema versions must be declared");
  assert.equal(Number(migratable[1]), Number(current[1]) - 1, "exactly the preceding schema is migrated");
  assert.match(store, /BOOL migratable = applicationID == kIMPApplicationID && schemaVersion == kIMPMigratableSchemaVersion/,
    "the open path must recognise the previous schema");
  assert.match(store, /if \(!fresh && !current && !migratable\)/, "only an unrecognised schema may be refused");
  // The refusal an operator does meet must say what to do about it.
  const refusal = store.match(/if \(!fresh && !current && !migratable\) \{[\s\S]{0,600}?\}/)[0];
  assert.ok(refusal.includes("uninstall.sh --purge"), "the refusal must name the recovery command");
});

test("the first administrator is identified as adm", () => {
  // The bootstrap key's messages are the first any recipient of a new
  // installation sees, so the marker says what wrote them rather than "aa".
  assert.match(store, /kIMPBootstrapSenderIdentifier = @"adm"/,
    "the bootstrap identifier must be adm");
  const bootstrap = store.match(/- \(IMPAPIKeyRecord \*\)bootstrapAdminNamed:[\s\S]*?\n}/)?.[0];
  assert.ok(bootstrap, "bootstrapAdminNamed: must be present");
  assert.ok(bootstrap.includes("kIMPBootstrapSenderIdentifier"),
    "the bootstrap must take the named identifier, not the next sequential one");
  // A revoked administrator keeps its identifier, and the column is unique over
  // every key on record - so the name can be taken, and a bootstrap must not
  // fail over it.
  assert.ok(bootstrap.includes("senderIdentifierTaken"),
    "the bootstrap must check whether the identifier is already held");
  assert.ok(bootstrap.includes("nextSenderIdentifier"),
    "the bootstrap must fall back to a sequential identifier when adm is taken");
  // Whatever it lands on, nobody chose it.
  assert.match(bootstrap, /identifierAssigned:YES/,
    "a bootstrap identifier is assigned by the service, not supplied");
  // The value has to satisfy the column it is written to.
  const ddl = store.match(/static const char \*const kIMPAPIKeysDDL =[\s\S]*?";/)?.[0] ?? "";
  const bounds = ddl.match(/length\(sender_identifier\) BETWEEN (\d+) AND (\d+)/);
  assert.ok(bounds, "the identifier length constraint must be present");
  assert.ok("adm".length >= Number(bounds[1]) && "adm".length <= Number(bounds[2]),
    "adm must satisfy the identifier length constraint");
  assert.ok(/^[a-z]+$/.test("adm"), "adm must satisfy the roman-letters constraint");
});
