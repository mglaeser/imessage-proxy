// Unit tests over the validation, encoding and digest functions in
// src/api-key-store.m. The source is #included whole rather than linked,
// because every function of interest here is file-static: they are the rules
// that decide what an API key name, a sender identifier, an idempotency key, an
// audit row and a bearer token may contain, and none of them is reachable from
// outside the translation unit. Including the file is what lets this suite test
// the exact text that ships rather than a copy that drifts from it.
//
// The shell suite exercises these rules through HTTP, which can only reach the
// values a request can carry and which reports every rejection as the same 400.
// Everything below is either a value the HTTP layer cannot express - an
// embedded NUL, a number one over a limit, a non-canonical base64 spelling that
// decodes to the right bytes - or an invariant between two places in the source
// that no end-to-end test can see at all, such as the audit action allowlist
// and the CHECK constraint that has to enumerate exactly the same actions.
//
// Nothing here opens a database, a socket or a file, and nothing reads the
// clock: the one date any of it needs is a fixed NSDate. A check belongs here
// only if it would have failed on a real bug.
//
// Every character outside printable ASCII is written as an escape, as it is
// everywhere in src/. Half the hostile inputs below are invisible on purpose -
// a right-to-left override, a zero-width space, a combining mark, an embedded
// NUL - and a source file that carried them literally would be unreviewable in
// exactly the way those characters are meant to exploit.

#import "imp-test.h"

#include "../../src/api-key-store.m"

// imp-test.h stops at the shapes every suite needs. These two are only
// meaningful for a store function, and both are macros rather than functions so
// that a failure names the line that made the call. The guards are here because
// either could reasonably graduate into imp-test.h later.
#ifndef IMP_ASSERT_EQ_OBJECT
#define IMP_ASSERT_EQ_OBJECT(actual, expected, ...)                                                                    \
    do {                                                                                                               \
        id impObserved = (actual);                                                                                     \
        id impWanted = (expected);                                                                                     \
        IMP_ASSERT(impObserved == impWanted || [impWanted isEqual:impObserved], @"%@ (expected %@, got %@)",           \
                   [NSString stringWithFormat:__VA_ARGS__], impWanted, impObserved);                                   \
    } while (0)
#endif

// The router turns InvalidArgument into a 400 and every other store code into a
// 5xx, so a validator that reported a caller's typo as a database failure would
// page somebody for a bad request.
#ifndef IMP_ASSERT_INVALID_ARGUMENT
#define IMP_ASSERT_INVALID_ARGUMENT(error, ...)                                                                        \
    do {                                                                                                               \
        NSError *impError = (error);                                                                                   \
        IMP_ASSERT(impError != nil && [impError.domain isEqualToString:IMPAPIKeyStoreErrorDomain] &&                   \
                       impError.code == IMPAPIKeyStoreErrorInvalidArgument,                                            \
                   @"%@ (got %@)", [NSString stringWithFormat:__VA_ARGS__], impError);                                 \
    } while (0)
#endif

// Returns nil through an opaque call. Several functions under test carry
// _Nonnull annotations that make a literal nil a compile error, but nothing
// between a JSON request body and those functions enforces the annotation at
// run time, so nil is a value they really do receive.
static id NilValue(void) { return nil; }

// Repeats a single-unit string, which is how every length boundary below is
// built. Only characters that occupy one UTF-16 unit may be passed, because
// padding counts units and would otherwise cut a surrogate pair in half.
static NSString *RepeatedString(NSString *unit, NSUInteger count) {
    return [@"" stringByPaddingToLength:count withString:unit startingAtIndex:0];
}

// Pulls the single-quoted literals out of a CHECK(<column> IN (...)) clause of
// one of the DDL strings. Three allowlists in this file are written out twice,
// once in a validator and once in SQL, and reading the second one back is the
// only way to know they still agree.
static NSArray<NSString *> *QuotedLiterals(NSString *ddl, NSString *marker) {
    NSRange start = [ddl rangeOfString:marker];
    if (start.location == NSNotFound) {
        return nil;
    }
    NSString *rest = [ddl substringFromIndex:NSMaxRange(start)];
    NSRange end = [rest rangeOfString:@"))"];
    if (end.location == NSNotFound) {
        return nil;
    }
    NSArray<NSString *> *parts = [[rest substringToIndex:end.location] componentsSeparatedByString:@"'"];
    NSMutableArray<NSString *> *literals = [NSMutableArray array];
    for (NSUInteger index = 1; index < parts.count; index += 2) {
        [literals addObject:parts[index]];
    }
    return literals;
}

