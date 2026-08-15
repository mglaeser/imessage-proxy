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
const apiKeysDDL = stringConstant("kIMPAPIKeysDDL");
const apiKeysIndexDDL = stringConstant("kIMPAPIKeysIndexDDL");
const auditRecordsDDL = stringConstant("kIMPAuditRecordsDDL");
const auditIndexesDDL = stringConstant("kIMPAuditIndexesDDL");
const idempotencyDDL = inlineStatement('"CREATE TABLE idempotency_records ("', '"PRAGMA application_id=1229803595;"');
const migrationSelectSQL = stringConstant("kIMPAPIKeysMigrationSelectSQL");
const migrationInsertSQL = stringConstant("kIMPAPIKeysMigrationInsertSQL");

// The schema as version 6 shipped it - the one every installation in the field
// is running. Frozen: version 6 is released and can never change again, so this
// is a historical record, not a copy of anything still being edited. The test
// below pins it to the fingerprint version 6 declared, so a typo here fails
// rather than quietly testing a schema nobody ever ran.
const VERSION_6_DDL =
  "CREATE TABLE api_keys (uuid TEXT PRIMARY KEY CHECK(length(uuid)=36),name TEXT NOT NULL CHECK(length(CAST(name AS BLOB)) BETWEEN 1 AND 80),key_prefix TEXT NOT NULL UNIQUE CHECK(length(key_prefix)=12),key_hash BLOB NOT NULL UNIQUE CHECK(length(key_hash)=32),scopes TEXT NOT NULL CHECK(scopes IN ('messages:read','messages:send','admin','messages:read,messages:send','messages:read,admin','messages:send,admin','messages:read,messages:send,admin')) ,created_at INTEGER NOT NULL CHECK(created_at > 0),expires_at INTEGER CHECK(expires_at IS NULL OR expires_at > created_at),revoked_at INTEGER CHECK(revoked_at IS NULL OR revoked_at >= created_at),last_used_at INTEGER CHECK(last_used_at IS NULL OR last_used_at >= created_at));" +
  "CREATE INDEX api_keys_active_idx ON api_keys(revoked_at, expires_at);" +
  "CREATE TABLE idempotency_records (principal_uuid TEXT NOT NULL REFERENCES api_keys(uuid) ON DELETE RESTRICT,idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 128),operation_uuid TEXT NOT NULL UNIQUE CHECK(length(operation_uuid)=36),request_hash BLOB NOT NULL CHECK(length(request_hash)=32),state TEXT NOT NULL CHECK(state IN ('in_progress','succeeded','ambiguous','failed')) ,response_status INTEGER CHECK(response_status IS NULL OR response_status BETWEEN 100 AND 599),response_body BLOB,created_at INTEGER NOT NULL CHECK(created_at > 0),updated_at INTEGER NOT NULL CHECK(updated_at >= created_at),PRIMARY KEY(principal_uuid, idempotency_key),CHECK((state='in_progress' AND response_status IS NULL AND response_body IS NULL) OR (state!='in_progress' AND response_status IS NOT NULL AND response_body IS NOT NULL)));" +
  "CREATE INDEX idempotency_updated_idx ON idempotency_records(updated_at);PRAGMA application_id=1229803595;" +
  "CREATE TABLE audit_records (request_uuid TEXT NOT NULL CHECK(length(request_uuid)=36),key_uuid TEXT REFERENCES api_keys(uuid) ON DELETE SET NULL,target_key_uuid TEXT CHECK(target_key_uuid IS NULL OR length(target_key_uuid)=36),source TEXT NOT NULL CHECK(length(source) BETWEEN 1 AND 64),action TEXT NOT NULL CHECK(action IN ('request.invalid','request.rate_limited','auth.unavailable','auth.rate_limited','auth.reject','origin.reject','route.not_found','status.read','chats.list','chats.read','background.read','messages.history','scheduled.list','statistics.read','messages.send','keys.list','keys.read','keys.create','keys.revoke','audit.list','targets.read','targets.replace','server.overloaded')) ,phase TEXT NOT NULL CHECK(phase IN ('attempted','final')) ,status INTEGER CHECK(status IS NULL OR status BETWEEN 100 AND 599),duration_ms INTEGER CHECK(duration_ms IS NULL OR duration_ms>=0),created_at INTEGER NOT NULL CHECK(created_at>0),PRIMARY KEY(request_uuid,phase),CHECK((phase='attempted' AND status IS NULL AND duration_ms IS NULL) OR (phase='final' AND status IS NOT NULL AND duration_ms IS NOT NULL)));" +
  "CREATE INDEX audit_created_idx ON audit_records(created_at DESC);CREATE INDEX audit_key_idx ON audit_records(key_uuid,created_at DESC);CREATE INDEX audit_target_key_idx ON audit_records(target_key_uuid,created_at DESC);";
