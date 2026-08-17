// The rules in this file are each written twice in src/: once in
// src/imessage-proxy-server.m, where a request arrives and is accepted or
// refused with a 400, and once in src/api-key-store.m, where the row that
// request produces is written and refused with an error the router can only
// turn into a 5xx. Neither file mentions the other. Reading either one alone
// tells you nothing about whether the pair still agrees, which is why a
// divergence here is invisible to every other suite in the repository: the
// store suite proves the store's rule is the rule it means to have, the server
// suite proves the same of the router's, the shell suite drives real requests
// and sees only that some of them are refused, and all four can pass while a
// caller who spelled a request correctly is handed a 503.
//
// Nothing is included here. Both production sources are already compiled into
// the two suites this file is linked with, and a third copy would give the
// process two of every class in src/api-key-store.m; the rules are reached
// instead through the imp_test_expose_* shims imp-test.h declares, which the
// two suites define at their own bottoms. One of those shims - the idempotency
// key rule - is a transcription rather than a call, for the reason given where
// it is defined, and the corpus below is the reason that is tolerable: a
// transcription that has drifted from its original is what fifty inputs find
// and three examples do not.
//
// The corpus is shared deliberately. Every rule sees every value, including the
// values that make no sense for it, because the defect this suite exists to
// catch is a disagreement about a value nobody thought to try on both sides.
// Each case also counts what it accepted and what it refused: two rules that
// have both stopped accepting anything agree perfectly, and that is the one way
// an agreement test passes while proving nothing.
//
// Every character outside printable ASCII is written as an escape, as it is
// everywhere in src/ and in the two suites beside this one. Several of the
// values below are invisible on purpose - an embedded NUL, a right-to-left
// override, a zero-width joiner, a byte-order mark - and a source file that
// carried them literally would be unreviewable in exactly the way those
// characters are meant to exploit.
//
// This tier's Foundation divergences do not reach here, and that is a property
// of the subject rather than luck: both sides of every comparison below call
// the same Foundation methods on the same host, so a host whose
// -lowercaseString or -stringByTrimmingCharactersInSet: differs from Apple's
// moves both answers together. What is asserted is that they moved together.

#import "imp-test.h"

// Returns nil through an opaque call. The rules under test are annotated
// _Nonnull in places, which makes a literal nil a compile error, but nothing
// between a request header and any of them enforces the annotation at run time,
// so nil is a value they really do receive.
static id NilValue(void) { return nil; }

// Repeats a single-unit string, which is how every length boundary below is
// built. Only characters that occupy one UTF-16 unit may be passed, because
// padding counts units and would otherwise cut a surrogate pair in half.
static NSString *Repeated(NSString *unit, NSUInteger count) {
    return [@"" stringByPaddingToLength:count withString:unit startingAtIndex:0];
}

// The C0 and C1 control characters in the corpus cannot be written as universal
// character names - C refuses a \u escape that names one - and writing them
// literally would make this file unreadable in exactly the way those characters
// are for.
static NSString *StringAroundCodeUnit(unichar unit) { return [NSString stringWithFormat:@"ab%Ccd", unit]; }

// A failure has to name which of the fifty values broke, and a third of them
// cannot be printed: an embedded NUL truncates the line at the C string
// boundary, a right-to-left override reverses everything after it in the
// terminal, a zero-width space leaves no mark at all. Rendering the value the
// same way the corpus is written is what makes the failure line something a
// reader can act on without opening this file.
static NSString *Readable(id value) {
    if (value == nil) {
        return @"nil";
    }
    if (![value isKindOfClass:NSString.class]) {
        return [NSString stringWithFormat:@"a %@", [value class]];
    }
    NSString *text = value;
    NSMutableString *rendered = [NSMutableString stringWithCapacity:text.length];
    for (NSUInteger index = 0; index < text.length; index++) {
        unichar unit = [text characterAtIndex:index];
        if (unit >= 0x20 && unit < 0x7f) {
            [rendered appendFormat:@"%C", unit];
        } else {
            [rendered appendFormat:@"\\u%04x", (unsigned)unit];
        }
    }
    return rendered;
}