// The 32 bytes 0x00 through 0x1f, used as key material wherever a token has to
// be built. A fixed buffer rather than a random one, so that the encoded payload
// can be written out in full below and checked by eye.
static NSData *KeyMaterial(void) {
    uint8_t bytes[32];
    for (NSUInteger index = 0; index < sizeof(bytes); index++) {
        bytes[index] = (uint8_t)index;
    }
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

// Records are built directly rather than read back from a statement, because
// the authorization decision depends on nothing but the scopes array.
static IMPAPIKeyRecord *RecordWithScopes(NSArray<IMPAPIKeyScope> *scopes) {
    NSDate *fixed = [NSDate dateWithTimeIntervalSince1970:1700000000];
    return [[IMPAPIKeyRecord alloc] initWithUUID:@"6f9619ff-8b86-d011-b42d-00c04fc964ff"
                                            name:@"ops"
                                       keyPrefix:@"imp_aaaaaaaa"
                                          scopes:scopes
                                senderIdentifier:@"ops"
                        senderIdentifierAssigned:NO
                                       createdAt:fixed
                                       expiresAt:nil
                                       revokedAt:nil
                                      lastUsedAt:nil];
}

IMP_TEST(sha256_matches_the_published_vectors) {
    // These come first because the key hash the whole authentication path
    // compares, the request hash the idempotency table keys on and the schema
    // fingerprint that decides whether the database opens at all are all this
    // one digest. If these two vectors are wrong nothing downstream is worth
    // reading, and on Linux they are also the only proof that the vendored
    // CommonCrypto shim is a SHA-256 rather than something that merely returns
    // 32 bytes.
    IMP_ASSERT_DATA_HEX(IMPSHA256([NSData data]), @"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                        @"SHA-256 of the empty input must match FIPS 180-4");
    IMP_ASSERT_DATA_HEX(IMPSHA256([@"abc" dataUsingEncoding:NSUTF8StringEncoding]),
                        @"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                        @"SHA-256 of \"abc\" must match FIPS 180-4");

    // 56 bytes is the length at which the padding no longer fits in the block
    // that holds the message, so this is the vector that fails when an
    // implementation forgets the extra block.
    IMP_ASSERT_DATA_HEX(
        IMPSHA256([@"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" dataUsingEncoding:NSUTF8StringEncoding]),
        @"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        @"SHA-256 of the 448-bit FIPS 180-4 vector must match");

    // One million 'a' characters. The message length is encoded in the last
    // eight bytes of the final block as a bit count, and an implementation that
    // wrote a byte count or truncated that count to 32 bits produces the wrong
    // digest only once the message is large - which is the size a stored
    // response body reaches, not the size a key does.
    NSMutableData *million = [NSMutableData dataWithLength:1000000];
    memset(million.mutableBytes, 'a', million.length);
    IMP_ASSERT_DATA_HEX(IMPSHA256(million), @"cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
                        @"SHA-256 of one million 'a' characters must match FIPS 180-4");

    IMP_ASSERT_EQ_INT(IMPSHA256([@"abc" dataUsingEncoding:NSUTF8StringEncoding]).length, 32,
                      @"a digest must be 32 bytes, which is the length the key_hash column CHECK requires");
}

IMP_TEST(sha256_for_data_substitutes_the_empty_input_for_nil) {
    // The substitution has to be the digest of nothing rather than a zeroed
    // buffer or a crash: a caller that hashed a nil body and got 32 zero bytes
    // would share a request hash with every other caller that did the same, and
    // the idempotency table would replay one caller's response to another.
    IMP_ASSERT_DATA_HEX([IMPAPIKeyStore SHA256ForData:NilValue()],
                        @"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                        @"+SHA256ForData: must treat nil as the empty input");
    IMP_ASSERT_DATA_HEX([IMPAPIKeyStore SHA256ForData:[@"abc" dataUsingEncoding:NSUTF8StringEncoding]],
                        @"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                        @"+SHA256ForData: must agree with the function it wraps");
}

IMP_TEST(base64url_encodes_without_padding_or_standard_punctuation) {
    IMP_ASSERT_EQ_STR(IMPBase64URLEncode([NSMutableData dataWithLength:32]), RepeatedString(@"A", 43),
                      @"32 zero bytes must encode to 43 'A' characters with no padding");

    NSMutableData *ones = [NSMutableData dataWithLength:32];
    memset(ones.mutableBytes, 0xFF, ones.length);
    IMP_ASSERT_EQ_STR(IMPBase64URLEncode(ones), @"__________________________________________8",
                      @"32 0xFF bytes must encode to the base64url spelling rather than the standard one");

    // 0xfb 0xff 0xbf is the byte sequence standard base64 spells with both '+'
    // and '/'. A token carrying either would be refused by the alphabet check in
    // IMPDecodeToken, so an encoder that stopped translating them would issue
    // keys that could never be presented again.
    uint8_t mixed[32] = {0xfb, 0xff, 0xbf};
    NSString *encoded = IMPBase64URLEncode([NSData dataWithBytes:mixed length:sizeof(mixed)]);
    IMP_ASSERT_EQ_STR(encoded, @"-_-_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                      @"bytes that standard base64 spells with '+' and '/' must encode to '-' and '_'");
    IMP_ASSERT_EQ_INT([encoded rangeOfString:@"+"].location, NSNotFound, @"an encoded payload must never contain '+'");
    IMP_ASSERT_EQ_INT([encoded rangeOfString:@"/"].location, NSNotFound, @"an encoded payload must never contain '/'");
    IMP_ASSERT_EQ_INT([encoded rangeOfString:@"="].location, NSNotFound,
                      @"an encoded payload must never carry base64 padding");
}

IMP_TEST(token_length_matches_the_configured_key_material_length) {
    // IMPDecodeToken hard-codes the token length as 47 while the key material
    // length is a named constant. The two agree only by arithmetic, so raising
    // kIMPRawKeyLength without touching the length gate would make every newly
    // issued key fail its own decode - and the failure would arrive at the first
    // authentication rather than at the creation that caused it.
    IMP_ASSERT_EQ_INT(IMPBase64URLEncode([NSMutableData dataWithLength:kIMPRawKeyLength]).length + 4, 47,
                      @"the token length gate must match the configured key material length");
    // The prefix stored beside the hash is "imp_" plus the first eight payload
    // characters, and the column requires exactly those twelve.
    IMP_ASSERT_TRUE([@(kIMPAPIKeysDDL) rangeOfString:@"length(key_prefix)=12"].location != NSNotFound,
                    @"the key prefix column must still require the twelve characters the create path writes");
}

IMP_TEST(decode_token_accepts_only_a_canonical_47_character_token) {
    NSData *raw = KeyMaterial();
    NSString *payload = IMPBase64URLEncode(raw);
    NSString *token = [@"imp_" stringByAppendingString:payload];

    IMP_ASSERT_EQ_INT(token.length, 47, @"a well-formed token must be 47 characters");
    IMP_ASSERT_DATA_HEX(IMPDecodeToken(token), @"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
                        @"a well-formed token must decode to exactly the bytes that were encoded");

    // One character short and one character long. The length gate is the only
    // thing standing between the base64 decoder and a payload that decodes to a
    // different number of bytes.
    IMP_ASSERT_NIL(IMPDecodeToken([token substringToIndex:46]), @"a 46-character token must be refused");
    IMP_ASSERT_NIL(IMPDecodeToken([token stringByAppendingString:@"A"]), @"a 48-character token must be refused");

    // The prefix is four characters and is compared case-sensitively, so both a
    // shouted prefix and a one-letter typo have to fail rather than fall through
    // to a substring that happens to decode.
    IMP_ASSERT_NIL(IMPDecodeToken([@"IMP_" stringByAppendingString:payload]), @"an upper-case prefix must be refused");
    IMP_ASSERT_NIL(IMPDecodeToken([@"imq_" stringByAppendingString:payload]), @"a misspelled prefix must be refused");
    IMP_ASSERT_NIL(IMPDecodeToken(RepeatedString(@"A", 47)), @"a token with no prefix at all must be refused");

    // Standard base64 punctuation inside the payload. Accepting it would give
    // two spellings of one key, and only one of them is what the key prefix
    // column was indexed under.
    NSMutableString *withPlus = [payload mutableCopy];
    [withPlus replaceCharactersInRange:NSMakeRange(0, 1) withString:@"+"];
    IMP_ASSERT_NIL(IMPDecodeToken([@"imp_" stringByAppendingString:withPlus]), @"a '+' in the payload must be refused");
    NSMutableString *withSlash = [payload mutableCopy];
    [withSlash replaceCharactersInRange:NSMakeRange(0, 1) withString:@"/"];
    IMP_ASSERT_NIL(IMPDecodeToken([@"imp_" stringByAppendingString:withSlash]),
                   @"a '/' in the payload must be refused");
    NSMutableString *withPadding = [payload mutableCopy];
    [withPadding replaceCharactersInRange:NSMakeRange(42, 1) withString:@"="];
    IMP_ASSERT_NIL(IMPDecodeToken([@"imp_" stringByAppendingString:withPadding]),
                   @"a '=' in the payload must be refused");

    // A non-ASCII character inside an otherwise correctly sized payload. The
    // alphabet check walks UTF-16 units, so a character ordered above 'z' must
    // not slip past a range comparison.
    NSMutableString *withAccent = [payload mutableCopy];
    [withAccent replaceCharactersInRange:NSMakeRange(5, 1) withString:@"\u00e9"];
    IMP_ASSERT_NIL(IMPDecodeToken([@"imp_" stringByAppendingString:withAccent]),
                   @"a non-ASCII character in the payload must be refused");
}

IMP_TEST(decode_token_refuses_a_non_canonical_payload_tail) {
    NSData *raw = KeyMaterial();
    NSString *payload = IMPBase64URLEncode(raw);

    // The last character of a 43-character payload carries four data bits and
    // two bits that must be zero. '8', '9', '-' and '_' share the same four data
    // bits, so all four decode to identical 32 bytes and only '8' is canonical.
    // Without the re-encode comparison every issued key would have four
    // presentable forms, three of which no key prefix lookup would ever find -
    // and any revocation keyed on that prefix would miss them.
    IMP_ASSERT_EQ_STR([payload substringFromIndex:42], @"8",
                      @"the fixture payload must end in the canonical spelling of its final four data bits");
    for (NSString *tail in @[@"9", @"-", @"_"]) {
        NSMutableString *nonCanonical = [payload mutableCopy];
        [nonCanonical replaceCharactersInRange:NSMakeRange(42, 1) withString:tail];
        NSString *base64 = [[nonCanonical stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
            stringByReplacingOccurrencesOfString:@"_"
                                      withString:@"/"];
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:[base64 stringByAppendingString:@"="] options:0];
        IMP_ASSERT_EQ_OBJECT(decoded, raw,
                             @"a '%@' tail must really decode to the same 32 bytes, or this test pins nothing", tail);
        IMP_ASSERT_NIL(IMPDecodeToken([@"imp_" stringByAppendingString:nonCanonical]),
                       @"a non-canonical '%@' tail must be refused", tail);
    }
}

IMP_TEST(decode_token_refuses_a_value_that_is_not_a_token) {
    IMP_ASSERT_NIL(IMPDecodeToken(NilValue()), @"a nil token must be refused rather than crashing");
    IMP_ASSERT_NIL(IMPDecodeToken((NSString *)@42),
                   @"a number where a token belongs must be refused rather than crashing");
    IMP_ASSERT_NIL(IMPDecodeToken((NSString *)KeyMaterial()),
                   @"an NSData where a token belongs must be refused rather than crashing");
    IMP_ASSERT_NIL(IMPDecodeToken(@""), @"an empty token must be refused");
    IMP_ASSERT_NIL(IMPDecodeToken(@"imp_"), @"a bare prefix must be refused");
}

IMP_TEST(constant_time_equal_compares_whole_buffers) {
    uint8_t pattern[32];
    memset(pattern, 0x5a, sizeof(pattern));
    NSData *reference = [NSData dataWithBytes:pattern length:sizeof(pattern)];

    IMP_ASSERT_TRUE(IMPConstantTimeEqual(reference, [reference copy]),
                    @"two identical 32-byte digests must compare equal");

    // The first and the last byte are checked separately because the two ways to
    // get this wrong are opposites: a comparison that stopped at the first
    // difference would still catch a first-byte change while leaking the match
    // length by timing, and one that only accumulated the tail would miss a
    // first-byte change outright.
    uint8_t firstDiffers[32];
    memcpy(firstDiffers, pattern, sizeof(pattern));
    firstDiffers[0] ^= 0x01;
    IMP_ASSERT_FALSE(IMPConstantTimeEqual(reference, [NSData dataWithBytes:firstDiffers length:sizeof(firstDiffers)]),
                     @"a single flipped bit in the first byte must compare unequal");
    uint8_t lastDiffers[32];
    memcpy(lastDiffers, pattern, sizeof(pattern));
    lastDiffers[31] ^= 0x80;
    IMP_ASSERT_FALSE(IMPConstantTimeEqual(reference, [NSData dataWithBytes:lastDiffers length:sizeof(lastDiffers)]),
                     @"a single flipped bit in the last byte must compare unequal");

    // A 31-byte candidate against a 32-byte stored digest. The length gate is
    // what keeps the loop inside both buffers; without it this reads one byte
    // past the end of the shorter one.
    IMP_ASSERT_FALSE(IMPConstantTimeEqual([reference subdataWithRange:NSMakeRange(0, 31)], reference),
                     @"a candidate one byte short must compare unequal");
    IMP_ASSERT_FALSE(IMPConstantTimeEqual(reference, [reference subdataWithRange:NSMakeRange(0, 31)]),
                     @"a stored digest one byte short must compare unequal");

    IMP_ASSERT_TRUE(IMPConstantTimeEqual([NSData data], [NSData data]), @"two empty buffers must compare equal");
    // nil has length zero, so nil against a real digest is a length mismatch and
    // nil against nil is a match. The second is only safe because both call
    // sites check the stored digest's length before they get here; pinned so
    // that any change to the nil handling is a deliberate one.
    IMP_ASSERT_FALSE(IMPConstantTimeEqual(NilValue(), reference), @"nil must never match a 32-byte digest");
    IMP_ASSERT_FALSE(IMPConstantTimeEqual(reference, NilValue()), @"a 32-byte digest must never match nil");
    IMP_ASSERT_TRUE(IMPConstantTimeEqual(NilValue(), NilValue()),
                    @"two nil buffers compare equal, both being zero length");
}

IMP_TEST(validate_name_trims_and_bounds_by_utf8_bytes) {
    NSString *normalized = nil;
    NSError *error = nil;

    IMP_ASSERT_TRUE(IMPValidateName(@"  ops key  ", &normalized, &error), @"a padded name must be accepted");
    IMP_ASSERT_EQ_STR(normalized, @"ops key", @"a name must be stored with its surrounding whitespace removed");
    IMP_ASSERT_NIL(error, @"an accepted name must leave the error untouched");

    // IMPRecordFromStatement re-validates the stored name and demands the result
    // equal what is in the row, so normalization has to be a fixed point.
    // Anything else makes every existing row unreadable the day it changes, and
    // the symptom is a key that stops authenticating with nothing in the audit
    // log to say why.
    NSString *renormalized = nil;
    IMP_ASSERT_TRUE(IMPValidateName(normalized, &renormalized, NULL),
                    @"an already normalized name must be accepted again");
    IMP_ASSERT_EQ_STR(renormalized, normalized, @"normalizing a normalized name must leave it unchanged");

    // The limit is 80 UTF-8 bytes applied after trimming. Counting before
    // trimming would refuse a name whose length the caller cannot see, and
    // counting UTF-16 units would let a name through that the column's
    // CHECK(length(CAST(name AS BLOB)) BETWEEN 1 AND 80) then refuses - which
    // surfaces as a 5xx on a request that deserved a 400.
    IMP_ASSERT_TRUE(IMPValidateName(RepeatedString(@"a", 80), NULL, NULL),
                    @"a name of exactly 80 bytes must be accepted");
    IMP_ASSERT_FALSE(IMPValidateName(RepeatedString(@"a", 81), NULL, NULL), @"a name of 81 bytes must be refused");
    IMP_ASSERT_TRUE(IMPValidateName([NSString stringWithFormat:@"   %@   ", RepeatedString(@"a", 80)], NULL, NULL),
                    @"80 bytes surrounded by whitespace must be accepted, the limit being applied after trimming");
    IMP_ASSERT_TRUE(IMPValidateName(RepeatedString(@"\u00e9", 40), NULL, NULL),
                    @"40 two-byte characters must be accepted, being exactly 80 bytes");
    IMP_ASSERT_FALSE(IMPValidateName(RepeatedString(@"\u00e9", 41), NULL, NULL),
                     @"41 two-byte characters must be refused, being 82 bytes");
    IMP_ASSERT_EQ_INT(kIMPMaximumNameBytes, 80, @"the name limit must still be the 80 bytes the column CHECK enforces");
    IMP_ASSERT_TRUE([@(kIMPAPIKeysDDL) rangeOfString:@"length(CAST(name AS BLOB)) BETWEEN 1 AND 80"].location !=
                        NSNotFound,
                    @"the name column must still enforce the same 80-byte bound the validator applies");

    IMP_ASSERT_FALSE(IMPValidateName(@"", NULL, NULL), @"an empty name must be refused");
    IMP_ASSERT_FALSE(IMPValidateName(@"      ", NULL, NULL), @"a name of only whitespace must be refused");
    IMP_ASSERT_FALSE(IMPValidateName(@"\t\n ", NULL, NULL), @"a name of only whitespace and newlines must be refused");

    // The out-parameter has to be left alone when the name is refused: a caller
    // that checked the return value second would otherwise store the sentinel.
    NSString *untouched = @"sentinel";
    IMP_ASSERT_FALSE(IMPValidateName(@"", &untouched, NULL),
                     @"an empty name must still be refused with an out-pointer");
    IMP_ASSERT_EQ_STR(untouched, @"sentinel", @"a refused name must not write through the out-pointer");
    IMP_ASSERT_TRUE(IMPValidateName(@"ops", NULL, NULL), @"a valid name must be accepted with no out-pointer at all");
}

IMP_TEST(validate_name_refuses_control_characters) {
    // The name is rendered in the console and read beside every audit row the
    // key produces. A newline in it forges a log line, and a NUL truncates the
    // name at the first C string boundary it reaches, so the value the operator
    // reads is not the value that was stored.
    IMP_ASSERT_FALSE(IMPValidateName(@"a\nb", NULL, NULL), @"a name containing a newline must be refused");
    IMP_ASSERT_FALSE(IMPValidateName(@"a\rb", NULL, NULL), @"a name containing a carriage return must be refused");
    IMP_ASSERT_FALSE(IMPValidateName(@"a\r\nb", NULL, NULL), @"a name containing a CRLF must be refused");
    IMP_ASSERT_FALSE(IMPValidateName(@"a\tb", NULL, NULL), @"a name containing an embedded tab must be refused");
    IMP_ASSERT_FALSE(IMPValidateName(@"a\0b", NULL, NULL), @"a name containing an embedded NUL must be refused");
    IMP_ASSERT_FALSE(IMPValidateName(@"a\177b", NULL, NULL), @"a name containing DEL must be refused");
    IMP_ASSERT_FALSE(IMPValidateName(@"a\u202eb", NULL, NULL),
                     @"a name containing a right-to-left override must be refused as a format character");
    IMP_ASSERT_FALSE(IMPValidateName(@"a\u200bb", NULL, NULL),
                     @"a name containing a zero-width space must be refused as a format character");

    // Documented accepts. Neither is a control character nor over the byte
    // limit, so both are stored exactly as written; pinned so that anyone
    // tightening the rule can see what it does to names already in the field.
    IMP_ASSERT_TRUE(IMPValidateName(@"\U0001F600", NULL, NULL),
                    @"a four-byte astral character must be accepted in a name");
    NSString *decomposed = nil;
    IMP_ASSERT_TRUE(IMPValidateName(@"e\u0301", &decomposed, NULL), @"a decomposed name must be accepted");
    IMP_ASSERT_EQ_INT(decomposed.length, 2, @"a decomposed name must be stored without Unicode normalization");
}

IMP_TEST(validate_name_refuses_a_value_that_is_not_a_string) {
    NSError *error = nil;
    IMP_ASSERT_FALSE(IMPValidateName(NilValue(), NULL, &error), @"a nil name must be refused rather than crashing");
    IMP_ASSERT_INVALID_ARGUMENT(error, @"a nil name must be reported as an invalid argument");
    error = nil;
    IMP_ASSERT_FALSE(IMPValidateName((NSString *)@42, NULL, &error), @"a number where a name belongs must be refused");
    IMP_ASSERT_INVALID_ARGUMENT(error, @"a non-string name must be reported as an invalid argument");
    IMP_ASSERT_FALSE(IMPValidateName((NSString *)NSNull.null, NULL, NULL),
                     @"the JSON null placeholder where a name belongs must be refused");
}

IMP_TEST(validate_sender_identifier_folds_case) {
    NSString *normalized = nil;
    NSError *error = nil;

    IMP_ASSERT_TRUE(IMPValidateSenderIdentifier(@"kle", &normalized, &error),
                    @"a three-letter identifier must be accepted");
    IMP_ASSERT_EQ_STR(normalized, @"kle", @"an already lower-case identifier must be unchanged");
    IMP_ASSERT_NIL(error, @"an accepted identifier must leave the error untouched");

    // Case is normalized rather than refused. If it were not, "KLE" and "kle"
    // would be two different keys whose messages read identically to whoever
    // receives them, which is the one thing the identifier exists to prevent.
    IMP_ASSERT_TRUE(IMPValidateSenderIdentifier(@"KLE", &normalized, NULL),
                    @"an upper-case identifier must be accepted");
    IMP_ASSERT_EQ_STR(normalized, @"kle", @"an upper-case identifier must be folded to lower case");
    IMP_ASSERT_TRUE(IMPValidateSenderIdentifier(@"Ab", &normalized, NULL), @"a mixed-case identifier must be accepted");
    IMP_ASSERT_EQ_STR(normalized, @"ab", @"a mixed-case identifier must be folded to lower case");

    NSString *untouched = @"sentinel";
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier(@"a", &untouched, NULL),
                     @"a one-letter identifier must be refused with an out-pointer");
    IMP_ASSERT_EQ_STR(untouched, @"sentinel", @"a refused identifier must not write through the out-pointer");
}

IMP_TEST(validate_sender_identifier_bounds_and_alphabet_match_the_column) {
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier(@"a", NULL, NULL), @"a one-letter identifier must be refused");
    IMP_ASSERT_TRUE(IMPValidateSenderIdentifier(@"ab", NULL, NULL), @"a two-letter identifier must be accepted");
    IMP_ASSERT_TRUE(IMPValidateSenderIdentifier(@"abcdefgh", NULL, NULL),
                    @"an eight-letter identifier must be accepted");
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier(@"abcdefghi", NULL, NULL),
                     @"a nine-letter identifier must be refused");
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier(@"", NULL, NULL), @"an empty identifier must be refused");

    // The column is UNIQUE and its CHECK repeats the rule in SQL. A validator
    // looser than the constraint turns a caller's bad input into a failed insert
    // and a 5xx; a tighter one refuses identifiers that existing rows already
    // hold, which makes those keys unreadable.
    IMP_ASSERT_EQ_INT(kIMPMinimumSenderIdentifierLength, 2, @"the identifier minimum must still be two");
    IMP_ASSERT_EQ_INT(kIMPMaximumSenderIdentifierLength, 8, @"the identifier maximum must still be eight");
    NSString *expectedCheck = [NSString stringWithFormat:@"length(sender_identifier) BETWEEN %lu AND %lu",
                                                         (unsigned long)kIMPMinimumSenderIdentifierLength,
                                                         (unsigned long)kIMPMaximumSenderIdentifierLength];
    IMP_ASSERT_TRUE([@(kIMPAPIKeysDDL) rangeOfString:expectedCheck].location != NSNotFound,
                    @"the identifier column CHECK must enforce the same length bounds as the validator");
    IMP_ASSERT_TRUE([@(kIMPAPIKeysDDL) rangeOfString:@"NOT sender_identifier GLOB '*[^a-z]*'"].location != NSNotFound,
                    @"the identifier column CHECK must enforce the same roman-letters-only alphabet");

    // The first administrator is given this identifier before any caller can
    // choose one, so a change that made the constant and the rule disagree would
    // fail every fresh installation at bootstrap - the one moment an operator
    // has no working key to investigate with.
    IMP_ASSERT_TRUE(IMPValidateSenderIdentifier(kIMPBootstrapSenderIdentifier, NULL, NULL),
                    @"the bootstrap administrator's identifier must pass the validator");
}

IMP_TEST(validate_sender_identifier_refuses_confusable_letters) {
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier(@"ab1", NULL, NULL), @"a digit in an identifier must be refused");
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier(@"a-b", NULL, NULL), @"a hyphen in an identifier must be refused");
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier(@"a b", NULL, NULL), @"a space in an identifier must be refused");
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier(@" ab ", NULL, NULL),
                     @"an identifier is not trimmed, so surrounding whitespace must be refused");
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier(@"a\nb", NULL, NULL), @"a newline in an identifier must be refused");
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier(@"a\0b", NULL, NULL),
                     @"an embedded NUL in an identifier must be refused");

    // Everything below looks like roman letters and is not. The identifier is
    // appended to real outgoing messages, and the SMS transport re-encodes
    // anything outside the GSM alphabet, so a Cyrillic 'a' arrives as mojibake
    // on the one transport nobody can inspect afterwards.
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier(@"ab\u00e7", NULL, NULL),
                     @"a cedilla in an identifier must be refused");
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier(@"\u0430b", NULL, NULL),
                     @"a Cyrillic letter that renders as 'a' must be refused");
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier(@"\uff21\uff22", NULL, NULL),
                     @"full-width latin letters must be refused even though case folding leaves them looking valid");
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier(@"e\u0301b", NULL, NULL),
                     @"a combining mark in an identifier must be refused");

    NSError *error = nil;
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier(NilValue(), NULL, &error),
                     @"a nil identifier must be refused rather than crashing");
    IMP_ASSERT_INVALID_ARGUMENT(error, @"a nil identifier must be reported as an invalid argument");
    error = nil;
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier((NSString *)@42, NULL, &error),
                     @"a number where an identifier belongs must be refused");
    IMP_ASSERT_INVALID_ARGUMENT(error, @"a non-string identifier must be reported as an invalid argument");
}

