#import "api-key-store.h"

#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <sqlite3.h>

#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <math.h>
#import <stdint.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

NSErrorDomain const IMPAPIKeyStoreErrorDomain = @"io.github.mglaeser.imessage-proxy.api-key-store";

IMPAPIKeyScope const IMPAPIKeyScopeMessagesRead = @"messages:read";
IMPAPIKeyScope const IMPAPIKeyScopeMessagesSend = @"messages:send";
IMPAPIKeyScope const IMPAPIKeyScopeAdmin = @"admin";

NSString *const IMPAPIKeyCreationRecordKey = @"record";
NSString *const IMPAPIKeyCreationTokenKey = @"key";

static const int kIMPApplicationID = 0x494d504b; // "IMPK"
static const int kIMPSchemaVersion = 7;
static const NSUInteger kIMPMinimumSenderIdentifierLength = 2;
static const NSUInteger kIMPMaximumSenderIdentifierLength = 8;
// SHA-256 of the ordered non-internal sqlite_master object signature; update only
// with a schema bump. tests/test-schema-fingerprint.mjs recomputes this from the
// DDL in this file and fails if the two disagree, because a stale value here
// would refuse to open every database in the field.
static NSString *const kIMPSchemaFingerprint = @"3d46edc160c5e89de3959aad521c54a7d152ba162d0d9dc5257e0552f0f90565";

// Every message a non-admin key sends carries this key's identifier, so it must
// be present, and two keys must never be confusable for one another in a
// received message - hence NOT NULL and UNIQUE, enforced by the database rather
// than only by the code that writes to it. Roman letters only: the identifier is
// appended to real messages, and anything else invites an encoding surprise on
// the SMS transport.
// The exact column list IMPRecordFromStatement expects, in order. Written once
// so a column cannot be added to one statement and forgotten in another.
// Columns in IMP_API_KEY_COLUMNS. Anything selected after them starts here, so a
// column added to the projection must be counted here in the same edit.
static const int kIMPAPIKeyColumnCount = 10;

#define IMP_API_KEY_COLUMNS                                                                                            \
    "uuid,name,key_prefix,scopes,sender_identifier,sender_identifier_assigned,created_at,expires_at,"                  \
    "revoked_at,last_used_at"

static const char *const kIMPAPIKeysDDL =
    "CREATE TABLE api_keys ("
    "uuid TEXT PRIMARY KEY CHECK(length(uuid)=36),"
    "name TEXT NOT NULL CHECK(length(CAST(name AS BLOB)) BETWEEN 1 AND 80),"
    "key_prefix TEXT NOT NULL UNIQUE CHECK(length(key_prefix)=12),"
    "key_hash BLOB NOT NULL UNIQUE CHECK(length(key_hash)=32),"
    "scopes TEXT NOT NULL CHECK(scopes IN ("
    "'messages:read','messages:send','admin',"
    "'messages:read,messages:send','messages:read,admin',"
    "'messages:send,admin','messages:read,messages:send,admin')) ,"
    "sender_identifier TEXT NOT NULL UNIQUE CHECK("
    "length(sender_identifier) BETWEEN 2 AND 8 AND NOT sender_identifier GLOB '*[^a-z]*'),"
    "sender_identifier_assigned INTEGER NOT NULL CHECK(sender_identifier_assigned IN (0,1)),"
    "created_at INTEGER NOT NULL CHECK(created_at > 0),"
    "expires_at INTEGER CHECK(expires_at IS NULL OR expires_at > created_at),"
    "revoked_at INTEGER CHECK(revoked_at IS NULL OR revoked_at >= created_at),"
    "last_used_at INTEGER CHECK(last_used_at IS NULL OR last_used_at >= created_at)"
    ");";
static const char *const kIMPAPIKeysIndexDDL = "CREATE INDEX api_keys_active_idx ON api_keys(revoked_at, expires_at);";

// The fingerprint above is a hash of the exact CREATE text SQLite stores, so any
// edit here must be reflected there or the store refuses to open.
static const char *const kIMPAuditRecordsDDL =
    "CREATE TABLE audit_records ("
    "request_uuid TEXT NOT NULL CHECK(length(request_uuid)=36),"
    "key_uuid TEXT REFERENCES api_keys(uuid) ON DELETE SET NULL,"
    "target_key_uuid TEXT CHECK(target_key_uuid IS NULL OR length(target_key_uuid)=36),"
    "source TEXT NOT NULL CHECK(length(source) BETWEEN 1 AND 64),"
    "action TEXT NOT NULL CHECK(action IN ("
    "'request.invalid','request.rate_limited','auth.unavailable','auth.rate_limited',"
    "'auth.reject','origin.reject','route.not_found','status.read','chats.list','chats.read','background.read',"
    "'messages.history','scheduled.list','statistics.read','messages.send','keys.list',"
    "'keys.read','keys.create','keys.revoke','audit.list','targets.read','targets.replace',"
    "'server.overloaded')) ,"
    "phase TEXT NOT NULL CHECK(phase IN ('attempted','final')) ,"
    "status INTEGER CHECK(status IS NULL OR status BETWEEN 100 AND 599),"
    "duration_ms INTEGER CHECK(duration_ms IS NULL OR duration_ms>=0),"
    "created_at INTEGER NOT NULL CHECK(created_at>0),"
    "PRIMARY KEY(request_uuid,phase),"
    "CHECK((phase='attempted' AND status IS NULL AND duration_ms IS NULL) OR "
    "(phase='final' AND status IS NOT NULL AND duration_ms IS NOT NULL))"
    ");";
static const char *const kIMPAuditIndexesDDL =
    "CREATE INDEX audit_created_idx ON audit_records(created_at DESC);"
    "CREATE INDEX audit_key_idx ON audit_records(key_uuid,created_at DESC);"
    "CREATE INDEX audit_target_key_idx ON audit_records(target_key_uuid,created_at DESC);";
static const NSUInteger kIMPRawKeyLength = 32;
static const NSUInteger kIMPRequestHashLength = 32;
static const NSUInteger kIMPMaximumNameBytes = 80;
static const NSUInteger kIMPMaximumIdempotencyKeyBytes = 128;
static const NSUInteger kIMPMaximumStoredResponseBytes = 1024 * 1024;
static const NSUInteger kIMPMaximumAPIKeys = 1000;
static const NSUInteger kIMPMaximumAuditRows = 100000;
static const NSUInteger kIMPMaximumIdempotencyRows = 100000;
static const int kIMPBusyTimeoutMilliseconds = 5000;
static const NSTimeInterval kIMPLastUsedWriteInterval = 5.0 * 60.0;

@interface IMPAPIKeyRecord ()
@property (nonatomic, copy, readwrite) NSString *uuid;
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSString *keyPrefix;
@property (nonatomic, copy, readwrite) NSArray<IMPAPIKeyScope> *scopes;
@property (nonatomic, copy, readwrite) NSString *senderIdentifier;
@property (nonatomic, readwrite) BOOL senderIdentifierAssigned;
@property (nonatomic, copy, readwrite) NSDate *createdAt;
@property (nonatomic, copy, readwrite, nullable) NSDate *expiresAt;
@property (nonatomic, copy, readwrite, nullable) NSDate *revokedAt;
@property (nonatomic, copy, readwrite, nullable) NSDate *lastUsedAt;

- (instancetype)initWithUUID:(NSString *)uuid
                        name:(NSString *)name
                   keyPrefix:(NSString *)keyPrefix
                      scopes:(NSArray<IMPAPIKeyScope> *)scopes
            senderIdentifier:(NSString *)senderIdentifier
    senderIdentifierAssigned:(BOOL)senderIdentifierAssigned
                   createdAt:(NSDate *)createdAt
                   expiresAt:(nullable NSDate *)expiresAt
                   revokedAt:(nullable NSDate *)revokedAt
                  lastUsedAt:(nullable NSDate *)lastUsedAt;
@end

@interface IMPIdempotencyRecord ()
@property (nonatomic, copy, readwrite) NSString *principalUUID;
@property (nonatomic, copy, readwrite) NSString *key;
@property (nonatomic, copy, readwrite) NSString *operationUUID;
@property (nonatomic, readwrite) IMPIdempotencyState state;
@property (nonatomic, readwrite) IMPIdempotencyDisposition disposition;
@property (nonatomic, strong, readwrite, nullable) NSNumber *responseStatus;
@property (nonatomic, copy, readwrite, nullable) NSData *responseBody;
@property (nonatomic, copy, readwrite) NSDate *createdAt;
@property (nonatomic, copy, readwrite) NSDate *updatedAt;

- (instancetype)initWithPrincipalUUID:(NSString *)principalUUID
                                  key:(NSString *)key
                        operationUUID:(NSString *)operationUUID
                                state:(IMPIdempotencyState)state
                          disposition:(IMPIdempotencyDisposition)disposition
                       responseStatus:(nullable NSNumber *)responseStatus
                         responseBody:(nullable NSData *)responseBody
                            createdAt:(NSDate *)createdAt
                            updatedAt:(NSDate *)updatedAt;
@end

@interface IMPAuditRecord ()
@property (nonatomic, copy, readwrite) NSString *requestUUID;
@property (nonatomic, copy, readwrite, nullable) NSString *keyUUID;
@property (nonatomic, copy, readwrite, nullable) NSString *targetKeyUUID;
@property (nonatomic, copy, readwrite) NSString *source;
@property (nonatomic, copy, readwrite) NSString *action;
@property (nonatomic, readwrite) IMPAuditPhase phase;
@property (nonatomic, strong, readwrite, nullable) NSNumber *status;
@property (nonatomic, strong, readwrite, nullable) NSNumber *durationMilliseconds;
@property (nonatomic, copy, readwrite) NSDate *createdAt;

- (instancetype)initWithRequestUUID:(NSString *)requestUUID
                            keyUUID:(nullable NSString *)keyUUID
                      targetKeyUUID:(nullable NSString *)targetKeyUUID
                             source:(NSString *)source
                             action:(NSString *)action
                              phase:(IMPAuditPhase)phase
                             status:(nullable NSNumber *)status
               durationMilliseconds:(nullable NSNumber *)durationMilliseconds
                          createdAt:(NSDate *)createdAt;
@end

@interface IMPAPIKeyStore () {
    sqlite3 *_database;
    NSLock *_lock;
    NSString *_path;
}
- (BOOL)configureAndValidateDatabase:(NSError **)error;
- (BOOL)verifySchema:(NSError **)error;
- (BOOL)validateNoActiveAdminLockedAtDate:(NSDate *)date error:(NSError **)error;
- (BOOL)ensureKeyCapacityLockedAtDate:(NSDate *)date pruneIfNeeded:(BOOL)pruneIfNeeded error:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)createKeyLockedNamed:(NSString *)name
                                                         scopes:(NSArray<IMPAPIKeyScope> *)scopes
                                                      expiresAt:(nullable NSDate *)expiresAt
                                               senderIdentifier:(NSString *)senderIdentifier
                                             identifierAssigned:(BOOL)identifierAssigned
                                                          error:(NSError **)error;
- (nullable NSString *)nextSenderIdentifier:(NSError **)error;
- (nullable IMPAPIKeyRecord *)recordLockedForUUID:(NSString *)uuid error:(NSError **)error;
@end

static void IMPSetError(NSError **error, IMPAPIKeyStoreErrorCode code, NSString *message) {
    if (error == NULL) {
        return;
    }
    *error = [NSError errorWithDomain:IMPAPIKeyStoreErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey: message}];
}

static IMPAPIKeyStoreErrorCode IMPErrorCodeForSQLiteResult(int result) {
    int primary = result & 0xff;
    if (primary == SQLITE_BUSY || primary == SQLITE_LOCKED) {
        return IMPAPIKeyStoreErrorDatabaseBusy;
    }
    if (primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB) {
        return IMPAPIKeyStoreErrorDatabaseCorrupt;
    }
    return IMPAPIKeyStoreErrorDatabaseUnavailable;
}

static BOOL IMPSetSQLiteError(NSError **error, int result) {
    IMPAPIKeyStoreErrorCode code = IMPErrorCodeForSQLiteResult(result);
    NSString *message = code == IMPAPIKeyStoreErrorDatabaseBusy ? @"The API key database is busy."
                                                                : (code == IMPAPIKeyStoreErrorDatabaseCorrupt
                                                                       ? @"The API key database is corrupt or invalid."
                                                                       : @"The API key database operation failed.");
    IMPSetError(error, code, message);
    return NO;
}

static BOOL IMPExecute(sqlite3 *database, const char *sql, NSError **error) {
    int result = sqlite3_exec(database, sql, NULL, NULL, NULL);
    if (result != SQLITE_OK) {
        return IMPSetSQLiteError(error, result);
    }
    return YES;
}

static BOOL IMPPrepare(sqlite3 *database, const char *sql, sqlite3_stmt **statement, NSError **error) {
    int result = sqlite3_prepare_v2(database, sql, -1, statement, NULL);
    if (result != SQLITE_OK) {
        if (*statement != NULL) {
            sqlite3_finalize(*statement);
            *statement = NULL;
        }
        return IMPSetSQLiteError(error, result);
    }
    return YES;
}