// The shared corpus. Fifty values, and every one of them is here because it
// sits on a bound, folds under a case conversion, disappears under a trim,
// hides inside a control character, or is simply what a caller sends. A rule
// that reads only the first character or only the length is not defeated by any
// one of these; it is defeated by the pair of rules answering differently about
// one of them.
static NSArray<NSString *> *SharedCorpus(void) {
    return @[
        // The bounds all three rules are built out of: 2 and 8 UTF-16 units for
        // a sender identifier, 1 and 80 UTF-8 bytes for a name, 8 and 128 UTF-8
        // bytes for an idempotency key. Each appears at the limit and one over.
        @"", @"a", @"ab", @"abcdefg", @"abcdefgh", @"abcdefghi", Repeated(@"a", 80), Repeated(@"a", 81),
        Repeated(@"a", 128), Repeated(@"a", 129),
        // Whitespace, which one side of the name rule trims and no side of the
        // other two does. The last of these is a non-breaking space, which is
        // whitespace to Unicode and to Foundation's trimming set but not to
        // anybody reading the request.
        @" ab ", @"   ", @"ab ", @"ab\tcd", @"ab\ncd", @"ab\r\ncd", @"\u00a0ab\u00a0",
        // Control and formatting characters. Every rule here has a defence
        // against them and no two of the defences are spelled the same way, so
        // the interesting question is not whether each refuses them but whether
        // both refuse the same ones.
        @"ab\0cd", StringAroundCodeUnit(0x007f), StringAroundCodeUnit(0x001b), StringAroundCodeUnit(0x0085),
        @"ab\u202ecd", @"ab\u200bcd", @"ab\u200dcd", @"ab\ufeffcd",
        // Case folding and normalisation. U+212A KELVIN SIGN folds to an ASCII
        // k and U+0130 LATIN CAPITAL LETTER I WITH DOT ABOVE folds to two units
        // rather than one, which is the only way a length check placed before a
        // fold and a length check placed after it can disagree.
        @"\u212ale", @"\u0130", @"\u0130\u0130\u0130\u0130", @"caf\u00e9", @"cafe\u0301", @"\u0430\u0430",
        @"\uff41\uff42", @"a\u00e7b", @"\U0001f600", Repeated(@"\u00e9", 40), Repeated(@"\u00e9", 41),
        // The RFC 3986 unreserved alphabet the idempotency rule is written
        // around, and the characters just outside it that a caller reaches for
        // first when generating one.
        @"abcdefgh._~-", @"ABCDEFGH01234567", @"abcdefg/hij", @"abcdefg+hij", @"abcdefg%20hij", @"abcdefg hij",
        @"01234567", @"--------",
        // Values a caller really sends, so that the corpus is not made entirely
        // of things nobody would type.
        @"ops", @"Ops Key", @"kle", @"KLE", @"messages.send", @"550e8400-e29b-41d4-a716-446655440000"
    ];
}

// The shapes that arrive when a JSON body carries the wrong type where a string
// belongs. The idempotency rule does not see them - it reads a parsed header,
// which is a string or nothing - and the reason that matters is recorded where
// it is used.
static NSArray *NonStringCorpus(void) { return @[@42, NSNull.null, @[], @{}]; }

