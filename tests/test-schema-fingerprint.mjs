// Guards the API-key database schema against the one class of mistake that
// cannot be recovered in the field.
//
// The store refuses to open a database whose sqlite_master hashes to anything
// other than kIMPSchemaFingerprint, and it refuses a user_version it does not
// know. So a schema edit that forgets the fingerprint, forgets the version bump,
// or produces a migrated database that differs from a fresh one by a single
// character does not fail in review or in a unit test: it fails on every
// operator's Mac, on the next start, with the server unable to open its own key
// store. Nothing else in the suite can catch that, because the fingerprint is a
// constant compared against a value only SQLite can produce.
//
// This runs anywhere Node does, so the check lands on Linux CI rather than after
// a release. It reads the real DDL out of src/api-key-store.m and joins the
// adjacent string literals the way the compiler will, so it can never drift from
// the text the server actually executes.

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";

const source = await readFile(new URL("../src/api-key-store.m", import.meta.url), "utf8");

function constant(name) {
  const match = source.match(new RegExp(`static const int ${name} = (\\d+);`));
  assert.ok(match, `${name} must be declared`);
  return Number(match[1]);
}

// Concatenates a run of adjacent C string literals into the single string the
// compiler produces, so this test reads the SQL the server will actually run
// rather than a copy that can drift from it.
function joinLiterals(text) {
  let sql = "";
  for (const raw of text.split("\n")) {
    let rest = raw.trim();
    while (rest.startsWith('"')) {
      let index = 1;
      while (index < rest.length && (rest[index] !== '"' || rest[index - 1] === "\\")) {
        index += 1;
      }
      sql += JSON.parse(rest.slice(0, index + 1));
      rest = rest.slice(index + 1).trim();
    }
  }
  return sql;
}

// The value of a file-scope "static const char *const NAME = <literals>;".
function stringConstant(name) {
  const marker = `static const char *const ${name} =`;
  const start = source.indexOf(marker);
  assert.ok(start >= 0, `${name} must be declared`);
  const end = source.indexOf('";', start);
  assert.ok(end > start, `${name} must be terminated`);
  const sql = joinLiterals(source.slice(start + marker.length, end + 1));
  assert.ok(sql.length > 0, `${name} must expand to SQL`);
  return sql;
}

// The literal run inside one IMPExecute call, from its first literal to the
// argument that follows. Matched on content rather than indentation, because
// clang-format chooses the indentation and may change it.
function inlineStatement(firstLiteral, lastLiteral) {
  const start = source.indexOf(firstLiteral);
  assert.ok(start >= 0, `could not find ${firstLiteral.slice(0, 48)}`);
  const last = source.indexOf(lastLiteral, start);
  assert.ok(last > start, `could not find ${lastLiteral.slice(0, 48)}`);
  const sql = joinLiterals(source.slice(start, last + lastLiteral.length));
  assert.ok(sql.startsWith("CREATE TABLE"), "the extracted statement must begin with a CREATE");
  assert.ok(sql.endsWith(";"), "the extracted statement must be complete");
  return sql;
}

const schemaVersion = constant("kIMPSchemaVersion");
const oldestMigratable = constant("kIMPOldestMigratableSchemaVersion");
const declaredFingerprint = source.match(/kIMPSchemaFingerprint = @"([0-9a-f]{64})"/)?.[1];
const apiKeysDDL = stringConstant("kIMPAPIKeysDDL");
const apiKeysIndexDDL = stringConstant("kIMPAPIKeysIndexDDL");
const apiKeysCopyDDL = stringConstant("kIMPAPIKeysMigrationCopyDDL");
const auditRecordsDDL = stringConstant("kIMPAuditRecordsDDL");
const auditIndexesDDL = stringConstant("kIMPAuditIndexesDDL");
const auditCopyDDL = stringConstant("kIMPAuditMigrationCopyDDL");
const idempotencyDDL = inlineStatement('"CREATE TABLE idempotency_records ("', '"PRAGMA application_id=1229803595;"');

// The order these run in inside configureAndValidateDatabase, for a fresh
// install and for an upgrade from the previous schema.
const freshDDL =
  apiKeysDDL + apiKeysIndexDDL + idempotencyDDL + auditRecordsDDL + auditIndexesDDL +
  `PRAGMA user_version=${schemaVersion};`;
// The two upgrade steps, in the order configureAndValidateDatabase runs them.
const auditMigrationDDL =
  "ALTER TABLE audit_records RENAME TO audit_records_v5;" +
  auditRecordsDDL + auditCopyDDL + auditIndexesDDL + "PRAGMA user_version=6;";