static BOOL IMPBindText(sqlite3_stmt *statement, int index, NSString *value, NSError **error) {
    NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (utf8 == nil || utf8.length > INT_MAX) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"A text value is invalid.");
        return NO;
    }
    int result = sqlite3_bind_text(statement, index, utf8.bytes, (int)utf8.length, SQLITE_TRANSIENT);
    return result == SQLITE_OK ? YES : IMPSetSQLiteError(error, result);
}

static BOOL IMPBindData(sqlite3_stmt *statement, int index, NSData *value, NSError **error) {
    if (value.length > INT_MAX) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"A binary value is too large.");
        return NO;
    }
    int result = sqlite3_bind_blob(statement, index, value.bytes, (int)value.length, SQLITE_TRANSIENT);
    return result == SQLITE_OK ? YES : IMPSetSQLiteError(error, result);
}

static BOOL IMPBindInteger(sqlite3_stmt *statement, int index, sqlite3_int64 value, NSError **error) {
    int result = sqlite3_bind_int64(statement, index, value);
    return result == SQLITE_OK ? YES : IMPSetSQLiteError(error, result);
}

static BOOL IMPBindNull(sqlite3_stmt *statement, int index, NSError **error) {
    int result = sqlite3_bind_null(statement, index);
    return result == SQLITE_OK ? YES : IMPSetSQLiteError(error, result);
}

static NSString *_Nullable IMPColumnString(sqlite3_stmt *statement, int column) {
    if (sqlite3_column_type(statement, column) == SQLITE_NULL) {
        return nil;
    }
    const void *bytes = sqlite3_column_text(statement, column);
    int length = sqlite3_column_bytes(statement, column);
    if (bytes == NULL || length < 0) {
        return nil;
    }
    return [[NSString alloc] initWithBytes:bytes length:(NSUInteger)length encoding:NSUTF8StringEncoding];
}

static NSData *_Nullable IMPColumnData(sqlite3_stmt *statement, int column) {
    if (sqlite3_column_type(statement, column) == SQLITE_NULL) {
        return nil;
    }
    const void *bytes = sqlite3_column_blob(statement, column);
    int length = sqlite3_column_bytes(statement, column);
    if (length < 0 || (bytes == NULL && length != 0)) {
        return nil;
    }
    const void *safeBytes = bytes != NULL ? bytes : "";
    return [NSData dataWithBytes:safeBytes length:(NSUInteger)length];
}

static sqlite3_int64 IMPMillisecondsForDate(NSDate *date) {
    return (sqlite3_int64)llround(date.timeIntervalSince1970 * 1000.0);
}

static NSDate *IMPDateForMilliseconds(sqlite3_int64 milliseconds) {
    return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)milliseconds / 1000.0];
}

static NSDate *_Nullable IMPNullableDateColumn(sqlite3_stmt *statement, int column) {
    if (sqlite3_column_type(statement, column) == SQLITE_NULL) {
        return nil;
    }
    return IMPDateForMilliseconds(sqlite3_column_int64(statement, column));
}

static BOOL IMPConstantTimeEqual(NSData *left, NSData *right) {
    if (left.length != right.length) {
        return NO;
    }
    const volatile uint8_t *leftBytes = left.bytes;
    const volatile uint8_t *rightBytes = right.bytes;
    uint8_t difference = 0;
    for (NSUInteger index = 0; index < left.length; index++) {
        difference |= leftBytes[index] ^ rightBytes[index];
    }
    return difference == 0;
}

static BOOL IMPNullableObjectsEqual(id _Nullable left, id _Nullable right) {
    if (left == nil || right == nil) {
        return left == right;
    }
    return [left isEqual:right];
}

static void IMPSecureZero(NSMutableData *data) {
    volatile uint8_t *bytes = data.mutableBytes;
    for (NSUInteger index = 0; index < data.length; index++) {
        bytes[index] = 0;
    }
}

static NSData *IMPSHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);

    const unsigned char *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        CC_LONG chunk = (CC_LONG)MIN(remaining, (NSUInteger)UINT32_MAX);
        CC_SHA256_Update(&context, bytes, chunk);
        bytes += chunk;
        remaining -= chunk;
    }
    CC_SHA256_Final(digest, &context);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}

static BOOL IMPVerifySchemaFingerprint(sqlite3 *database, NSError **error) {
    sqlite3_stmt *statement = NULL;
    if (!IMPPrepare(database,
                    "SELECT type,name,tbl_name,sql FROM sqlite_master "
                    "WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name",
                    &statement, error))
        return NO;
    NSMutableString *signature = [NSMutableString string];
    BOOL ok = YES;
    int result = SQLITE_ROW;
    while ((result = sqlite3_step(statement)) == SQLITE_ROW) {
        NSString *type = IMPColumnString(statement, 0);
        NSString *name = IMPColumnString(statement, 1);
        NSString *tableName = IMPColumnString(statement, 2);
        NSString *sql = IMPColumnString(statement, 3);
        if (type == nil || name == nil || tableName == nil || sql == nil) {
            ok = NO;
            break;
        }
        [signature appendFormat:@"%@\t%@\t%@\t%@\n", type, name, tableName, sql];
    }
    if (ok && result != SQLITE_DONE)
        ok = IMPSetSQLiteError(error, result);
    int finalResult = sqlite3_finalize(statement);
    if (ok && finalResult != SQLITE_OK)
        ok = IMPSetSQLiteError(error, finalResult);
    if (!ok) {
        if (error != NULL && *error == nil) {
            IMPSetError(error, IMPAPIKeyStoreErrorSchemaMismatch, @"The API key database schema objects are invalid.");
        }
        return NO;
    }
    NSData *signatureData = [signature dataUsingEncoding:NSUTF8StringEncoding];
    NSData *digest = IMPSHA256(signatureData);
    NSMutableString *hex = [NSMutableString stringWithCapacity:digest.length * 2];
    const uint8_t *bytes = digest.bytes;
    for (NSUInteger index = 0; index < digest.length; index++) {
        [hex appendFormat:@"%02x", bytes[index]];
    }
    if (![hex isEqualToString:kIMPSchemaFingerprint]) {
        IMPSetError(error, IMPAPIKeyStoreErrorSchemaMismatch,
                    @"The API key database schema does not match this release.");
        return NO;
    }
    return YES;
}

static NSString *IMPBase64URLEncode(NSData *data) {
    NSString *encoded = [data base64EncodedStringWithOptions:0];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [encoded stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

static NSData *_Nullable IMPDecodeToken(NSString *token) {
    if (![token isKindOfClass:NSString.class] || ![token hasPrefix:@"imp_"] || token.length != 47) {
        return nil;
    }

    NSString *payload = [token substringFromIndex:4];
    for (NSUInteger index = 0; index < payload.length; index++) {
        unichar character = [payload characterAtIndex:index];
        BOOL valid = (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') ||
                     (character >= '0' && character <= '9') || character == '-' || character == '_';
        if (!valid) {
            return nil;
        }
    }

    NSString *base64 = [payload stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    base64 = [base64 stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    base64 = [base64 stringByAppendingString:@"="];
    NSData *raw = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    if (raw.length != kIMPRawKeyLength || ![IMPBase64URLEncode(raw) isEqualToString:payload]) {
        return nil;
    }
    return raw;
}

static NSArray<IMPAPIKeyScope> *_Nullable IMPNormalizeScopes(NSArray<IMPAPIKeyScope> *scopes, NSError **error) {
    if (![scopes isKindOfClass:NSArray.class] || scopes.count == 0) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"At least one scope is required.");
        return nil;
    }

    NSSet<NSString *> *allowed =
        [NSSet setWithObjects:IMPAPIKeyScopeMessagesRead, IMPAPIKeyScopeMessagesSend, IMPAPIKeyScopeAdmin, nil];
    NSMutableSet<NSString *> *requested = [NSMutableSet set];
    for (id value in scopes) {
        if (![value isKindOfClass:NSString.class] || ![allowed containsObject:value]) {
            IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"An API key scope is invalid.");
            return nil;
        }
        [requested addObject:value];
    }

    NSMutableArray<IMPAPIKeyScope> *normalized = [NSMutableArray array];
    for (IMPAPIKeyScope scope in @[IMPAPIKeyScopeMessagesRead, IMPAPIKeyScopeMessagesSend, IMPAPIKeyScopeAdmin]) {
        if ([requested containsObject:scope]) {
            [normalized addObject:scope];
        }
    }
    return normalized;
}

static BOOL IMPValidateName(NSString *name, NSString **normalizedName, NSError **error) {
    if (![name isKindOfClass:NSString.class]) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The API key name is invalid.");
        return NO;
    }
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSData *utf8 = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
    if (trimmed.length == 0 || utf8 == nil || utf8.length > kIMPMaximumNameBytes ||
        [trimmed rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The API key name is invalid.");
        return NO;
    }
    if (normalizedName != NULL) {
        *normalizedName = trimmed;
    }
    return YES;
}

static BOOL IMPValidateBootstrapArguments(NSString *name, NSUInteger expiresDays, NSString **normalizedName,
                                          NSError **error) {
    if (expiresDays < 1 || expiresDays > 365) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The API key expiry is invalid.");
        return NO;
    }
    return IMPValidateName(name, normalizedName, error);
}

static BOOL IMPValidateUUID(NSString *uuid, NSError **error) {
    if (![uuid isKindOfClass:NSString.class]) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"An API key UUID is invalid.");
        return NO;
    }
    NSUUID *parsed = [[NSUUID alloc] initWithUUIDString:uuid];
    if (parsed == nil) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"An API key UUID is invalid.");
        return NO;
    }
    return YES;
}

static NSString *IMPNormalizedUUID(NSString *uuid) {
    return [[[[NSUUID alloc] initWithUUIDString:uuid] UUIDString] lowercaseString];
}

static BOOL IMPValidateIdempotencyKey(NSString *key, NSError **error) {
    if (![key isKindOfClass:NSString.class]) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The idempotency key is invalid.");
        return NO;
    }
    NSData *utf8 = [key dataUsingEncoding:NSUTF8StringEncoding];
    if (utf8 == nil || utf8.length < 8 || utf8.length > kIMPMaximumIdempotencyKeyBytes ||
        [key rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The idempotency key is invalid.");
        return NO;
    }
    NSCharacterSet *invalid = [[NSCharacterSet
        characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~-"]
        invertedSet];
    if ([key rangeOfCharacterFromSet:invalid].location != NSNotFound) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The idempotency key is invalid.");
        return NO;
    }
    return YES;
}

static BOOL IMPValidateRequestHash(NSData *requestHash, NSError **error) {
    if (![requestHash isKindOfClass:NSData.class] || requestHash.length != kIMPRequestHashLength) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The request hash must be 32 bytes.");
        return NO;
    }
    return YES;
}

static NSString *IMPStateString(IMPIdempotencyState state) {
    switch (state) {
    case IMPIdempotencyStateInProgress:
        return @"in_progress";
    case IMPIdempotencyStateSucceeded:
        return @"succeeded";
    case IMPIdempotencyStateAmbiguous:
        return @"ambiguous";
    case IMPIdempotencyStateFailed:
        return @"failed";
    }
    return @"";
}

static IMPIdempotencyState IMPStateFromString(NSString *state) {
    if ([state isEqualToString:@"in_progress"]) {
        return IMPIdempotencyStateInProgress;
    }
    if ([state isEqualToString:@"succeeded"]) {
        return IMPIdempotencyStateSucceeded;
    }
    if ([state isEqualToString:@"ambiguous"]) {
        return IMPIdempotencyStateAmbiguous;
    }
    if ([state isEqualToString:@"failed"]) {
        return IMPIdempotencyStateFailed;
    }
    return 0;
}

static NSString *IMPAuditPhaseString(IMPAuditPhase phase) {
    switch (phase) {
    case IMPAuditPhaseAttempted:
        return @"attempted";
    case IMPAuditPhaseFinal:
        return @"final";
    }
    return @"";
}

static IMPAuditPhase IMPAuditPhaseFromString(NSString *phase) {
    if ([phase isEqualToString:@"attempted"]) {
        return IMPAuditPhaseAttempted;
    }
    if ([phase isEqualToString:@"final"]) {
        return IMPAuditPhaseFinal;
    }
    return 0;
}

// Roman letters only, lower case, 2 to 8 of them. This value is appended to real
// messages on both transports, so anything outside a-z risks an encoding
// surprise on SMS, and anything long enough to matter eats the sender's text.
// Case is normalized rather than rejected: "KLE" and "kle" naming different keys
// would make the identifier useless for telling them apart.
static BOOL IMPValidateSenderIdentifier(NSString *value, NSString **normalized, NSError **error) {
    NSString *candidate = [value isKindOfClass:NSString.class] ? value.lowercaseString : nil;
    NSCharacterSet *notRoman =
        [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz"] invertedSet];
    if (candidate == nil || candidate.length < kIMPMinimumSenderIdentifierLength ||
        candidate.length > kIMPMaximumSenderIdentifierLength ||
        [candidate rangeOfCharacterFromSet:notRoman].location != NSNotFound) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The sender identifier must be 2 to 8 roman letters.");
        return NO;
    }
    if (normalized != NULL) {
        *normalized = candidate;
    }
    return YES;
}