IMP_TEST(the_wire_and_the_store_agree_about_a_sender_identifier) {
    // POST /api/keys validates the sender identifier and then hands it to the
    // store, which validates it again against a column whose CHECK enforces the
    // same shape a third time. If the HTTP layer is the looser of the two, a
    // caller who spelled an identifier the API accepted gets a 503 for it,
    // because the store's refusal arrives after the request has been admitted
    // and there is no longer a 400 to give. If it is the tighter of the two, an
    // identifier the store would have held is refused before it is ever tried.
    //
    // The size of the corpus is asserted once, here, rather than described in a
    // comment above it: a corpus that had shrunk would weaken every case in
    // this file at once and none of them would fail.
    IMP_ASSERT_TRUE(SharedCorpus().count >= 40, @"the shared corpus must hold at least forty values, got %lu",
                    (unsigned long)SharedCorpus().count);

    NSUInteger accepted = 0;
    NSUInteger refused = 0;
    for (NSString *value in SharedCorpus()) {
        BOOL fromWire = imp_test_expose_router_sender_identifier_rule(value);
        BOOL fromStore = imp_test_expose_store_sender_identifier_rule(value);
        IMP_ASSERT_TRUE(fromWire == fromStore, @"the API and the store must agree about %@ (API %@, store %@)",
                        Readable(value), fromWire ? @"YES" : @"NO", fromStore ? @"YES" : @"NO");
        fromWire ? accepted++ : refused++;
    }

    for (id value in NonStringCorpus()) {
        IMP_ASSERT_FALSE(imp_test_expose_router_sender_identifier_rule(value),
                         @"the API must refuse %@ where an identifier belongs", Readable(value));
        IMP_ASSERT_FALSE(imp_test_expose_store_sender_identifier_rule(value),
                         @"the store must refuse %@ where an identifier belongs", Readable(value));
    }
    IMP_ASSERT_FALSE(imp_test_expose_router_sender_identifier_rule(NilValue()), @"the API must refuse nil");
    IMP_ASSERT_FALSE(imp_test_expose_store_sender_identifier_rule(NilValue()), @"the store must refuse nil as well");

    // The count, so that two rules which have both stopped accepting anything
    // cannot agree their way through this case. The identifier alphabet is
    // narrow, so only a handful of the corpus gets through, and that handful is
    // the whole evidence that the agreement above is about acceptance and not
    // only about refusal.
    IMP_ASSERT_TRUE(accepted >= 4, @"the corpus must contain identifiers both sides accept, got %lu",
                    (unsigned long)accepted);
    IMP_ASSERT_TRUE(refused >= 40, @"the corpus must contain identifiers both sides refuse, got %lu",
                    (unsigned long)refused);
}

IMP_TEST(the_wire_and_the_store_agree_about_an_api_key_name) {
    // The same argument, with one addition: both sides also return the string
    // they would store, and it is the trimmed one. A disagreement about the
    // verdict costs a 503; a disagreement about the normalised value costs
    // something quieter and worse, because IMPRecordFromStatement validates a
    // name again on the way back out of the database and a row whose stored
    // name does not survive that second pass cannot be read at all.
    NSUInteger accepted = 0;
    NSUInteger refused = 0;
    for (NSString *value in SharedCorpus()) {
        NSString *fromWireNormalized = nil;
        NSString *fromStoreNormalized = nil;
        BOOL fromWire = imp_test_expose_router_api_key_name_rule(value, &fromWireNormalized);
        BOOL fromStore = imp_test_expose_store_api_key_name_rule(value, &fromStoreNormalized);
        IMP_ASSERT_TRUE(fromWire == fromStore, @"the API and the store must agree about %@ (API %@, store %@)",
                        Readable(value), fromWire ? @"YES" : @"NO", fromStore ? @"YES" : @"NO");
        IMP_ASSERT_EQ_STR(fromWireNormalized, fromStoreNormalized,
                          @"both must normalise %@ to the same string, or a stored row stops matching itself",
                          Readable(value));
        fromWire ? accepted++ : refused++;
    }

    for (id value in NonStringCorpus()) {
        NSString *normalized = nil;
        IMP_ASSERT_FALSE(imp_test_expose_router_api_key_name_rule(value, &normalized),
                         @"the API must refuse %@ where a name belongs", Readable(value));
        IMP_ASSERT_NIL(normalized, @"a refused name must leave the out-pointer untouched at the API");
        IMP_ASSERT_FALSE(imp_test_expose_store_api_key_name_rule(value, &normalized),
                         @"the store must refuse %@ where a name belongs", Readable(value));
        IMP_ASSERT_NIL(normalized, @"a refused name must leave the out-pointer untouched at the store");
    }
    IMP_ASSERT_FALSE(imp_test_expose_router_api_key_name_rule(NilValue(), NULL), @"the API must refuse nil");
    IMP_ASSERT_FALSE(imp_test_expose_store_api_key_name_rule(NilValue(), NULL), @"the store must refuse nil as well");

    // Both sides accept most of a corpus that was not built for them, which is
    // what a name rule bounded only by length and control characters should do.
    IMP_ASSERT_TRUE(accepted >= 25, @"the corpus must contain names both sides accept, got %lu",
                    (unsigned long)accepted);
    IMP_ASSERT_TRUE(refused >= 10, @"the corpus must contain names both sides refuse, got %lu", (unsigned long)refused);
}

