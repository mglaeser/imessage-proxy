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
const cli = await readFile(new URL("../bin/imessage-proxy", import.meta.url), "utf8");
const example = await readFile(new URL("../config/imessage-proxy.env.example", import.meta.url), "utf8");

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

test("the listener binds what it was configured to bind, and proves it", () => {
  // The bind address stopped being a compile-time constant when it became
  // configurable. The guarantee that replaced it is narrower but not weaker: the
  // listener must prove with getsockname() that it is on the address that was
  // asked for, so a setting that widened the bind still refuses to serve.
  assert.match(server, /address\.sin_addr\.s_addr = configuration\.bindAddress;/,
    "the socket must bind the configured address");
  const proof = server.match(/struct sockaddr_in bound = \{0\};[\s\S]*?socket_not_configured_address"\);/)?.[0];
  assert.ok(proof, "the bind must be verified after listen()");
  assert.ok(proof.includes("getsockname"), "the verification must read the socket, not the request");
  assert.ok(proof.includes("bound.sin_addr.s_addr != configuration.bindAddress"),
    "the verification must compare against the configured address");
  assert.ok(proof.includes("ntohs(bound.sin_port) != configuration.port"),
    "the verification must still compare the port");
});

test("loopback is what an unconfigured installation gets", () => {
  // Every path to another address has to be one an operator asked for by name.
  assert.match(server, /environment\[@"IMESSAGE_PROXY_BIND_ADDRESS"\] \?: @"127\.0\.0\.1"/,
    "the server must default to loopback");
  assert.match(server, /@"IMESSAGE_PROXY_BIND_ADDRESS"\n?\s*\]\]|@"IMESSAGE_PROXY_BIND_ADDRESS"/,
    "the setting must be in the recognized set or the server refuses the plist");
  // inet_pton is what decides the text is an address, so a hostname cannot be
  // resolved into something the operator did not write.
  assert.match(server, /inet_pton\(AF_INET, bindText\.UTF8String, &parsedBind\) != 1/,
    "the address must be parsed by inet_pton, not accepted as text");
});

test("a wildcard bind does not widen the console's origins", () => {
  // Enumerating interfaces to guess an origin would turn the allowlist into
  // "anything that resolves here". Exposing the port exposes the API; reaching
  // the console over an interface means binding that interface.
  const derivation = server.match(/NSMutableArray<NSString \*> \*origins =[\s\S]*?configuration\.allowedOrigins = origins;/)?.[0];
  assert.ok(derivation, "the allowed origins must be derived where the bind is parsed");
  assert.ok(derivation.includes("INADDR_ANY"),
    "0.0.0.0 must be excluded from the origins explicitly");
  assert.ok(derivation.includes("INADDR_LOOPBACK"),
    "loopback must not be added twice");
  // And the check must consult that list rather than rebuilding one beside it.
  const check = server.match(/- \(BOOL\)originAllowed:[\s\S]*?\n}/)?.[0];
  assert.ok(check, "originAllowed: must exist");
  assert.ok(check.includes("self.configuration.allowedOrigins containsObject:origin"),
    "the origin check must use the derived list");
  assert.ok(!/127\.0\.0\.1|localhost/.test(check),
    "the origin check must not hardcode an origin beside the derived list");
});

test("the settings the CLI writes and the settings the server recognises are the same settings", () => {
  // The server refuses to start on any IMESSAGE_PROXY_* name it does not
  // recognise, so a setting threaded through the CLI and forgotten in that set
  // is not a setting that is quietly ignored: it is a LaunchAgent that boots,
  // exits, and is relaunched every ThrottleInterval until an operator reads the
  // log. The mistake is one line in either file and is invisible in both.
  const declaration = server.match(/NSSet<NSString \*> \*recognized =[\s\S]*?\]\];/)?.[0];
  assert.ok(declaration, "the recognised settings must be declared in one place");
  const recognized = new Set(Array.from(declaration.matchAll(/@"(IMESSAGE_PROXY_[A-Z0-9_]+)"/g), (m) => m[1]));
  assert.ok(recognized.size > 10, "the recognised set must list the settings");
  for (const name of new Set(cli.match(/IMESSAGE_PROXY_[A-Z0-9_]+/g) ?? [])) {
    assert.ok(recognized.has(name), `the CLI names ${name} and the server would refuse to start on it`);
  }
  // The other direction, minus the two a caller sets for the CLI's own HTTP
  // client rather than for the service, so a setting added to the server and
  // never rendered into the LaunchAgent fails here too.
  for (const name of recognized) {
    if (name === "IMESSAGE_PROXY_API_KEY" || name === "IMESSAGE_PROXY_URL") {
      continue;
    }
    assert.ok(cli.includes(name), `the server recognises ${name} and the CLI never sets it`);
  }
  // And the setting is only useful if it reaches the running service by both
  // routes: the rendered LaunchAgent, and the environment `serve` is run with.
  const rendered = cli.match(/render_server_agent_to\(\) \{[\s\S]*?\n\}/)?.[0];
  const runner = cli.match(/run_server\(\) \{[\s\S]*?\n\}/)?.[0];
  assert.ok(rendered && runner, "both paths that hand the server its environment must be present");
  for (const name of ["IMESSAGE_PROXY_BIND_ADDRESS", "IMESSAGE_PROXY_PORT", "IMESSAGE_PROXY_PUBLIC_ORIGIN"]) {
    assert.ok(rendered.includes(name), `the LaunchAgent render omits ${name}`);
    assert.ok(runner.includes(name), `the serve environment omits ${name}`);
  }
});