static BOOL IMPValidateAuditAction(NSString *action, NSError **error) {
    if (![action isKindOfClass:NSString.class]) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The audit action is invalid.");
        return NO;
    }
    NSSet<NSString *> *allowed = [NSSet setWithArray:@[
        @"request.invalid", @"request.rate_limited", @"auth.unavailable", @"auth.rate_limited",
        @"auth.reject",     @"origin.reject",        @"route.not_found",  @"status.read",
        @"chats.list",      @"chats.read",           @"background.read",  @"messages.history",
        @"scheduled.list",  @"statistics.read",      @"messages.send",    @"keys.list",
        @"keys.read",       @"keys.create",          @"keys.revoke",      @"audit.list",
        @"targets.read",    @"targets.replace",      @"server.overloaded"
    ]];
    if (![allowed containsObject:action]) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The audit action is invalid.");
        return NO;
    }
    return YES;
}

static BOOL IMPValidateAuditSource(NSString *source, NSError **error) {
    if (![source isKindOfClass:NSString.class] || source.length == 0 || source.length > 64) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The audit source is invalid.");
        return NO;
    }
    if ([source isEqualToString:@"local"] || [source isEqualToString:@"invalid"])
        return YES;
    NSCharacterSet *invalid =
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF:."] invertedSet];
    if ([source rangeOfCharacterFromSet:invalid].location != NSNotFound) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The audit source is invalid.");
        return NO;
    }
    return YES;
}

static BOOL IMPNumberIsIntegerInRange(NSNumber *number, long long minimum, long long maximum) {
    if (![number isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) {
        return NO;
    }
    // Preserve NSDecimalNumber precision and the exact signed 64-bit boundaries.
    NSDecimal value = number.decimalValue;
    if (NSDecimalIsNotANumber(&value)) {
        return NO;
    }
    NSDecimal minimumValue = [@(minimum) decimalValue];
    NSDecimal maximumValue = [@(maximum) decimalValue];
    if (NSDecimalCompare(&value, &minimumValue) == NSOrderedAscending ||
        NSDecimalCompare(&value, &maximumValue) == NSOrderedDescending) {
        return NO;
    }
    NSDecimal roundedValue;
    NSDecimalRound(&roundedValue, &value, 0, NSRoundPlain);
    return NSDecimalCompare(&value, &roundedValue) == NSOrderedSame;
}

static BOOL IMPBegin(sqlite3 *database, NSError **error) { return IMPExecute(database, "BEGIN IMMEDIATE", error); }

static BOOL IMPCommit(sqlite3 *database, NSError **error) { return IMPExecute(database, "COMMIT", error); }

static void IMPRollback(sqlite3 *database) { sqlite3_exec(database, "ROLLBACK", NULL, NULL, NULL); }

static BOOL IMPScalarInteger(sqlite3 *database, const char *sql, sqlite3_int64 *value, NSError **error) {
    sqlite3_stmt *statement = NULL;
    if (!IMPPrepare(database, sql, &statement, error)) {
        return NO;
    }
    int result = sqlite3_step(statement);
    if (result == SQLITE_ROW) {
        *value = sqlite3_column_int64(statement, 0);
    }
    int finalResult = sqlite3_finalize(statement);
    if (result != SQLITE_ROW) {
        return IMPSetSQLiteError(error, result);
    }
    if (finalResult != SQLITE_OK) {
        return IMPSetSQLiteError(error, finalResult);
    }
    return YES;
}

static BOOL IMPVerifyPrivateDirectory(NSString *path, BOOL createIfMissing, NSError **error) {
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        if (errno != ENOENT || !createIfMissing) {
            IMPSetError(error, IMPAPIKeyStoreErrorDatabaseUnavailable,
                        @"The API key database directory is unavailable.");
            return NO;
        }
        NSError *createError = nil;
        NSDictionary *attributes = @{NSFilePosixPermissions: @0700};
        if (![NSFileManager.defaultManager createDirectoryAtPath:path
                                     withIntermediateDirectories:NO
                                                      attributes:attributes
                                                           error:&createError] ||
            lstat(path.fileSystemRepresentation, &info) != 0) {
            IMPSetError(error, IMPAPIKeyStoreErrorDatabaseUnavailable,
                        @"The API key database directory could not be created.");
            return NO;
        }
    }

    if (!S_ISDIR(info.st_mode) || info.st_uid != geteuid() || (info.st_mode & 0077) != 0) {
        IMPSetError(error, IMPAPIKeyStoreErrorDatabaseUnavailable,
                    @"The API key database directory is not private and user-owned.");
        return NO;
    }
    return YES;
}

static BOOL IMPPreflightDatabaseFile(NSString *path, struct stat *openedInfo, NSError **error) {
    int descriptor = open(path.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR);
    if (descriptor < 0) {
        IMPSetError(error, IMPAPIKeyStoreErrorDatabaseUnavailable,
                    @"The API key database file could not be opened securely.");
        return NO;
    }

    BOOL valid = fstat(descriptor, openedInfo) == 0 && S_ISREG(openedInfo->st_mode) &&
                 openedInfo->st_uid == geteuid() && (openedInfo->st_mode & 0077) == 0;
    if (valid && fchmod(descriptor, S_IRUSR | S_IWUSR) != 0) {
        valid = NO;
    }
    close(descriptor);
    if (!valid) {
        IMPSetError(error, IMPAPIKeyStoreErrorDatabaseUnavailable,
                    @"The API key database file is not private, regular, and user-owned.");
    }
    return valid;
}

static BOOL IMPPreflightSidecars(NSString *path, NSError **error) {
    for (NSString *suffix in @[@"-wal", @"-shm"]) {
        NSString *sidecar = [path stringByAppendingString:suffix];
        struct stat info;
        if (lstat(sidecar.fileSystemRepresentation, &info) != 0) {
            if (errno == ENOENT) {
                continue;
            }
            IMPSetError(error, IMPAPIKeyStoreErrorDatabaseUnavailable,
                        @"An API key database sidecar could not be inspected.");
            return NO;
        }
        if (!S_ISREG(info.st_mode) || info.st_uid != geteuid() || (info.st_mode & 0077) != 0) {
            IMPSetError(error, IMPAPIKeyStoreErrorDatabaseUnavailable,
                        @"An API key database sidecar is not private, regular, and user-owned.");
            return NO;
        }
    }
    return YES;
}

static BOOL IMPVerifyUnchangedDatabaseFile(NSString *path, const struct stat *openedInfo, NSError **error) {
    struct stat current;
    if (lstat(path.fileSystemRepresentation, &current) != 0 || !S_ISREG(current.st_mode) ||
        current.st_uid != geteuid() || (current.st_mode & 0077) != 0 || current.st_dev != openedInfo->st_dev ||
        current.st_ino != openedInfo->st_ino) {
        IMPSetError(error, IMPAPIKeyStoreErrorDatabaseUnavailable,
                    @"The API key database file changed during secure open.");
        return NO;
    }
    return YES;
}

static void IMPTightenSidecarModes(NSString *path) {
    for (NSString *suffix in @[@"-wal", @"-shm"]) {
        NSString *sidecar = [path stringByAppendingString:suffix];
        struct stat info;
        if (lstat(sidecar.fileSystemRepresentation, &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == geteuid()) {
            chmod(sidecar.fileSystemRepresentation, S_IRUSR | S_IWUSR);
        }
    }
}

static IMPAPIKeyRecord *_Nullable IMPRecordFromStatement(sqlite3_stmt *statement, int firstColumn) {
    NSString *uuid = IMPColumnString(statement, firstColumn);
    NSString *name = IMPColumnString(statement, firstColumn + 1);
    NSString *keyPrefix = IMPColumnString(statement, firstColumn + 2);
    NSString *scopeString = IMPColumnString(statement, firstColumn + 3);
    NSString *senderIdentifier = IMPColumnString(statement, firstColumn + 4);
    NSString *normalizedName = nil;
    if (uuid == nil || name == nil || keyPrefix == nil || scopeString == nil ||
        !IMPValidateSenderIdentifier(senderIdentifier, NULL, NULL) ||
        sqlite3_column_type(statement, firstColumn + 6) == SQLITE_NULL ||
        !IMPValidateName(name, &normalizedName, NULL) || ![normalizedName isEqualToString:name]) {
        return nil;
    }
    NSArray<IMPAPIKeyScope> *scopes = [scopeString componentsSeparatedByString:@","];
    return
        [[IMPAPIKeyRecord alloc] initWithUUID:uuid
                                         name:name
                                    keyPrefix:keyPrefix
                                       scopes:scopes
                             senderIdentifier:senderIdentifier
                     senderIdentifierAssigned:sqlite3_column_int64(statement, firstColumn + 5) != 0
                                    createdAt:IMPDateForMilliseconds(sqlite3_column_int64(statement, firstColumn + 6))
                                    expiresAt:IMPNullableDateColumn(statement, firstColumn + 7)
                                    revokedAt:IMPNullableDateColumn(statement, firstColumn + 8)
                                   lastUsedAt:IMPNullableDateColumn(statement, firstColumn + 9)];
}

@implementation IMPAPIKeyRecord

- (instancetype)initWithUUID:(NSString *)uuid
                        name:(NSString *)name
                   keyPrefix:(NSString *)keyPrefix
                      scopes:(NSArray<IMPAPIKeyScope> *)scopes
            senderIdentifier:(NSString *)senderIdentifier
    senderIdentifierAssigned:(BOOL)senderIdentifierAssigned
                   createdAt:(NSDate *)createdAt
                   expiresAt:(NSDate *)expiresAt
                   revokedAt:(NSDate *)revokedAt
                  lastUsedAt:(NSDate *)lastUsedAt {
    self = [super init];
    if (self != nil) {
        _uuid = [uuid copy];
        _name = [name copy];
        _keyPrefix = [keyPrefix copy];
        _scopes = [scopes copy];
        _senderIdentifier = [senderIdentifier copy];
        _senderIdentifierAssigned = senderIdentifierAssigned;
        _createdAt = [createdAt copy];
        _expiresAt = [expiresAt copy];
        _revokedAt = [revokedAt copy];
        _lastUsedAt = [lastUsedAt copy];
    }
    return self;
}

- (BOOL)hasScope:(IMPAPIKeyScope)scope {
    if (![scope isKindOfClass:NSString.class] ||
        ![@[IMPAPIKeyScopeMessagesRead, IMPAPIKeyScopeMessagesSend, IMPAPIKeyScopeAdmin] containsObject:scope]) {
        return NO;
    }
    return [self.scopes containsObject:IMPAPIKeyScopeAdmin] || [self.scopes containsObject:scope];
}

@end

@implementation IMPIdempotencyRecord

- (instancetype)initWithPrincipalUUID:(NSString *)principalUUID
                                  key:(NSString *)key
                        operationUUID:(NSString *)operationUUID
                                state:(IMPIdempotencyState)state
                          disposition:(IMPIdempotencyDisposition)disposition
                       responseStatus:(NSNumber *)responseStatus
                         responseBody:(NSData *)responseBody
                            createdAt:(NSDate *)createdAt
                            updatedAt:(NSDate *)updatedAt {
    self = [super init];
    if (self != nil) {
        _principalUUID = [principalUUID copy];
        _key = [key copy];
        _operationUUID = [operationUUID copy];
        _state = state;
        _disposition = disposition;
        _responseStatus = responseStatus;
        _responseBody = [responseBody copy];
        _createdAt = [createdAt copy];
        _updatedAt = [updatedAt copy];
    }
    return self;
}

@end

@implementation IMPAuditRecord

- (instancetype)initWithRequestUUID:(NSString *)requestUUID
                            keyUUID:(NSString *)keyUUID
                      targetKeyUUID:(NSString *)targetKeyUUID
                             source:(NSString *)source
                             action:(NSString *)action
                              phase:(IMPAuditPhase)phase
                             status:(NSNumber *)status
               durationMilliseconds:(NSNumber *)durationMilliseconds
                          createdAt:(NSDate *)createdAt {
    self = [super init];
    if (self != nil) {
        _requestUUID = [requestUUID copy];
        _keyUUID = [keyUUID copy];
        _targetKeyUUID = [targetKeyUUID copy];
        _source = [source copy];
        _action = [action copy];
        _phase = phase;
        _status = status;
        _durationMilliseconds = durationMilliseconds;
        _createdAt = [createdAt copy];
    }
    return self;
}

@end

@implementation IMPAPIKeyStore

+ (NSData *)SHA256ForData:(NSData *)data {
    return IMPSHA256(data != nil ? data : [NSData data]);
}

- (nullable instancetype)initWithPath:(NSString *)path error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    if (![path isKindOfClass:NSString.class] || path.length == 0) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The API key database path is invalid.");
        return nil;
    }
    NSString *normalizedPath = path.stringByExpandingTildeInPath.stringByStandardizingPath;
    if (![normalizedPath isAbsolutePath] || [normalizedPath isEqualToString:@"/"]) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The API key database path must be absolute.");
        return nil;
    }
    NSString *parent = normalizedPath.stringByDeletingLastPathComponent;
    if (!IMPVerifyPrivateDirectory(parent, YES, error)) {
        return nil;
    }

    struct stat openedInfo;
    if (!IMPPreflightDatabaseFile(normalizedPath, &openedInfo, error) || !IMPPreflightSidecars(normalizedPath, error)) {
        return nil;
    }

    _lock = [[NSLock alloc] init];
    _lock.name = @"io.github.mglaeser.imessage-proxy.api-key-store";
    _path = [normalizedPath copy];

    int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX;