const apiKeysMigrationDDL =
  "ALTER TABLE api_keys RENAME TO api_keys_v6;" +
  apiKeysDDL + apiKeysCopyDDL + apiKeysIndexDDL + `PRAGMA user_version=${schemaVersion};`;

// Exactly IMPVerifySchemaFingerprint in src/api-key-store.m.
function fingerprint(database) {
  const rows = database
    .prepare("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name")
    .all();
  const signature = rows.map((row) => `${row.type}\t${row.name}\t${row.tbl_name}\t${row.sql}\n`).join("");
  return createHash("sha256").update(signature, "utf8").digest("hex");
}

function freshDatabase() {
  const database = new DatabaseSync(":memory:");
  database.exec("PRAGMA foreign_keys=ON");
  database.exec(freshDDL);
  return database;
}

// A populated database on the OLDEST schema this release still opens, built from
// the current DDL with each later addition removed, so the fixture cannot rot
// into something the migrations were never going to meet.
function legacyDatabase() {
  const apiKeysV5 = apiKeysDDL
    .replace(
      "sender_identifier TEXT NOT NULL UNIQUE CHECK(" +
        "length(sender_identifier) BETWEEN 2 AND 8 AND NOT sender_identifier GLOB '*[^a-z]*')," +
        "sender_identifier_assigned INTEGER NOT NULL CHECK(sender_identifier_assigned IN (0,1)),",
      "",
    );
  const auditV5 = auditRecordsDDL.replace(",'targets.read','targets.replace'", "");
  assert.ok(!apiKeysV5.includes("sender_identifier"), "the legacy fixture must predate the sender identifier");
  assert.ok(!auditV5.includes("targets.read"), "the legacy fixture must predate the allowlist audit actions");

  const database = new DatabaseSync(":memory:");
  database.exec("PRAGMA foreign_keys=ON");
  database.exec(
    apiKeysV5 + apiKeysIndexDDL + idempotencyDDL + auditV5 + auditIndexesDDL +
      `PRAGMA user_version=${oldestMigratable};`,
  );
  for (let index = 0; index < 3; index += 1) {
    database.exec(
      `INSERT INTO api_keys VALUES('1111111${index}-1111-4111-8111-11111111111${index}','Key ${index}',` +
        `'imp_abcdefg${index}',x'${String(index + 1).repeat(64).slice(0, 64)}','admin',${100 + index},NULL,NULL,NULL)`,
    );
  }
  database.exec(
    "INSERT INTO audit_records VALUES('22222222-2222-4222-8222-222222222222'," +
      "'11111110-1111-4111-8111-111111111110',NULL,'local','keys.list','final',200,5,100)",
  );
  database.exec(
    "INSERT INTO idempotency_records VALUES('11111110-1111-4111-8111-111111111110','idem-key-0001'," +
      `'33333333-3333-4333-8333-333333333333',x'${"aa".repeat(32)}','succeeded',202,x'7b7d',100,100)`,
  );
  return database;
}

// Exactly the sequence configureAndValidateDatabase runs, pragmas included. The
// legacy_alter_table pragma is not incidental: api_keys is the parent of both
// foreign keys, and without it SQLite rewrites the children's REFERENCES text,
// which changes their stored schema and fails the fingerprint on every existing
// installation.
function migrate(database) {
  database.exec("BEGIN EXCLUSIVE");
  database.exec(auditMigrationDDL);
  database.exec("COMMIT");
  database.exec("PRAGMA foreign_keys=OFF");
  database.exec("PRAGMA legacy_alter_table=ON");
  database.exec("BEGIN EXCLUSIVE");
  database.exec(apiKeysMigrationDDL);
  database.exec("COMMIT");
  database.exec("PRAGMA legacy_alter_table=OFF");
  database.exec("PRAGMA foreign_keys=ON");
}

test("the schema versions describe a coherent upgrade", () => {
  assert.ok(Number.isInteger(schemaVersion) && schemaVersion > 0);
  assert.ok(oldestMigratable > 0 && oldestMigratable < schemaVersion,
    "the oldest migratable schema must precede this release");
  assert.ok(/^[0-9a-f]{64}$/.test(declaredFingerprint ?? ""), "kIMPSchemaFingerprint must be a SHA-256 digest");
  assert.ok(freshDDL.includes(`PRAGMA user_version=${schemaVersion};`),
    "the DDL must set the version this release declares");
  assert.ok(apiKeysMigrationDDL.includes(`PRAGMA user_version=${schemaVersion};`),
    "the last migration step must set the version this release declares");
});

