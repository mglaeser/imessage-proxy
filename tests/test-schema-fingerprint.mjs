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
const migratableVersion = constant("kIMPMigratableSchemaVersion");
const declaredFingerprint = source.match(/kIMPSchemaFingerprint = @"([0-9a-f]{64})"/)?.[1];
const auditRecordsDDL = stringConstant("kIMPAuditRecordsDDL");
const auditIndexesDDL = stringConstant("kIMPAuditIndexesDDL");
const auditCopyDDL = stringConstant("kIMPAuditMigrationCopyDDL");

// The order these run in inside configureAndValidateDatabase, for a fresh
// install and for an upgrade from the previous schema.
const freshDDL =
  inlineStatement('"CREATE TABLE api_keys ("', '"PRAGMA application_id=1229803595;"') +
  auditRecordsDDL +
  auditIndexesDDL +
  `PRAGMA user_version=${schemaVersion};`;
const migrationDDL =
  "ALTER TABLE audit_records RENAME TO audit_records_v5;" +
  auditRecordsDDL +
  auditCopyDDL +
  auditIndexesDDL +
  `PRAGMA user_version=${schemaVersion};`;

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

// A populated database on the previous schema, built from the current DDL with
// the version-6 additions removed, so the fixture cannot rot into something the
// migration was never going to meet.
function legacyDatabase() {
  const legacyDDL = freshDDL
    .replace(",'targets.read','targets.replace'", "")
    .replace(`PRAGMA user_version=${schemaVersion};`, `PRAGMA user_version=${migratableVersion};`);
  assert.ok(!legacyDDL.includes("targets.read"), "the legacy fixture must not already allow the new actions");
  assert.ok(legacyDDL.includes(`user_version=${migratableVersion}`), "the legacy fixture must be the migratable version");
  const database = new DatabaseSync(":memory:");
  database.exec("PRAGMA foreign_keys=ON");
  database.exec(legacyDDL);
  database.exec(
    "INSERT INTO api_keys VALUES('11111111-1111-4111-8111-111111111111','Existing key','imp_abcdefgh'," +
      `x'${"11".repeat(32)}','admin',100,NULL,NULL,NULL)`,
  );
  database.exec(
    "INSERT INTO audit_records VALUES('22222222-2222-4222-8222-222222222222'," +
      "'11111111-1111-4111-8111-111111111111',NULL,'local','keys.list','final',200,5,100)",
  );
  database.exec(
    "INSERT INTO audit_records VALUES('33333333-3333-4333-8333-333333333333'," +
      "NULL,NULL,'local','auth.reject','attempted',NULL,NULL,101)",
  );
  return database;
}

test("the schema versions describe a coherent upgrade", () => {
  // Everything else here is derived from these two numbers, so they are checked
  // against each other rather than against themselves. If they were ever equal,
  // a database would be simultaneously current and in need of migration, and the
  // migration would run against the schema it was meant to produce.
  assert.ok(Number.isInteger(schemaVersion) && schemaVersion > 0);
  assert.equal(
    schemaVersion,
    migratableVersion + 1,
    "this release must migrate from exactly the previous schema version",
  );
  assert.ok(/^[0-9a-f]{64}$/.test(declaredFingerprint ?? ""), "kIMPSchemaFingerprint must be a SHA-256 digest");
  // A schema edit that changed the DDL but not the version would leave existing
  // databases claiming a version whose fingerprint no longer matches.
  assert.ok(
    freshDDL.includes(`PRAGMA user_version=${schemaVersion};`),
    "the DDL must set the version this release declares",
  );
  assert.ok(
    migrationDDL.includes(`PRAGMA user_version=${schemaVersion};`),
    "the migration must set the version this release declares",
  );
});

test("the declared fingerprint matches the schema this release creates", () => {
  const database = freshDatabase();
  assert.equal(database.prepare("PRAGMA user_version").get().user_version, schemaVersion);
  assert.equal(
    fingerprint(database),
    declaredFingerprint,
    "kIMPSchemaFingerprint is stale: every existing installation would refuse to open its key store",
  );
});

test("a database on the previous schema migrates to a byte-identical schema", () => {
  const migrated = legacyDatabase();
  const before = migrated.prepare("SELECT count(*) AS n FROM audit_records").get().n;
  const keysBefore = migrated.prepare("SELECT count(*) AS n FROM api_keys").get().n;

  migrated.exec("BEGIN EXCLUSIVE");
  migrated.exec(migrationDDL);
  migrated.exec("COMMIT");

  assert.equal(migrated.prepare("PRAGMA user_version").get().user_version, schemaVersion);
  assert.equal(
    fingerprint(migrated),
    declaredFingerprint,
    "a migrated database differs from a fresh one, so upgrading would brick the installation",
  );
  // An upgrade must not cost the operator their credentials or their history.
  assert.equal(migrated.prepare("SELECT count(*) AS n FROM audit_records").get().n, before);
  assert.equal(migrated.prepare("SELECT count(*) AS n FROM api_keys").get().n, keysBefore);
  assert.equal(
    migrated.prepare("SELECT source FROM audit_records WHERE request_uuid='22222222-2222-4222-8222-222222222222'").get()
      .source,
    "local",
  );
  assert.equal(migrated.prepare("SELECT count(*) AS n FROM sqlite_master WHERE name LIKE '%_v5'").get().n, 0);
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