#ifdef SQLITE_OPEN_NOFOLLOW
    flags |= SQLITE_OPEN_NOFOLLOW;
#endif
    int result = sqlite3_open_v2(_path.fileSystemRepresentation, &_database, flags, NULL);
    if (result != SQLITE_OK) {
        if (_database != NULL) {
            sqlite3_close_v2(_database);
            _database = NULL;
        }
        IMPSetSQLiteError(error, result);
        return nil;
    }
    int configurationResult = sqlite3_extended_result_codes(_database, 1);
    if (configurationResult == SQLITE_OK) {
        configurationResult = sqlite3_busy_timeout(_database, kIMPBusyTimeoutMilliseconds);
    }
    if (configurationResult != SQLITE_OK) {
        sqlite3_close_v2(_database);
        _database = NULL;
        IMPSetSQLiteError(error, configurationResult);
        return nil;
    }

    if (!IMPVerifyUnchangedDatabaseFile(_path, &openedInfo, error) || ![self configureAndValidateDatabase:error]) {
        sqlite3_close_v2(_database);
        _database = NULL;
        return nil;
    }
    IMPTightenSidecarModes(_path);
    return self;
}

- (void)dealloc {
    [_lock lock];
    if (_database != NULL) {
        sqlite3_close_v2(_database);
        _database = NULL;
    }
    [_lock unlock];
}

- (BOOL)configureAndValidateDatabase:(NSError **)error {
    if (!IMPExecute(_database, "PRAGMA foreign_keys=ON", error) ||
        !IMPExecute(_database, "PRAGMA trusted_schema=OFF", error) ||
        !IMPExecute(_database, "PRAGMA secure_delete=ON", error)) {
        return NO;
    }
#ifdef SQLITE_DBCONFIG_DEFENSIVE
    int defensiveEnabled = 0;
    int configResult = sqlite3_db_config(_database, SQLITE_DBCONFIG_DEFENSIVE, 1, &defensiveEnabled);
    if (configResult != SQLITE_OK || defensiveEnabled != 1) {
        return IMPSetSQLiteError(error, configResult);
    }
#endif

    sqlite3_int64 applicationID = 0;
    sqlite3_int64 schemaVersion = 0;
    sqlite3_int64 userObjectCount = 0;
    if (!IMPScalarInteger(_database, "PRAGMA application_id", &applicationID, error) ||
        !IMPScalarInteger(_database, "PRAGMA user_version", &schemaVersion, error) ||
        !IMPScalarInteger(_database, "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
                          &userObjectCount, error)) {
        return NO;
    }

    BOOL fresh = applicationID == 0 && schemaVersion == 0 && userObjectCount == 0;
    BOOL current = applicationID == kIMPApplicationID && schemaVersion == kIMPSchemaVersion;
    // A schema this release does not recognise is refused rather than upgraded in
    // place. Carrying databases forward means maintaining one migration per
    // release forever, and a migration that produces a schema even one character
    // different from a fresh install refuses to open on every machine that ran
    // it. Reinstalling is the supported path; scripts/uninstall.sh --purge exists
    // for exactly this.
    if (!fresh && !current) {
        IMPSetError(error, IMPAPIKeyStoreErrorSchemaMismatch, @"The API key database schema is unsupported.");
        return NO;
    }

    sqlite3_stmt *walStatement = NULL;
    if (!IMPPrepare(_database, "PRAGMA journal_mode=WAL", &walStatement, error)) {
        return NO;
    }
    int walResult = sqlite3_step(walStatement);
    NSString *journalMode = walResult == SQLITE_ROW ? IMPColumnString(walStatement, 0) : nil;
    int walFinalizeResult = sqlite3_finalize(walStatement);
    if (walResult != SQLITE_ROW || walFinalizeResult != SQLITE_OK ||
        ![journalMode.lowercaseString isEqualToString:@"wal"]) {
        if (walResult != SQLITE_ROW) {
            return IMPSetSQLiteError(error, walResult);
        }
        if (walFinalizeResult != SQLITE_OK) {
            return IMPSetSQLiteError(error, walFinalizeResult);
        }
        IMPSetError(error, IMPAPIKeyStoreErrorDatabaseUnavailable, @"The API key database could not enable WAL mode.");
        return NO;
    }
    if (!IMPExecute(_database, "PRAGMA synchronous=FULL", error) ||
        !IMPExecute(_database, "PRAGMA wal_autocheckpoint=1000", error)) {
        return NO;
    }

    if (fresh) {
        if (!IMPExecute(_database, "BEGIN EXCLUSIVE", error)) {
            return NO;
        }
        BOOL created = IMPExecute(_database, kIMPAPIKeysDDL, error);
        created = created && IMPExecute(_database, kIMPAPIKeysIndexDDL, error);
        created =
            created &&
            IMPExecute(_database,
                       "CREATE TABLE idempotency_records ("
                       "principal_uuid TEXT NOT NULL REFERENCES api_keys(uuid) ON DELETE RESTRICT,"
                       "idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 8 AND 128),"
                       "operation_uuid TEXT NOT NULL UNIQUE CHECK(length(operation_uuid)=36),"
                       "request_hash BLOB NOT NULL CHECK(length(request_hash)=32),"
                       "state TEXT NOT NULL CHECK(state IN ('in_progress','succeeded','ambiguous','failed')) ,"
                       "response_status INTEGER CHECK(response_status IS NULL OR response_status BETWEEN 100 AND 599),"
                       "response_body BLOB,"
                       "created_at INTEGER NOT NULL CHECK(created_at > 0),"
                       "updated_at INTEGER NOT NULL CHECK(updated_at >= created_at),"
                       "PRIMARY KEY(principal_uuid, idempotency_key),"
                       "CHECK((state='in_progress' AND response_status IS NULL AND response_body IS NULL) OR "
                       "(state!='in_progress' AND response_status IS NOT NULL AND response_body IS NOT NULL))"
                       ");"
                       "CREATE INDEX idempotency_updated_idx ON idempotency_records(updated_at);"
                       "PRAGMA application_id=1229803595;",
                       error);
        created = created && IMPExecute(_database, kIMPAuditRecordsDDL, error);
        created = created && IMPExecute(_database, kIMPAuditIndexesDDL, error);
        created = created && IMPExecute(_database, "PRAGMA user_version=7;", error);
        if (!created || !IMPCommit(_database, error)) {
            IMPRollback(_database);
            return NO;
        }
    }

    sqlite3_int64 configuredApplicationID = 0;
    sqlite3_int64 configuredSchemaVersion = 0;
    if (!IMPScalarInteger(_database, "PRAGMA application_id", &configuredApplicationID, error) ||
        !IMPScalarInteger(_database, "PRAGMA user_version", &configuredSchemaVersion, error)) {
        return NO;
    }
    if (configuredApplicationID != kIMPApplicationID || configuredSchemaVersion != kIMPSchemaVersion) {
        IMPSetError(error, IMPAPIKeyStoreErrorSchemaMismatch,
                    @"The API key database schema configuration did not complete.");
        return NO;
    }

    if (!IMPVerifySchemaFingerprint(_database, error) || ![self verifySchema:error]) {
        return NO;
    }
    sqlite3_int64 requiredIndexes = 0;
    if (!IMPScalarInteger(_database,
                          "SELECT count(*) FROM sqlite_master WHERE type='index' AND name IN ("
                          "'api_keys_active_idx','idempotency_updated_idx','audit_created_idx',"
                          "'audit_key_idx','audit_target_key_idx')",
                          &requiredIndexes, error) ||
        requiredIndexes != 5) {
        if (error != NULL && *error == nil) {
            IMPSetError(error, IMPAPIKeyStoreErrorSchemaMismatch, @"The API key database indexes are incomplete.");
        }
        return NO;
    }
    sqlite3_stmt *foreignKeyCheck = NULL;
    if (!IMPPrepare(_database, "PRAGMA foreign_key_check", &foreignKeyCheck, error))
        return NO;
    int foreignKeyResult = sqlite3_step(foreignKeyCheck);
    int foreignKeyFinalizeResult = sqlite3_finalize(foreignKeyCheck);
    if (foreignKeyResult != SQLITE_DONE || foreignKeyFinalizeResult != SQLITE_OK) {
        if (foreignKeyResult != SQLITE_DONE && foreignKeyResult != SQLITE_ROW) {
            return IMPSetSQLiteError(error, foreignKeyResult);
        }
        if (foreignKeyFinalizeResult != SQLITE_OK)
            return IMPSetSQLiteError(error, foreignKeyFinalizeResult);
        IMPSetError(error, IMPAPIKeyStoreErrorDatabaseCorrupt, @"The API key database contains invalid references.");
        return NO;
    }
    sqlite3_int64 foreignKeys = 0;
    if (!IMPScalarInteger(_database, "PRAGMA foreign_keys", &foreignKeys, error) || foreignKeys != 1) {
        if (error != NULL && *error == nil) {
            IMPSetError(error, IMPAPIKeyStoreErrorDatabaseUnavailable,
                        @"The API key database could not enable foreign keys.");
        }
        return NO;
    }
    return YES;
}

- (BOOL)verifySchema:(NSError **)error {
    const char *queries[] = {
        "SELECT " IMP_API_KEY_COLUMNS " "
        "FROM api_keys LIMIT 0",
        "SELECT principal_uuid,idempotency_key,operation_uuid,request_hash,state,response_status,"
        "response_body,created_at,updated_at FROM idempotency_records LIMIT 0",
        "SELECT request_uuid,key_uuid,target_key_uuid,source,action,phase,status,duration_ms,created_at "
        "FROM audit_records LIMIT 0",
    };
    for (NSUInteger index = 0; index < sizeof(queries) / sizeof(queries[0]); index++) {
        sqlite3_stmt *statement = NULL;
        int result = sqlite3_prepare_v2(_database, queries[index], -1, &statement, NULL);
        if (result != SQLITE_OK) {
            if (statement != NULL) {
                sqlite3_finalize(statement);
            }
            IMPSetError(error, IMPAPIKeyStoreErrorSchemaMismatch, @"The API key database schema is incomplete.");
            return NO;
        }
        result = sqlite3_step(statement);
        int finalResult = sqlite3_finalize(statement);
        if (result != SQLITE_DONE || finalResult != SQLITE_OK) {
            IMPSetError(error, IMPAPIKeyStoreErrorSchemaMismatch, @"The API key database schema is invalid.");
            return NO;
        }
    }
    return YES;
}

- (BOOL)validateNoActiveAdminLockedAtDate:(NSDate *)date error:(NSError **)error {
    sqlite3_stmt *statement = NULL;
    BOOL ok = IMPPrepare(_database,
                         "SELECT count(*) FROM api_keys WHERE revoked_at IS NULL "
                         "AND (expires_at IS NULL OR expires_at>?) "
                         "AND instr(','||scopes||',', ',admin,')>0",
                         &statement, error);
    if (ok) {
        ok = IMPBindInteger(statement, 1, IMPMillisecondsForDate(date), error);
    }
    if (ok) {
        int result = sqlite3_step(statement);
        if (result != SQLITE_ROW) {
            ok = IMPSetSQLiteError(error, result);
        } else if (sqlite3_column_int64(statement, 0) > 0) {
            IMPSetError(error, IMPAPIKeyStoreErrorActiveAdminExists,
                        @"An active administrator API key already exists.");
            ok = NO;
        }
    }
    if (statement != NULL) {
        int finalResult = sqlite3_finalize(statement);
        if (ok && finalResult != SQLITE_OK) {
            ok = IMPSetSQLiteError(error, finalResult);
        }
    }
    return ok;
}