test("the extra console origin is validated on both sides of the plist", () => {
  // The CLI writes the value launchd hands the server, so a value the server
  // will not start on has to be refused before it is written; the server
  // validates it again because a plist can be edited by hand.
  assert.match(cli, /^public_origin_valid\(\) \{$/m, "the CLI must have a rule of its own");
  const guard = cli.match(/require_api_settings\(\) \{[\s\S]*?\n\}/)?.[0];
  assert.ok(guard?.includes("public_origin_valid"), "the CLI must refuse a bad origin before launchd sees it");
  const validator = server.match(/static BOOL IsValidPublicOrigin\([\s\S]*?\n}/)?.[0];
  assert.ok(validator, "IsValidPublicOrigin must exist");
  assert.ok(validator.includes('[value hasPrefix:@"http://"]') && validator.includes('[value hasPrefix:@"https://"]'),
    "only the two schemes a console is served over may be accepted");
  assert.ok(validator.includes("inet_pton"), "a host of digits and dots must be held to the address rule");
  // Fail closed, like every other unusable setting: a console that answers 403
  // to every send is the failure this setting exists to end, and starting with
  // the value ignored reproduces it exactly.
  const use = server.match(/NSString \*publicOrigin =[\s\S]*?configuration\.allowedOrigins = origins;/)?.[0];
  assert.ok(use, "the setting must be read where the origins are built");
  assert.ok(use.includes("IMPServerErrorInvalidConfiguration") && use.includes("IMESSAGE_PROXY_PUBLIC_ORIGIN"),
    "an invalid value must refuse to start and name the setting");
  assert.ok(use.includes("publicOrigin.length > 0"), "an absent or empty value must leave the derived list alone");
  assert.ok(use.includes("![origins containsObject:normalizedOrigin]"),
    "the entry must not be added twice when it repeats one the server derived");
});

test("the RFC 3339 pattern is anchored at end of input, not end of line", () => {
  // ICU's $ matches at the end of the input and also before a final line
  // terminator, so "2024-01-01T00:00:00Z\n" satisfies a pattern anchored with $.
  // The formatter behind it does not reject the newline either - Apple's
  // NSISO8601DateFormatter parses that string and returns a date - so with $ the
  // strict parser accepted a timestamp with trailing whitespace. \z is end of
  // input and admits no line terminator.
  //
  // This is checkable only by reading the source: on Linux the formatter returns
  // nil for every input, so the parser rejects the string for an unrelated
  // reason and a behavioural test passes either way.
  const parser = server.match(/static BOOL ParseStrictRFC3339\([\s\S]*?\n}/)?.[0];
  assert.ok(parser, "ParseStrictRFC3339 must exist");
  const pattern = parser.match(/regularExpressionWithPattern:([\s\S]*?)options:/)?.[1];
  assert.ok(pattern, "ParseStrictRFC3339 must build its pattern inline");
  assert.ok(pattern.includes("\\\\z"), "the timestamp pattern must end at \\z");
  assert.ok(!/\$"/.test(pattern), "the timestamp pattern must not anchor with $");
});

test("every key the example configuration names is a key the CLI accepts", () => {
  // config/imessage-proxy.env.example is installed alongside the CLI and tells
  // the reader to copy it and replace the placeholders. The CLI dies on the
  // first key it does not recognise, so a stale example is not a stale comment:
  // it is a configuration that cannot start. This file kept naming the Caddy
  // edge, its ACME address and its two ports for every release after that edge
  // was deleted, and nothing failed until somebody followed the instruction.
  const allowed = cli.match(/service_config_key_allowed\(\) \{[\s\S]*?\n\}/)?.[0];
  assert.ok(allowed, "the CLI must decide the accepted keys in one place");
  for (const name of example.match(/^#?(IMESSAGE_PROXY_[A-Z0-9_]+)=/gm) ?? []) {
    const key = name.replace(/^#?/, "").replace(/=$/, "");
    assert.ok(
      allowed.includes(key),
      `config/imessage-proxy.env.example names ${key}, which the CLI refuses; a copy of that file cannot start`,
    );
  }
  // And the other way for the two the CLI insists on, so an example that stops
  // showing a required key fails here rather than in somebody's install.
  for (const required of ["IMESSAGE_PROXY_IMSG_BIN", "IMESSAGE_PROXY_IMSG_SHA256"]) {
    assert.match(
      example,
      new RegExp(`^${required}=`, "m"),
      `the example must show ${required}, which the CLI requires to be present`,
    );
  }
});