IMP_TEST(validate_idempotency_key_bounds_by_utf8_bytes) {
    NSError *error = nil;
    IMP_ASSERT_TRUE(IMPValidateIdempotencyKey(@"abcdefgh", &error), @"an eight-character key must be accepted");
    IMP_ASSERT_NIL(error, @"an accepted idempotency key must leave the error untouched");

    // Eight bytes at the bottom and 128 at the top, matching the CHECK on the
    // idempotency_key column. A key one byte over that reached the insert would
    // be reported as a database failure on a send that had already been
    // accepted, and the caller would retry a send that did happen.
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(RepeatedString(@"a", 7), NULL), @"a seven-byte key must be refused");
    IMP_ASSERT_TRUE(IMPValidateIdempotencyKey(RepeatedString(@"a", 8), NULL), @"an eight-byte key must be accepted");
    IMP_ASSERT_TRUE(IMPValidateIdempotencyKey(RepeatedString(@"a", 128), NULL), @"a 128-byte key must be accepted");
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(RepeatedString(@"a", 129), NULL), @"a 129-byte key must be refused");
    IMP_ASSERT_EQ_INT(kIMPMaximumIdempotencyKeyBytes, 128,
                      @"the idempotency key limit must still be the 128 the column CHECK enforces");

    // 43 three-byte characters are 43 characters and 129 bytes. The limit is
    // counted in bytes, so this is refused twice over; a character count would
    // have let the length gate pass it on to the alphabet check alone.
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(RepeatedString(@"\u3042", 43), NULL),
                     @"43 three-byte characters must be refused, being 129 bytes");
}