- (BOOL)ensureKeyCapacityLockedAtDate:(NSDate *)date pruneIfNeeded:(BOOL)pruneIfNeeded error:(NSError **)error {
    sqlite3_int64 keyCount = 0;
    if (!IMPScalarInteger(_database, "SELECT count(*) FROM api_keys", &keyCount, error)) {
        return NO;
    }
    if (keyCount < (sqlite3_int64)kIMPMaximumAPIKeys) {
        return YES;
    }

    if (!pruneIfNeeded) {
        sqlite3_stmt *statement = NULL;
        BOOL ok = IMPPrepare(_database,
                             "SELECT count(*) FROM ("
                             "SELECT k.uuid FROM api_keys k WHERE "
                             "(k.revoked_at IS NOT NULL OR (k.expires_at IS NOT NULL AND k.expires_at<=?)) "
                             "AND NOT EXISTS(SELECT 1 FROM idempotency_records i WHERE i.principal_uuid=k.uuid) "
                             "ORDER BY COALESCE(k.revoked_at,k.expires_at,k.created_at) ASC LIMIT 100)",
                             &statement, error);
        if (ok) {
            ok = IMPBindInteger(statement, 1, IMPMillisecondsForDate(date), error);
        }
        sqlite3_int64 removableCount = 0;
        if (ok) {
            int result = sqlite3_step(statement);
            if (result != SQLITE_ROW) {
                ok = IMPSetSQLiteError(error, result);
            } else {
                removableCount = sqlite3_column_int64(statement, 0);
            }
        }
        if (statement != NULL) {
            int finalResult = sqlite3_finalize(statement);
            if (ok && finalResult != SQLITE_OK) {
                ok = IMPSetSQLiteError(error, finalResult);
            }
        }
        if (!ok) {
            return NO;
        }
        sqlite3_int64 requiredCount = keyCount - (sqlite3_int64)kIMPMaximumAPIKeys + 1;
        if (removableCount >= requiredCount) {
            return YES;
        }
    } else {
        sqlite3_stmt *prune = NULL;
        BOOL ok = IMPPrepare(_database,
                             "DELETE FROM api_keys WHERE uuid IN ("
                             "SELECT k.uuid FROM api_keys k WHERE "
                             "(k.revoked_at IS NOT NULL OR (k.expires_at IS NOT NULL AND k.expires_at<=?)) "
                             "AND NOT EXISTS(SELECT 1 FROM idempotency_records i WHERE i.principal_uuid=k.uuid) "
                             "ORDER BY COALESCE(k.revoked_at,k.expires_at,k.created_at) ASC LIMIT 100)",
                             &prune, error);
        if (ok) {
            ok = IMPBindInteger(prune, 1, IMPMillisecondsForDate(date), error);
        }
        if (ok) {
            int result = sqlite3_step(prune);
            if (result != SQLITE_DONE) {
                ok = IMPSetSQLiteError(error, result);
            }
        }
        if (prune != NULL) {
            int finalResult = sqlite3_finalize(prune);
            if (ok && finalResult != SQLITE_OK) {
                ok = IMPSetSQLiteError(error, finalResult);
            }
        }
        if (!ok || !IMPScalarInteger(_database, "SELECT count(*) FROM api_keys", &keyCount, error)) {
            return NO;
        }
        if (keyCount < (sqlite3_int64)kIMPMaximumAPIKeys) {
            return YES;
        }
    }

    IMPSetError(error, IMPAPIKeyStoreErrorConflict, @"The API key retention limit has been reached.");
    return NO;
}

- (BOOL)checkBootstrapAdminNamed:(NSString *)name expiresDays:(NSUInteger)expiresDays error:(NSError **)error {
    if (!IMPValidateBootstrapArguments(name, expiresDays, NULL, error)) {
        return NO;
    }

    [_lock lock];
    BOOL ok = IMPExecute(_database, "BEGIN", error);
    NSDate *now = NSDate.date;
    if (ok) {
        ok = [self validateNoActiveAdminLockedAtDate:now error:error];
    }
    if (ok) {
        ok = [self ensureKeyCapacityLockedAtDate:now pruneIfNeeded:NO error:error];
    }
    if (ok) {
        ok = IMPCommit(_database, error);
    }
    if (!ok) {
        IMPRollback(_database);
    }
    [_lock unlock];
    return ok;
}

- (IMPAPIKeyRecord *)bootstrapAdminNamed:(NSString *)name
                             expiresDays:(NSUInteger)expiresDays
                            deliverToken:(BOOL (^)(NSString *token))deliverToken
                                   error:(NSError **)error {
    NSString *normalizedName = nil;
    if (!IMPValidateBootstrapArguments(name, expiresDays, &normalizedName, error) || deliverToken == nil) {
        if (deliverToken == nil && error != NULL && *error == nil) {
            IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The bootstrap token delivery is invalid.");
        }
        return nil;
    }
    NSDate *now = NSDate.date;
    NSDate *expiresAt = [now dateByAddingTimeInterval:(NSTimeInterval)expiresDays * 24.0 * 60.0 * 60.0];

    [_lock lock];
    NSDictionary<NSString *, id> *creation = nil;
    IMPAPIKeyRecord *record = nil;
    if (!IMPBegin(_database, error)) {
        [_lock unlock];
        return nil;
    }
    BOOL ok = [self validateNoActiveAdminLockedAtDate:now error:error];
    if (ok) {
        ok = [self ensureKeyCapacityLockedAtDate:now pruneIfNeeded:YES error:error];
    }
    if (ok) {
        NSString *bootstrapIdentifier = [self nextSenderIdentifier:error];
        creation = bootstrapIdentifier == nil ? nil
                                              : [self createKeyLockedNamed:normalizedName
                                                                    scopes:@[IMPAPIKeyScopeAdmin]
                                                                 expiresAt:expiresAt
                                                          senderIdentifier:bootstrapIdentifier
                                                        identifierAssigned:YES
                                                                     error:error];
        ok = creation != nil;
    }
    if (ok) {
        record = creation[IMPAPIKeyCreationRecordKey];
        NSString *token = creation[IMPAPIKeyCreationTokenKey];
        if (!deliverToken(token)) {
            IMPSetError(error, IMPAPIKeyStoreErrorInvalidState, @"The bootstrap credential could not be delivered.");
            ok = NO;
        }
    }
    if (ok) {
        ok = IMPCommit(_database, error);
    }
    if (!ok) {
        IMPRollback(_database);
        record = nil;
    }
    IMPTightenSidecarModes(_path);
    [_lock unlock];
    return record;
}

// The lowest unused two-letter identifier, then three, and so on. Sequential
// rather than random so an operator reading their key list sees something
// stable and short; uniqueness is enforced by the column regardless.
- (NSString *)nextSenderIdentifier:(NSError **)error {
    sqlite3_stmt *statement = NULL;
    if (!IMPPrepare(_database, "SELECT sender_identifier FROM api_keys", &statement, error)) {
        return nil;
    }
    NSMutableSet<NSString *> *taken = [NSMutableSet set];
    int result = SQLITE_ROW;
    while ((result = sqlite3_step(statement)) == SQLITE_ROW) {
        NSString *existing = IMPColumnString(statement, 0);
        if (existing != nil) {
            [taken addObject:existing];
        }
    }
    int finalResult = sqlite3_finalize(statement);
    if (result != SQLITE_DONE) {
        IMPSetSQLiteError(error, result);
        return nil;
    }
    if (finalResult != SQLITE_OK) {
        IMPSetSQLiteError(error, finalResult);
        return nil;
    }
    for (NSUInteger width = kIMPMinimumSenderIdentifierLength; width <= kIMPMaximumSenderIdentifierLength; width++) {
        NSUInteger span = 1;
        for (NSUInteger power = 0; power < width; power++) {
            span *= 26;
        }
        for (NSUInteger index = 0; index < span; index++) {
            NSMutableString *candidate = [NSMutableString stringWithCapacity:width];
            NSUInteger remaining = index;
            for (NSUInteger position = 0; position < width; position++) {
                [candidate insertString:[NSString stringWithFormat:@"%c", (char)('a' + remaining % 26)] atIndex:0];
                remaining /= 26;
            }
            if (![taken containsObject:candidate]) {
                return [candidate copy];
            }
        }
    }
    IMPSetError(error, IMPAPIKeyStoreErrorConflict, @"No sender identifier is available.");
    return nil;
}

- (NSDictionary<NSString *, id> *)createKeyNamed:(NSString *)name
                                          scopes:(NSArray<IMPAPIKeyScope> *)scopes
                                       expiresAt:(NSDate *)expiresAt
                                senderIdentifier:(NSString *)senderIdentifier
                                       actorUUID:(NSString *)actorUUID
                                           error:(NSError **)error {
    NSString *normalizedName = nil;
    if (!IMPValidateName(name, &normalizedName, error)) {
        return nil;
    }
    // Validated before anything is written, so a malformed identifier is a plain
    // rejection rather than a rolled-back transaction.
    NSString *normalizedIdentifier = nil;
    BOOL identifierAssigned = senderIdentifier == nil;
    if (!identifierAssigned && !IMPValidateSenderIdentifier(senderIdentifier, &normalizedIdentifier, error)) {
        return nil;
    }
    NSArray<IMPAPIKeyScope> *normalizedScopes = IMPNormalizeScopes(scopes, error);
    if (normalizedScopes == nil) {
        return nil;
    }
    if (expiresAt != nil && (!isfinite(expiresAt.timeIntervalSince1970) || [expiresAt timeIntervalSinceNow] < 1.0)) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The API key expiry must be in the future.");
        return nil;
    }
    if (!IMPValidateUUID(actorUUID, error))
        return nil;
    actorUUID = IMPNormalizedUUID(actorUUID);

    [_lock lock];
    NSDictionary<NSString *, id> *creation = nil;
    BOOL ok = IMPBegin(_database, error);
    if (ok) {
        NSError *lookupError = nil;
        IMPAPIKeyRecord *actor = [self recordLockedForUUID:actorUUID error:&lookupError];
        NSDate *now = NSDate.date;
        BOOL activeAdmin = actor != nil && actor.revokedAt == nil &&
                           (actor.expiresAt == nil || [actor.expiresAt compare:now] == NSOrderedDescending) &&
                           [actor hasScope:IMPAPIKeyScopeAdmin];
        if (!activeAdmin) {
            if (lookupError != nil && lookupError.code != IMPAPIKeyStoreErrorNotFound) {
                if (error != NULL)
                    *error = lookupError;
            } else {
                IMPSetError(error, IMPAPIKeyStoreErrorAuthorizationFailed,
                            @"An active administrator API key is required.");
            }
            ok = NO;
        }
    }
    if (ok) {
        ok = [self ensureKeyCapacityLockedAtDate:NSDate.date pruneIfNeeded:YES error:error];
    }
    if (ok && identifierAssigned) {
        normalizedIdentifier = [self nextSenderIdentifier:error];
        ok = normalizedIdentifier != nil;
    }
    if (ok) {
        creation = [self createKeyLockedNamed:normalizedName
                                       scopes:normalizedScopes
                                    expiresAt:expiresAt
                             senderIdentifier:normalizedIdentifier
                           identifierAssigned:identifierAssigned
                                        error:error];
        ok = creation != nil;
    }
    if (ok) {
        ok = IMPCommit(_database, error);
    }
    if (!ok) {
        IMPRollback(_database);
        creation = nil;
    }
    IMPTightenSidecarModes(_path);
    [_lock unlock];
    return creation;
}

- (NSDictionary<NSString *, id> *)createKeyLockedNamed:(NSString *)name
                                                scopes:(NSArray<IMPAPIKeyScope> *)scopes
                                             expiresAt:(NSDate *)expiresAt
                                      senderIdentifier:(NSString *)normalizedIdentifier
                                    identifierAssigned:(BOOL)identifierAssigned
                                                 error:(NSError **)error {
    NSString *scopeString = [scopes componentsJoinedByString:@","];
    NSDate *createdAt = NSDate.date;

    for (NSUInteger attempt = 0; attempt < 4; attempt++) {
        NSMutableData *rawKey = [NSMutableData dataWithLength:kIMPRawKeyLength];
        if (SecRandomCopyBytes(kSecRandomDefault, rawKey.length, rawKey.mutableBytes) != errSecSuccess) {
            IMPSetError(error, IMPAPIKeyStoreErrorCryptography, @"A secure API key could not be generated.");
            return nil;
        }
        NSString *encoded = IMPBase64URLEncode(rawKey);
        NSString *token = [@"imp_" stringByAppendingString:encoded];
        NSString *prefix = [@"imp_" stringByAppendingString:[encoded substringToIndex:8]];
        NSData *hash = IMPSHA256(rawKey);
        IMPSecureZero(rawKey);
        NSString *uuid = NSUUID.UUID.UUIDString.lowercaseString;

        sqlite3_stmt *statement = NULL;
        if (!IMPPrepare(_database,
                        "INSERT INTO api_keys"
                        "(uuid,name,key_prefix,key_hash,scopes,sender_identifier,sender_identifier_assigned,"
                        "created_at,expires_at) "
                        "VALUES(?,?,?,?,?,?,?,?,?)",
                        &statement, error)) {
            return nil;
        }
        BOOL bound = IMPBindText(statement, 1, uuid, error) && IMPBindText(statement, 2, name, error) &&
                     IMPBindText(statement, 3, prefix, error) && IMPBindData(statement, 4, hash, error) &&
                     IMPBindText(statement, 5, scopeString, error) &&
                     IMPBindText(statement, 6, normalizedIdentifier, error) &&
                     IMPBindInteger(statement, 7, identifierAssigned ? 1 : 0, error);
        if (bound) {
            bound = IMPBindInteger(statement, 8, IMPMillisecondsForDate(createdAt), error);
        }
        if (bound) {
            bound = expiresAt == nil ? IMPBindNull(statement, 9, error)
                                     : IMPBindInteger(statement, 9, IMPMillisecondsForDate(expiresAt), error);
        }
        int result = bound ? sqlite3_step(statement) : SQLITE_ERROR;
        int finalResult = sqlite3_finalize(statement);
        if (!bound) {
            return nil;
        }
        if (result == SQLITE_DONE && finalResult == SQLITE_OK) {
            IMPAPIKeyRecord *record = [[IMPAPIKeyRecord alloc] initWithUUID:uuid
                                                                       name:name
                                                                  keyPrefix:prefix
                                                                     scopes:scopes
                                                           senderIdentifier:normalizedIdentifier
                                                   senderIdentifierAssigned:identifierAssigned
                                                                  createdAt:createdAt
                                                                  expiresAt:expiresAt
                                                                  revokedAt:nil
                                                                 lastUsedAt:nil];
            return @{IMPAPIKeyCreationRecordKey: record, IMPAPIKeyCreationTokenKey: token};
        }
        if ((result & 0xff) != SQLITE_CONSTRAINT || attempt == 3) {
            IMPSetSQLiteError(error, result != SQLITE_DONE ? result : finalResult);
            return nil;
        }
    }
    IMPSetError(error, IMPAPIKeyStoreErrorCryptography, @"A unique API key could not be generated.");
    return nil;
}