test("the declared fingerprint matches the schema this release creates", () => {
  const database = freshDatabase();
  assert.equal(database.prepare("PRAGMA user_version").get().user_version, schemaVersion);
  assert.equal(fingerprint(database), declaredFingerprint,
    "kIMPSchemaFingerprint is stale: every existing installation would refuse to open its key store");
});

test("a database on the oldest supported schema migrates to a byte-identical schema", () => {
  const database = legacyDatabase();
  const counted = (table) => database.prepare(`SELECT count(*) AS n FROM ${table}`).get().n;
  const before = ["api_keys", "audit_records", "idempotency_records"].map(counted);

  migrate(database);

  assert.equal(database.prepare("PRAGMA user_version").get().user_version, schemaVersion);
  assert.equal(fingerprint(database), declaredFingerprint,
    "a migrated database differs from a fresh one, so upgrading would brick the installation");
  // An upgrade must not cost the operator their credentials or their history.
  assert.deepEqual(["api_keys", "audit_records", "idempotency_records"].map(counted), before);
  assert.equal(database.prepare("PRAGMA foreign_key_check").all().length, 0);
  assert.equal(database.prepare("SELECT count(*) AS n FROM sqlite_master WHERE name LIKE '%\\_v_' ESCAPE '\\'").get().n, 0);

  // Every carried-forward key must be attributable, or the transparency the
  // identifier exists for would have a hole exactly the size of the install base.
  const carried = database.prepare("SELECT sender_identifier, sender_identifier_assigned FROM api_keys").all();
  assert.equal(carried.length, before[0]);
  assert.equal(new Set(carried.map((row) => row.sender_identifier)).size, carried.length, "identifiers must be unique");
  for (const row of carried) {
    assert.match(row.sender_identifier, /^[a-z]{2,8}$/);
    assert.equal(row.sender_identifier_assigned, 1, "a carried-forward identifier must be marked as assigned");
  }
});

test("the children keep referencing api_keys after the parent is rebuilt", () => {
  // Without legacy_alter_table the RENAME rewrites these to api_keys_v6, which
  // changes their stored schema silently and only fails later, as a refusal to
  // open. Asserted directly so the pragma cannot be dropped as noise.
  const database = legacyDatabase();
  migrate(database);
  for (const child of ["audit_records", "idempotency_records"]) {
    const sql = database.prepare("SELECT sql FROM sqlite_master WHERE name=?").get(child).sql;
    assert.ok(sql.includes("REFERENCES api_keys(uuid)"), `${child} must still reference api_keys`);
    assert.ok(!sql.includes("api_keys_v6"), `${child} must not reference the renamed table`);
  }
});

test("the audit action constraint and the Objective-C validator list the same actions", () => {
  // The two lists are written separately, and a route naming an action only one
  // of them knows is accepted by the validator and then silently dropped by the
  // database, or refused at the boundary for no visible reason.
  const constraint = auditRecordsDDL.match(/action TEXT NOT NULL CHECK\(action IN \(([^)]*)\)\)/);
  assert.ok(constraint, "the audit action CHECK constraint must be present");
  const stored = new Set(Array.from(constraint[1].matchAll(/'([^']+)'/g), (match) => match[1]));

  const validator = source.match(/NSSet<NSString \*> \*allowed = \[NSSet setWithArray:@\[([\s\S]*?)\]\];/);
  assert.ok(validator, "the audit action validator must be present");
  const validated = new Set(Array.from(validator[1].matchAll(/@"([^"]+)"/g), (match) => match[1]));

  assert.deepEqual(Array.from(stored).sort(), Array.from(validated).sort());
  for (const action of ["targets.read", "targets.replace"]) {
    assert.ok(stored.has(action), `${action} must be an accepted audit action`);
  }
});

test("the migrated schema accepts the new actions and still refuses unknown ones", () => {
  const database = freshDatabase();
  const rows = [
    ["44444444-4444-4444-8444-444444444444", "targets.read"],
    ["66666666-6666-4666-8666-666666666666", "targets.replace"],
  ];
  for (const [uuid, action] of rows) {
    database.exec(
      `INSERT INTO audit_records VALUES('${uuid}',NULL,NULL,'local','${action}','final',200,1,102)`,
    );
  }
  assert.throws(
    () =>
      database.exec(
        "INSERT INTO audit_records VALUES('55555555-5555-4555-8555-555555555555'," +
          "NULL,NULL,'local','targets.delete','final',200,1,103)",
      ),
    /constraint/i,
    "an unregistered action must still be rejected by the database",
  );
});