IMP_TEST(validate_idempotency_key_restricts_the_alphabet) {
    IMP_ASSERT_TRUE(IMPValidateIdempotencyKey(@"abcdefg~", NULL),
                    @"a tilde must be accepted, being unreserved in RFC 3986");
    IMP_ASSERT_TRUE(IMPValidateIdempotencyKey(@"a.b_c-d~", NULL),
                    @"the full unreserved punctuation set must be accepted");
    IMP_ASSERT_TRUE(IMPValidateIdempotencyKey(@"ABCDEFGH", NULL),
                    @"an upper-case key must be accepted without being folded");
    IMP_ASSERT_TRUE(IMPValidateIdempotencyKey(@"01234567", NULL), @"a numeric key must be accepted");

    // Everything below would be a different key after any layer re-encoded it,
    // which is exactly the failure the idempotency table exists to prevent: two
    // spellings of one key are two rows, and the send happens twice.
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(@"abcdefg!", NULL), @"an exclamation mark must be refused");
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(@"abcdefg/", NULL), @"a slash must be refused");
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(@"abcdefg+", NULL), @"a plus sign must be refused");
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(@"abcdefg%20", NULL), @"a percent escape must be refused");
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(@"abcdef g", NULL), @"an embedded space must be refused");
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(@"abcdefg\n", NULL), @"a trailing newline must be refused");
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(@"abcdefg\r\n", NULL), @"a trailing CRLF must be refused");
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(@"abcdefg\t", NULL), @"an embedded tab must be refused");
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(@"abcdefg\0", NULL), @"an embedded NUL must be refused");
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(@"abcdefg\u202e", NULL), @"a right-to-left override must be refused");
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(@"abcdefg\U0001F600", NULL),
                     @"a four-byte astral character must be refused");
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(@"abcdefg\u00e9", NULL), @"a non-ASCII letter must be refused");
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(@"", NULL), @"an empty key must be refused");
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(@"        ", NULL), @"a key of only spaces must be refused");

    NSError *error = nil;
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey(NilValue(), &error), @"a nil key must be refused rather than crashing");
    IMP_ASSERT_INVALID_ARGUMENT(error, @"a nil idempotency key must be reported as an invalid argument");
    error = nil;
    IMP_ASSERT_FALSE(IMPValidateIdempotencyKey((NSString *)@42, &error),
                     @"a number where a key belongs must be refused");
    IMP_ASSERT_INVALID_ARGUMENT(error, @"a non-string idempotency key must be reported as an invalid argument");
}

IMP_TEST(validate_request_hash_requires_exactly_32_bytes) {
    // The request hash is compared byte for byte against the stored one to
    // decide whether a repeated idempotency key is a replay or a conflict. A
    // shorter buffer would make that comparison a length mismatch every time,
    // and every retry would come back as a 409 the caller cannot resolve.
    NSError *error = nil;
    IMP_ASSERT_TRUE(IMPValidateRequestHash([NSMutableData dataWithLength:32], &error),
                    @"a 32-byte request hash must be accepted");
    IMP_ASSERT_NIL(error, @"an accepted request hash must leave the error untouched");
    IMP_ASSERT_EQ_INT(kIMPRequestHashLength, 32, @"the request hash length must still be the 32 the column requires");
    IMP_ASSERT_FALSE(IMPValidateRequestHash([NSMutableData dataWithLength:31], NULL),
                     @"a 31-byte request hash must be refused");
    IMP_ASSERT_FALSE(IMPValidateRequestHash([NSMutableData dataWithLength:33], NULL),
                     @"a 33-byte request hash must be refused");
    IMP_ASSERT_FALSE(IMPValidateRequestHash([NSData data], NULL), @"an empty request hash must be refused");
    error = nil;
    IMP_ASSERT_FALSE(IMPValidateRequestHash(NilValue(), &error),
                     @"a nil request hash must be refused rather than crashing");
    IMP_ASSERT_INVALID_ARGUMENT(error, @"a nil request hash must be reported as an invalid argument");
    IMP_ASSERT_FALSE(IMPValidateRequestHash((NSData *)@"0123456789abcdef0123456789abcdef", NULL),
                     @"a 32-character string where 32 bytes belong must be refused");
}