- (IMPAPIKeyRecord *)authenticateToken:(NSString *)token error:(NSError **)error {
    NSData *raw = IMPDecodeToken(token);
    if (raw == nil) {
        IMPSetError(error, IMPAPIKeyStoreErrorAuthenticationFailed, @"Authentication failed.");
        return nil;
    }
    NSData *candidateHash = IMPSHA256(raw);
    NSString *prefix = [token substringToIndex:12];

    [_lock lock];
    sqlite3_stmt *statement = NULL;
    IMPAPIKeyRecord *matchedRecord = nil;
    NSData *storedHash = nil;
    BOOL databaseOK = IMPPrepare(_database,
                                 "SELECT " IMP_API_KEY_COLUMNS ",key_hash "
                                 "FROM api_keys WHERE key_prefix=?",
                                 &statement, error) &&
                      IMPBindText(statement, 1, prefix, error);
    if (databaseOK) {
        int result = sqlite3_step(statement);
        if (result == SQLITE_ROW) {
            matchedRecord = IMPRecordFromStatement(statement, 0);
            storedHash = IMPColumnData(statement, kIMPAPIKeyColumnCount);
            if (matchedRecord == nil || storedHash.length != kIMPRawKeyLength) {
                IMPSetError(error, IMPAPIKeyStoreErrorDatabaseCorrupt, @"An API key record is invalid.");
                databaseOK = NO;
            }
        } else if (result != SQLITE_DONE) {
            databaseOK = IMPSetSQLiteError(error, result);
        }
    }
    if (statement != NULL) {
        int finalResult = sqlite3_finalize(statement);
        if (databaseOK && finalResult != SQLITE_OK) {
            databaseOK = IMPSetSQLiteError(error, finalResult);
        }
    }

    NSDate *now = NSDate.date;
    NSData *comparisonHash = storedHash != nil ? storedHash : [NSMutableData dataWithLength:kIMPRawKeyLength];
    BOOL digestMatches = IMPConstantTimeEqual(candidateHash, comparisonHash);
    BOOL active = databaseOK && digestMatches && matchedRecord != nil && matchedRecord.revokedAt == nil &&
                  (matchedRecord.expiresAt == nil || [matchedRecord.expiresAt compare:now] == NSOrderedDescending);
    BOOL shouldUpdateLastUsed =
        active && (matchedRecord.lastUsedAt == nil ||
                   [now timeIntervalSinceDate:matchedRecord.lastUsedAt] >= kIMPLastUsedWriteInterval);
    if (databaseOK && shouldUpdateLastUsed) {
        statement = NULL;
        databaseOK = IMPPrepare(_database,
                                "UPDATE api_keys SET last_used_at=? WHERE uuid=? AND revoked_at IS NULL "
                                "AND (expires_at IS NULL OR expires_at>?) "
                                "AND (last_used_at IS NULL OR last_used_at<=?)",
                                &statement, error);
        if (databaseOK) {
            sqlite3_int64 nowMilliseconds = IMPMillisecondsForDate(now);
            databaseOK = IMPBindInteger(statement, 1, nowMilliseconds, error) &&
                         IMPBindText(statement, 2, matchedRecord.uuid, error);
            if (databaseOK) {
                sqlite3_int64 threshold =
                    IMPMillisecondsForDate([now dateByAddingTimeInterval:-kIMPLastUsedWriteInterval]);
                databaseOK = IMPBindInteger(statement, 3, nowMilliseconds, error) &&
                             IMPBindInteger(statement, 4, threshold, error);
                if (databaseOK) {
                    int result = sqlite3_step(statement);
                    if (result != SQLITE_DONE) {
                        databaseOK = IMPSetSQLiteError(error, result);
                    }
                }
            }
        }
        if (statement != NULL) {
            int finalResult = sqlite3_finalize(statement);
            if (databaseOK && finalResult != SQLITE_OK) {
                databaseOK = IMPSetSQLiteError(error, finalResult);
            }
        }
        if (databaseOK && sqlite3_changes(_database) == 1) {
            matchedRecord = [[IMPAPIKeyRecord alloc] initWithUUID:matchedRecord.uuid
                                                             name:matchedRecord.name
                                                        keyPrefix:matchedRecord.keyPrefix
                                                           scopes:matchedRecord.scopes
                                                 senderIdentifier:matchedRecord.senderIdentifier
                                         senderIdentifierAssigned:matchedRecord.senderIdentifierAssigned
                                                        createdAt:matchedRecord.createdAt
                                                        expiresAt:matchedRecord.expiresAt
                                                        revokedAt:nil
                                                       lastUsedAt:now];
        }
    }
    IMPTightenSidecarModes(_path);
    [_lock unlock];

    if (!databaseOK) {
        return nil;
    }
    if (!active) {
        IMPSetError(error, IMPAPIKeyStoreErrorAuthenticationFailed, @"Authentication failed.");
        return nil;
    }
    return matchedRecord;
}

- (NSArray<IMPAPIKeyRecord *> *)listKeysWithLimit:(NSUInteger)limit error:(NSError **)error {
    if (limit == 0 || limit > kIMPMaximumAPIKeys) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The API key list limit is invalid.");
        return nil;
    }
    [_lock lock];
    sqlite3_stmt *statement = NULL;
    NSMutableArray<IMPAPIKeyRecord *> *records = [NSMutableArray array];
    BOOL ok = IMPPrepare(_database,
                         "SELECT " IMP_API_KEY_COLUMNS " "
                         "FROM api_keys ORDER BY created_at DESC, uuid ASC LIMIT ?",
                         &statement, error) &&
              IMPBindInteger(statement, 1, (sqlite3_int64)limit, error);
    if (ok) {
        int result = SQLITE_ROW;
        while ((result = sqlite3_step(statement)) == SQLITE_ROW) {
            IMPAPIKeyRecord *record = IMPRecordFromStatement(statement, 0);
            if (record == nil) {
                IMPSetError(error, IMPAPIKeyStoreErrorDatabaseCorrupt, @"An API key record is invalid.");
                ok = NO;
                break;
            }
            [records addObject:record];
        }
        if (ok && result != SQLITE_DONE) {
            ok = IMPSetSQLiteError(error, result);
        }
    }
    if (statement != NULL) {
        int finalResult = sqlite3_finalize(statement);
        if (ok && finalResult != SQLITE_OK) {
            ok = IMPSetSQLiteError(error, finalResult);
        }
    }
    [_lock unlock];
    return ok ? records : nil;
}

- (IMPAPIKeyRecord *)keyWithUUID:(NSString *)uuid error:(NSError **)error {
    if (!IMPValidateUUID(uuid, error)) {
        return nil;
    }
    uuid = IMPNormalizedUUID(uuid);
    [_lock lock];
    IMPAPIKeyRecord *record = [self recordLockedForUUID:uuid error:error];
    [_lock unlock];
    return record;
}

- (BOOL)revokeKeyUUID:(NSString *)uuid actorUUID:(NSString *)actorUUID error:(NSError **)error {
    if (!IMPValidateUUID(uuid, error) || !IMPValidateUUID(actorUUID, error)) {
        return NO;
    }
    uuid = IMPNormalizedUUID(uuid);
    actorUUID = IMPNormalizedUUID(actorUUID);
    [_lock lock];
    BOOL ok = IMPBegin(_database, error);
    NSDate *now = NSDate.date;
    sqlite3_int64 nowMilliseconds = IMPMillisecondsForDate(now);

    IMPAPIKeyRecord *actor = nil;
    IMPAPIKeyRecord *target = nil;
    if (ok) {
        NSError *lookupError = nil;
        actor = [self recordLockedForUUID:actorUUID error:&lookupError];
        if (actor == nil && lookupError.code != IMPAPIKeyStoreErrorNotFound) {
            if (error != NULL) {
                *error = lookupError;
            }
            ok = NO;
        }
        BOOL actorActive = ok && actor != nil && actor.revokedAt == nil &&
                           (actor.expiresAt == nil || [actor.expiresAt compare:now] == NSOrderedDescending) &&
                           [actor hasScope:IMPAPIKeyScopeAdmin];
        if (ok && !actorActive) {
            IMPSetError(error, IMPAPIKeyStoreErrorAuthorizationFailed, @"An active administrator API key is required.");
            ok = NO;
        }
    }
    if (ok) {
        target = [self recordLockedForUUID:uuid error:error];
        ok = target != nil;
    }
    if (ok && target.revokedAt == nil && [target hasScope:IMPAPIKeyScopeAdmin] &&
        (target.expiresAt == nil || [target.expiresAt compare:now] == NSOrderedDescending)) {
        sqlite3_stmt *countStatement = NULL;
        ok = IMPPrepare(_database,
                        "SELECT count(*) FROM api_keys WHERE revoked_at IS NULL "
                        "AND (expires_at IS NULL OR expires_at>?) "
                        "AND instr(','||scopes||',', ',admin,')>0",
                        &countStatement, error);
        if (ok) {
            ok = IMPBindInteger(countStatement, 1, nowMilliseconds, error);
            if (ok) {
                int result = sqlite3_step(countStatement);
                if (result != SQLITE_ROW) {
                    ok = IMPSetSQLiteError(error, result);
                } else if (sqlite3_column_int64(countStatement, 0) <= 1) {
                    IMPSetError(error, IMPAPIKeyStoreErrorLastActiveAdmin,
                                @"The final active administrator API key cannot be revoked.");
                    ok = NO;
                }
            }
        }
        if (countStatement != NULL) {
            int finalResult = sqlite3_finalize(countStatement);
            if (ok && finalResult != SQLITE_OK) {
                ok = IMPSetSQLiteError(error, finalResult);
            }
        }
    }
    if (ok && target.revokedAt == nil) {
        sqlite3_stmt *update = NULL;
        ok = IMPPrepare(_database, "UPDATE api_keys SET revoked_at=? WHERE uuid=? AND revoked_at IS NULL", &update,
                        error);
        if (ok) {
            ok = IMPBindInteger(update, 1, nowMilliseconds, error) && IMPBindText(update, 2, uuid, error);
        }
        if (ok) {
            int result = sqlite3_step(update);
            if (result != SQLITE_DONE) {
                ok = IMPSetSQLiteError(error, result);
            } else if (sqlite3_changes(_database) != 1) {
                IMPSetError(error, IMPAPIKeyStoreErrorConflict, @"The API key changed while it was being revoked.");
                ok = NO;
            }
        }
        if (update != NULL) {
            int finalResult = sqlite3_finalize(update);
            if (ok && finalResult != SQLITE_OK) {
                ok = IMPSetSQLiteError(error, finalResult);
            }
        }
    }
    if (ok) {
        ok = IMPCommit(_database, error);
    }
    if (!ok) {
        IMPRollback(_database);
    }
    IMPTightenSidecarModes(_path);
    [_lock unlock];
    return ok;
}

- (IMPAPIKeyRecord *)recordLockedForUUID:(NSString *)uuid error:(NSError **)error {
    sqlite3_stmt *statement = NULL;
    if (!IMPPrepare(_database,
                    "SELECT " IMP_API_KEY_COLUMNS " "
                    "FROM api_keys WHERE uuid=?",
                    &statement, error)) {
        return nil;
    }
    if (!IMPBindText(statement, 1, uuid, error)) {
        sqlite3_finalize(statement);
        return nil;
    }
    int result = sqlite3_step(statement);
    IMPAPIKeyRecord *record = result == SQLITE_ROW ? IMPRecordFromStatement(statement, 0) : nil;
    int finalResult = sqlite3_finalize(statement);
    if (result == SQLITE_DONE) {
        IMPSetError(error, IMPAPIKeyStoreErrorNotFound, @"The API key was not found.");
        return nil;
    }
    if (result != SQLITE_ROW) {
        IMPSetSQLiteError(error, result);
        return nil;
    }
    if (finalResult != SQLITE_OK) {
        IMPSetSQLiteError(error, finalResult);
        return nil;
    }
    if (record == nil) {
        IMPSetError(error, IMPAPIKeyStoreErrorDatabaseCorrupt, @"An API key record is invalid.");
    }
    return record;
}