IMP_TEST(the_wire_and_the_store_agree_about_an_idempotency_key) {
    // POST /api/messages refuses a bad Idempotency-Key with a 400 and then
    // passes the good ones to the store, which validates them again before it
    // claims the key. The router's copy of the rule counts UTF-16 units and the
    // store's counts UTF-8 bytes, which is a difference that cancels only
    // because the alphabet both of them enforce is ASCII - so the two agree for
    // a reason neither file states, and the corpus below is what holds that
    // reason in place. A caller whose key the API accepted and the store then
    // refused would be told 503 on a send it is entitled to retry, which is the
    // worst possible answer to give about a message that may already be sent.
    NSUInteger accepted = 0;
    NSUInteger refused = 0;
    for (NSString *value in SharedCorpus()) {
        BOOL fromWire = imp_test_expose_router_idempotency_key_rule(value);
        BOOL fromStore = imp_test_expose_store_idempotency_key_rule(value);
        IMP_ASSERT_TRUE(fromWire == fromStore, @"the API and the store must agree about %@ (API %@, store %@)",
                        Readable(value), fromWire ? @"YES" : @"NO", fromStore ? @"YES" : @"NO");
        fromWire ? accepted++ : refused++;
    }

    // An absent header is the shape the router's rule really meets. It reads
    // request.headers, whose values are strings or nothing, and it has no type
    // check of its own - so nil is the only non-string it may be asked about,
    // and the store's rule, which does have a type check, has to answer the
    // same way about it.
    IMP_ASSERT_FALSE(imp_test_expose_router_idempotency_key_rule(NilValue()),
                     @"a missing Idempotency-Key must be refused at the API");
    IMP_ASSERT_FALSE(imp_test_expose_store_idempotency_key_rule(NilValue()),
                     @"a missing idempotency key must be refused at the store as well");

    IMP_ASSERT_TRUE(accepted >= 8, @"the corpus must contain idempotency keys both sides accept, got %lu",
                    (unsigned long)accepted);
    IMP_ASSERT_TRUE(refused >= 30, @"the corpus must contain idempotency keys both sides refuse, got %lu",
                    (unsigned long)refused);
}

IMP_TEST(the_router_and_the_column_check_enumerate_the_same_audit_actions) {
    // An audit row is written on the way out of a request that has already been
    // answered. An action the router passes that the store's validator refuses,
    // or that the column CHECK refuses after it, turns that write into a
    // failure and the answer into a 503 - for a request that had done exactly
    // what it was asked to do. The three lists live in three files and none of
    // them can see the others.
    NSArray<NSString *> *routerActions = imp_test_expose_router_audit_actions();
    NSArray<NSString *> *checkActions = imp_test_expose_store_audit_action_check();

    IMP_ASSERT_NOT_NIL(checkActions, @"the audit action CHECK constraint must still be where this invariant reads it");

    // The count is asserted rather than only the set, because the set
    // comparison below is between two lists that a single careless edit could
    // shorten together. Thirty-four literals appear in the router, on
    // thirty-two lines, and twenty-three of them are distinct; a twenty-fourth
    // that reaches the store without reaching the CHECK has to fail here rather
    // than on somebody's audit write.
    IMP_ASSERT_EQ_INT(routerActions.count, 23, @"the router must still pass twenty-three distinct audit actions");
    NSSet<NSString *> *routerSet = [NSSet setWithArray:routerActions];
    NSSet<NSString *> *checkSet = [NSSet setWithArray:checkActions];
    IMP_ASSERT_EQ_INT(routerSet.count, routerActions.count, @"the router must not name one audit action twice");
    IMP_ASSERT_EQ_INT(checkSet.count, checkActions.count, @"the column CHECK must not list one audit action twice");

    for (NSString *action in routerActions) {
        IMP_ASSERT_TRUE(imp_test_expose_store_audit_action_rule(action),
                        @"the store must accept the audit action the router passes: %@", action);
        IMP_ASSERT_TRUE([checkSet containsObject:action],
                        @"the column CHECK must hold the audit action the router passes: %@", action);
    }

    // The other direction, which is the one that catches an action retired from
    // the router and left behind in the schema. It is not a failure the
    // database will ever report, because a constraint that permits a value
    // nobody writes permits it silently; it is a failure of the schema to
    // describe what the service does.
    for (NSString *action in checkActions) {
        IMP_ASSERT_TRUE([routerSet containsObject:action],
                        @"every audit action the schema permits must be reachable from a router path: %@", action);
    }

    // Near misses, so that the agreement above is an agreement about an
    // enumeration rather than about any string that looks like one.
    IMP_ASSERT_FALSE(imp_test_expose_store_audit_action_rule(@"messages.sent"),
                     @"a misspelled action must be refused rather than stored");
    IMP_ASSERT_FALSE(imp_test_expose_store_audit_action_rule(@"Messages.send"),
                     @"the action comparison must be case sensitive");
    IMP_ASSERT_FALSE(imp_test_expose_store_audit_action_rule(@"messages.send "),
                     @"a trailing space must not be trimmed into a valid action");
    IMP_ASSERT_FALSE(imp_test_expose_store_audit_action_rule(@""), @"an empty action must be refused");
    IMP_ASSERT_FALSE(imp_test_expose_store_audit_action_rule(NilValue()), @"a nil action must be refused");
}