IMP_TEST(validate_bootstrap_arguments_bounds_the_expiry) {
    // Four years counted in days including a leap day, so that "four years from
    // today" always validates rather than falling one day short in three years
    // out of four. The key created at bootstrap is the only credential a fresh
    // installation has, so an off-by-one here is discovered by an operator with
    // no other key to fix it with.
    IMP_ASSERT_EQ_INT(kIMPMaximumExpiryDays, 1461, @"the expiry maximum must still cover four years with a leap day");
    IMP_ASSERT_FALSE(IMPValidateBootstrapArguments(@"ops", 0, NULL, NULL), @"an expiry of zero days must be refused");
    IMP_ASSERT_TRUE(IMPValidateBootstrapArguments(@"ops", 1, NULL, NULL), @"an expiry of one day must be accepted");
    IMP_ASSERT_TRUE(IMPValidateBootstrapArguments(@"ops", kIMPMaximumExpiryDays - 1, NULL, NULL),
                    @"an expiry one day under the maximum must be accepted");
    IMP_ASSERT_TRUE(IMPValidateBootstrapArguments(@"ops", kIMPMaximumExpiryDays, NULL, NULL),
                    @"an expiry of exactly the maximum must be accepted");
    IMP_ASSERT_FALSE(IMPValidateBootstrapArguments(@"ops", kIMPMaximumExpiryDays + 1, NULL, NULL),
                     @"an expiry one day over the maximum must be refused");
    IMP_ASSERT_FALSE(IMPValidateBootstrapArguments(@"ops", NSUIntegerMax, NULL, NULL),
                     @"an expiry of NSUIntegerMax must be refused rather than wrapping");

    // The expiry is checked before the name, so the two have to be refused
    // independently rather than one masking the other.
    NSString *normalized = nil;
    IMP_ASSERT_TRUE(IMPValidateBootstrapArguments(@"  ops  ", 30, &normalized, NULL),
                    @"a valid expiry with a padded name must be accepted");
    IMP_ASSERT_EQ_STR(normalized, @"ops", @"bootstrap must normalize the name the way every other path does");
    IMP_ASSERT_FALSE(IMPValidateBootstrapArguments(@"", 30, NULL, NULL),
                     @"an empty name must be refused even with a valid expiry");
    IMP_ASSERT_FALSE(IMPValidateBootstrapArguments(@"", 0, NULL, NULL), @"both arguments wrong must still be refused");
}

IMP_TEST(validate_audit_action_matches_the_column_check) {
    // Written out rather than derived from the source, so that this list and the
    // CHECK constraint have to be edited together and a third copy cannot appear
    // between them.
    NSArray<NSString *> *actions = @[
        @"request.invalid", @"request.rate_limited", @"auth.unavailable", @"auth.rate_limited",
        @"auth.reject",     @"origin.reject",        @"route.not_found",  @"status.read",
        @"chats.list",      @"chats.read",           @"background.read",  @"messages.history",
        @"scheduled.list",  @"statistics.read",      @"messages.send",    @"keys.list",
        @"keys.read",       @"keys.create",          @"keys.revoke",      @"audit.list",
        @"targets.read",    @"targets.replace",      @"server.overloaded"
    ];

    for (NSString *action in actions) {
        IMP_ASSERT_TRUE(IMPValidateAuditAction(action, NULL), @"the audit action %@ must be accepted", action);
    }

    // An audit write happens on the way out of a request that has otherwise
    // succeeded. An action the validator accepts but the CHECK does not turns
    // that write into a constraint failure, and the caller is handed a 503 for a
    // request that already did what it asked.
    NSArray<NSString *> *ddlActions = QuotedLiterals(@(kIMPAuditRecordsDDL), @"CHECK(action IN (");
    IMP_ASSERT_NOT_NIL(ddlActions, @"the audit action CHECK constraint must still be where this invariant reads it");
    IMP_ASSERT_EQ_OBJECT([NSSet setWithArray:ddlActions ?: @[]], [NSSet setWithArray:actions],
                         @"the audit action allowlist and the column CHECK must enumerate the same actions");
    IMP_ASSERT_EQ_INT(ddlActions.count, actions.count, @"the audit action CHECK must list no action twice");

    IMP_ASSERT_FALSE(IMPValidateAuditAction(@"keys.delete", NULL),
                     @"an action that reads plausibly must still be refused");
    IMP_ASSERT_FALSE(IMPValidateAuditAction(@"KEYS.LIST", NULL), @"the allowlist must be case sensitive");
    IMP_ASSERT_FALSE(IMPValidateAuditAction(@"keys.list ", NULL),
                     @"an action must not be trimmed before it is matched");
    IMP_ASSERT_FALSE(IMPValidateAuditAction(@" keys.list", NULL), @"a leading space must defeat the match");
    IMP_ASSERT_FALSE(IMPValidateAuditAction(@"keys.list\n", NULL), @"a trailing newline must defeat the match");
    IMP_ASSERT_FALSE(IMPValidateAuditAction(@"keys", NULL), @"a prefix of an allowed action must be refused");
    IMP_ASSERT_FALSE(IMPValidateAuditAction(@"", NULL), @"an empty action must be refused");

    NSError *error = nil;
    IMP_ASSERT_FALSE(IMPValidateAuditAction(NilValue(), &error), @"a nil action must be refused rather than crashing");
    IMP_ASSERT_INVALID_ARGUMENT(error, @"a nil audit action must be reported as an invalid argument");
    error = nil;
    IMP_ASSERT_FALSE(IMPValidateAuditAction((NSString *)@42, &error),
                     @"a number where an action belongs must be refused");
    IMP_ASSERT_INVALID_ARGUMENT(error, @"a non-string audit action must be reported as an invalid argument");
}

IMP_TEST(validate_audit_source_accepts_an_alphabet_rather_than_an_address) {
    IMP_ASSERT_TRUE(IMPValidateAuditSource(@"local", NULL), @"the local sentinel must be accepted");
    IMP_ASSERT_TRUE(IMPValidateAuditSource(@"invalid", NULL), @"the unparseable-peer sentinel must be accepted");
    IMP_ASSERT_TRUE(IMPValidateAuditSource(@"127.0.0.1", NULL), @"an IPv4 address must be accepted");
    IMP_ASSERT_TRUE(IMPValidateAuditSource(@"::1", NULL), @"an IPv6 loopback address must be accepted");
    IMP_ASSERT_TRUE(IMPValidateAuditSource(@"fe80::1ff:fe23:4567:890a", NULL), @"a full IPv6 address must be accepted");

    // The rule is an alphabet, not an address parser: anything spelled out of
    // hexadecimal digits, ':' and '.' is accepted. Both of these are pinned so
    // that whoever tightens the rule can see they are changing what the audit
    // source column may already contain in the field.
    IMP_ASSERT_TRUE(IMPValidateAuditSource(@"deadbeef", NULL),
                    @"a hexadecimal word is accepted, the rule being an alphabet rather than an address parser");
    IMP_ASSERT_TRUE(IMPValidateAuditSource(@"...", NULL), @"a string of only dots is accepted");
    IMP_ASSERT_TRUE(IMPValidateAuditSource(@":", NULL), @"a lone colon is accepted");

    IMP_ASSERT_FALSE(IMPValidateAuditSource(@"example.com", NULL),
                     @"a hostname must be refused, its letters being outside a-f");
    IMP_ASSERT_FALSE(IMPValidateAuditSource(@"LOCAL", NULL), @"the sentinel comparison must be case sensitive");
    IMP_ASSERT_FALSE(IMPValidateAuditSource(@"local ", NULL),
                     @"a trailing space must defeat both the sentinel and the alphabet");
    IMP_ASSERT_FALSE(IMPValidateAuditSource(@"127.0.0.1\n", NULL), @"a trailing newline must be refused");
    IMP_ASSERT_FALSE(IMPValidateAuditSource(@"127.0.0.1\0", NULL), @"an embedded NUL must be refused");
    IMP_ASSERT_FALSE(IMPValidateAuditSource(@"::1%eth0", NULL), @"a zone identifier must be refused");
    IMP_ASSERT_FALSE(IMPValidateAuditSource(@"", NULL), @"an empty source must be refused");

    // 64 characters is the column's upper bound. One over would be accepted here
    // and refused by the database, on the audit write that follows a request
    // that already succeeded.
    IMP_ASSERT_TRUE(IMPValidateAuditSource(RepeatedString(@"a", 64), NULL), @"a 64-character source must be accepted");
    IMP_ASSERT_FALSE(IMPValidateAuditSource(RepeatedString(@"a", 65), NULL), @"a 65-character source must be refused");
    IMP_ASSERT_TRUE([@(kIMPAuditRecordsDDL) rangeOfString:@"length(source) BETWEEN 1 AND 64"].location != NSNotFound,
                    @"the source column CHECK must enforce the same length bounds as the validator");

    NSError *error = nil;
    IMP_ASSERT_FALSE(IMPValidateAuditSource(NilValue(), &error), @"a nil source must be refused rather than crashing");
    IMP_ASSERT_INVALID_ARGUMENT(error, @"a nil audit source must be reported as an invalid argument");
    error = nil;
    IMP_ASSERT_FALSE(IMPValidateAuditSource((NSString *)@42, &error),
                     @"a number where a source belongs must be refused");
    IMP_ASSERT_INVALID_ARGUMENT(error, @"a non-string audit source must be reported as an invalid argument");
}