- (BOOL)prepareForServerStartup:(NSError **)error {
    [_lock lock];
    BOOL ok = IMPBegin(_database, error);
    sqlite3_stmt *statement = NULL;
    if (ok) {
        ok = IMPPrepare(_database,
                        "UPDATE idempotency_records SET state='ambiguous',response_status=409,"
                        "response_body=X'',updated_at=max(updated_at,?) WHERE state='in_progress'",
                        &statement, error) &&
             IMPBindInteger(statement, 1, IMPMillisecondsForDate(NSDate.date), error);
    }
    if (ok) {
        int result = sqlite3_step(statement);
        if (result != SQLITE_DONE)
            ok = IMPSetSQLiteError(error, result);
    }
    if (statement != NULL) {
        int finalResult = sqlite3_finalize(statement);
        statement = NULL;
        if (ok && finalResult != SQLITE_OK)
            ok = IMPSetSQLiteError(error, finalResult);
    }
    if (ok)
        ok = IMPCommit(_database, error);
    if (!ok)
        IMPRollback(_database);
    IMPTightenSidecarModes(_path);
    [_lock unlock];
    return ok;
}

- (IMPIdempotencyRecord *)claimForPrincipalUUID:(NSString *)principalUUID
                                            key:(NSString *)key
                                    requestHash:(NSData *)requestHash
                                          error:(NSError **)error {
    if (!IMPValidateUUID(principalUUID, error) || !IMPValidateIdempotencyKey(key, error) ||
        !IMPValidateRequestHash(requestHash, error)) {
        return nil;
    }
    principalUUID = IMPNormalizedUUID(principalUUID);

    [_lock lock];
    BOOL ok = IMPBegin(_database, error);
    IMPIdempotencyRecord *record = nil;
    NSDate *now = NSDate.date;
    if (ok) {
        NSError *lookupError = nil;
        IMPAPIKeyRecord *principal = [self recordLockedForUUID:principalUUID error:&lookupError];
        if (principal == nil && lookupError.code != IMPAPIKeyStoreErrorNotFound) {
            if (error != NULL) {
                *error = lookupError;
            }
            ok = NO;
        }
        BOOL principalActive = ok && principal != nil && principal.revokedAt == nil &&
                               (principal.expiresAt == nil || [principal.expiresAt compare:now] == NSOrderedDescending);
        if (ok && !principalActive) {
            IMPSetError(error, IMPAPIKeyStoreErrorAuthenticationFailed, @"Authentication failed.");
            ok = NO;
        }
    }

    sqlite3_stmt *statement = NULL;
    if (ok) {
        ok = IMPPrepare(_database,
                        "SELECT operation_uuid,request_hash,state,response_status,response_body,created_at,updated_at "
                        "FROM idempotency_records WHERE principal_uuid=? AND idempotency_key=?",
                        &statement, error) &&
             IMPBindText(statement, 1, principalUUID, error) && IMPBindText(statement, 2, key, error);
    }
    int result = ok ? sqlite3_step(statement) : SQLITE_ERROR;
    if (ok && result == SQLITE_DONE) {
        int selectionFinalizeResult = sqlite3_finalize(statement);
        statement = NULL;
        if (selectionFinalizeResult != SQLITE_OK) {
            ok = IMPSetSQLiteError(error, selectionFinalizeResult);
        }
        sqlite3_int64 rowCount = 0;
        if (ok) {
            ok = IMPScalarInteger(_database, "SELECT count(*) FROM idempotency_records", &rowCount, error);
        }
        if (ok && rowCount >= (sqlite3_int64)kIMPMaximumIdempotencyRows) {
            IMPSetError(error, IMPAPIKeyStoreErrorConflict, @"The idempotency retention limit has been reached.");
            ok = NO;
        }
        if (ok) {
            NSString *operationUUID = NSUUID.UUID.UUIDString.lowercaseString;
            ok = IMPPrepare(_database,
                            "INSERT INTO idempotency_records"
                            "(principal_uuid,idempotency_key,operation_uuid,request_hash,state,created_at,updated_at) "
                            "VALUES(?,?,?,?,'in_progress',?,?)",
                            &statement, error) &&
                 IMPBindText(statement, 1, principalUUID, error) && IMPBindText(statement, 2, key, error) &&
                 IMPBindText(statement, 3, operationUUID, error) && IMPBindData(statement, 4, requestHash, error);
            if (ok) {
                sqlite3_int64 milliseconds = IMPMillisecondsForDate(now);
                ok = IMPBindInteger(statement, 5, milliseconds, error) &&
                     IMPBindInteger(statement, 6, milliseconds, error);
            }
            if (ok) {
                result = sqlite3_step(statement);
                if (result != SQLITE_DONE) {
                    ok = IMPSetSQLiteError(error, result);
                } else {
                    record = [[IMPIdempotencyRecord alloc] initWithPrincipalUUID:principalUUID
                                                                             key:key
                                                                   operationUUID:operationUUID
                                                                           state:IMPIdempotencyStateInProgress
                                                                     disposition:IMPIdempotencyDispositionNew
                                                                  responseStatus:nil
                                                                    responseBody:nil
                                                                       createdAt:now
                                                                       updatedAt:now];
                }
            }
        }
    } else if (ok && result == SQLITE_ROW) {
        NSString *operationUUID = IMPColumnString(statement, 0);
        NSData *storedHash = IMPColumnData(statement, 1);
        NSString *stateString = IMPColumnString(statement, 2);
        IMPIdempotencyState state = IMPStateFromString(stateString);
        NSNumber *status = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : @(sqlite3_column_int(statement, 3));
        NSData *body = IMPColumnData(statement, 4);
        sqlite3_int64 createdMilliseconds = sqlite3_column_int64(statement, 5);
        sqlite3_int64 updatedMilliseconds = sqlite3_column_int64(statement, 6);
        NSDate *createdAt = IMPDateForMilliseconds(createdMilliseconds);
        NSDate *updatedAt = IMPDateForMilliseconds(updatedMilliseconds);
        BOOL responseShapeValid = state == IMPIdempotencyStateInProgress
                                      ? (status == nil && body == nil)
                                      : (status != nil && status.integerValue >= 100 && status.integerValue <= 599 &&
                                         body != nil && body.length <= kIMPMaximumStoredResponseBytes);
        if ([[NSUUID alloc] initWithUUIDString:operationUUID] == nil || storedHash.length != kIMPRequestHashLength ||
            state == 0 || !responseShapeValid || createdMilliseconds <= 0 ||
            updatedMilliseconds < createdMilliseconds) {
            IMPSetError(error, IMPAPIKeyStoreErrorDatabaseCorrupt, @"An idempotency record is invalid.");
            ok = NO;
        } else {
            BOOL sameRequest = IMPConstantTimeEqual(requestHash, storedHash);
            IMPIdempotencyDisposition disposition;
            if (!sameRequest) {
                disposition = IMPIdempotencyDispositionConflict;
                status = nil;
                body = nil;
            } else if (state == IMPIdempotencyStateInProgress) {
                disposition = IMPIdempotencyDispositionInProgress;
            } else if (state == IMPIdempotencyStateAmbiguous) {
                disposition = IMPIdempotencyDispositionAmbiguous;
            } else {
                disposition = IMPIdempotencyDispositionReplay;
            }
            record = [[IMPIdempotencyRecord alloc] initWithPrincipalUUID:principalUUID
                                                                     key:key
                                                           operationUUID:operationUUID
                                                                   state:state
                                                             disposition:disposition
                                                          responseStatus:status
                                                            responseBody:body
                                                               createdAt:createdAt
                                                               updatedAt:updatedAt];
        }
    } else if (ok) {
        ok = IMPSetSQLiteError(error, result);
    }
    if (statement != NULL) {
        int finalResult = sqlite3_finalize(statement);
        if (ok && finalResult != SQLITE_OK) {
            ok = IMPSetSQLiteError(error, finalResult);
        }
    }
    if (ok) {
        ok = IMPCommit(_database, error);
    }
    if (!ok) {
        IMPRollback(_database);
        record = nil;
    }
    IMPTightenSidecarModes(_path);
    [_lock unlock];
    return record;
}

- (BOOL)completeForPrincipalUUID:(NSString *)principalUUID
                             key:(NSString *)key
                     requestHash:(NSData *)requestHash
                   operationUUID:(NSString *)operationUUID
                           state:(IMPIdempotencyState)state
                  responseStatus:(NSInteger)responseStatus
                    responseBody:(NSData *)responseBody
                           error:(NSError **)error {
    BOOL terminalState = state == IMPIdempotencyStateSucceeded || state == IMPIdempotencyStateAmbiguous ||
                         state == IMPIdempotencyStateFailed;
    if (!IMPValidateUUID(principalUUID, error) || !IMPValidateUUID(operationUUID, error) ||
        !IMPValidateIdempotencyKey(key, error) || !IMPValidateRequestHash(requestHash, error) || !terminalState ||
        responseStatus < 100 || responseStatus > 599 || ![responseBody isKindOfClass:NSData.class] ||
        responseBody.length > kIMPMaximumStoredResponseBytes) {
        if (error != NULL && *error == nil) {
            IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The idempotency completion is invalid.");
        }
        return NO;
    }
    principalUUID = IMPNormalizedUUID(principalUUID);
    operationUUID = IMPNormalizedUUID(operationUUID);

    [_lock lock];
    BOOL ok = IMPBegin(_database, error);
    sqlite3_stmt *statement = NULL;
    NSString *storedOperationUUID = nil;
    NSData *storedHash = nil;
    IMPIdempotencyState storedState = 0;
    NSNumber *storedStatus = nil;
    NSData *storedBody = nil;
    if (ok) {
        ok = IMPPrepare(
                 _database,
                 "SELECT operation_uuid,request_hash,state,response_status,response_body FROM idempotency_records "
                 "WHERE principal_uuid=? AND idempotency_key=?",
                 &statement, error) &&
             IMPBindText(statement, 1, principalUUID, error) && IMPBindText(statement, 2, key, error);
    }
    if (ok) {
        int result = sqlite3_step(statement);
        if (result == SQLITE_DONE) {
            IMPSetError(error, IMPAPIKeyStoreErrorNotFound, @"The idempotency claim was not found.");
            ok = NO;
        } else if (result != SQLITE_ROW) {
            ok = IMPSetSQLiteError(error, result);
        } else {
            storedOperationUUID = IMPColumnString(statement, 0);
            storedHash = IMPColumnData(statement, 1);
            storedState = IMPStateFromString(IMPColumnString(statement, 2));
            storedStatus = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : @(sqlite3_column_int(statement, 3));
            storedBody = IMPColumnData(statement, 4);
        }
    }
    if (statement != NULL) {
        int finalResult = sqlite3_finalize(statement);
        statement = NULL;
        if (ok && finalResult != SQLITE_OK) {
            ok = IMPSetSQLiteError(error, finalResult);
        }
    }
    if (ok && ([[NSUUID alloc] initWithUUIDString:storedOperationUUID] == nil ||
               storedHash.length != kIMPRequestHashLength || storedState == 0)) {
        IMPSetError(error, IMPAPIKeyStoreErrorDatabaseCorrupt, @"The idempotency record is invalid.");
        ok = NO;
    }
    if (ok && !IMPConstantTimeEqual(requestHash, storedHash)) {
        IMPSetError(error, IMPAPIKeyStoreErrorConflict, @"The idempotency key belongs to a different request.");
        ok = NO;
    }
    if (ok && ![storedOperationUUID isEqualToString:operationUUID]) {
        IMPSetError(error, IMPAPIKeyStoreErrorConflict, @"The idempotency operation ownership token does not match.");
        ok = NO;
    }
    if (ok && storedState != IMPIdempotencyStateInProgress) {
        BOOL identical = storedState == state && storedStatus.integerValue == responseStatus &&
                         [storedBody isEqualToData:responseBody];
        if (!identical) {
            IMPSetError(error, IMPAPIKeyStoreErrorInvalidState, @"The idempotency record is already complete.");
            ok = NO;
        }
    } else if (ok) {
        ok = IMPPrepare(_database,
                        "UPDATE idempotency_records SET state=?,response_status=?,response_body=?,updated_at=? "
                        "WHERE principal_uuid=? AND idempotency_key=? AND operation_uuid=? "
                        "AND request_hash=? AND state='in_progress'",
                        &statement, error) &&
             IMPBindText(statement, 1, IMPStateString(state), error);
        if (ok) {
            ok = IMPBindInteger(statement, 2, (sqlite3_int64)responseStatus, error) &&
                 IMPBindData(statement, 3, responseBody, error);
        }
        if (ok) {
            ok = IMPBindInteger(statement, 4, IMPMillisecondsForDate(NSDate.date), error) &&
                 IMPBindText(statement, 5, principalUUID, error) && IMPBindText(statement, 6, key, error) &&
                 IMPBindText(statement, 7, operationUUID, error) && IMPBindData(statement, 8, requestHash, error);
        }
        if (ok) {
            int result = sqlite3_step(statement);
            if (result != SQLITE_DONE) {
                ok = IMPSetSQLiteError(error, result);
            } else if (sqlite3_changes(_database) != 1) {
                IMPSetError(error, IMPAPIKeyStoreErrorConflict, @"The idempotency record changed before completion.");
                ok = NO;
            }
        }
        if (statement != NULL) {
            int finalResult = sqlite3_finalize(statement);
            statement = NULL;
            if (ok && finalResult != SQLITE_OK) {
                ok = IMPSetSQLiteError(error, finalResult);
            }
        }
    }
    if (ok) {
        ok = IMPCommit(_database, error);
    }
    if (!ok) {
        IMPRollback(_database);
    }
    IMPTightenSidecarModes(_path);
    [_lock unlock];
    return ok;
}