IMP_TEST(the_two_files_agree_about_a_sha256_digest) {
    // Both files compute SHA-256 and neither uses the other's function: the
    // router hashes the resolved configuration into the fingerprint it reports
    // and logs, the store hashes every API key into the column it authenticates
    // against. The store's version exists to feed CommonCrypto in chunks that
    // fit a CC_LONG, and that loop - the pointer it advances and the count it
    // decrements - is the only arithmetic in either file that could quietly
    // produce a different digest for the same bytes. If it ever did, every
    // stored key hash would stop matching the key that made it and no
    // credential in the database would authenticate again, with nothing in
    // either file looking wrong. What cannot be reached from a unit test is the
    // second turn of that loop, which needs four gigabytes of input; what is
    // pinned is that the two agree at every size a test can build, and that
    // both are SHA-256 rather than merely equal to each other.
    NSMutableData *allBytes = [NSMutableData dataWithLength:256];
    unsigned char *bytes = allBytes.mutableBytes;
    for (NSUInteger index = 0; index < 256; index++) {
        bytes[index] = (unsigned char)index;
    }

    NSArray<NSData *> *corpus = @[
        [NSData data], [@"abc" dataUsingEncoding:NSUTF8StringEncoding], [NSData dataWithBytes:"\0" length:1], allBytes,
        [Repeated(@"a", 1000) dataUsingEncoding:NSUTF8StringEncoding],
        [@"ab\0cd\u202e" dataUsingEncoding:NSUTF8StringEncoding],
        [Repeated(@"\u00e9", 4096) dataUsingEncoding:NSUTF8StringEncoding]
    ];
    for (NSData *data in corpus) {
        NSString *fromRouter = imp_test_expose_router_sha256_hex(data);
        NSString *fromStore = imp_test_expose_store_sha256_hex(data);
        IMP_ASSERT_EQ_STR(fromRouter, fromStore, @"both files must hash %lu bytes to the same digest",
                          (unsigned long)data.length);
        IMP_ASSERT_EQ_INT(fromRouter.length, 64, @"a SHA-256 digest is sixty-four hexadecimal characters");
    }

    // Absent data, which the router meets when JSONData refuses to serialise
    // the fingerprint object and the store meets through +SHA256ForData:. Both
    // have to answer with the digest of nothing rather than with nothing, or a
    // fingerprint comparison starts succeeding against an empty string.
    IMP_ASSERT_EQ_STR(imp_test_expose_router_sha256_hex(nil), imp_test_expose_store_sha256_hex(nil),
                      @"both files must hash absent data the same way");

    // The two FIPS 180-4 vectors, so that a pair of functions which had both
    // stopped hashing could not agree their way past this case.
    IMP_ASSERT_EQ_STR(imp_test_expose_router_sha256_hex([NSData data]),
                      @"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                      @"the digest of no bytes must be the published SHA-256 of the empty string");
    IMP_ASSERT_EQ_STR(imp_test_expose_store_sha256_hex([@"abc" dataUsingEncoding:NSUTF8StringEncoding]),
                      @"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                      @"the digest of \"abc\" must be the published SHA-256 of \"abc\"");
}