IMP_TEST(normalize_scopes_produces_the_canonical_order) {
    NSError *error = nil;
    NSArray<IMPAPIKeyScope> *normalized =
        IMPNormalizeScopes(@[IMPAPIKeyScopeAdmin, IMPAPIKeyScopeMessagesRead], &error);
    IMP_ASSERT_EQ_OBJECT(normalized, (@[@"messages:read", @"admin"]),
                         @"scopes must come back in the canonical order rather than the order supplied");
    IMP_ASSERT_NIL(error, @"an accepted scope list must leave the error untouched");

    IMP_ASSERT_EQ_OBJECT(IMPNormalizeScopes(@[IMPAPIKeyScopeAdmin, IMPAPIKeyScopeAdmin], NULL), (@[@"admin"]),
                         @"a repeated scope must be collapsed to one");
    IMP_ASSERT_EQ_OBJECT(
        IMPNormalizeScopes(@[IMPAPIKeyScopeAdmin, IMPAPIKeyScopeMessagesSend, IMPAPIKeyScopeMessagesRead], NULL),
        (@[@"messages:read", @"messages:send", @"admin"]), @"all three scopes must come back in the canonical order");
}

IMP_TEST(normalize_scopes_covers_exactly_the_column_check) {
    // The joined result is compared against a set of seven string literals by
    // the scopes column CHECK, and ordering plus dedup are the only things that
    // make the comparison hold. Every reachable output is generated here and
    // matched against the constraint the database will apply, in both
    // directions: an output the CHECK refuses fails every key creation with that
    // scope set, and a literal nothing can produce is dead SQL hiding the
    // combination somebody meant to allow.
    NSArray<IMPAPIKeyScope> *everyScope =
        @[IMPAPIKeyScopeMessagesRead, IMPAPIKeyScopeMessagesSend, IMPAPIKeyScopeAdmin];
    NSMutableSet<NSString *> *reachable = [NSMutableSet set];
    for (NSUInteger mask = 1; mask < 8; mask++) {
        NSMutableArray<IMPAPIKeyScope> *requested = [NSMutableArray array];
        NSMutableArray<IMPAPIKeyScope> *reversed = [NSMutableArray array];
        for (NSUInteger bit = 0; bit < everyScope.count; bit++) {
            if ((mask & (1u << bit)) != 0) {
                [requested addObject:everyScope[bit]];
                [reversed insertObject:everyScope[bit] atIndex:0];
            }
        }
        NSArray<IMPAPIKeyScope> *fromRequested = IMPNormalizeScopes(requested, NULL);
        IMP_ASSERT_EQ_OBJECT(IMPNormalizeScopes(reversed, NULL), fromRequested,
                             @"scope subset %lu must normalize the same from either input order", (unsigned long)mask);
        [reachable addObject:[fromRequested componentsJoinedByString:@","]];
    }

    NSArray<NSString *> *ddlScopes = QuotedLiterals(@(kIMPAPIKeysDDL), @"CHECK(scopes IN (");
    IMP_ASSERT_NOT_NIL(ddlScopes, @"the scopes CHECK constraint must still be where this invariant reads it");
    IMP_ASSERT_EQ_OBJECT(reachable, [NSSet setWithArray:ddlScopes ?: @[]],
                         @"every reachable scope string must be one the column CHECK permits, and none unreachable");
    IMP_ASSERT_EQ_INT(reachable.count, 7, @"there must be seven non-empty scope combinations");
}

IMP_TEST(normalize_scopes_refuses_anything_outside_the_three) {
    NSError *error = nil;
    IMP_ASSERT_NIL(IMPNormalizeScopes(@[], &error), @"an empty scope list must be refused");
    IMP_ASSERT_INVALID_ARGUMENT(error, @"an empty scope list must be reported as an invalid argument");
    error = nil;
    IMP_ASSERT_NIL(IMPNormalizeScopes(@[@"messages:delete"], &error), @"an invented scope must be refused");
    IMP_ASSERT_INVALID_ARGUMENT(error, @"an invented scope must be reported as an invalid argument");

    IMP_ASSERT_NIL(IMPNormalizeScopes(@[@"messages:read", @"messages:delete"], NULL),
                   @"one invented scope must refuse the whole list rather than being dropped from it");
    IMP_ASSERT_NIL(IMPNormalizeScopes(@[@"MESSAGES:READ"], NULL), @"a scope must be matched case sensitively");
    IMP_ASSERT_NIL(IMPNormalizeScopes(@[@"messages:read "], NULL), @"a scope must not be trimmed before it is matched");
    IMP_ASSERT_NIL(IMPNormalizeScopes(@[@""], NULL), @"an empty scope string must be refused");
    IMP_ASSERT_NIL(IMPNormalizeScopes(@[@"messages:read,admin"], NULL),
                   @"the joined form is not itself a scope, so submitting it must be refused");
    IMP_ASSERT_NIL(IMPNormalizeScopes(@[(NSString *)@42], NULL), @"a number where a scope belongs must be refused");
    IMP_ASSERT_NIL(IMPNormalizeScopes(@[(NSString *)NSNull.null], NULL),
                   @"the JSON null placeholder where a scope belongs must be refused");
    IMP_ASSERT_NIL(IMPNormalizeScopes(NilValue(), NULL), @"a nil scope list must be refused rather than crashing");
    IMP_ASSERT_NIL(IMPNormalizeScopes((NSArray *)@"admin", NULL),
                   @"a bare string where an array belongs must be refused rather than enumerated");
    IMP_ASSERT_NIL(IMPNormalizeScopes((NSArray *)[NSSet setWithObject:@"admin"], NULL),
                   @"a set where an array belongs must be refused");
}