- (BOOL)recordAuditForRequestUUID:(NSString *)requestUUID
                          keyUUID:(NSString *)keyUUID
                    targetKeyUUID:(NSString *)targetKeyUUID
                           source:(NSString *)source
                           action:(NSString *)action
                            phase:(IMPAuditPhase)phase
                           status:(NSNumber *)status
             durationMilliseconds:(NSNumber *)durationMilliseconds
                            error:(NSError **)error {
    if (!IMPValidateUUID(requestUUID, error) || (keyUUID != nil && !IMPValidateUUID(keyUUID, error)) ||
        (targetKeyUUID != nil && !IMPValidateUUID(targetKeyUUID, error)) || !IMPValidateAuditSource(source, error) ||
        !IMPValidateAuditAction(action, error) || (phase != IMPAuditPhaseAttempted && phase != IMPAuditPhaseFinal)) {
        if (error != NULL && *error == nil) {
            IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The audit row is invalid.");
        }
        return NO;
    }
    BOOL phaseValuesValid = (phase == IMPAuditPhaseAttempted && status == nil && durationMilliseconds == nil) ||
                            (phase == IMPAuditPhaseFinal && status != nil && durationMilliseconds != nil);
    if (!phaseValuesValid || (status != nil && !IMPNumberIsIntegerInRange(status, 100, 599)) ||
        (durationMilliseconds != nil && !IMPNumberIsIntegerInRange(durationMilliseconds, 0, LLONG_MAX))) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The audit row is invalid.");
        return NO;
    }

    NSString *normalizedRequestUUID = [[[[NSUUID alloc] initWithUUIDString:requestUUID] UUIDString] lowercaseString];
    NSString *normalizedKeyUUID =
        keyUUID == nil ? nil : [[[[NSUUID alloc] initWithUUIDString:keyUUID] UUIDString] lowercaseString];
    NSString *normalizedTargetKeyUUID =
        targetKeyUUID == nil ? nil : [[[[NSUUID alloc] initWithUUIDString:targetKeyUUID] UUIDString] lowercaseString];
    NSString *phaseString = IMPAuditPhaseString(phase);

    [_lock lock];
    BOOL ok = IMPBegin(_database, error);
    BOOL existingExact = NO;
    sqlite3_stmt *statement = NULL;
    if (ok) {
        ok = IMPPrepare(_database,
                        "SELECT key_uuid,target_key_uuid,source,action,status,duration_ms FROM audit_records "
                        "WHERE request_uuid=? AND phase=?",
                        &statement, error) &&
             IMPBindText(statement, 1, normalizedRequestUUID, error) && IMPBindText(statement, 2, phaseString, error);
    }
    if (ok) {
        int result = sqlite3_step(statement);
        if (result == SQLITE_ROW) {
            NSString *storedKeyUUID = IMPColumnString(statement, 0);
            NSString *storedTargetKeyUUID = IMPColumnString(statement, 1);
            NSString *storedSource = IMPColumnString(statement, 2);
            NSString *storedAction = IMPColumnString(statement, 3);
            NSNumber *storedStatus =
                sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : @(sqlite3_column_int64(statement, 4));
            NSNumber *storedDuration =
                sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : @(sqlite3_column_int64(statement, 5));
            BOOL keysEqual = IMPNullableObjectsEqual(storedKeyUUID, normalizedKeyUUID);
            BOOL targetsEqual = IMPNullableObjectsEqual(storedTargetKeyUUID, normalizedTargetKeyUUID);
            BOOL statusesEqual = IMPNullableObjectsEqual(storedStatus, status);
            BOOL durationsEqual = IMPNullableObjectsEqual(storedDuration, durationMilliseconds);
            existingExact = keysEqual && targetsEqual && [storedSource isEqualToString:source] &&
                            [storedAction isEqualToString:action] && statusesEqual && durationsEqual;
            if (!existingExact) {
                IMPSetError(error, IMPAPIKeyStoreErrorConflict, @"The audit phase is already recorded differently.");
                ok = NO;
            }
        } else if (result != SQLITE_DONE) {
            ok = IMPSetSQLiteError(error, result);
        }
    }
    if (statement != NULL) {
        int finalResult = sqlite3_finalize(statement);
        statement = NULL;
        if (ok && finalResult != SQLITE_OK) {
            ok = IMPSetSQLiteError(error, finalResult);
        }
    }

    if (ok && !existingExact && phase == IMPAuditPhaseFinal) {
        ok = IMPPrepare(_database,
                        "SELECT key_uuid,target_key_uuid,source,action FROM audit_records "
                        "WHERE request_uuid=? AND phase='attempted'",
                        &statement, error) &&
             IMPBindText(statement, 1, normalizedRequestUUID, error);
        if (ok) {
            int result = sqlite3_step(statement);
            if (result == SQLITE_ROW) {
                NSString *attemptedKeyUUID = IMPColumnString(statement, 0);
                NSString *attemptedTargetKeyUUID = IMPColumnString(statement, 1);
                NSString *attemptedSource = IMPColumnString(statement, 2);
                NSString *attemptedAction = IMPColumnString(statement, 3);
                BOOL keysEqual = IMPNullableObjectsEqual(attemptedKeyUUID, normalizedKeyUUID);
                BOOL targetsCompatible =
                    attemptedTargetKeyUUID == nil || (normalizedTargetKeyUUID != nil &&
                                                      [attemptedTargetKeyUUID isEqualToString:normalizedTargetKeyUUID]);
                if (!keysEqual || !targetsCompatible || ![attemptedSource isEqualToString:source] ||
                    ![attemptedAction isEqualToString:action]) {
                    IMPSetError(error, IMPAPIKeyStoreErrorConflict,
                                @"The final audit row does not match its attempted row.");
                    ok = NO;
                }
            } else if (result != SQLITE_DONE) {
                ok = IMPSetSQLiteError(error, result);
            }
        }
        if (statement != NULL) {
            int finalResult = sqlite3_finalize(statement);
            statement = NULL;
            if (ok && finalResult != SQLITE_OK) {
                ok = IMPSetSQLiteError(error, finalResult);
            }
        }
    }

    if (ok && !existingExact) {
        sqlite3_int64 rowCount = 0;
        ok = IMPScalarInteger(_database, "SELECT count(*) FROM audit_records", &rowCount, error);
        if (ok && rowCount >= (sqlite3_int64)kIMPMaximumAuditRows) {
            sqlite3_stmt *prune = NULL;
            ok = IMPPrepare(_database,
                            "DELETE FROM audit_records WHERE request_uuid IN ("
                            "SELECT request_uuid FROM audit_records WHERE request_uuid<>? GROUP BY request_uuid "
                            "ORDER BY max(created_at) ASC LIMIT 1000)",
                            &prune, error) &&
                 IMPBindText(prune, 1, normalizedRequestUUID, error);
            if (ok) {
                int result = sqlite3_step(prune);
                if (result != SQLITE_DONE)
                    ok = IMPSetSQLiteError(error, result);
            }
            if (prune != NULL) {
                int finalResult = sqlite3_finalize(prune);
                if (ok && finalResult != SQLITE_OK)
                    ok = IMPSetSQLiteError(error, finalResult);
            }
            if (ok)
                ok = IMPScalarInteger(_database, "SELECT count(*) FROM audit_records", &rowCount, error);
        }
        if (ok && rowCount >= (sqlite3_int64)kIMPMaximumAuditRows) {
            IMPSetError(error, IMPAPIKeyStoreErrorConflict, @"The audit retention limit has been reached.");
            ok = NO;
        }
    }

    if (ok && !existingExact) {
        ok = IMPPrepare(_database,
                        "INSERT INTO audit_records"
                        "(request_uuid,key_uuid,target_key_uuid,source,action,phase,status,duration_ms,created_at) "
                        "VALUES(?,?,?,?,?,?,?,?,?)",
                        &statement, error) &&
             IMPBindText(statement, 1, normalizedRequestUUID, error);
        if (ok) {
            ok = normalizedKeyUUID == nil ? IMPBindNull(statement, 2, error)
                                          : IMPBindText(statement, 2, normalizedKeyUUID, error);
        }
        if (ok) {
            ok = normalizedTargetKeyUUID == nil ? IMPBindNull(statement, 3, error)
                                                : IMPBindText(statement, 3, normalizedTargetKeyUUID, error);
        }
        if (ok) {
            ok = IMPBindText(statement, 4, source, error) && IMPBindText(statement, 5, action, error) &&
                 IMPBindText(statement, 6, phaseString, error);
        }
        if (ok) {
            ok = status == nil ? IMPBindNull(statement, 7, error)
                               : IMPBindInteger(statement, 7, status.longLongValue, error);
        }
        if (ok) {
            ok = durationMilliseconds == nil ? IMPBindNull(statement, 8, error)
                                             : IMPBindInteger(statement, 8, durationMilliseconds.longLongValue, error);
        }
        if (ok) {
            ok = IMPBindInteger(statement, 9, IMPMillisecondsForDate(NSDate.date), error);
        }
        if (ok) {
            int result = sqlite3_step(statement);
            if (result != SQLITE_DONE) {
                ok = IMPSetSQLiteError(error, result);
            }
        }
        if (statement != NULL) {
            int finalResult = sqlite3_finalize(statement);
            statement = NULL;
            if (ok && finalResult != SQLITE_OK) {
                ok = IMPSetSQLiteError(error, finalResult);
            }
        }
    }
    if (ok) {
        ok = IMPCommit(_database, error);
    }
    if (!ok) {
        IMPRollback(_database);
    }
    IMPTightenSidecarModes(_path);
    [_lock unlock];
    return ok;
}

- (NSArray<IMPAuditRecord *> *)auditRecordsWithLimit:(NSUInteger)limit error:(NSError **)error {
    if (limit == 0 || limit > 1000) {
        IMPSetError(error, IMPAPIKeyStoreErrorInvalidArgument, @"The audit record limit is invalid.");
        return nil;
    }
    [_lock lock];
    sqlite3_stmt *statement = NULL;
    NSMutableArray<IMPAuditRecord *> *records = [NSMutableArray array];
    BOOL ok =
        IMPPrepare(_database,
                   "SELECT request_uuid,key_uuid,target_key_uuid,source,action,phase,status,duration_ms,created_at "
                   "FROM audit_records ORDER BY created_at DESC,request_uuid DESC,phase DESC LIMIT ?",
                   &statement, error) &&
        IMPBindInteger(statement, 1, (sqlite3_int64)limit, error);
    if (ok) {
        int result = SQLITE_ROW;
        while ((result = sqlite3_step(statement)) == SQLITE_ROW) {
            NSString *requestUUID = IMPColumnString(statement, 0);
            NSString *keyUUID = IMPColumnString(statement, 1);
            NSString *targetKeyUUID = IMPColumnString(statement, 2);
            NSString *source = IMPColumnString(statement, 3);
            NSString *action = IMPColumnString(statement, 4);
            IMPAuditPhase phase = IMPAuditPhaseFromString(IMPColumnString(statement, 5));
            NSNumber *status =
                sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : @(sqlite3_column_int64(statement, 6));
            NSNumber *duration =
                sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : @(sqlite3_column_int64(statement, 7));
            sqlite3_int64 createdMilliseconds = sqlite3_column_int64(statement, 8);
            BOOL phaseShapeValid = phase == IMPAuditPhaseAttempted
                                       ? (status == nil && duration == nil)
                                       : (phase == IMPAuditPhaseFinal && status != nil && duration != nil &&
                                          IMPNumberIsIntegerInRange(status, 100, 599) &&
                                          IMPNumberIsIntegerInRange(duration, 0, LLONG_MAX));
            if ([[NSUUID alloc] initWithUUIDString:requestUUID] == nil ||
                (keyUUID != nil && [[NSUUID alloc] initWithUUIDString:keyUUID] == nil) ||
                (targetKeyUUID != nil && [[NSUUID alloc] initWithUUIDString:targetKeyUUID] == nil) ||
                !IMPValidateAuditAction(action, NULL) || !IMPValidateAuditSource(source, NULL) || !phaseShapeValid ||
                sqlite3_column_type(statement, 8) == SQLITE_NULL || createdMilliseconds <= 0) {
                IMPSetError(error, IMPAPIKeyStoreErrorDatabaseCorrupt, @"An audit record is invalid.");
                ok = NO;
                break;
            }
            IMPAuditRecord *record =
                [[IMPAuditRecord alloc] initWithRequestUUID:requestUUID
                                                    keyUUID:keyUUID
                                              targetKeyUUID:targetKeyUUID
                                                     source:source
                                                     action:action
                                                      phase:phase
                                                     status:status
                                       durationMilliseconds:duration
                                                  createdAt:IMPDateForMilliseconds(createdMilliseconds)];
            [records addObject:record];
        }
        if (ok && result != SQLITE_DONE) {
            ok = IMPSetSQLiteError(error, result);
        }
    }
    if (statement != NULL) {
        int finalResult = sqlite3_finalize(statement);
        if (ok && finalResult != SQLITE_OK) {
            ok = IMPSetSQLiteError(error, finalResult);
        }
    }
    [_lock unlock];
    return ok ? records : nil;
}

@end