const VERSION_6_FINGERPRINT = "223b40977c9f54e55e35a65d003934c62e8376b11ccedc139b2bd212846d69e1";

// The order these run in inside configureAndValidateDatabase, for a fresh
// install and for an upgrade from the previous schema.
const freshDDL =
  apiKeysDDL + apiKeysIndexDDL + idempotencyDDL + auditRecordsDDL + auditIndexesDDL +
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

test("the schema versions describe a coherent release", () => {
  assert.ok(Number.isInteger(schemaVersion) && schemaVersion > 0);
  assert.ok(/^[0-9a-f]{64}$/.test(declaredFingerprint ?? ""), "kIMPSchemaFingerprint must be a SHA-256 digest");
  assert.ok(freshDDL.includes(`PRAGMA user_version=${schemaVersion};`),
    "the DDL must set the version this release declares");
});

test("the declared fingerprint matches the schema this release creates", () => {
  const database = freshDatabase();
  assert.equal(database.prepare("PRAGMA user_version").get().user_version, schemaVersion);
  assert.equal(fingerprint(database), declaredFingerprint,
    "kIMPSchemaFingerprint is stale: the store would refuse to open its own database");
});

test("every key is attributable and no two keys can be confused", () => {
  // The identifier is what a recipient sees, so the database - not only the code
  // that writes to it - refuses a key without one, refuses a duplicate, and
  // refuses anything that is not roman letters.
  const database = freshDatabase();
  const insert = (uuid, prefix, identifier) =>
    database.exec(
      `INSERT INTO api_keys VALUES('${uuid}','Key','${prefix}',x'${uuid.replace(/-/g, "").repeat(4).slice(0, 64)}',` +
        `'admin','${identifier}',0,100,NULL,NULL,NULL)`,
    );
  insert("11111111-1111-4111-8111-111111111111", "imp_aaaaaaaa", "kle");
  assert.throws(() => insert("22222222-2222-4222-8222-222222222222", "imp_bbbbbbbb", "kle"), /UNIQUE|constraint/i,
    "two keys must not share an identifier");
  for (const invalid of ["k", "abcdefghi", "ab1", "AB", "a-b", ""]) {
    assert.throws(() => insert("33333333-3333-4333-8333-333333333333", "imp_cccccccc", invalid), /constraint/i,
      `the database must refuse the identifier "${invalid}"`);
  }
  assert.throws(
    () => database.exec(
      "INSERT INTO api_keys(uuid,name,key_prefix,key_hash,scopes,sender_identifier_assigned,created_at) " +
        `VALUES('44444444-4444-4444-8444-444444444444','Key','imp_dddddddd',x'${"dd".repeat(32)}','admin',0,100)`,
    ),
    /NOT NULL|constraint/i,
    "a key with no identifier must be impossible",
  );
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

// A version-6 database with keys, audit history and idempotency records in it -
// what an operator who has been running this proxy actually has on disk.
function populatedVersion6Database(keyCount = 3) {
  const database = new DatabaseSync(":memory:");
  database.exec("PRAGMA foreign_keys=ON");
  database.exec(VERSION_6_DDL);
  database.exec("PRAGMA user_version=6;");
  for (let index = 0; index < keyCount; index += 1) {
    const uuid = `${String(index + 1).repeat(8)}-1111-4111-8111-111111111111`.slice(0, 36);
    database.exec(
      `INSERT INTO api_keys(uuid,name,key_prefix,key_hash,scopes,created_at,expires_at,revoked_at,last_used_at) ` +
        `VALUES('${uuid}','Key ${index}','imp_${String.fromCharCode(97 + index).repeat(8)}',` +
        `x'${String(index + 1).repeat(2).slice(0, 2).repeat(32)}','admin',${100 + index},NULL,NULL,NULL)`,
    );
    database.exec(
      `INSERT INTO audit_records VALUES('${uuid}','${uuid}',NULL,'local','keys.create','final',200,1,${100 + index})`,
    );
    database.exec(
      `INSERT INTO idempotency_records VALUES('${uuid}','idem-key-${index}','${uuid}',` +
        `x'${"ab".repeat(32)}','succeeded',200,x'7b7d',${100 + index},${100 + index})`,
    );
  }
  return database;
}

// The lowest unused identifier, then the next - nextSenderIdentifier in JavaScript.
function nextIdentifier(taken) {
  for (let width = 2; width <= 8; width += 1) {
    for (let index = 0; index < 26 ** width; index += 1) {
      let candidate = "";
      let remaining = index;
      for (let position = 0; position < width; position += 1) {
        candidate = String.fromCharCode(97 + (remaining % 26)) + candidate;
        remaining = Math.floor(remaining / 26);
      }
      if (!taken.has(candidate)) return candidate;
    }
  }
  throw new Error("the identifier space is exhausted");
}

// configureAndValidateDatabase's migratable branch, statement for statement.
function migrateToVersion7(database) {
  database.exec("PRAGMA foreign_keys=OFF");
  database.exec("PRAGMA legacy_alter_table=ON");
  database.exec("BEGIN EXCLUSIVE");
  database.exec("ALTER TABLE api_keys RENAME TO api_keys_v6;");
  database.exec(apiKeysDDL);
  const rows = database.prepare(migrationSelectSQL).all();
  const taken = new Set();
  for (const row of rows) {
    const identifier = nextIdentifier(taken);
    taken.add(identifier);
    database
      .prepare(migrationInsertSQL)
      .run(row.uuid, row.name, row.key_prefix, row.key_hash, row.scopes, identifier, row.created_at,
        row.expires_at, row.revoked_at, row.last_used_at);
  }
  database.exec("DROP TABLE api_keys_v6;");
  database.exec(apiKeysIndexDDL);
  const violations = database.prepare("SELECT count(*) AS count FROM pragma_foreign_key_check").get().count;
  database.exec(`PRAGMA user_version=${schemaVersion};`);
  database.exec("COMMIT");
  database.exec("PRAGMA legacy_alter_table=OFF");
  database.exec("PRAGMA foreign_keys=ON");
  return { violations, identifiers: Array.from(taken) };
}

test("the frozen version-6 schema is the one version 6 actually shipped", () => {
  const database = populatedVersion6Database(0);
  assert.equal(fingerprint(database), VERSION_6_FINGERPRINT,
    "VERSION_6_DDL no longer reproduces the schema release 6 created");
  assert.equal(migratableVersion, 6);
  assert.equal(migratableVersion, schemaVersion - 1,
    "only the immediately preceding schema is carried forward");
});

test("upgrading a version-6 database lands on exactly the schema a fresh install creates", () => {
  // The whole point of the migration. A migrated database whose sqlite_master
  // differs from a fresh one by a single character fails nowhere but on an
  // operator's Mac, on the next start, with the store refusing its own file.
  const database = populatedVersion6Database();
  migrateToVersion7(database);
  assert.equal(database.prepare("PRAGMA user_version").get().user_version, schemaVersion);
  assert.equal(fingerprint(database), declaredFingerprint,
    "a migrated database does not match a fresh one: the store would refuse to open it");
});

test("the upgrade leaves the tables that reference api_keys untouched", () => {
  // ALTER TABLE RENAME rewrites REFERENCES clauses in other tables unless
  // legacy_alter_table is on. That edit is permanent and silent: audit_records
  // and idempotency_records would keep pointing at the temporary name, on a
  // release that never mentions it.
  const before = populatedVersion6Database();
  const childSQL = (database) =>
    database
      .prepare("SELECT name,sql FROM sqlite_master WHERE name IN ('audit_records','idempotency_records') ORDER BY name")
      .all();
  const original = JSON.stringify(childSQL(before));
  const { violations } = migrateToVersion7(before);
  assert.equal(JSON.stringify(childSQL(before)), original,
    "the upgrade rewrote a child table's REFERENCES clause");
  assert.equal(violations, 0, "the upgrade orphaned rows that referenced api_keys");
  assert.ok(original.includes("REFERENCES api_keys(uuid)"));
  assert.ok(!original.includes("api_keys_v6"));
});

test("the upgrade keeps every key, and gives each one a usable identifier", () => {
  const database = populatedVersion6Database(5);
  const before = database.prepare("SELECT uuid,name,key_prefix,key_hash,scopes,created_at FROM api_keys ORDER BY created_at").all();
  migrateToVersion7(database);
  const after = database.prepare("SELECT uuid,name,key_prefix,key_hash,scopes,created_at,sender_identifier,sender_identifier_assigned FROM api_keys ORDER BY created_at").all();

  assert.equal(after.length, before.length, "the upgrade lost a key");
  for (const [index, row] of after.entries()) {
    assert.equal(row.uuid, before[index].uuid);
    assert.equal(row.key_prefix, before[index].key_prefix, "a key's prefix changed, so the key stopped authenticating");
    assert.deepEqual(row.key_hash, before[index].key_hash, "a key's hash changed, so the issued token stopped working");
    assert.equal(row.scopes, before[index].scopes);
    assert.match(row.sender_identifier, /^[a-z]{2,8}$/, "a migrated key got an identifier the column would refuse");
    assert.equal(row.sender_identifier_assigned, 1, "nobody chose these identifiers, so they are recorded as assigned");
  }
  assert.equal(new Set(after.map((row) => row.sender_identifier)).size, after.length,
    "two migrated keys share an identifier, so their messages are indistinguishable");
  assert.equal(database.prepare("SELECT count(*) AS count FROM audit_records").get().count, 5,
    "the upgrade discarded audit history");
  assert.equal(database.prepare("SELECT count(*) AS count FROM idempotency_records").get().count, 5,
    "the upgrade discarded idempotency records, so replays would resend");
});

test("a migrated database still enforces every version-7 constraint", () => {
  // The rebuilt table must be the real thing, not a lookalike that happens to
  // hold the same rows.
  const database = populatedVersion6Database(2);
  migrateToVersion7(database);
  assert.throws(
    () => database.exec("UPDATE api_keys SET sender_identifier='aa'"),
    /UNIQUE|constraint/i,
    "the migrated table must still refuse two keys sharing an identifier",
  );
  assert.throws(
    () => database.exec("INSERT INTO api_keys(uuid,name,key_prefix,key_hash,scopes,sender_identifier_assigned,created_at) " +
      `VALUES('99999999-9999-4999-8999-999999999999','Key','imp_zzzzzzzz',x'${"ee".repeat(32)}','admin',0,100)`),
    /NOT NULL|constraint/i,
    "the migrated table must still refuse a key with no identifier",
  );
});

test("the migration in the source is the one this test exercises", () => {
  // The recipe is three statements and two pragmas, and dropping any one of them
  // is silent here but fatal in the field. Assert the source still contains them.
  const migration = source.slice(source.indexOf("if (migratable) {"));
  for (const required of [
    "PRAGMA foreign_keys=OFF",
    "PRAGMA legacy_alter_table=ON",
    "ALTER TABLE api_keys RENAME TO api_keys_v6;",
    "pragma_foreign_key_check",
    "PRAGMA legacy_alter_table=OFF",
    "PRAGMA foreign_keys=ON",
  ]) {
    assert.ok(migration.includes(required), `the migration must still run ${required}`);
  }
  assert.ok(migration.indexOf("DROP TABLE api_keys_v6;") < migration.indexOf("kIMPAPIKeysIndexDDL"),
    "the renamed table keeps its index, so it must be dropped before the new index is created");
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