IMP_TEST(number_is_integer_in_range_refuses_json_booleans) {
    // A JSON boolean is an NSNumber whose value is 1, so nothing about its
    // numeric value distinguishes it from a real 1. Only the CoreFoundation type
    // identity does, and without that check a request body carrying true where a
    // duration belongs would be recorded as one millisecond.
    NSData *body = [@"{\"true\":true,\"false\":false,\"one\":1,\"zero\":0}" dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
    IMP_ASSERT_NOT_NIL(parsed, @"the JSON provenance fixture must parse, or the rest of this test pins nothing");

    IMP_ASSERT_FALSE(IMPNumberIsIntegerInRange(parsed[@"true"], 0, LLONG_MAX),
                     @"a boolean that came out of JSON must be refused where an integer belongs");
    IMP_ASSERT_FALSE(IMPNumberIsIntegerInRange(parsed[@"false"], 0, LLONG_MAX),
                     @"a false that came out of JSON must be refused where an integer belongs");
    IMP_ASSERT_TRUE(IMPNumberIsIntegerInRange(parsed[@"one"], 0, LLONG_MAX),
                    @"a 1 that came out of JSON must be accepted, so the rule is not refusing small integers");
    IMP_ASSERT_TRUE(IMPNumberIsIntegerInRange(parsed[@"zero"], 0, LLONG_MAX),
                    @"a 0 that came out of JSON must be accepted");
    IMP_ASSERT_FALSE(IMPNumberIsIntegerInRange(@YES, 0, LLONG_MAX),
                     @"a literal YES must be refused where an integer belongs");
    IMP_ASSERT_FALSE(IMPNumberIsIntegerInRange(@NO, 0, LLONG_MAX),
                     @"a literal NO must be refused where an integer belongs");
}

IMP_TEST(number_is_integer_in_range_bounds_the_audit_columns) {
    // The audit status column is CHECK(status BETWEEN 100 AND 599), so these
    // four values are the difference between a rejected argument and a failed
    // insert on the way out of a request that already succeeded.
    IMP_ASSERT_TRUE(IMPNumberIsIntegerInRange(@200, 100, 599), @"a plain HTTP status must be accepted");
    IMP_ASSERT_TRUE(IMPNumberIsIntegerInRange(@100, 100, 599), @"the lowest permitted status must be accepted");
    IMP_ASSERT_FALSE(IMPNumberIsIntegerInRange(@99, 100, 599),
                     @"one below the lowest permitted status must be refused");
    IMP_ASSERT_TRUE(IMPNumberIsIntegerInRange(@599, 100, 599), @"the highest permitted status must be accepted");
    IMP_ASSERT_FALSE(IMPNumberIsIntegerInRange(@600, 100, 599),
                     @"one above the highest permitted status must be refused");
    IMP_ASSERT_TRUE([@(kIMPAuditRecordsDDL) rangeOfString:@"status BETWEEN 100 AND 599"].location != NSNotFound,
                    @"the status column CHECK must still use the range this validator is called with");
    IMP_ASSERT_TRUE([@(kIMPAuditRecordsDDL) rangeOfString:@"duration_ms>=0"].location != NSNotFound,
                    @"the duration column CHECK must still refuse negative values");

    // A fractional value has to be refused rather than truncated: the column
    // would store the truncation and the caller would never learn that the
    // duration it reported is not the duration that was recorded.
    IMP_ASSERT_FALSE(IMPNumberIsIntegerInRange(@200.5, 100, 599), @"a fractional value must be refused");
    IMP_ASSERT_FALSE(IMPNumberIsIntegerInRange(@199.999, 100, 599), @"a value just under an integer must be refused");
    IMP_ASSERT_TRUE(IMPNumberIsIntegerInRange(@(200.0), 100, 599),
                    @"a whole number written as a double must be accepted");
    IMP_ASSERT_FALSE(IMPNumberIsIntegerInRange([NSDecimalNumber decimalNumberWithString:@"200.5"], 100, 599),
                     @"a fractional decimal must be refused");
    IMP_ASSERT_TRUE(IMPNumberIsIntegerInRange([NSDecimalNumber decimalNumberWithString:@"200"], 100, 599),
                    @"a whole decimal must be accepted");

    IMP_ASSERT_FALSE(IMPNumberIsIntegerInRange(@(-1), 0, LLONG_MAX), @"a negative duration must be refused");
    IMP_ASSERT_TRUE(IMPNumberIsIntegerInRange(@0, 0, LLONG_MAX), @"a zero duration must be accepted");
    IMP_ASSERT_TRUE(IMPNumberIsIntegerInRange(@(LLONG_MAX), 0, LLONG_MAX),
                    @"the largest signed 64-bit value must be accepted");
    IMP_ASSERT_TRUE(IMPNumberIsIntegerInRange(@(LLONG_MIN), LLONG_MIN, 0),
                    @"the smallest signed 64-bit value must be accepted");
    IMP_ASSERT_FALSE(IMPNumberIsIntegerInRange(@(1e30), 0, LLONG_MAX),
                     @"a value far beyond the 64-bit range must be refused rather than wrapping");
    IMP_ASSERT_FALSE(IMPNumberIsIntegerInRange(@(-1e30), LLONG_MIN, 0),
                     @"a value far below the 64-bit range must be refused");
    IMP_ASSERT_FALSE(IMPNumberIsIntegerInRange((NSNumber *)NSDecimalNumber.notANumber, 0, LLONG_MAX),
                     @"a not-a-number decimal must be refused rather than comparing as in range");

    IMP_ASSERT_FALSE(IMPNumberIsIntegerInRange((NSNumber *)@"200", 100, 599), @"a numeric string must be refused");
    IMP_ASSERT_FALSE(IMPNumberIsIntegerInRange((NSNumber *)NSNull.null, 100, 599),
                     @"the JSON null placeholder must be refused rather than crashing");
    IMP_ASSERT_FALSE(IMPNumberIsIntegerInRange(NilValue(), 100, 599),
                     @"a nil number must be refused rather than crashing");
}

IMP_TEST(error_code_for_sqlite_result_masks_extended_codes) {
    // Busy and locked are the two retryable results and get their own code,
    // because the router turns that one into a response that invites a retry and
    // every other one into a flat failure.
    IMP_ASSERT_EQ_INT(IMPErrorCodeForSQLiteResult(SQLITE_BUSY), IMPAPIKeyStoreErrorDatabaseBusy,
                      @"SQLITE_BUSY must map to the busy code");
    IMP_ASSERT_EQ_INT(IMPErrorCodeForSQLiteResult(SQLITE_LOCKED), IMPAPIKeyStoreErrorDatabaseBusy,
                      @"SQLITE_LOCKED must map to the busy code");

    // Extended result codes carry the primary code in the low byte. Without the
    // mask these are all unrecognised, and a contended write - the single most
    // common transient failure this store has - would be reported as permanent.
    IMP_ASSERT_EQ_INT(IMPErrorCodeForSQLiteResult(SQLITE_BUSY_SNAPSHOT), IMPAPIKeyStoreErrorDatabaseBusy,
                      @"SQLITE_BUSY_SNAPSHOT must map to the busy code through the low-byte mask");
    IMP_ASSERT_EQ_INT(IMPErrorCodeForSQLiteResult(SQLITE_BUSY_RECOVERY), IMPAPIKeyStoreErrorDatabaseBusy,
                      @"SQLITE_BUSY_RECOVERY must map to the busy code");
    IMP_ASSERT_EQ_INT(IMPErrorCodeForSQLiteResult(SQLITE_LOCKED_SHAREDCACHE), IMPAPIKeyStoreErrorDatabaseBusy,
                      @"SQLITE_LOCKED_SHAREDCACHE must map to the busy code");
    IMP_ASSERT_EQ_INT(IMPErrorCodeForSQLiteResult(SQLITE_BUSY | (7 << 8)), IMPAPIKeyStoreErrorDatabaseBusy,
                      @"an extension byte SQLite has not defined yet must still map by its primary code");

    IMP_ASSERT_EQ_INT(IMPErrorCodeForSQLiteResult(SQLITE_CORRUPT), IMPAPIKeyStoreErrorDatabaseCorrupt,
                      @"SQLITE_CORRUPT must map to the corrupt code");
    IMP_ASSERT_EQ_INT(IMPErrorCodeForSQLiteResult(SQLITE_NOTADB), IMPAPIKeyStoreErrorDatabaseCorrupt,
                      @"SQLITE_NOTADB must map to the corrupt code");
    IMP_ASSERT_EQ_INT(IMPErrorCodeForSQLiteResult(SQLITE_CORRUPT_VTAB), IMPAPIKeyStoreErrorDatabaseCorrupt,
                      @"SQLITE_CORRUPT_VTAB must map to the corrupt code");

    IMP_ASSERT_EQ_INT(IMPErrorCodeForSQLiteResult(SQLITE_IOERR), IMPAPIKeyStoreErrorDatabaseUnavailable,
                      @"SQLITE_IOERR must map to the generic unavailable code");
    IMP_ASSERT_EQ_INT(IMPErrorCodeForSQLiteResult(SQLITE_IOERR_READ), IMPAPIKeyStoreErrorDatabaseUnavailable,
                      @"an extended I/O error must map to the generic unavailable code");
    IMP_ASSERT_EQ_INT(IMPErrorCodeForSQLiteResult(SQLITE_READONLY), IMPAPIKeyStoreErrorDatabaseUnavailable,
                      @"SQLITE_READONLY must map to the generic unavailable code");

    // A constraint violation is deliberately not distinguished here, which is
    // why the create path inspects the constraint itself before it reaches this
    // mapping: a taken sender identifier has to be a 409, and this would make it
    // a 503 that invites a retry which can never succeed.
    IMP_ASSERT_EQ_INT(IMPErrorCodeForSQLiteResult(SQLITE_CONSTRAINT), IMPAPIKeyStoreErrorDatabaseUnavailable,
                      @"a constraint failure must fall through to the generic unavailable code");
    IMP_ASSERT_EQ_INT(IMPErrorCodeForSQLiteResult(SQLITE_CONSTRAINT_UNIQUE), IMPAPIKeyStoreErrorDatabaseUnavailable,
                      @"a unique constraint failure must fall through to the generic unavailable code");
    IMP_ASSERT_EQ_INT(IMPErrorCodeForSQLiteResult(SQLITE_OK), IMPAPIKeyStoreErrorDatabaseUnavailable,
                      @"a success passed in by mistake must fall through rather than reporting a success");
}

IMP_TEST(idempotency_state_strings_round_trip) {
    // These four literals are the only spelling the state column accepts, and
    // the reverse mapping returns 0 for anything it does not recognise, which
    // the read path treats as a corrupt row. A round trip that lost a state
    // would make every row in that state unreadable, and a caller retrying with
    // the same idempotency key would be told its own record is corrupt.
    NSDictionary<NSNumber *, NSString *> *states = @{
        @(IMPIdempotencyStateInProgress): @"in_progress",
        @(IMPIdempotencyStateSucceeded): @"succeeded",
        @(IMPIdempotencyStateAmbiguous): @"ambiguous",
        @(IMPIdempotencyStateFailed): @"failed"
    };
    for (NSNumber *state in states) {
        NSString *expected = states[state];
        IMP_ASSERT_EQ_STR(IMPStateString((IMPIdempotencyState)state.integerValue), expected,
                          @"the idempotency state %@ must spell itself %@", state, expected);
        IMP_ASSERT_EQ_INT(IMPStateFromString(expected), state.integerValue, @"the idempotency state %@ must round trip",
                          expected);
    }

    IMP_ASSERT_EQ_INT(IMPStateFromString(@"done"), 0, @"an unrecognised state must read back as zero");
    IMP_ASSERT_EQ_INT(IMPStateFromString(@"In_Progress"), 0, @"a state must be matched case sensitively");
    IMP_ASSERT_EQ_INT(IMPStateFromString(@"in_progress "), 0, @"a state must not be trimmed before it is matched");
    IMP_ASSERT_EQ_INT(IMPStateFromString(@""), 0, @"an empty state must read back as zero");
    IMP_ASSERT_EQ_INT(IMPStateFromString(NilValue()), 0, @"a nil state must read back as zero rather than crashing");
    IMP_ASSERT_EQ_STR(IMPStateString((IMPIdempotencyState)0), @"",
                      @"a state outside the enumeration must spell itself as the empty string, which no CHECK accepts");
    IMP_ASSERT_EQ_STR(IMPStateString((IMPIdempotencyState)99), @"",
                      @"a state well outside the enumeration must spell itself as the empty string");
}

IMP_TEST(audit_phase_strings_round_trip_and_match_the_column_check) {
    NSDictionary<NSNumber *, NSString *> *phases =
        @{@(IMPAuditPhaseAttempted): @"attempted",
          @(IMPAuditPhaseFinal): @"final"};
    for (NSNumber *phase in phases) {
        NSString *expected = phases[phase];
        IMP_ASSERT_EQ_STR(IMPAuditPhaseString((IMPAuditPhase)phase.integerValue), expected,
                          @"the audit phase %@ must spell itself %@", phase, expected);
        IMP_ASSERT_EQ_INT(IMPAuditPhaseFromString(expected), phase.integerValue, @"the audit phase %@ must round trip",
                          expected);
    }
    IMP_ASSERT_EQ_INT(IMPAuditPhaseFromString(@"attempt"), 0, @"a truncated phase must read back as zero");
    IMP_ASSERT_EQ_INT(IMPAuditPhaseFromString(NilValue()), 0,
                      @"a nil phase must read back as zero rather than crashing");
    IMP_ASSERT_EQ_STR(IMPAuditPhaseString((IMPAuditPhase)0), @"",
                      @"a phase outside the enumeration must spell itself as the empty string");

    // The phase column enumerates its own copy of these two literals and the
    // primary key is (request_uuid, phase), so a phase spelled differently by
    // the writer than by the constraint refuses every audit write there is.
    NSArray<NSString *> *ddlPhases = QuotedLiterals(@(kIMPAuditRecordsDDL), @"CHECK(phase IN (");
    IMP_ASSERT_NOT_NIL(ddlPhases, @"the phase CHECK constraint must still be where this invariant reads it");
    IMP_ASSERT_EQ_OBJECT([NSSet setWithArray:ddlPhases ?: @[]], ([NSSet setWithObjects:@"attempted", @"final", nil]),
                         @"the audit phase strings and the column CHECK must enumerate the same phases");
}

IMP_TEST(record_has_scope_treats_admin_as_implying_every_scope) {
    // Every authorization decision the router makes is one call to this method,
    // so both directions are failures a caller sees: a wrong YES is a privilege
    // escalation and a wrong NO locks the holder out of their own key.
    IMPAPIKeyRecord *admin = RecordWithScopes(@[IMPAPIKeyScopeAdmin]);
    IMP_ASSERT_TRUE([admin hasScope:IMPAPIKeyScopeAdmin], @"an admin key must have the admin scope");
    IMP_ASSERT_TRUE([admin hasScope:IMPAPIKeyScopeMessagesRead], @"an admin key must imply the read scope");
    IMP_ASSERT_TRUE([admin hasScope:IMPAPIKeyScopeMessagesSend], @"an admin key must imply the send scope");

    IMPAPIKeyRecord *reader = RecordWithScopes(@[IMPAPIKeyScopeMessagesRead]);
    IMP_ASSERT_TRUE([reader hasScope:IMPAPIKeyScopeMessagesRead], @"a read-only key must have the read scope");
    IMP_ASSERT_FALSE([reader hasScope:IMPAPIKeyScopeMessagesSend], @"a read-only key must not have the send scope");
    IMP_ASSERT_FALSE([reader hasScope:IMPAPIKeyScopeAdmin], @"a read-only key must not have the admin scope");

    IMPAPIKeyRecord *both = RecordWithScopes(@[IMPAPIKeyScopeMessagesRead, IMPAPIKeyScopeMessagesSend]);
    IMP_ASSERT_TRUE([both hasScope:IMPAPIKeyScopeMessagesRead], @"a read and send key must have the read scope");
    IMP_ASSERT_TRUE([both hasScope:IMPAPIKeyScopeMessagesSend], @"a read and send key must have the send scope");
    IMP_ASSERT_FALSE([both hasScope:IMPAPIKeyScopeAdmin],
                     @"holding every non-admin scope must not add up to the admin scope");

    // The stored scopes arrive as a comma-separated string that the read path
    // splits, so this is the shape the method actually sees in production.
    IMPAPIKeyRecord *fromColumn = RecordWithScopes([@"messages:read,admin" componentsSeparatedByString:@","]);
    IMP_ASSERT_TRUE([fromColumn hasScope:IMPAPIKeyScopeMessagesSend],
                    @"a record built from the stored scope string must still imply the send scope for an admin");

    IMPAPIKeyRecord *empty = RecordWithScopes(@[]);
    IMP_ASSERT_FALSE([empty hasScope:IMPAPIKeyScopeMessagesRead], @"a key with no scopes must have no read scope");
    IMP_ASSERT_FALSE([empty hasScope:IMPAPIKeyScopeMessagesSend], @"a key with no scopes must have no send scope");
    IMP_ASSERT_FALSE([empty hasScope:IMPAPIKeyScopeAdmin], @"a key with no scopes must have no admin scope");
}

IMP_TEST(record_has_scope_refuses_a_scope_outside_the_allowlist) {
    // The scope being asked about is checked against the allowlist before the
    // record is consulted, so an admin key does not answer YES to a scope that
    // does not exist. Without that, a route added with a misspelled scope
    // constant would be silently open to every admin instead of failing loudly
    // the first time an administrator called it.
    IMPAPIKeyRecord *admin = RecordWithScopes(@[IMPAPIKeyScopeAdmin]);
    IMP_ASSERT_FALSE([admin hasScope:@"messages:delete"], @"an invented scope must be refused even for an admin key");
    IMP_ASSERT_FALSE([admin hasScope:@"ADMIN"], @"a scope must be matched case sensitively even for an admin key");
    IMP_ASSERT_FALSE([admin hasScope:@"admin "],
                     @"a scope with trailing whitespace must be refused even for an admin key");
    IMP_ASSERT_FALSE([admin hasScope:@""], @"an empty scope must be refused even for an admin key");
    IMP_ASSERT_FALSE([admin hasScope:NilValue()], @"a nil scope must be refused rather than crashing");
    IMP_ASSERT_FALSE([admin hasScope:(IMPAPIKeyScope) @42], @"a number where a scope belongs must be refused");

    // A row whose scopes column has picked up something the store would never
    // write. The junk must neither grant anything nor take away what is there.
    IMPAPIKeyRecord *withJunk = RecordWithScopes(@[@"messages:read", @"messages:delete"]);
    IMP_ASSERT_TRUE([withJunk hasScope:IMPAPIKeyScopeMessagesRead],
                    @"an unrecognised stored scope must not mask a real one");
    IMP_ASSERT_FALSE([withJunk hasScope:IMPAPIKeyScopeAdmin], @"an unrecognised stored scope must grant nothing");
}

// The store half of the shims imp-test.h declares. They exist because
// tests/native/test-differential.m has to compare these rules against the ones
// the HTTP layer applies before them, and every one of them is file-static: the
// only way to reach them from another translation unit is for a translation
// unit that already has them to hand them out. Each one is a call and nothing
// else, so that what the differential suite compares is the rule that ships and
// not a paraphrase of it.

BOOL imp_test_expose_store_sender_identifier_rule(NSString *value) {
    return IMPValidateSenderIdentifier(value, NULL, NULL);
}

BOOL imp_test_expose_store_api_key_name_rule(NSString *value, NSString **normalized) {
    return IMPValidateName(value, normalized, NULL);
}

BOOL imp_test_expose_store_idempotency_key_rule(NSString *value) { return IMPValidateIdempotencyKey(value, NULL); }

BOOL imp_test_expose_store_audit_action_rule(NSString *action) { return IMPValidateAuditAction(action, NULL); }

// The second copy of the audit allowlist, the one the database enforces. It is
// read back out of the DDL text rather than written out again here, because a
// third copy of a list that already exists twice is the defect this whole tier
// is about.
NSArray<NSString *> *imp_test_expose_store_audit_action_check(void) {
    return QuotedLiterals(@(kIMPAuditRecordsDDL), @"CHECK(action IN (");
}

NSString *imp_test_expose_store_sha256_hex(NSData *data) { return IMPTestHexFromData(IMPSHA256(data)); }
