// Unit tests over the validators, parsers and projectors in
// src/imessage-proxy-server.m. The source is #included whole rather than
// linked, because every function of interest here is file-static: they are the
// rules that decide which dates, targets, query parameters, filenames and
// upstream records the service accepts, and none of them is reachable from
// outside the translation unit. Including the file is what lets this suite test
// the exact text that ships rather than a copy that drifts from it.
//
// src/api-key-store.m is included with it because the server file uses the
// store's classes and this suite is linked on its own. That is not only a link
// convenience: it puts IsValidSenderIdentifier beside
// IMPValidateSenderIdentifier and MessagesReadAuditAction beside
// IMPValidateAuditAction, so the two agreements no end-to-end test can see - an
// identifier the API accepts and the store then refuses, an audit action the
// router writes and the store's allowlist does not hold - become expressible.
// A divergence in either turns a caller's ordinary request into a 5xx.
//
// The shell suite reaches these functions through HTTP, which can only carry
// what a request can spell and which reports every rejection as the same 400.
// Everything below is either a value the HTTP layer cannot express - an
// embedded NUL, a number one over a limit, a struct stat with one field moved -
// or the inside of a projection the wire never shows in full.
//
// Nothing here opens a database, a socket or a file, and nothing reads the
// clock: every date is a fixed NSDate. A check belongs here only if it would
// have failed on a real bug.
//
// Every character outside printable ASCII is written as an escape, as it is
// everywhere in src/. Several of the hostile inputs below are invisible on
// purpose - a right-to-left override, a zero-width joiner, an embedded NUL, a
// next-line control - and a source file that carried them literally would be
// unreviewable in exactly the way those characters are meant to exploit.
//
// One fence applies on Linux and it is measured rather than assumed, by
// tests/native/linux/foundation-parity.m: GNUstep base 1.29 ships an
// NSISO8601DateFormatter that parses nothing, so ParseStrictRFC3339 refuses
// every well-formed timestamp on this host. The acceptance half of the
// timestamp checks is therefore compiled only where the formatter works, and
// the rejection half - which is the half a hostile input reaches - runs
// everywhere. The same fence covers the 64-bit boundaries of IsIntegerNumber,
// because GNUstep parses every JSON number as a double.

#import "imp-test.h"

// IMP_TEST_EXPOSE_ONLY is the second build of this file, the one
// tests/native/test-differential.m links for the router rules it compares
// against the store's. That binary already has src/api-key-store.m compiled
// into tests/native/test-api-key-store.m, so this build takes the header and
// leaves the classes to the linker; everything below the includes is left out,
// and all that survives is the block of exposure shims at the bottom. Without
// the split the differential binary would hold two of every store class and
// three entry points.
// The release build compiles each production source as its own translation
// unit. This suite compiles two of them into one, and that arrangement is what
// turns on -Wnullability-completeness: src/api-key-store.h is nullability
// audited, src/imessage-proxy-server.m is not, and merged into a single unit
// clang asks the second to finish what the first started. The diagnostic
// therefore describes how this file includes the product, not the product, and
// acting on it would mean annotating shipping code to satisfy a test.
//
// The exemption is scoped to the includes rather than passed on the command
// line, so the suite's own code below is still held to the warning set the
// release build uses.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"

#if defined(IMP_TEST_EXPOSE_ONLY)
#include "../../src/api-key-store.h"
#else
#include "../../src/api-key-store.m"
#endif

// The production file has a main of its own and this suite needs one too. It is
// renamed rather than compiled out, because a #ifdef in src/ would mean the
// text under test is no longer the text that ships.
#define main imp_test_imessage_proxy_server_m_main_under_test
#include "../../src/imessage-proxy-server.m"
#undef main

#pragma clang diagnostic pop

#include <stdio.h>
#include <string.h>

#if defined(__APPLE__)
#define IMPTimestampsParse 1
#else
#define IMPTimestampsParse 0
#endif

#if !defined(IMP_TEST_EXPOSE_ONLY)

// runner.m owns these two for every suite it links, and this suite cannot link
// it: run.sh builds a source that includes a production main on its own.
// Supplying them here rather than growing a second assertion vocabulary is what
// keeps a failure in this file readable beside a failure from the others.

static const char *gRunningTest;
static NSUInteger gExecutedTests;
static NSUInteger gFailedTests;
static NSUInteger gFailedAssertions;

void IMPTestRegister(const char *name, __unused IMPTestFunction function) {
    fprintf(stderr, "ERROR: %s registered itself, but this suite has no registry; call it from main.\n", name);
    abort();
}

void IMPTestFail(const char *file, int line, NSString *message) {
    fprintf(stderr, "FAIL: %s: %s:%d: %s\n", gRunningTest, file, line, message.UTF8String);
    fflush(stderr);
    gFailedAssertions++;
}

// Reporting and continuing rather than aborting, for the reason imp-test.h
// gives: one compile-run cycle should report everything a change broke, not
// only whichever validator happens to be ordered first.
static void RunTest(const char *name, void (*body)(void)) {
    NSUInteger before = gFailedAssertions;
    gRunningTest = name;
    @autoreleasepool {
        body();
    }
    gRunningTest = NULL;
    gExecutedTests++;
    if (gFailedAssertions > before) {
        gFailedTests++;
    }
}

// A nil the optimiser cannot see through. Passing a literal nil would let a
// future nullability annotation on one of these functions turn the very case
// the check exists for into a compile error rather than a test.
static NSString *NilString(void) { return nil; }

// The control characters below cannot be written as universal character names -
// C refuses a \u escape that names one - and writing them literally would make
// this file unreadable in the way those characters are for.
static NSString *StringAroundCodeUnit(unichar unit) { return [NSString stringWithFormat:@"a%Cb", unit]; }

static NSString *Repeated(NSString *unit, NSUInteger count) {
    NSMutableString *result = [NSMutableString stringWithCapacity:unit.length * count];
    for (NSUInteger index = 0; index < count; index++) {
        [result appendString:unit];
    }
    return result;
}

static id ParsedJSON(NSString *text) {
    return [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
}

static IMPProcessResult *ProcessResult(int status, NSData *standardOutput, NSData *standardError) {
    IMPProcessResult *result = [IMPProcessResult new];
    result.terminationStatus = status;
    result.standardOutput = standardOutput;
    result.standardError = standardError;
    return result;
}

static IMPHTTPRequest *RequestForPath(NSString *path) {
    IMPHTTPRequest *request = [IMPHTTPRequest new];
    request.path = path;
    return request;
}

static NSDate *FixedDate(void) { return [NSDate dateWithTimeIntervalSince1970:1704067200.0]; }

// The three counts and the four dimensions StatisticsDTO demands, so each test
// below states only the one field it is about.
static NSDictionary *StatisticsSourceWith(NSDictionary *overrides) {
    NSMutableDictionary *source = [@{
        @"total_messages": @3,
        @"sent_messages": @2,
        @"received_messages": @1,
        @"time_zone": @"UTC",
        @"chats": @[],
        @"senders": @[],
        @"services": @[],
        @"dates": @[],
    } mutableCopy];
    [source addEntriesFromDictionary:overrides];
    return source;
}

static NSDictionary *ChatBackgroundSourceWith(NSDictionary *overrides) {
    NSMutableDictionary *source =
        [@{@"ok": @YES,
           @"chat_id": @42,
           @"chat_guid": @"g",
           @"background_set": @NO} mutableCopy];
    [source addEntriesFromDictionary:overrides];
    return source;
}

static void TestGregorianCalendarRules(void) {
    // The table is indexed by month with no bound of its own, so the guard is
    // as much of the subject here as the calendar: a month of 0 or 13 that
    // reached daysByMonth would read outside a static array.
    IMP_ASSERT_FALSE(IsValidGregorianDate(2023, 0, 1), @"month zero must be refused before the table is indexed");
    IMP_ASSERT_FALSE(IsValidGregorianDate(2023, 13, 1), @"month thirteen must be refused before the table is indexed");
    IMP_ASSERT_FALSE(IsValidGregorianDate(2023, NSIntegerMin, 1), @"a hugely negative month must not index the table");
    IMP_ASSERT_FALSE(IsValidGregorianDate(2023, 1, 0), @"day zero must be refused");
    IMP_ASSERT_FALSE(IsValidGregorianDate(2023, 1, -1), @"a negative day must be refused");
    IMP_ASSERT_FALSE(IsValidGregorianDate(0, 1, 1), @"year zero is not a Gregorian year");
    IMP_ASSERT_FALSE(IsValidGregorianDate(-1, 1, 1), @"a negative year must be refused");
    IMP_ASSERT_TRUE(IsValidGregorianDate(1, 1, 1), @"year one is the first year the guard admits");

    // The century rule, which is the part of the leap-year test a naive
    // year % 4 gets wrong, and which decides whether 29 February 1900 or 2100
    // can arrive in a date filter.
    IMP_ASSERT_TRUE(IsValidGregorianDate(2024, 2, 29), @"2024 is divisible by four and has a 29 February");
    IMP_ASSERT_FALSE(IsValidGregorianDate(2023, 2, 29), @"2023 is not divisible by four");
    IMP_ASSERT_TRUE(IsValidGregorianDate(2023, 2, 28), @"28 February exists in a common year");
    IMP_ASSERT_TRUE(IsValidGregorianDate(2000, 2, 29), @"2000 is divisible by 400 and is a leap year");
    IMP_ASSERT_FALSE(IsValidGregorianDate(1900, 2, 29), @"1900 is divisible by 100 but not 400");
    IMP_ASSERT_FALSE(IsValidGregorianDate(2100, 2, 29), @"2100 is divisible by 100 but not 400");

    // One over and one under each month length, because an off-by-one in the
    // table is invisible until the one day of the year it rejects.
    IMP_ASSERT_TRUE(IsValidGregorianDate(2023, 4, 30), @"April has thirty days");
    IMP_ASSERT_FALSE(IsValidGregorianDate(2023, 4, 31), @"April has no thirty-first");
    IMP_ASSERT_TRUE(IsValidGregorianDate(2023, 1, 31), @"January has thirty-one days");
    IMP_ASSERT_TRUE(IsValidGregorianDate(2023, 12, 31), @"December has thirty-one days");
    IMP_ASSERT_FALSE(IsValidGregorianDate(2023, 12, 32), @"no month has a thirty-second");
    IMP_ASSERT_TRUE(IsValidGregorianDate(2023, 9, 30), @"September has thirty days");
    IMP_ASSERT_FALSE(IsValidGregorianDate(2023, 9, 31), @"September has no thirty-first");
}

static void TestStrictFullDates(void) {
    // The statistics dimension keys are full dates and nothing else validates
    // them, so anything this accepts is a key the console renders.
    IMP_ASSERT_TRUE(IsStrictFullDate(@"2024-02-29"), @"a leap day is a full date");
    IMP_ASSERT_TRUE(IsStrictFullDate(@"2023-12-31"), @"the last day of a common year is a full date");
    IMP_ASSERT_FALSE(IsStrictFullDate(@"2023-02-29"), @"29 February does not exist in a common year");
    IMP_ASSERT_FALSE(IsStrictFullDate(@"0000-01-01"), @"year zero must reach the Gregorian check and be refused");
    IMP_ASSERT_FALSE(IsStrictFullDate(@"2024-13-01"), @"a thirteenth month must be refused");
    IMP_ASSERT_FALSE(IsStrictFullDate(@"2024-00-01"), @"a zeroth month must be refused");
    IMP_ASSERT_FALSE(IsStrictFullDate(@"2024-01-32"), @"a thirty-second day must be refused");

    // The length and separator checks run before the digits are read, and each
    // of these has the right shape in every respect but one.
    IMP_ASSERT_FALSE(IsStrictFullDate(@"2024-1-01"), @"a nine-character date must be refused on length");
    IMP_ASSERT_FALSE(IsStrictFullDate(@"2024-01-011"), @"an eleven-character date must be refused on length");
    IMP_ASSERT_FALSE(IsStrictFullDate(@"2024/01/01"), @"slashes where the hyphens belong must be refused");
    IMP_ASSERT_FALSE(IsStrictFullDate(@"+024-01-01"), @"a leading sign must not be read as a digit by -integerValue");
    IMP_ASSERT_FALSE(IsStrictFullDate(@"2024-01-0\0"), @"an embedded NUL is not a digit");
    IMP_ASSERT_FALSE(IsStrictFullDate(@" 2024-01-0"), @"a leading space is not a digit");
    IMP_ASSERT_FALSE(IsStrictFullDate(@""), @"an empty string is not a full date");
    IMP_ASSERT_FALSE(IsStrictFullDate(NilString()), @"nil must be refused rather than crash in -characterAtIndex:");
    IMP_ASSERT_FALSE(IsStrictFullDate((NSString *)@42), @"a number where a date belongs must be refused");
}

static void TestStrictRFC3339Rejections(void) {
    // Everything here is refused before the formatter is consulted, which is
    // why it is asserted on both platforms: the regex and the Gregorian check
    // are the layers a hostile timestamp meets first.
    IMP_ASSERT_FALSE(ParseStrictRFC3339(@"2024-01-01T00:00:0Z", NULL),
                     @"a nineteen-character value is under the bound");
    IMP_ASSERT_FALSE(ParseStrictRFC3339(@"2024-01-01T00:00:00.1234567890+14:00", NULL),
                     @"a thirty-six character value is over the bound");
    IMP_ASSERT_FALSE(ParseStrictRFC3339(@"2024-01-01t00:00:00z", NULL),
                     @"RFC 3339's lowercase spelling is deliberately not accepted");
    IMP_ASSERT_FALSE(ParseStrictRFC3339(@"2024-01-01 00:00:00Z", NULL), @"a space where the T belongs must be refused");
    IMP_ASSERT_FALSE(ParseStrictRFC3339(@"2024-01-01T24:00:00Z", NULL), @"hour 24 must be refused");
    IMP_ASSERT_FALSE(ParseStrictRFC3339(@"2016-12-31T23:59:60Z", NULL),
                     @"a leap second must be refused rather than rounded into the next minute");
    IMP_ASSERT_FALSE(ParseStrictRFC3339(@"2024-01-01T00:00:00+14:01", NULL), @"the largest offset is exactly +14:00");
    IMP_ASSERT_FALSE(ParseStrictRFC3339(@"2024-01-01T00:00:00+15:00", NULL), @"no UTC offset reaches +15:00");
    IMP_ASSERT_FALSE(ParseStrictRFC3339(@"2024-01-01T00:00:00.Z", NULL),
                     @"a decimal point with no digits after it must be refused");

    // The Gregorian check exists because the regex admits any 3[01] day in any
    // month; without it 31 February would parse and then be silently moved.
    IMP_ASSERT_FALSE(ParseStrictRFC3339(@"2023-02-29T00:00:00Z", NULL), @"29 February 2023 does not exist");
    IMP_ASSERT_FALSE(ParseStrictRFC3339(@"1900-02-29T00:00:00Z", NULL), @"29 February 1900 does not exist");
    IMP_ASSERT_FALSE(ParseStrictRFC3339(@"2023-02-31T00:00:00Z", NULL), @"31 February never exists");

    IMP_ASSERT_FALSE(ParseStrictRFC3339(NilString(), NULL), @"nil must be refused rather than crash on -length");
    IMP_ASSERT_FALSE(ParseStrictRFC3339((NSString *)@42, NULL), @"a number where a timestamp belongs must be refused");

    // This assertion is the reason the tier exists. It was written believing the
    // formatter refused a trailing newline, since ICU's dollar anchor matches
    // before a final line terminator and something had to. On Linux it passed,
    // because -dateFromString: returns nil for every input and the parser
    // therefore refuses the string for an unrelated reason. On a Mac it failed:
    // Apple's formatter parses "...Z\n", so with the dollar anchor nothing
    // refused it and every timestamp-taking endpoint accepted trailing
    // whitespace. The pattern now anchors with \z, which is what makes this
    // pass on both. Keep it pointed at ParseStrictRFC3339 rather than at the
    // pattern alone: the defect was in how the two layers combined.
    IMP_ASSERT_FALSE(ParseStrictRFC3339(@"2024-01-01T00:00:00Z\n", NULL),
                     @"a timestamp with a trailing newline must be refused");
}

static void TestStrictRFC3339Acceptances(void) {
#if IMPTimestampsParse
    // Only the three spellings foundation-parity.m has proved the formatter
    // answers for are asserted here, so a failure means ParseStrictRFC3339
    // changed rather than that Foundation was assumed to do something.
    NSDate *parsed = nil;
    IMP_ASSERT_TRUE(ParseStrictRFC3339(@"2024-01-01T00:00:00Z", &parsed), @"a whole-second Zulu timestamp is valid");
    IMP_ASSERT_EQ_INT((long long)parsed.timeIntervalSince1970, 1704067200LL,
                      @"the parsed date must be the instant the timestamp names");

    NSDate *offset = nil;
    IMP_ASSERT_TRUE(ParseStrictRFC3339(@"2024-01-01T01:00:00+01:00", &offset), @"a numeric UTC offset is valid");
    IMP_ASSERT_EQ_INT((long long)offset.timeIntervalSince1970, 1704067200LL,
                      @"the offset must be applied rather than ignored, or every filter is out by an hour");

    // A '.' in the value selects the other formatter, and the whole-second one
    // returns nil for a fractional string rather than truncating it.
    NSDate *fractional = nil;
    IMP_ASSERT_TRUE(ParseStrictRFC3339(@"2024-01-01T00:00:00.123Z", &fractional),
                    @"a fractional-second timestamp must reach the fractional formatter");
    IMP_ASSERT_TRUE(fabs(fractional.timeIntervalSince1970 - 1704067200.123) < 0.0005,
                    @"the fractional part must survive, got %f", fractional.timeIntervalSince1970);

    IMP_ASSERT_TRUE(ParseStrictRFC3339(@"2024-02-29T00:00:00Z", NULL), @"a leap day is a valid timestamp");
    IMP_ASSERT_TRUE(ParseStrictRFC3339(@"2024-01-01T00:00:00Z", NULL),
                    @"a NULL out-pointer must still report the value as valid");
#else
    // The consequence of the divergence foundation-parity.m records, pinned
    // here as well so that this fence fails loudly on the day the host grows a
    // working formatter instead of leaving these checks quietly unrun.
    IMP_ASSERT_FALSE(ParseStrictRFC3339(@"2024-01-01T00:00:00Z", NULL),
                     @"a host whose ISO 8601 formatter parses nothing is expected to refuse every timestamp");
#endif
}

static void TestPositiveIntegers(void) {
    // The listen port, every timeout, the concurrency cap, Content-Length,
    // every ?limit= and every chat id come through here.
    NSUInteger parsed = 0;
    IMP_ASSERT_TRUE(ParsePositiveInteger(@"42", 100, &parsed), @"an ordinary number below the maximum is valid");
    IMP_ASSERT_EQ_INT(parsed, 42, @"the parsed value must be the number that was written");

    IMP_ASSERT_TRUE(ParsePositiveInteger(@"1", 1, &parsed), @"the maximum itself must be accepted");
    IMP_ASSERT_EQ_INT(parsed, 1, @"the value at the maximum must still be reported");
    IMP_ASSERT_FALSE(ParsePositiveInteger(@"2", 1, &parsed), @"one over the maximum must be refused");
    IMP_ASSERT_TRUE(ParsePositiveInteger(@"100", 100, NULL), @"a NULL result pointer must still validate");
    IMP_ASSERT_FALSE(ParsePositiveInteger(@"101", 100, NULL), @"one over the maximum must be refused with no result");
    IMP_ASSERT_FALSE(ParsePositiveInteger(@"0", 100, &parsed), @"zero is not a positive integer");

    // The twenty-digit length gate and strtoull's range check have to agree:
    // between them lies every value that would wrap rather than be refused.
    IMP_ASSERT_TRUE(ParsePositiveInteger(@"18446744073709551615", NSUIntegerMax, &parsed),
                    @"the largest NSUInteger is twenty digits and must be accepted");
    IMP_ASSERT_TRUE(parsed == NSUIntegerMax, @"the largest NSUInteger must survive the parse, got %lu",
                    (unsigned long)parsed);
    IMP_ASSERT_FALSE(ParsePositiveInteger(@"18446744073709551616", NSUIntegerMax, &parsed),
                     @"one over the largest NSUInteger must be refused through ERANGE, not wrapped");
    IMP_ASSERT_FALSE(ParsePositiveInteger(@"123456789012345678901", NSUIntegerMax, &parsed),
                     @"a twenty-one digit value must be refused on length");

    // Accepted, and the reason ParseAllowedTargets re-formats the number and
    // compares it against the line it came from. Removing that compensating
    // check would let chat_id:042 and chat_id:42 name the same target under two
    // spellings, one of which the file would not round-trip.
    IMP_ASSERT_TRUE(ParsePositiveInteger(@"007", 100, &parsed), @"leading zeros are accepted here");
    IMP_ASSERT_EQ_INT(parsed, 7, @"a value with leading zeros parses as the number it spells");

    IMP_ASSERT_FALSE(ParsePositiveInteger(@"+5", 100, &parsed), @"a leading plus must be refused");
    IMP_ASSERT_FALSE(ParsePositiveInteger(@"-5", 100, &parsed), @"a leading minus must be refused, not negated");
    IMP_ASSERT_FALSE(ParsePositiveInteger(@" 5", 100, &parsed), @"a leading space must be refused, not skipped");
    IMP_ASSERT_FALSE(ParsePositiveInteger(@"5 ", 100, &parsed), @"a trailing space must be refused");
    IMP_ASSERT_FALSE(ParsePositiveInteger(@"5.0", 100, &parsed), @"a decimal point must be refused, not truncated");
    IMP_ASSERT_FALSE(ParsePositiveInteger(@"0x10", 100, &parsed), @"a hexadecimal spelling must be refused");
    IMP_ASSERT_FALSE(ParsePositiveInteger(@"", 100, &parsed), @"an empty string is not a number");
    IMP_ASSERT_FALSE(ParsePositiveInteger(NilString(), 100, &parsed), @"nil is not a number");

    // The ASCII round trip is the reason the digit loop can read bytes at all.
    // Full-width digits are digits to a human and to some parsers, and they
    // must not become an ASCII number here.
    IMP_ASSERT_FALSE(ParsePositiveInteger(@"\uFF14\uFF12", 100, &parsed), @"full-width digits must be refused");
    IMP_ASSERT_FALSE(ParsePositiveInteger(@"1\0002", 100, &parsed),
                     @"an embedded NUL must be refused rather than truncate the value to 1");
}

static void TestPublicOrigins(void) {
    // Whatever this accepts becomes an entry in the list -[IMPHTTPServer
    // originAllowed:] compares a browser's Origin header against, so it is the
    // one place an operator can widen who may drive the console. The grammar is
    // an origin and nothing else: everything a URL may carry beyond a scheme, a
    // host and a port is refused rather than trimmed, because a value a browser
    // would never send is a mistake that must be reported at startup rather
    // than accepted into a list it can never match.
    NSString *normalized = nil;
    IMP_ASSERT_TRUE(IsValidPublicOrigin(@"https://message.klee.me", &normalized),
                    @"the documented shape - https and a name - is the whole point of the setting");
    IMP_ASSERT_EQ_STR(normalized, @"https://message.klee.me", @"an already lowercase origin is returned unchanged");
    IMP_ASSERT_TRUE(IsValidPublicOrigin(@"http://console.example.com:8443", NULL),
                    @"http with a port is accepted, with a NULL out-pointer");
    IMP_ASSERT_TRUE(IsValidPublicOrigin(@"https://proxy", NULL), @"a single-label host is a host");
    IMP_ASSERT_TRUE(IsValidPublicOrigin(@"https://x-1.example-site.co.uk", NULL),
                    @"hyphens and digits inside a label are ordinary");
    IMP_ASSERT_TRUE(IsValidPublicOrigin(@"https://xn--sterreich-z7a.example", NULL),
                    @"a punycode label is the only spelling of an international name a browser sends");
    IMP_ASSERT_TRUE(IsValidPublicOrigin(@"http://192.168.1.10:8765", NULL), @"a dotted quad with a port is accepted");
    IMP_ASSERT_TRUE(IsValidPublicOrigin(@"http://10.0.0.5:1", NULL), @"port one is the lowest port");
    IMP_ASSERT_TRUE(IsValidPublicOrigin(@"http://10.0.0.5:65535", NULL), @"port 65535 is the highest port");

    // A browser lowercases the host in the Origin header it sends, so a value
    // spelled with capitals has to be folded here or the setting is accepted at
    // startup and then matches nothing an operator can produce.
    IMP_ASSERT_TRUE(IsValidPublicOrigin(@"https://Message.Klee.Me", &normalized), @"a capitalised name is accepted");
    IMP_ASSERT_EQ_STR(normalized, @"https://message.klee.me", @"the compared value is the folded one");

    // The scheme is exactly two words, in exactly one case. A browser sends the
    // scheme lowercase, and nothing else is a transport this console is served
    // over.
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"HTTPS://message.klee.me", NULL), @"an uppercase scheme must be refused");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"Http://message.klee.me", NULL), @"a capitalised scheme must be refused");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"ftp://message.klee.me", NULL), @"another scheme must be refused");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"//message.klee.me", NULL), @"a scheme-relative value has no scheme");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"message.klee.me", NULL), @"a bare host is not an origin");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"http:/message.klee.me", NULL), @"one slash is not the separator");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://", NULL), @"a scheme with no host is not an origin");

    // The two values a browser sends for cases this list must never widen to.
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"*", NULL), @"a wildcard must be refused");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"null", NULL),
                     @"the origin a sandboxed document sends must never be nameable");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"", NULL), @"an empty value is the feature being off, not an origin");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(NilString(), NULL), @"nil must be refused rather than crash on -hasPrefix:");
    IMP_ASSERT_FALSE(IsValidPublicOrigin((NSString *)@42, NULL), @"a number must be refused");

    // Everything beyond scheme, host and port. A browser sends none of it, so
    // each of these would validate and then match nothing.
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://message.klee.me/", NULL), @"a trailing slash must be refused");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://message.klee.me/console", NULL), @"a path must be refused");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://message.klee.me?a=1", NULL), @"a query must be refused");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://message.klee.me#top", NULL), @"a fragment must be refused");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://ops@message.klee.me", NULL), @"userinfo must be refused");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://ops:secret@message.klee.me", NULL),
                     @"a password in an origin must be refused rather than stored in a plist");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://message.klee.me:8443/", NULL),
                     @"a trailing slash after a port must be refused too");

    IMP_ASSERT_FALSE(IsValidPublicOrigin(@" https://message.klee.me", NULL), @"a leading space must be refused");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://message.klee.me ", NULL), @"a trailing space must be refused");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://message klee.me", NULL), @"an interior space must be refused");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://message.klee.me\n", NULL),
                     @"a trailing newline must be refused, or one setting spans two lines");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://message.klee.me\t", NULL), @"a tab must be refused");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://message.klee.me\0", NULL),
                     @"an embedded NUL must be refused rather than truncate the origin");
    // Written with %C for the reason StringAroundCodeUnit gives: C refuses a \u
    // escape that names a control character, and a literal one would be
    // invisible in exactly the way this input is meant to be.
    IMP_ASSERT_FALSE(IsValidPublicOrigin([NSString stringWithFormat:@"https://klee%Cme", (unichar)0x0085], NULL),
                     @"a next-line control inside the host must be refused");

    // The ASCII round trip. A full-width letter renders as the name an operator
    // reads and is a different host to every browser.
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://\uFF4Dessage.klee.me", NULL),
                     @"a full-width letter must not pass for the ASCII one");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://m\u00E9ssage.klee.me", NULL),
                     @"an accented letter must be refused; the punycode spelling is what a browser sends");

    // Ports, in the one spelling a browser uses. ParsePositiveInteger accepts a
    // leading zero, so the first digit is checked before it.
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"http://10.0.0.5:0", NULL), @"port zero is not a port");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"http://10.0.0.5:08443", NULL), @"a leading zero is not the canonical port");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"http://10.0.0.5:65536", NULL), @"one over the highest port must be refused");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"http://10.0.0.5:", NULL), @"a colon with no port must be refused");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"http://10.0.0.5:80:80", NULL), @"two ports must be refused");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"http://10.0.0.5:8a", NULL), @"a letter in the port must be refused");
    IMP_ASSERT_FALSE(
        IsValidPublicOrigin(@"http://[::1]:8765", NULL),
        @"an IPv6 literal must be refused; the listener is IPv4 and the brackets are not label characters");

    // A host of digits and dots is meant to be an address and is held to
    // inet_pton, because the label rules alone would read every one of these as
    // a perfectly good sequence of labels.
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://999.1.1.1", NULL), @"an octet over 255 is not an address");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://1.2.3", NULL), @"three octets is not an address");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://1.2.3.4.5", NULL), @"five octets is not an address");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://010.1.1.1", NULL),
                     @"a leading zero is 8 to some resolvers and 10 to others");

    // Labels, which is what the rest of the hosts are.
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://.klee.me", NULL), @"a leading dot leaves an empty label");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://klee.me.", NULL), @"a trailing dot leaves an empty label");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://klee..me", NULL), @"two dots leave an empty label between them");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://-klee.me", NULL), @"a label may not begin with a hyphen");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://klee-.me", NULL), @"a label may not end with a hyphen");
    IMP_ASSERT_FALSE(IsValidPublicOrigin(@"https://klee_me.example", NULL), @"an underscore is not a label character");
    IMP_ASSERT_TRUE(IsValidPublicOrigin([@"https://" stringByAppendingFormat:@"%@.me", Repeated(@"a", 63)], NULL),
                    @"a sixty-three character label is exactly at the bound");
    IMP_ASSERT_FALSE(IsValidPublicOrigin([@"https://" stringByAppendingFormat:@"%@.me", Repeated(@"a", 64)], NULL),
                     @"a sixty-four character label is one over the bound");

    // The whole value is bounded in bytes, so a name assembled from legal labels
    // cannot grow without limit.
    NSString *longestHost = [NSString stringWithFormat:@"%@.%@.%@.%@", Repeated(@"a", 60), Repeated(@"a", 60),
                                                       Repeated(@"a", 60), Repeated(@"a", 62)];
    NSString *longest = [@"https://" stringByAppendingString:longestHost];
    IMP_ASSERT_EQ_INT(longest.length, 253, @"the fixture is exactly at the bound");
    IMP_ASSERT_TRUE(IsValidPublicOrigin(longest, NULL), @"two hundred and fifty-three bytes is exactly at the bound");
    IMP_ASSERT_FALSE(IsValidPublicOrigin([longest stringByAppendingString:@"a"], NULL),
                     @"one byte over the bound must be refused");
}

static void TestDirectMessageRecipients(void) {
    // Anything this accepts becomes a permitted send target and then an argv
    // value handed to the pinned binary.
    IMP_ASSERT_TRUE(IsDirectMessageRecipient(@"+15551234567"), @"an E.164 number is a recipient");
    IMP_ASSERT_TRUE(IsDirectMessageRecipient(@"+1234567"), @"seven digits is the shortest accepted number");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"+123456"), @"six digits is one under the shortest number");
    IMP_ASSERT_TRUE(IsDirectMessageRecipient(@"+123456789012345"), @"fifteen digits is the longest accepted number");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"+1234567890123456"), @"sixteen digits is one over the longest number");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"+0123456789"), @"no country code begins with zero");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"+"), @"a lone plus is not a number");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"+1555123456a"), @"a letter among the digits must be refused");

    IMP_ASSERT_TRUE(IsDirectMessageRecipient(@"a@b"), @"the shortest handle has one character either side of the at");
    IMP_ASSERT_TRUE(IsDirectMessageRecipient(@"user@example.com"), @"an ordinary handle is a recipient");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"@b"), @"an at-sign at index zero leaves no local part");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"a@"), @"an at-sign at the end leaves nothing after it");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"a@b@c"), @"two at-signs must be refused");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"ab"), @"a value with neither a plus nor an at is not a recipient");

    // A value beginning with a hyphen would be read by the pinned binary as an
    // option rather than as a target, which is how an allowlist entry becomes
    // an argument injection.
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"-to"), @"a leading hyphen must be refused");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"--db"), @"a long option spelling must be refused");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"-a@b"), @"a leading hyphen must be refused even on a valid handle");

    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"a b@c"), @"an interior space must be refused");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"a@b\n"), @"a newline must be refused, or one target becomes two lines");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"a@b\t"), @"a tab must be refused");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"a@b\0"), @"an embedded NUL must be refused");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@""), @"an empty string is not a recipient");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(NilString()), @"nil must be refused rather than crash");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"\U0001F600"), @"a single emoji is neither a number nor a handle");

    // The zero-width joiner is category Cf, which controlCharacterSet holds, so
    // two handles that render identically cannot both be accepted.
    IMP_ASSERT_FALSE(IsDirectMessageRecipient(@"a@b\u200D"), @"a zero-width joiner must be refused");

    // The bound is 256 code points, not 256 UTF-16 units. Measuring the string
    // with -length instead would refuse a legal handle of 129 astral characters
    // and accept one of 511.
    IMP_ASSERT_TRUE(IsDirectMessageRecipient([Repeated(@"\U0001F600", 254) stringByAppendingString:@"@a"]),
                    @"a 256-code-point handle is exactly at the bound");
    IMP_ASSERT_FALSE(IsDirectMessageRecipient([Repeated(@"\U0001F600", 255) stringByAppendingString:@"@a"]),
                     @"a 257-code-point handle is one over the bound");

    // Accepted through the handle rule rather than the number rule, because the
    // digits after the plus stop at the at-sign. Pinned so that tightening the
    // number rule is not mistaken for tightening this.
    IMP_ASSERT_TRUE(IsDirectMessageRecipient(@"+1@b.com"), @"a plus-prefixed value with an at-sign is a handle");
}

static void TestAllowedTargetFiles(void) {
    // One malformed line rejects the whole file rather than being skipped:
    // silently ignoring a line an operator believed they had authorised is the
    // worse failure, and this is the parser both startup and every send use.
    NSMutableSet<NSString *> *recipients = nil;
    NSMutableSet<NSString *> *chatIDs = nil;
    IMP_ASSERT_TRUE(ParseAllowedTargets(@"a@b\nchat_id:42\n# note\n\n+15551234567", &recipients, &chatIDs, NULL),
                    @"a file of handles, chat ids, a comment and a blank line is valid");
    NSSet<NSString *> *expectedRecipients = [NSSet setWithArray:@[@"a@b", @"+15551234567"]];
    IMP_ASSERT_TRUE([recipients isEqualToSet:expectedRecipients], @"both recipients must be collected, got %@",
                    recipients);
    IMP_ASSERT_TRUE([chatIDs isEqualToSet:[NSSet setWithObject:@"42"]], @"the chat id must be collected, got %@",
                    chatIDs);

    recipients = nil;
    chatIDs = nil;
    IMP_ASSERT_TRUE(ParseAllowedTargets(@"# only a comment\n\n   \n", &recipients, &chatIDs, NULL),
                    @"a file of comments and blank lines is valid");
    IMP_ASSERT_EQ_INT(recipients.count, 0, @"a file with no targets must produce an empty recipient set");
    IMP_ASSERT_EQ_INT(chatIDs.count, 0, @"a file with no targets must produce an empty chat id set");

    // A CR is a newline to newlineCharacterSet, so a file written on Windows
    // splits into the same targets with an empty line between them.
    recipients = nil;
    IMP_ASSERT_TRUE(ParseAllowedTargets(@"a@b\r\nc@d", &recipients, NULL, NULL), @"a CRLF file is valid");
    NSSet<NSString *> *expectedFromCRLF = [NSSet setWithArray:@[@"a@b", @"c@d"]];
    IMP_ASSERT_TRUE([recipients isEqualToSet:expectedFromCRLF],
                    @"CRLF must not turn one target into two spellings, got %@", recipients);

    IMP_ASSERT_TRUE(ParseAllowedTargets(@"  a@b  ", &recipients, NULL, NULL), @"a padded line is valid");
    IMP_ASSERT_TRUE([recipients isEqualToSet:[NSSet setWithObject:@"a@b"]],
                    @"the stored recipient must be the trimmed one, got %@", recipients);

    // The re-format is what makes a chat id canonical. Without it the file
    // could hold chat_id:042 and chat_id:42, which name one chat under two
    // strings the service compares by string.
    IMP_ASSERT_FALSE(ParseAllowedTargets(@"chat_id:042", NULL, NULL, NULL),
                     @"a non-canonical chat id must be refused rather than normalised");
    IMP_ASSERT_FALSE(ParseAllowedTargets(@"chat_id:0", NULL, NULL, NULL), @"chat id zero must be refused");
    IMP_ASSERT_FALSE(ParseAllowedTargets(@"chat_id: 42", NULL, NULL, NULL),
                     @"a space after the colon must be refused rather than trimmed into the number");
    IMP_ASSERT_FALSE(ParseAllowedTargets(@"chat_id:", NULL, NULL, NULL), @"an empty chat id must be refused");
    IMP_ASSERT_TRUE(ParseAllowedTargets(@"chat_id:9223372036854775807", NULL, NULL, NULL),
                    @"NSIntegerMax is the largest chat id the parser admits");
    IMP_ASSERT_FALSE(ParseAllowedTargets(@"chat_id:9223372036854775808", NULL, NULL, NULL),
                     @"one over NSIntegerMax must be refused");

    // Neither out-set may be written when a later line fails, or a caller that
    // ignored the return value would authorise the targets it did parse.
    NSMutableSet<NSString *> *partialRecipients = nil;
    NSMutableSet<NSString *> *partialChatIDs = nil;
    NSError *error = nil;
    IMP_ASSERT_FALSE(ParseAllowedTargets(@"a@b\n!!!\nc@d", &partialRecipients, &partialChatIDs, &error),
                     @"one malformed line must reject the whole file");
    IMP_ASSERT_NIL(partialRecipients, @"a rejected file must leave the recipient out-parameter untouched");
    IMP_ASSERT_NIL(partialChatIDs, @"a rejected file must leave the chat id out-parameter untouched");
    IMP_ASSERT_NOT_NIL(error, @"a rejected file must report why");
    IMP_ASSERT_EQ_INT(error.code, IMPServerErrorInvalidConfiguration,
                      @"a bad allowlist is a configuration error, which is what the caller reports as such");

    IMP_ASSERT_TRUE(ParseAllowedTargets(@"a@b", NULL, NULL, NULL), @"NULL out-parameters must still validate");
    IMP_ASSERT_TRUE(ParseAllowedTargets(@"", NULL, NULL, NULL), @"an empty file authorises nothing and is valid");
}

static void TestAllowedTargetLines(void) {
    // One submitted string must mean exactly one stored target, which is why
    // this counts what the shared parser produced rather than re-validating.
    IMP_ASSERT_TRUE(IsAllowedTargetLine(@"a@b"), @"one handle is one target");
    IMP_ASSERT_TRUE(IsAllowedTargetLine(@"chat_id:42"), @"one chat id is one target");
    IMP_ASSERT_FALSE(IsAllowedTargetLine(@"a@b\nc@d"), @"a value carrying a newline would be stored as two targets");
    IMP_ASSERT_FALSE(IsAllowedTargetLine(@"# a@b"), @"a commented value would be stored as none");
    IMP_ASSERT_FALSE(IsAllowedTargetLine(@""), @"an empty value is no target");
    IMP_ASSERT_FALSE(IsAllowedTargetLine(@"   "), @"a whitespace-only value is no target");
    IMP_ASSERT_FALSE(IsAllowedTargetLine(@"\n"), @"a lone newline is no target");
    IMP_ASSERT_FALSE(IsAllowedTargetLine(@"!!!"), @"a malformed value is refused by the parser");

    // Both of these count as one target because the parser collects into sets
    // and skips comments, while -[IMPServer replaceTargets:] writes the string
    // it was given. The file therefore ends up with two lines where the caller
    // was told it stored one. Asserted as it behaves today so that changing it
    // is a decision rather than an accident.
    IMP_ASSERT_TRUE(IsAllowedTargetLine(@"a@b\na@b"), @"a repeated handle collapses to one target in the set");
    IMP_ASSERT_TRUE(IsAllowedTargetLine(@"a@b\n#c"), @"a handle followed by a comment counts as one target");
}

static void TestUnicodeCodePointLength(void) {
    // The bound on message text, on recipients and on query names and values is
    // measured with this. Counting UTF-16 units instead would reject a legal
    // message of 2001 emoji and accept a recipient twice the documented length.
    IMP_ASSERT_EQ_INT(UnicodeCodePointLength(@"abc"), 3, @"ASCII counts one per character");
    IMP_ASSERT_EQ_INT(UnicodeCodePointLength(@"h\u00E9llo"), 5, @"a Latin-1 letter is one code point");
    IMP_ASSERT_EQ_INT(UnicodeCodePointLength(@""), 0, @"the empty string has no code points");
    IMP_ASSERT_EQ_INT(UnicodeCodePointLength(NilString()), 0, @"nil must count as zero rather than crash");

    IMP_ASSERT_EQ_INT(@"\U0001F516".length, 2, @"the fixture must really be a surrogate pair");
    IMP_ASSERT_EQ_INT(UnicodeCodePointLength(@"\U0001F516"), 1, @"an astral character is one code point");
    IMP_ASSERT_EQ_INT(UnicodeCodePointLength(@"a\U0001F516b"), 3, @"a surrogate pair between two letters counts once");

    // A combining mark is its own code point, so a rendered character can cost
    // more than one against a bound. Pinned because it is the case a reviewer
    // reaches for when a message length looks wrong.
    IMP_ASSERT_EQ_INT(UnicodeCodePointLength(@"e\u0301"), 2, @"a combining acute is counted separately");

    NSString *fourThousand = Repeated(@"\U0001F516", 4000);
    IMP_ASSERT_EQ_INT(fourThousand.length, 8000, @"the fixture must be eight thousand UTF-16 units");
    IMP_ASSERT_EQ_INT(UnicodeCodePointLength(fourThousand), 4000,
                      @"four thousand astral characters must count as four thousand code points");
}

static void TestSafeMessageText(void) {
    // The last filter before text is appended with a sender marker and handed
    // to the pinned binary as an argv value. Tab, newline and carriage return
    // are deliberately allowed; nothing else in the control set is.
    IMP_ASSERT_TRUE(IsSafeMessageText(@"hello"), @"ordinary text is safe");
    IMP_ASSERT_TRUE(IsSafeMessageText(@"a\tb\nc\r"), @"tab, newline and carriage return are the three exceptions");
    IMP_ASSERT_TRUE(IsSafeMessageText(@""), @"an empty message carries nothing unsafe; the length rule is elsewhere");
    IMP_ASSERT_TRUE(IsSafeMessageText(@"a\U0001F600b"), @"an emoji is not a control character");
    IMP_ASSERT_FALSE(IsSafeMessageText(NilString()), @"nil must be refused rather than treated as empty");

    IMP_ASSERT_FALSE(IsSafeMessageText(@"a\0b"), @"an embedded NUL must be refused before it truncates an argv value");
    IMP_ASSERT_FALSE(IsSafeMessageText(StringAroundCodeUnit(0x001B)),
                     @"an escape character must be refused, or a message repaints the operator's terminal");
    IMP_ASSERT_FALSE(IsSafeMessageText(StringAroundCodeUnit(0x007F)), @"DEL must be refused");
    IMP_ASSERT_FALSE(IsSafeMessageText(StringAroundCodeUnit(0x0085)), @"the C1 next-line control must be refused");
    IMP_ASSERT_FALSE(IsSafeMessageText(StringAroundCodeUnit(0x0001)),
                     @"a C0 control other than the three must be refused");

    // Category Cf is in controlCharacterSet as well as Cc, so the bidirectional
    // overrides that make a message render as something other than what it says
    // are refused here rather than at some later layer that does not exist.
    IMP_ASSERT_FALSE(IsSafeMessageText(@"a\u202Eb"), @"a right-to-left override must be refused");
    IMP_ASSERT_FALSE(IsSafeMessageText(@"a\u200Db"), @"a zero-width joiner must be refused");
}

static void TestSafeFilenameComponents(void) {
    // The whole of the traversal defence AttachmentDTO leans on.
    IMP_ASSERT_TRUE(IsSafeFilenameComponent(@"photo.png"), @"an ordinary filename is safe");
    IMP_ASSERT_FALSE(IsSafeFilenameComponent(@"."), @"the current directory is not a filename");
    IMP_ASSERT_FALSE(IsSafeFilenameComponent(@".."), @"the parent directory is not a filename");
    IMP_ASSERT_FALSE(IsSafeFilenameComponent(@""), @"an empty component is not a filename");
    IMP_ASSERT_FALSE(IsSafeFilenameComponent(NilString()), @"nil must be refused rather than crash");
    IMP_ASSERT_FALSE(IsSafeFilenameComponent(@"a/b"), @"a POSIX separator must be refused");
    IMP_ASSERT_FALSE(IsSafeFilenameComponent(@"a\\b"), @"a Windows separator must be refused");
    IMP_ASSERT_FALSE(IsSafeFilenameComponent(@"a\0b"), @"an embedded NUL must be refused");
    IMP_ASSERT_FALSE(IsSafeFilenameComponent(@"a\nb"), @"a newline must be refused");

    // Both are accepted. Neither escapes a directory, but a reviewer tightening
    // this predicate should know they are the two values that look like they
    // ought to be refused and are not.
    IMP_ASSERT_TRUE(IsSafeFilenameComponent(@"..."), @"three dots is an ordinary name and is accepted");
    IMP_ASSERT_TRUE(IsSafeFilenameComponent(@" "), @"a single space is accepted");
}

static void TestReasonPhrases(void) {
    // Emitted in the status line and as the title of every problem body, so a
    // status the router can produce but this cannot name reaches a caller as
    // the word "Error" with no explanation of which error.
    IMP_ASSERT_EQ_STR(ReasonPhrase(200), @"OK", @"200 is the ordinary success");
    IMP_ASSERT_EQ_STR(ReasonPhrase(201), @"Created", @"201 answers a key creation");
    IMP_ASSERT_EQ_STR(ReasonPhrase(202), @"Accepted", @"202 answers an accepted send");
    IMP_ASSERT_EQ_STR(ReasonPhrase(204), @"No Content", @"204 answers a body-less success");
    IMP_ASSERT_EQ_STR(ReasonPhrase(400), @"Bad Request", @"400 answers every validator in this file");
    IMP_ASSERT_EQ_STR(ReasonPhrase(401), @"Unauthorized", @"401 answers a missing or bad credential");
    IMP_ASSERT_EQ_STR(ReasonPhrase(403), @"Forbidden", @"403 answers a scope the key does not hold");
    IMP_ASSERT_EQ_STR(ReasonPhrase(404), @"Not Found", @"404 answers an unknown route or chat");
    IMP_ASSERT_EQ_STR(ReasonPhrase(409), @"Conflict", @"409 answers a disabled read path and a taken identifier");
    IMP_ASSERT_EQ_STR(ReasonPhrase(413), @"Payload Too Large", @"413 answers a body over the request bound");
    IMP_ASSERT_EQ_STR(ReasonPhrase(415), @"Unsupported Media Type", @"415 answers a non-JSON content type");
    IMP_ASSERT_EQ_STR(ReasonPhrase(429), @"Too Many Requests", @"429 answers the rate limiter");
    IMP_ASSERT_EQ_STR(ReasonPhrase(431), @"Request Header Fields Too Large", @"431 answers headers over the bound");
    IMP_ASSERT_EQ_STR(ReasonPhrase(500), @"Internal Server Error", @"500 answers an unhandled failure");
    IMP_ASSERT_EQ_STR(ReasonPhrase(502), @"Bad Gateway", @"502 answers a dependency that failed");
    IMP_ASSERT_EQ_STR(ReasonPhrase(503), @"Service Unavailable", @"503 answers a store that is unavailable");
    IMP_ASSERT_EQ_STR(ReasonPhrase(504), @"Gateway Timeout", @"504 answers a dependency that ran out of time");

    IMP_ASSERT_EQ_STR(ReasonPhrase(418), @"Error", @"an unmapped status falls back to the placeholder");
    IMP_ASSERT_EQ_STR(ReasonPhrase(0), @"Error", @"zero is not a status and falls back");
    IMP_ASSERT_EQ_STR(ReasonPhrase(-1), @"Error", @"a negative status falls back rather than indexing anything");
    IMP_ASSERT_EQ_STR(ReasonPhrase(NSIntegerMax), @"Error", @"the largest NSInteger falls back");
}

static void TestJSONContentTypes(void) {
    // The 415 gate on POST /api/messages and POST /api/keys. It splits on the
    // first semicolon, trims and folds case, so the parameter handling is the
    // whole of the behaviour.
    IMP_ASSERT_TRUE(IsJSONContentType(@"application/json"), @"the bare media type is accepted");
    IMP_ASSERT_TRUE(IsJSONContentType(@"application/json; charset=utf-8"), @"a charset parameter must not refuse it");
    IMP_ASSERT_TRUE(IsJSONContentType(@"Application/JSON"), @"the media type is case insensitive");
    IMP_ASSERT_TRUE(IsJSONContentType(@"  application/json  "), @"surrounding whitespace must be trimmed");
    IMP_ASSERT_TRUE(IsJSONContentType(@"application/json ;x"), @"whitespace before the semicolon must be trimmed");

    IMP_ASSERT_FALSE(IsJSONContentType(@"text/json"), @"a different type must be refused");
    IMP_ASSERT_FALSE(IsJSONContentType(@"application/json-patch+json"),
                     @"a longer media type must be refused, not matched as a prefix");
    IMP_ASSERT_FALSE(IsJSONContentType(@"application/jsonx"), @"a suffixed media type must be refused");
    IMP_ASSERT_FALSE(IsJSONContentType(@";application/json"),
                     @"the media type is what precedes the first semicolon, so this one is empty");
    IMP_ASSERT_FALSE(IsJSONContentType(@""), @"an empty header must be refused");
    IMP_ASSERT_FALSE(IsJSONContentType(NilString()), @"an absent header must be refused rather than crash");
}

static void TestQueryParsing(void) {
    // Every query string reaches every route through this, and it builds a URL
    // by concatenation, so URL syntax the caller did not intend is parsed as
    // URL syntax.
    NSError *error = nil;
    NSDictionary *parsed = ParseQueryAllowingRepeatedNames(@"limit=5", [NSSet set], &error);
    IMP_ASSERT_TRUE([parsed isEqualToDictionary:@{@"limit": @"5"}], @"one parameter parses to one entry, got %@",
                    parsed);

    IMP_ASSERT_TRUE([ParseQueryAllowingRepeatedNames(@"", [NSSet set], &error) isEqualToDictionary:@{}],
                    @"an empty query is an empty dictionary, not a failure");

    // A repeated name is a caller mistake unless the route asked for it, and
    // taking the last silently would make ?limit=1&limit=1000 mean 1000.
    error = nil;
    IMP_ASSERT_NIL(ParseQueryAllowingRepeatedNames(@"limit=1&limit=2", [NSSet set], &error),
                   @"a repeated name the route did not permit must be refused");
    IMP_ASSERT_NOT_NIL(error, @"a refused query must report why");
    IMP_ASSERT_EQ_INT(error.code, IMPServerErrorRequest,
                      @"a bad query is a request error, which the router maps to 400");

    NSDictionary *repeated =
        ParseQueryAllowingRepeatedNames(@"participant=a&participant=b", [NSSet setWithObject:@"participant"], NULL);
    NSDictionary *expectedRepeated = @{@"participant": @[@"a", @"b"]};
    IMP_ASSERT_TRUE([repeated isEqualToDictionary:expectedRepeated], @"a permitted repeat collects in order, got %@",
                    repeated);

    // A name with no equals sign has a nil value, and a name with an empty one
    // has an empty string. The two are different requests and only one is legal.
    IMP_ASSERT_NIL(ParseQueryAllowingRepeatedNames(@"limit", [NSSet set], NULL), @"a valueless name must be refused");
    IMP_ASSERT_TRUE(
        [ParseQueryAllowingRepeatedNames(@"limit=", [NSSet set], NULL) isEqualToDictionary:@{@"limit": @""}],
        @"an empty value is a value");
    IMP_ASSERT_NIL(ParseQueryAllowingRepeatedNames(@"=5", [NSSet set], NULL), @"an empty name must be refused");

    NSDictionary *decoded = ParseQueryAllowingRepeatedNames(@"a=%20b", [NSSet set], NULL);
    IMP_ASSERT_EQ_STR(decoded[@"a"], @" b", @"a percent escape must be decoded once, not left literal");

    // A plus is not a space in a URL query as NSURLComponents reads it, so a
    // caller that form-encodes gets the plus through to the route.
    NSDictionary *plus = ParseQueryAllowingRepeatedNames(@"a=b+c", [NSSet set], NULL);
    IMP_ASSERT_EQ_STR(plus[@"a"], @"b+c", @"a plus must arrive as a plus rather than as a space");

    // Both of these are decided entirely by NSURLComponents, and the two
    // platforms decide them differently - see the divergences recorded in
    // foundation-parity.m. GNUstep refuses the string; Apple accepts it and
    // hands the query through with the offending text intact. Neither is
    // reachable over HTTP: the request line is delimited by spaces and
    // terminated by CRLF, so a target carrying a raw space parses as too many
    // fields and never reaches here, and a stray percent survives as literal
    // text that every parameter validator downstream rejects on its own terms.
    // They are asserted per platform because the alternative is a suite that
    // states a rule the product does not have on the platform it ships to.
#if defined(__APPLE__)
    IMP_ASSERT_EQ_STR(ParseQueryAllowingRepeatedNames(@"a=%zz", [NSSet set], NULL)[@"a"], @"%zz",
                      @"a stray percent arrives as literal text on Darwin");
    IMP_ASSERT_EQ_STR(ParseQueryAllowingRepeatedNames(@"a= b", [NSSet set], NULL)[@"a"], @" b",
                      @"a raw space is tolerated by NSURLComponents on Darwin");
#else
    IMP_ASSERT_NIL(ParseQueryAllowingRepeatedNames(@"a=%zz", [NSSet set], NULL),
                   @"GNUstep refuses a malformed percent escape outright");
    IMP_ASSERT_NIL(ParseQueryAllowingRepeatedNames(@"a= b", [NSSet set], NULL),
                   @"GNUstep refuses a raw space outright");
#endif

    // Everything after an unescaped hash is a URL fragment and never reaches
    // the query. Pinned because it means a caller can hide a parameter from the
    // route while the request line still shows it.
    NSDictionary *fragment = ParseQueryAllowingRepeatedNames(@"limit=1#anything", [NSSet set], NULL);
    IMP_ASSERT_TRUE([fragment isEqualToDictionary:@{@"limit": @"1"}],
                    @"a hash ends the query and the rest is dropped, got %@", fragment);

    NSString *name = Repeated(@"n", 64);
    IMP_ASSERT_NOT_NIL(ParseQueryAllowingRepeatedNames([name stringByAppendingString:@"=1"], [NSSet set], NULL),
                       @"a 64-code-point name is exactly at the bound");
    IMP_ASSERT_NIL(
        ParseQueryAllowingRepeatedNames([Repeated(@"n", 65) stringByAppendingString:@"=1"], [NSSet set], NULL),
        @"a 65-code-point name is one over the bound");
    IMP_ASSERT_NOT_NIL(
        ParseQueryAllowingRepeatedNames([@"a=" stringByAppendingString:Repeated(@"v", 512)], [NSSet set], NULL),
        @"a 512-code-point value is exactly at the bound");
    IMP_ASSERT_NIL(
        ParseQueryAllowingRepeatedNames([@"a=" stringByAppendingString:Repeated(@"v", 513)], [NSSet set], NULL),
        @"a 513-code-point value is one over the bound");
}

static void TestNumberProvenance(void) {
    // Every numeric field of every DTO funnels through these two, and @YES and
    // @1 are indistinguishable without asking CFGetTypeID. An audit status of
    // true would otherwise sail through a range check as a 1.
    NSDictionary *parsed = ParsedJSON(@"{\"t\":true,\"f\":false,\"n\":1,\"z\":0,\"neg\":-3,\"d\":1.5,\"s\":\"1\"}");
    IMP_ASSERT_NOT_NIL(parsed, @"the provenance fixture must parse");
    IMP_ASSERT_TRUE(IsIntegerNumber(parsed[@"n"]), @"a JSON integer is an integer");
    IMP_ASSERT_TRUE(IsIntegerNumber(parsed[@"z"]), @"JSON zero is an integer");
    IMP_ASSERT_TRUE(IsIntegerNumber(parsed[@"neg"]), @"a negative JSON integer is an integer");
    IMP_ASSERT_FALSE(IsIntegerNumber(parsed[@"t"]), @"JSON true must not pass as the integer one");
    IMP_ASSERT_FALSE(IsIntegerNumber(parsed[@"f"]), @"JSON false must not pass as the integer zero");
    IMP_ASSERT_FALSE(IsIntegerNumber(parsed[@"d"]), @"a JSON fraction is not an integer");
    IMP_ASSERT_FALSE(IsIntegerNumber(parsed[@"s"]), @"a JSON string is not an integer");

    IMP_ASSERT_TRUE(IsBooleanNumber(parsed[@"t"]), @"JSON true is a boolean");
    IMP_ASSERT_TRUE(IsBooleanNumber(parsed[@"f"]), @"JSON false is a boolean");
    IMP_ASSERT_FALSE(IsBooleanNumber(parsed[@"n"]), @"a JSON integer is not a boolean");
    IMP_ASSERT_FALSE(IsBooleanNumber(parsed[@"s"]), @"a JSON string is not a boolean");
    IMP_ASSERT_FALSE(IsBooleanNumber(NilString()), @"nil is not a boolean");

    IMP_ASSERT_FALSE(IsIntegerNumber(@YES), @"a literal boolean must be refused as well as a parsed one");
    IMP_ASSERT_FALSE(IsIntegerNumber(@NO), @"a literal false must be refused as well as a parsed one");
    IMP_ASSERT_TRUE(IsIntegerNumber(@(1.0)), @"a whole double is an integer, which is how JSON spells one");
    IMP_ASSERT_FALSE(IsIntegerNumber(@1.5), @"a fractional double is not an integer");
    IMP_ASSERT_FALSE(IsIntegerNumber([NSDecimalNumber notANumber]), @"NaN must be refused before it is compared");
    IMP_ASSERT_FALSE(IsIntegerNumber(NSNull.null), @"a JSON null is not a number");
    IMP_ASSERT_FALSE(IsIntegerNumber(NilString()), @"an absent value is not a number");
    IMP_ASSERT_FALSE(IsIntegerNumber(@"1"), @"a string that spells a number is not a number");

    // The range check is what keeps a chat id that cannot be a chat id out of
    // an argv slot.
    IMP_ASSERT_FALSE(IsIntegerNumber(@1e19), @"a value beyond LLONG_MAX must be refused");
    IMP_ASSERT_FALSE(IsIntegerNumber(@-1e19), @"a value below LLONG_MIN must be refused");
#if IMPTimestampsParse
    // Fenced with the timestamp checks for the same reason: this host's
    // NSJSONSerialization is the one that answers exactly, and
    // foundation-parity.m records that GNUstep's rounds past 2^53.
    IMP_ASSERT_TRUE(IsIntegerNumber(@(LLONG_MAX)), @"LLONG_MAX itself is inside the range");
    IMP_ASSERT_TRUE(IsIntegerNumber(@(LLONG_MIN)), @"LLONG_MIN itself is inside the range");
#endif
}

// Every field ExecutableMetadataMatches compares, set to something no zeroed
// struct would hold, so a check that clears one field is testing the comparison
// rather than a value that was already equal on both sides.
static struct stat PinnedMetadata(void) {
    struct stat metadata;
    memset(&metadata, 0, sizeof(metadata));
    metadata.st_dev = 1;
    metadata.st_ino = 2;
    metadata.st_mode = S_IFREG | 0500;
    metadata.st_uid = 501;
    metadata.st_gid = 20;
    metadata.st_nlink = 1;
    metadata.st_size = 4096;
#if defined(__APPLE__)
    metadata.st_gen = 3;
    metadata.st_flags = 5;
#endif
    metadata.st_mtimespec.tv_sec = 1704067200;
    metadata.st_mtimespec.tv_nsec = 123;
    metadata.st_ctimespec.tv_sec = 1704067201;
    metadata.st_ctimespec.tv_nsec = 456;
    return metadata;
}

#define IMP_ASSERT_STAT_FIELD_IS_COMPARED(field, replacement)                                                          \
    do {                                                                                                               \
        struct stat impExpected = PinnedMetadata();                                                                    \
        struct stat impActual = PinnedMetadata();                                                                      \
        impActual.field = (replacement);                                                                               \
        IMP_ASSERT_FALSE(ExecutableMetadataMatches(&impExpected, &impActual),                                          \
                         @"a change to " #field " must break the pin on the imsg executable");                         \
    } while (0)

static void TestExecutableMetadata(void) {
    // The TOCTOU defence: the pinned binary is stat-ed after it is hashed and
    // again immediately before posix_spawn, and this is what decides the two
    // are the same file. Every term dropped is a way to swap the executable
    // between the hash and the exec, so each is asserted on its own.
    struct stat expected = PinnedMetadata();
    struct stat actual = PinnedMetadata();
    IMP_ASSERT_TRUE(ExecutableMetadataMatches(&expected, &actual), @"identical metadata must match");

    IMP_ASSERT_STAT_FIELD_IS_COMPARED(st_dev, 2);
    IMP_ASSERT_STAT_FIELD_IS_COMPARED(st_ino, 3);
    IMP_ASSERT_STAT_FIELD_IS_COMPARED(st_mode, S_IFREG | 0700);
    IMP_ASSERT_STAT_FIELD_IS_COMPARED(st_uid, 502);
    IMP_ASSERT_STAT_FIELD_IS_COMPARED(st_gid, 21);
    IMP_ASSERT_STAT_FIELD_IS_COMPARED(st_nlink, 2);
    IMP_ASSERT_STAT_FIELD_IS_COMPARED(st_size, 4097);
#if defined(__APPLE__)
    // The generation counter and the file flags exist only on Darwin, so this
    // run pins eleven of the thirteen terms and a Mac pins all thirteen. A
    // regression that drops either of these two is therefore invisible to a
    // Linux run, which is the price of the platform split in
    // ExecutableMetadataMatches and the reason src/ is compiled on macOS in CI
    // as well as here.
    IMP_ASSERT_STAT_FIELD_IS_COMPARED(st_gen, 4);
    IMP_ASSERT_STAT_FIELD_IS_COMPARED(st_flags, 6);
#endif
    IMP_ASSERT_STAT_FIELD_IS_COMPARED(st_mtimespec.tv_sec, 1704067201);
    IMP_ASSERT_STAT_FIELD_IS_COMPARED(st_mtimespec.tv_nsec, 124);
    IMP_ASSERT_STAT_FIELD_IS_COMPARED(st_ctimespec.tv_sec, 1704067202);
    IMP_ASSERT_STAT_FIELD_IS_COMPARED(st_ctimespec.tv_nsec, 457);

    // Both sides have to be regular files, so a directory that somehow carried
    // identical metadata is still refused, and a pair of zeroed structs - what
    // a failed lstat leaves behind - matches nothing.
    struct stat directory = PinnedMetadata();
    directory.st_mode = S_IFDIR | 0700;
    struct stat otherDirectory = directory;
    IMP_ASSERT_FALSE(ExecutableMetadataMatches(&directory, &otherDirectory),
                     @"two identical directories must not satisfy an executable pin");
    IMP_ASSERT_FALSE(ExecutableMetadataMatches(&expected, &directory),
                     @"a regular file and a directory must not match");

    struct stat zeroed;
    struct stat otherZeroed;
    memset(&zeroed, 0, sizeof(zeroed));
    memset(&otherZeroed, 0, sizeof(otherZeroed));
    IMP_ASSERT_FALSE(ExecutableMetadataMatches(&zeroed, &otherZeroed),
                     @"two zeroed structs must not match, or a failed stat would satisfy the pin");
}

static void TestPinnedChatNotFound(void) {
    // Turns a nonzero exit from the pinned binary into a 404 rather than a 502
    // by matching its stdout exactly. Anything looser would report a dependency
    // that crashed while printing something similar as an ordinary empty answer.
    NSData *groupOutput = [@"Chat not found: 42\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSArray<NSString *> *groupArguments = @[@"group", @"--chat-id", @"42"];
    IMP_ASSERT_TRUE(IsPinnedChatNotFoundResult(ProcessResult(1, groupOutput, nil), groupArguments),
                    @"the group command's own not-found message is a not-found");
    IMP_ASSERT_FALSE(IsPinnedChatNotFoundResult(ProcessResult(0, groupOutput, nil), groupArguments),
                     @"a successful exit is never a not-found, whatever it printed");
    IMP_ASSERT_FALSE(
        IsPinnedChatNotFoundResult(
            ProcessResult(1, [@"Chat not found: 43\n" dataUsingEncoding:NSUTF8StringEncoding], nil), groupArguments),
        @"a not-found naming a different chat must not answer for this one");
    IMP_ASSERT_FALSE(IsPinnedChatNotFoundResult(
                         ProcessResult(1, [@"Chat not found: 42\nmore" dataUsingEncoding:NSUTF8StringEncoding], nil),
                         groupArguments),
                     @"output with anything after the message must not be read as a not-found");
    IMP_ASSERT_FALSE(
        IsPinnedChatNotFoundResult(
            ProcessResult(1, [@"Chat Not Found: 42" dataUsingEncoding:NSUTF8StringEncoding], nil), groupArguments),
        @"the match is case sensitive because the dependency's spelling is fixed");
    IMP_ASSERT_FALSE(IsPinnedChatNotFoundResult(ProcessResult(1, groupOutput, nil), @[@"group", @"--chat-id"]),
                     @"two arguments cannot name a chat and must not be read as a not-found");
    IMP_ASSERT_FALSE(IsPinnedChatNotFoundResult(ProcessResult(1, groupOutput, nil), @[]),
                     @"no arguments must be refused rather than indexed");

    IMP_ASSERT_TRUE(IsPinnedChatNotFoundResult(
                        ProcessResult(1, [@"chat_id 42 does not exist" dataUsingEncoding:NSUTF8StringEncoding], nil),
                        @[@"stats", @"--chat-id", @"42", @"--json"]),
                    @"the stats command spells its not-found differently and takes more arguments");
    IMP_ASSERT_TRUE(
        IsPinnedChatNotFoundResult(ProcessResult(1, [@"chat not found" dataUsingEncoding:NSUTF8StringEncoding], nil),
                                   @[@"chat-background", @"status", @"--chat-id", @"42"]),
        @"the chat-background command spells its not-found without the id");

    // Output that is not UTF-8 decodes to nil, and a nil string compared
    // against the expected message must be a mismatch rather than a crash.
    IMP_ASSERT_FALSE(
        IsPinnedChatNotFoundResult(ProcessResult(1, [NSData dataWithBytes:"\xff\xfe" length:2], nil), groupArguments),
        @"output that is not UTF-8 must not be read as a not-found");
    IMP_ASSERT_FALSE(IsPinnedChatNotFoundResult(ProcessResult(1, nil, nil), groupArguments),
                     @"a process that printed nothing must not be read as a not-found");
}

static void TestScrubbing(void) {
    // The privacy filter over everything the pinned dependency emits. It has to
    // drop the named keys and every _path key at every depth, and lose nothing
    // else: a filter that dropped a level of nesting would silently empty the
    // console.
    NSDictionary *unchanged = @{@"a": @1, @"b": @"x"};
    IMP_ASSERT_TRUE([ScrubValue(unchanged) isEqualToDictionary:unchanged], @"an innocent dictionary passes through");

    NSArray<NSString *> *forbidden = @[
        @"account_id", @"account_login", @"last_addressed_handle", @"destination_caller_id", @"original_path",
        @"converted_path", @"cache_path", @"watch_background_path", @"file_path", @"upstream_private"
    ];
    for (NSString *key in forbidden) {
        NSDictionary *scrubbed = ScrubValue(@{key: @1, @"kept": @2});
        IMP_ASSERT_TRUE([scrubbed isEqualToDictionary:@{@"kept": @2}], @"%@ must be dropped, got %@", key, scrubbed);
    }

    // The suffix rule is what covers a key the dependency has not shipped yet,
    // and it must be a suffix rather than a substring.
    NSDictionary *suffixed = ScrubValue(@{@"weird_path": @1, @"kept": @2});
    IMP_ASSERT_TRUE([suffixed isEqualToDictionary:@{@"kept": @2}], @"an unknown key ending in _path must be dropped");
    IMP_ASSERT_TRUE([ScrubValue(
                        @{@"pathological": @1}) isEqualToDictionary:@{
                        @"pathological": @1
                    }],
                    @"a key that merely contains path must be kept");

    NSDictionary *nested = ScrubValue(@{@"x": @{@"file_path": @1, @"y": @2}});
    IMP_ASSERT_TRUE([nested isEqualToDictionary:@{@"x": @{@"y": @2}}], @"nesting must be scrubbed too, got %@", nested);

    NSArray *array = ScrubValue(@[@{@"file_path": @1}, @{@"y": @2}]);
    NSArray *expectedArray = @[@{}, @{@"y": @2}];
    IMP_ASSERT_TRUE([array isEqualToArray:expectedArray],
                    @"an element that scrubs to nothing stays as an empty dictionary, got %@", array);

    // A dictionary the dependency could not have produced but a future caller
    // could hand over. A non-string key cannot be tested with -hasSuffix:, so
    // it is dropped rather than trusted.
    NSDictionary *nonStringKey = ScrubValue(@{@42: @1, @"a": @2});
    IMP_ASSERT_TRUE([nonStringKey isEqualToDictionary:@{
                        @"a": @2
                    }],
                    @"a non-string key must be dropped rather than compared");

    IMP_ASSERT_TRUE([ScrubValue(@{@"a": NSNull.null}) isEqualToDictionary:@{@"a": NSNull.null}],
                    @"a JSON null must survive as a null rather than become an absent key");
    IMP_ASSERT_EQ_STR(ScrubValue(@"x"), @"x", @"a scalar passes through unchanged");
    IMP_ASSERT_TRUE([ScrubValue(@[]) isEqualToArray:@[]], @"an empty array survives as an empty array");

    // A hundred levels of nesting, because the recursion has no depth bound of
    // its own and the leaf has to survive all of them.
    id deep = @{@"leaf": @1};
    for (NSUInteger level = 0; level < 100; level++) {
        deep = @{@"x": deep, @"file_path": @"secret"};
    }
    id scrubbedDeep = ScrubValue(deep);
    for (NSUInteger level = 0; level < 100; level++) {
        IMP_ASSERT_NIL(((NSDictionary *)scrubbedDeep)[@"file_path"], @"a forbidden key must be dropped at every depth");
        scrubbedDeep = ((NSDictionary *)scrubbedDeep)[@"x"];
    }
    IMP_ASSERT_TRUE([scrubbedDeep isEqualToDictionary:@{
                        @"leaf": @1
                    }],
                    @"the leaf must survive a hundred levels, got %@", scrubbedDeep);
}

static void TestAttachmentProjection(void) {
    // The only place an attacker-influenced filename from the Messages database
    // becomes a value the console renders. Everything here is about what the
    // filename ends up being, because that is the field with a path in it.
    NSDictionary *traversal = AttachmentDTO(@{@"filename": @"../../../etc/passwd"});
    IMP_ASSERT_EQ_STR(traversal[@"filename"], @"passwd", @"a traversal must be reduced to its last component");

    NSDictionary *windows = AttachmentDTO(@{@"filename": @"C:\\Users\\x\\y.png"});
    IMP_ASSERT_EQ_STR(windows[@"filename"], @"y.png",
                      @"a backslash separator must be normalised before the last component is taken");

    NSDictionary *trailing = AttachmentDTO(@{@"filename": @"a/b/"});
    IMP_ASSERT_EQ_STR(trailing[@"filename"], @"b", @"a trailing separator must not leave an empty component");

    // transfer_name is the name the sender chose and filename is the path on
    // disk, so a safe transfer_name wins outright and an unsafe one falls
    // through rather than rejecting the row.
    NSDictionary *precedence = AttachmentDTO(@{@"transfer_name": @"good.png", @"filename": @"../bad.png"});
    IMP_ASSERT_EQ_STR(precedence[@"filename"], @"good.png", @"a safe transfer_name must win over the path");
    NSDictionary *fallthrough = AttachmentDTO(@{@"transfer_name": @".", @"filename": @"ok.png"});
    IMP_ASSERT_EQ_STR(fallthrough[@"filename"], @"ok.png", @"an unsafe transfer_name must fall through to the path");

    IMP_ASSERT_TRUE(AttachmentDTO(@{@"filename": @""})[@"filename"] == NSNull.null,
                    @"an empty filename becomes an explicit null rather than an absent key");
    IMP_ASSERT_TRUE(AttachmentDTO(@{})[@"filename"] == NSNull.null,
                    @"an absent filename becomes an explicit null, so the key is always present");

    // A row whose filename cannot be reduced to something safe is refused
    // whole, because rendering the attachment without its name would be a
    // quieter answer than the caller can act on.
    IMP_ASSERT_NIL(AttachmentDTO(@{@"filename": @".."}), @"a filename of two dots must reject the row");
    IMP_ASSERT_NIL(AttachmentDTO(@{@"filename": @"a\nb.png"}), @"a control character in the filename must reject it");
    IMP_ASSERT_NIL(AttachmentDTO(@{@"filename": @"a\0b.png"}), @"an embedded NUL in the filename must reject it");
    IMP_ASSERT_NIL(AttachmentDTO(@{@"filename": @5}), @"a number where a filename belongs must reject the row");
    IMP_ASSERT_NIL(AttachmentDTO(@{@"is_sticker": @"yes"}), @"a string where a boolean belongs must reject the row");
    IMP_ASSERT_NIL(AttachmentDTO(@{@"mime_type": @5}), @"a number where a media type belongs must reject the row");

    // byte_size and total_bytes are two spellings the dependency has used, and
    // the first is preferred rather than added to the second.
    IMP_ASSERT_EQ_INT([AttachmentDTO(
                          @{@"byte_size": @5})[@"byte_size"] longLongValue],
                      5, @"byte_size is reported as itself");
    IMP_ASSERT_EQ_INT([AttachmentDTO(
                          @{@"total_bytes": @7})[@"byte_size"] longLongValue],
                      7, @"total_bytes is reported under the byte_size key");
    NSDictionary *bothSizes = AttachmentDTO(@{@"byte_size": @5, @"total_bytes": @7});
    IMP_ASSERT_EQ_INT([bothSizes[@"byte_size"] longLongValue], 5, @"byte_size wins when both are present");
    IMP_ASSERT_NIL(AttachmentDTO(@{@"byte_size": @(-1)}), @"a negative size must reject the row");
    IMP_ASSERT_NIL(AttachmentDTO(@{@"byte_size": @1.5}), @"a fractional size must reject the row");
    IMP_ASSERT_NIL(AttachmentDTO(@{@"byte_size": @YES}), @"a boolean size must reject the row");
    IMP_ASSERT_NIL(AttachmentDTO(@{})[@"byte_size"], @"an absent size must stay absent rather than become zero");
}

static void TestChatBackgroundProjection(void) {
    // The strictest projector: an exact key allowlist, a cross-check against
    // the chat the caller asked about, and an exact key count on the nested
    // event. Each of those is a way for the dependency to answer about a chat
    // the caller is not authorised for.
    NSDictionary *minimal = ChatBackgroundDTO(ChatBackgroundSourceWith(@{}), 42);
    IMP_ASSERT_NOT_NIL(minimal, @"a minimal well-formed background must project");
    NSSet<NSString *> *expectedKeys = [NSSet setWithArray:@[
        @"chat_id", @"background_set", @"file_size", @"cache_exists", @"watch_background_exists", @"latest_event"
    ]];
    IMP_ASSERT_TRUE([[NSSet setWithArray:minimal.allKeys] isEqualToSet:expectedKeys],
                    @"the projection has exactly six keys, got %@", minimal.allKeys);
    IMP_ASSERT_TRUE(minimal[@"file_size"] == NSNull.null, @"an absent optional becomes an explicit null");
    IMP_ASSERT_TRUE(minimal[@"latest_event"] == NSNull.null, @"an absent event becomes an explicit null");

    IMP_ASSERT_NIL(ChatBackgroundDTO(ChatBackgroundSourceWith(@{}), 43),
                   @"an answer about another chat must be refused rather than relabelled");
    IMP_ASSERT_NIL(ChatBackgroundDTO(ChatBackgroundSourceWith(
                                         @{@"extra": @1}),
                                     42),
                   @"a key outside the allowlist must reject the answer");
    IMP_ASSERT_NIL(ChatBackgroundDTO(ChatBackgroundSourceWith(
                                         @{@"ok": @NO}),
                                     42),
                   @"an answer the dependency marked unsuccessful must be refused");
    IMP_ASSERT_NIL(ChatBackgroundDTO(ChatBackgroundSourceWith(
                                         @{@"ok": @1}),
                                     42),
                   @"the integer one must not stand in for the boolean true");
    IMP_ASSERT_NIL(ChatBackgroundDTO(ChatBackgroundSourceWith(
                                         @{@"chat_guid": @5}),
                                     42),
                   @"a number where the guid belongs must reject the answer");
    IMP_ASSERT_NIL(ChatBackgroundDTO(ChatBackgroundSourceWith(
                                         @{@"file_size": @(-1)}),
                                     42),
                   @"a negative file size must reject the answer");

    NSDictionary *populated = ChatBackgroundDTO(ChatBackgroundSourceWith(
                                                    @{@"file_size": @7,
                                                      @"cache_exists": @YES}),
                                                42);
    IMP_ASSERT_EQ_INT([populated[@"file_size"] longLongValue], 7, @"a present file size is carried through");
    IMP_ASSERT_TRUE([populated[@"cache_exists"] boolValue], @"a present boolean is carried through");

    IMP_ASSERT_TRUE(ChatBackgroundDTO(ChatBackgroundSourceWith(@{@"latest_event": NSNull.null}), 42)[@"latest_event"] ==
                        NSNull.null,
                    @"an explicit null event stays a null rather than rejecting the answer");
    IMP_ASSERT_NIL(ChatBackgroundDTO(ChatBackgroundSourceWith(@{@"latest_event": @"set"}), 42),
                   @"a string where the event belongs must reject the answer");

    // The event needs all four keys, not a subset: the count check is what
    // stops a row that has the allowlisted keys but is missing the date.
    NSDictionary *threeKeyEvent = ChatBackgroundSourceWith(
        @{@"latest_event": @{@"row_id": @1, @"guid": @"g", @"action": @"set"}});
    IMP_ASSERT_NIL(ChatBackgroundDTO(threeKeyEvent, 42),
                   @"an event with three of the four keys must reject the answer");

    NSDictionary *badActionEvent = ChatBackgroundSourceWith(
        @{@"latest_event": @{@"row_id": @1, @"guid": @"g", @"action": @"toggle", @"date": @"2024-01-01T00:00:00Z"}});
    IMP_ASSERT_NIL(ChatBackgroundDTO(badActionEvent, 42), @"an action outside set and clear must reject the answer");

    NSDictionary *badDateEvent = ChatBackgroundSourceWith(
        @{@"latest_event": @{@"row_id": @1, @"guid": @"g", @"action": @"set", @"date": @"2024-13-01T00:00:00Z"}});
    IMP_ASSERT_NIL(ChatBackgroundDTO(badDateEvent, 42), @"a malformed date must reject the answer");

#if IMPTimestampsParse
    // The event is projected down to two of its four keys, so the row id and
    // the guid the dependency reported never reach the caller.
    NSDictionary *eventSource = ChatBackgroundSourceWith(
        @{@"latest_event": @{@"row_id": @1, @"guid": @"g", @"action": @"set", @"date": @"2024-01-01T00:00:00Z"}});
    NSDictionary *withEvent = ChatBackgroundDTO(eventSource, 42);
    NSDictionary *expectedEvent = @{@"action": @"set", @"date": @"2024-01-01T00:00:00Z"};
    IMP_ASSERT_NOT_NIL(withEvent, @"a well-formed event must project");
    IMP_ASSERT_TRUE([withEvent[@"latest_event"] isEqualToDictionary:expectedEvent],
                    @"only the action and the date may be exposed, got %@", withEvent[@"latest_event"]);
#endif
}

static void TestStatisticsProjection(void) {
    // Four dimensions, an optional media block, and a truncation list computed
    // from the raw arrays. An off-by-one there lies to the caller about
    // completeness, which is worse than truncating.
    NSDictionary *minimal = StatisticsDTO(StatisticsSourceWith(@{}));
    IMP_ASSERT_NOT_NIL(minimal, @"a minimal well-formed statistics answer must project");
    IMP_ASSERT_EQ_INT([minimal[@"truncated_dimensions"] count], 0, @"nothing is truncated when nothing is present");
    IMP_ASSERT_TRUE(minimal[@"media"] == NSNull.null, @"an absent media block becomes an explicit null");

    NSMutableArray *chats = [NSMutableArray array];
    for (NSUInteger index = 0; index < 101; index++) {
        [chats addObject:@{
            @"chat_id": @(index + 1),
            @"identifier": @"i",
            @"name": @"n",
            @"service": @"s",
            @"message_count": @1
        }];
    }
    NSDictionary *atBound =
        StatisticsDTO(StatisticsSourceWith(@{@"chats": [chats subarrayWithRange:NSMakeRange(0, 100)]}));
    IMP_ASSERT_EQ_INT([atBound[@"chats"] count], 100, @"exactly a hundred chats are all projected");
    IMP_ASSERT_EQ_INT([atBound[@"truncated_dimensions"] count], 0, @"exactly a hundred chats is not a truncation");

    NSDictionary *overBound = StatisticsDTO(StatisticsSourceWith(@{@"chats": chats}));
    IMP_ASSERT_EQ_INT([overBound[@"chats"] count], 100, @"a hundred and one chats project as a hundred");
    IMP_ASSERT_TRUE([overBound[@"truncated_dimensions"] isEqualToArray:@[@"chats"]],
                    @"the truncated dimension must be named, got %@", overBound[@"truncated_dimensions"]);

    IMP_ASSERT_NIL(StatisticsDTO(StatisticsSourceWith(@{@"time_zone": @"Mars/Olympus"})),
                   @"an unknown time zone must reject the answer");
    IMP_ASSERT_NIL(StatisticsDTO(StatisticsSourceWith(
                       @{@"time_zone": @5})),
                   @"a number where the time zone belongs must reject the answer");
    IMP_ASSERT_NIL(StatisticsDTO(StatisticsSourceWith(
                       @{@"total_messages": @(-1)})),
                   @"a negative total must reject the answer");
    IMP_ASSERT_NIL(StatisticsDTO(StatisticsSourceWith(
                       @{@"total_messages": @YES})),
                   @"a boolean total must not pass as the count one");
    NSDictionary *impossibleDate = StatisticsSourceWith(
        @{@"dates":
              @[@{@"date": @"2023-02-29",
                  @"message_count": @1}]});
    IMP_ASSERT_NIL(StatisticsDTO(impossibleDate), @"a date that does not exist must reject the answer");

    NSDictionary *leapDay = StatisticsSourceWith(@{@"dates": @[@{@"date": @"2024-02-29", @"message_count": @1}]});
    IMP_ASSERT_NOT_NIL(StatisticsDTO(leapDay), @"a leap day is a legal statistics date");

    NSDictionary *zeroChatID = StatisticsSourceWith(
        @{@"chats":
              @[@{@"chat_id": @0,
                  @"identifier": @"i",
                  @"name": @"n",
                  @"service": @"s",
                  @"message_count": @1}]});
    IMP_ASSERT_NIL(StatisticsDTO(zeroChatID), @"chat id zero cannot be a chat and must reject the answer");
    IMP_ASSERT_NIL(StatisticsDTO(StatisticsSourceWith(@{@"chats": @"not an array"})),
                   @"a string where a dimension belongs must reject the answer");

    IMP_ASSERT_TRUE(StatisticsDTO(StatisticsSourceWith(@{@"media": NSNull.null}))[@"media"] == NSNull.null,
                    @"an explicit null media block stays a null");
    IMP_ASSERT_NIL(StatisticsDTO(StatisticsSourceWith(@{@"media": @"x"})),
                   @"a string where the media block belongs must reject the answer");

    NSMutableArray *types = [NSMutableArray array];
    for (NSUInteger index = 0; index < 101; index++) {
        [types addObject:@{@"uti": @"u", @"mime_type": @"m", @"attachment_count": @1, @"total_bytes": @2}];
    }
    NSDictionary *mediaSource = StatisticsSourceWith(
        @{@"media": @{@"total_attachments": @1, @"total_bytes": @2, @"types": types, @"chats": @[]}});
    NSDictionary *media = StatisticsDTO(mediaSource);
    IMP_ASSERT_EQ_INT([media[@"media"][@"types"] count], 100, @"the media types are truncated at the same bound");
    IMP_ASSERT_TRUE([media[@"truncated_dimensions"] isEqualToArray:@[@"media.types"]],
                    @"a truncated media dimension is named with its prefix, got %@", media[@"truncated_dimensions"]);
}

static void TestAcceptedSendProjection(void) {
    // Its output is the body stored in the idempotency table and replayed for
    // that key forever after, so a false accept is not recoverable.
    NSDictionary *accepted = AcceptedSendDTO(@{@"status": @"sent", @"id": @5, @"guid": @"g"}, @"op");
    NSDictionary *expectedAccepted = @{@"operation_id": @"op", @"state": @"accepted", @"message_id": @5, @"guid": @"g"};
    IMP_ASSERT_TRUE([accepted isEqualToDictionary:expectedAccepted],
                    @"a sent message projects to exactly four keys, got %@", accepted);

    NSDictionary *shouted = AcceptedSendDTO(@{@"status": @"SENT"}, @"op");
    IMP_ASSERT_EQ_STR(shouted[@"state"], @"accepted", @"the status is compared case insensitively");
    IMP_ASSERT_NIL(shouted[@"message_id"], @"an absent id must stay absent rather than become zero");

    IMP_ASSERT_NIL(AcceptedSendDTO(@{@"status": @"queued"}, @"op"),
                   @"a queued message is not an accepted one and must not be recorded as sent");
    IMP_ASSERT_NIL(AcceptedSendDTO(@{@"status": @YES}, @"op"), @"a boolean status must be refused");
    IMP_ASSERT_NIL(AcceptedSendDTO(@{}, @"op"), @"an answer with no status must be refused");
    IMP_ASSERT_NIL(AcceptedSendDTO(@{@"status": @"sent", @"id": @0}, @"op"), @"message id zero must be refused");
    IMP_ASSERT_NIL(AcceptedSendDTO(
                       @{@"status": @"sent",
                         @"id": @(-1)},
                       @"op"),
                   @"a negative message id must be refused");
    IMP_ASSERT_NIL(AcceptedSendDTO(
                       @{@"status": @"sent",
                         @"guid": @5},
                       @"op"),
                   @"a number where the guid belongs must be refused");

    // An empty guid is omitted rather than reported as an empty string,
    // because a caller that stored it would hold something that matches no
    // message.
    NSDictionary *emptyGUID = AcceptedSendDTO(@{@"status": @"sent", @"guid": @""}, @"op");
    IMP_ASSERT_NOT_NIL(emptyGUID, @"an empty guid must not reject the send");
    IMP_ASSERT_NIL(emptyGUID[@"guid"], @"an empty guid must be omitted rather than echoed");
}

static void TestKeyProjection(void) {
    // The API key representation. It must never carry the token or the hash,
    // and the nil-date handling is the kind of thing that becomes a
    // dictionary-insert exception the first time a key has never been used.
    IMPAPIKeyRecord *record = [[IMPAPIKeyRecord alloc] initWithUUID:@"1cf9a3d2"
                                                               name:@"ops"
                                                          keyPrefix:@"imp_abcdefgh"
                                                             scopes:@[@"messages:read", @"admin"]
                                                   senderIdentifier:@"kle"
                                           senderIdentifierAssigned:YES
                                                          createdAt:FixedDate()
                                                          expiresAt:nil
                                                          revokedAt:nil
                                                         lastUsedAt:nil];
    NSDictionary *projected = KeyDTO(record);
    NSSet<NSString *> *expectedKeys = [NSSet setWithArray:@[
        @"id", @"name", @"key_prefix", @"scopes", @"sender_identifier", @"sender_identifier_assigned", @"created_at",
        @"expires_at", @"revoked_at", @"last_used_at"
    ]];
    IMP_ASSERT_TRUE([[NSSet setWithArray:projected.allKeys] isEqualToSet:expectedKeys],
                    @"the projection has exactly ten keys, got %@", projected.allKeys);
    IMP_ASSERT_NIL(projected[@"key"], @"the token must never be projected");
    IMP_ASSERT_NIL(projected[@"key_hash"], @"the key hash must never be projected");
    IMP_ASSERT_TRUE(projected[@"expires_at"] == NSNull.null, @"a key that never expires reports an explicit null");
    IMP_ASSERT_TRUE(projected[@"revoked_at"] == NSNull.null, @"a key that was never revoked reports an explicit null");
    IMP_ASSERT_TRUE(projected[@"last_used_at"] == NSNull.null, @"a key never used reports an explicit null");
    IMP_ASSERT_NOT_NIL(projected[@"created_at"], @"a creation date is always present");
    NSArray<NSString *> *expectedScopes = @[@"messages:read", @"admin"];
    IMP_ASSERT_TRUE([projected[@"scopes"] isEqualToArray:expectedScopes],
                    @"the scopes are passed through in the order they are stored, got %@", projected[@"scopes"]);
    IMP_ASSERT_TRUE([projected[@"sender_identifier_assigned"] boolValue],
                    @"an assigned identifier must be reported as assigned");
    IMP_ASSERT_TRUE([NSJSONSerialization isValidJSONObject:projected],
                    @"the projection has to survive serialisation, which nil in a value slot would not");

    // A row written before the prefix column existed carries no prefix, and the
    // fallback is what stops the console rendering a blank where a credential
    // identifier belongs.
    IMPAPIKeyRecord *legacy = [[IMPAPIKeyRecord alloc] initWithUUID:@"1cf9a3d2"
                                                               name:@"ops"
                                                          keyPrefix:nil
                                                             scopes:@[@"admin"]
                                                   senderIdentifier:@"kle"
                                           senderIdentifierAssigned:NO
                                                          createdAt:FixedDate()
                                                          expiresAt:FixedDate()
                                                          revokedAt:FixedDate()
                                                         lastUsedAt:FixedDate()];
    NSDictionary *legacyProjected = KeyDTO(legacy);
    IMP_ASSERT_EQ_STR(legacyProjected[@"key_prefix"], @"imp_", @"a missing prefix falls back to the scheme alone");
    IMP_ASSERT_FALSE([legacyProjected[@"expires_at"] isEqual:NSNull.null], @"a present expiry is rendered, not nulled");
    IMP_ASSERT_FALSE([legacyProjected[@"revoked_at"] isEqual:NSNull.null], @"a present revocation is rendered");
    IMP_ASSERT_FALSE([legacyProjected[@"last_used_at"] isEqual:NSNull.null], @"a present last use is rendered");
    IMP_ASSERT_TRUE([NSJSONSerialization isValidJSONObject:legacyProjected],
                    @"the fully populated projection must serialise too");

#if IMPTimestampsParse
    IMP_ASSERT_EQ_STR(projected[@"created_at"], @"2024-01-01T00:00:00.000Z",
                      @"the wire spelling of a date is the one the console and the OpenAPI document agree on");
#endif
}

static void TestAuditEventProjection(void) {
    // Rendered to administrators. Every optional has to become an explicit null
    // rather than nil, or the dictionary literal raises rather than answers.
    IMPAuditRecord *attempted = [[IMPAuditRecord alloc] initWithRequestUUID:@"3f2a"
                                                                    keyUUID:nil
                                                              targetKeyUUID:nil
                                                                     source:@"local"
                                                                     action:@"keys.list"
                                                                      phase:IMPAuditPhaseAttempted
                                                                     status:nil
                                                       durationMilliseconds:nil
                                                                  createdAt:FixedDate()];
    NSDictionary *projected = AuditEventDTO(attempted);
    NSSet<NSString *> *expectedKeys = [NSSet setWithArray:@[
        @"request_id", @"key_id", @"target_key_id", @"source", @"action", @"phase", @"status", @"duration_ms",
        @"created_at"
    ]];
    IMP_ASSERT_TRUE([[NSSet setWithArray:projected.allKeys] isEqualToSet:expectedKeys],
                    @"the projection has exactly nine keys, got %@", projected.allKeys);
    IMP_ASSERT_EQ_STR(projected[@"phase"], @"attempted", @"an attempted row is reported as attempted");
    IMP_ASSERT_TRUE(projected[@"key_id"] == NSNull.null, @"an unauthenticated request reports a null key");
    IMP_ASSERT_TRUE(projected[@"target_key_id"] == NSNull.null, @"a request with no target key reports a null");
    IMP_ASSERT_TRUE(projected[@"status"] == NSNull.null, @"an attempt has no status yet and reports a null");
    IMP_ASSERT_TRUE(projected[@"duration_ms"] == NSNull.null, @"an attempt has no duration yet and reports a null");
    IMP_ASSERT_TRUE([NSJSONSerialization isValidJSONObject:projected], @"the projection has to survive serialisation");

    IMPAuditRecord *final = [[IMPAuditRecord alloc] initWithRequestUUID:@"3f2a"
                                                                keyUUID:@"k"
                                                          targetKeyUUID:@"t"
                                                                 source:@"127.0.0.1"
                                                                 action:@"keys.revoke"
                                                                  phase:IMPAuditPhaseFinal
                                                                 status:@200
                                                   durationMilliseconds:@12
                                                              createdAt:FixedDate()];
    NSDictionary *finalProjected = AuditEventDTO(final);
    IMP_ASSERT_EQ_STR(finalProjected[@"phase"], @"final", @"a final row is reported as final");
    IMP_ASSERT_EQ_INT([finalProjected[@"status"] longLongValue], 200, @"a present status is carried through");
    IMP_ASSERT_EQ_INT([finalProjected[@"duration_ms"] longLongValue], 12, @"a present duration is carried through");
    IMP_ASSERT_EQ_STR(finalProjected[@"key_id"], @"k", @"a present key id is carried through");

    // The phase is a ternary against Attempted, so a stored value that is
    // neither of the two enumerators is rendered as final rather than refused.
    // Pinned because a corrupted row then reads as a completed request.
    IMPAuditRecord *corrupt = [[IMPAuditRecord alloc] initWithRequestUUID:@"3f2a"
                                                                  keyUUID:nil
                                                            targetKeyUUID:nil
                                                                   source:@"local"
                                                                   action:@"keys.list"
                                                                    phase:(IMPAuditPhase)99
                                                                   status:nil
                                                     durationMilliseconds:nil
                                                                createdAt:FixedDate()];
    IMP_ASSERT_EQ_STR(AuditEventDTO(corrupt)[@"phase"], @"final",
                      @"a phase outside the enumeration is rendered as final");
}

static void TestChronologicalOrder(void) {
    IMP_ASSERT_EQ_INT(MessagesInChronologicalOrder(@[]).count, 0, @"an empty history sorts to an empty history");

    NSArray<NSDictionary *> *single = @[@{@"id": @1, @"created_at": @"2024-01-01T00:00:00Z"}];
    IMP_ASSERT_TRUE([MessagesInChronologicalOrder(single) isEqualToArray:single],
                    @"a single message is returned unchanged");

#if IMPTimestampsParse
    // The comparator returns NSOrderedSame whenever either timestamp fails to
    // parse, so it can only order what it can read. These pin what it does
    // read: the date first and the id as the tie-break, which is what makes a
    // page of a history stable between two requests.
    NSArray<NSDictionary *> *unordered = @[
        @{@"id": @3,
          @"created_at": @"2024-01-01T00:00:02Z"},
        @{@"id": @1,
          @"created_at": @"2024-01-01T00:00:00Z"},
        @{@"id": @2,
          @"created_at": @"2024-01-01T00:00:01Z"}
    ];
    NSArray<NSDictionary *> *sorted = MessagesInChronologicalOrder(unordered);
    IMP_ASSERT_EQ_INT([sorted[0][@"id"] longLongValue], 1, @"the oldest message must come first");
    IMP_ASSERT_EQ_INT([sorted[1][@"id"] longLongValue], 2, @"the middle message must stay in the middle");
    IMP_ASSERT_EQ_INT([sorted[2][@"id"] longLongValue], 3, @"the newest message must come last");

    NSArray<NSDictionary *> *tied =
        @[@{@"id": @9,
            @"created_at": @"2024-01-01T00:00:00Z"},
          @{@"id": @4,
            @"created_at": @"2024-01-01T00:00:00Z"}];
    NSArray<NSDictionary *> *tieBroken = MessagesInChronologicalOrder(tied);
    IMP_ASSERT_EQ_INT([tieBroken[0][@"id"] longLongValue], 4, @"two messages at the same instant order by id");
    IMP_ASSERT_EQ_INT([tieBroken[1][@"id"] longLongValue], 9, @"the larger id comes second");

    NSArray<NSDictionary *> *fractional = @[
        @{@"id": @2,
          @"created_at": @"2024-01-01T00:00:00.002Z"},
        @{@"id": @1,
          @"created_at": @"2024-01-01T00:00:00.001Z"}
    ];
    IMP_ASSERT_EQ_INT([MessagesInChronologicalOrder(fractional)[0][@"id"] longLongValue], 1,
                      @"a millisecond of difference must still order");
#endif
}

static void TestDependencyDiagnostics(void) {
    // The operator-visible account of why the pinned dependency failed. It is
    // bounded and stripped of controls because it goes into the system log,
    // where an unbounded line with an escape sequence in it is a problem of its
    // own.
    IMP_ASSERT_EQ_STR(DependencyDiagnostic(ProcessResult(
                          1, nil, [@"   fatal error: missing bundle\nstack" dataUsingEncoding:NSUTF8StringEncoding])),
                      @"fatal error: missing bundle", @"only the first line is reported, trimmed");
    IMP_ASSERT_EQ_STR(DependencyDiagnostic(ProcessResult(1, nil, nil)), @"",
                      @"a dependency that wrote nothing reports an empty diagnostic rather than nil");
    IMP_ASSERT_EQ_STR(DependencyDiagnostic(ProcessResult(1, nil, [NSData dataWithBytes:"\xff\xfe" length:2])), @"",
                      @"output that is not UTF-8 reports empty rather than crashing on a nil string");
    IMP_ASSERT_EQ_STR(DependencyDiagnostic(ProcessResult(1, nil, [@"a\r\nb" dataUsingEncoding:NSUTF8StringEncoding])),
                      @"a", @"a carriage return ends the first line as surely as a newline does");

    NSString *exact = Repeated(@"a", 200);
    IMP_ASSERT_EQ_STR(DependencyDiagnostic(ProcessResult(1, nil, [exact dataUsingEncoding:NSUTF8StringEncoding])),
                      exact, @"a two hundred character line is exactly at the bound and is unchanged");
    NSString *overLong = Repeated(@"a", 201);
    IMP_ASSERT_EQ_STR(DependencyDiagnostic(ProcessResult(1, nil, [overLong dataUsingEncoding:NSUTF8StringEncoding])),
                      [exact stringByAppendingString:@"..."],
                      @"one character over the bound is truncated and marked as truncated");
}

static void TestSenderIdentifierAgreement(void) {
    // POST /api/keys validates the identifier and then the store validates it
    // again. If the API is looser the store refuses and the caller gets a 503
    // for a request it spelled correctly; if it is tighter the API refuses an
    // identifier the store would have taken.
    NSArray<NSString *> *corpus = @[
        @"kle", @"KLE", @"Ab", @"ab", @"abcdefgh", @"a", @"abcdefghi", @"", @"ab1", @"a-b", @"a b", @"ab\n", @" ab",
        @"ab\0", @"a\u00E7b", @"\u0410b", @"\uFF21\uFF22", @"a\U0001F600"
    ];
    for (NSString *value in corpus) {
        BOOL fromServer = IsValidSenderIdentifier(value);
        BOOL fromStore = IMPValidateSenderIdentifier(value, NULL, NULL);
        IMP_ASSERT_TRUE(fromServer == fromStore, @"the API and the store must agree about %@ (API %@, store %@)", value,
                        fromServer ? @"YES" : @"NO", fromStore ? @"YES" : @"NO");
    }
    IMP_ASSERT_FALSE(IsValidSenderIdentifier(NilString()), @"nil must be refused");
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier(NilString(), NULL, NULL), @"the store must refuse nil as well");
    IMP_ASSERT_FALSE(IsValidSenderIdentifier((NSString *)@42), @"a number must be refused");
    IMP_ASSERT_FALSE(IMPValidateSenderIdentifier((NSString *)@42, NULL, NULL),
                     @"the store must refuse a number as well");

    IMP_ASSERT_TRUE(IsValidSenderIdentifier(@"ab"), @"two letters is the shortest identifier");
    IMP_ASSERT_FALSE(IsValidSenderIdentifier(@"a"), @"one letter is one under the shortest identifier");
    IMP_ASSERT_TRUE(IsValidSenderIdentifier(@"abcdefgh"), @"eight letters is the longest identifier");
    IMP_ASSERT_FALSE(IsValidSenderIdentifier(@"abcdefghi"), @"nine letters is one over the longest identifier");

    // U+212A KELVIN SIGN folds to an ASCII k, so it passes a check that runs
    // after the fold. It is the one way a non-ASCII character reaches this
    // column, and it is pinned because it is surprising rather than because it
    // is wanted.
    IMP_ASSERT_TRUE(IsValidSenderIdentifier(@"\u212Ale"), @"a Kelvin sign folds to k and is accepted");
    IMP_ASSERT_TRUE(IMPValidateSenderIdentifier(@"\u212Ale", NULL, NULL), @"the store accepts it too");
}

static void TestAPIKeyNameAgreement(void) {
    // The same argument as the sender identifier: the HTTP layer and the store
    // both trim and both bound by UTF-8 bytes, and the trimmed value is what is
    // stored. A divergence turns a 400 into a 503 or refuses a name the store
    // would hold.
    NSArray<NSString *> *corpus = @[
        @"  ops  ", @"ops", @"", @"   ", @"a\nb", @"a\0b", @"a\tb", Repeated(@"n", 80), Repeated(@"n", 81),
        Repeated(@"\u00E9", 40), Repeated(@"\u00E9", 41), @"\U0001F600"
    ];
    for (NSString *value in corpus) {
        NSString *fromServerNormalized = nil;
        NSString *fromStoreNormalized = nil;
        BOOL fromServer = IsValidAPIKeyName(value, &fromServerNormalized);
        BOOL fromStore = IMPValidateName(value, &fromStoreNormalized, NULL);
        IMP_ASSERT_TRUE(fromServer == fromStore, @"the API and the store must agree about a %lu-character name",
                        (unsigned long)value.length);
        IMP_ASSERT_EQ_STR(fromServerNormalized, fromStoreNormalized,
                          @"both must normalise a name to the same string, or a stored row stops matching itself");
    }

    NSString *normalized = nil;
    IMP_ASSERT_TRUE(IsValidAPIKeyName(@"  ops  ", &normalized), @"a padded name is valid");
    IMP_ASSERT_EQ_STR(normalized, @"ops", @"the normalised name is the trimmed one");
    IMP_ASSERT_TRUE(IsValidAPIKeyName(Repeated(@"n", 80), NULL),
                    @"eighty UTF-8 bytes is exactly at the bound, with a NULL out-pointer");
    IMP_ASSERT_FALSE(IsValidAPIKeyName(Repeated(@"n", 81), NULL), @"eighty-one bytes is one over the bound");
    IMP_ASSERT_TRUE(IsValidAPIKeyName(Repeated(@"\u00E9", 40), NULL),
                    @"forty two-byte characters is exactly eighty bytes");
    IMP_ASSERT_FALSE(IsValidAPIKeyName(Repeated(@"\u00E9", 41), NULL),
                     @"forty-one two-byte characters is eighty-two bytes and over the bound");
    IMP_ASSERT_FALSE(IsValidAPIKeyName(NilString(), NULL), @"nil must be refused");
    IMP_ASSERT_FALSE(IsValidAPIKeyName((NSString *)@42, NULL), @"a number must be refused");

    // Idempotence, because IMPRecordFromStatement compares a stored name
    // against the name it validates on the way back out: a normalisation that
    // moved twice would make an existing row unreadable.
    NSString *once = nil;
    NSString *twice = nil;
    IMP_ASSERT_TRUE(IsValidAPIKeyName(@"  ops key  ", &once), @"the name is valid");
    IMP_ASSERT_TRUE(IsValidAPIKeyName(once, &twice), @"the normalised name is valid in its own right");
    IMP_ASSERT_EQ_STR(twice, once, @"normalising twice must not move the name again");
}

static void TestMessagesReadRoutes(void) {
    // When reading is turned off these two decide which audit action is written
    // for the refused request. An action outside the store's allowlist turns
    // the 409 into an audit write that fails, and then into a 503 on a request
    // that had a perfectly good answer.
    IMP_ASSERT_TRUE(RequestReadsMessages(RequestForPath(@"/api/chats")), @"the chat list is a read path");
    IMP_ASSERT_TRUE(RequestReadsMessages(RequestForPath(@"/api/chats/42")), @"one chat is a read path");
    IMP_ASSERT_TRUE(RequestReadsMessages(RequestForPath(@"/api/chats/42/messages")), @"a history is a read path");
    IMP_ASSERT_TRUE(RequestReadsMessages(RequestForPath(@"/api/chats/42/background")), @"a background is a read path");
    IMP_ASSERT_TRUE(RequestReadsMessages(RequestForPath(@"/api/scheduled-messages")),
                    @"the scheduled list is a read path");
    IMP_ASSERT_TRUE(RequestReadsMessages(RequestForPath(@"/api/statistics/messages")), @"statistics is a read path");

    // Sending uses Apple Events rather than the database, so it must keep
    // working on an installation that declined Full Disk Access.
    IMP_ASSERT_FALSE(RequestReadsMessages(RequestForPath(@"/api/messages")), @"sending is not a read path");
    IMP_ASSERT_FALSE(RequestReadsMessages(RequestForPath(@"/api/keys")), @"key administration is not a read path");
    IMP_ASSERT_FALSE(RequestReadsMessages(RequestForPath(@"/api/targets")), @"the allowlist is not a read path");
    IMP_ASSERT_FALSE(RequestReadsMessages(RequestForPath(@"/api/audit-events")), @"the audit trail is not a read path");

    // The prefix test is on "/api/chats/" with the separator, so a route that
    // merely starts with the same letters is not swept in with it.
    IMP_ASSERT_FALSE(RequestReadsMessages(RequestForPath(@"/api/chatsfoo")),
                     @"a longer path that shares the prefix is not a read path");

    IMP_ASSERT_EQ_STR(MessagesReadAuditAction(RequestForPath(@"/api/chats")), @"chats.list",
                      @"the chat list has its own action");
    IMP_ASSERT_EQ_STR(MessagesReadAuditAction(RequestForPath(@"/api/chats/")), @"chats.read",
                      @"a trailing separator names one chat rather than the list");
    IMP_ASSERT_EQ_STR(MessagesReadAuditAction(RequestForPath(@"/api/chats/42")), @"chats.read",
                      @"one chat has the read action");
    IMP_ASSERT_EQ_STR(MessagesReadAuditAction(RequestForPath(@"/api/chats/42/messages")), @"messages.history",
                      @"a history has the history action");
    IMP_ASSERT_EQ_STR(MessagesReadAuditAction(RequestForPath(@"/api/chats/42/background")), @"background.read",
                      @"a background has the background action");
    IMP_ASSERT_EQ_STR(MessagesReadAuditAction(RequestForPath(@"/api/scheduled-messages")), @"scheduled.list",
                      @"the scheduled list has the scheduled action");
    IMP_ASSERT_EQ_STR(MessagesReadAuditAction(RequestForPath(@"/api/statistics/messages")), @"statistics.read",
                      @"statistics has the statistics action");

    NSArray<NSString *> *readPaths = @[
        @"/api/chats", @"/api/chats/", @"/api/chats/42", @"/api/chats/42/messages", @"/api/chats/42/background",
        @"/api/scheduled-messages", @"/api/statistics/messages"
    ];
    for (NSString *path in readPaths) {
        NSString *action = MessagesReadAuditAction(RequestForPath(path));
        IMP_ASSERT_TRUE(IMPValidateAuditAction(action, NULL),
                        @"%@ is written to the audit table and the store must accept it, got %@", path, action);
    }
}

int main(void) {
    @autoreleasepool {
        RunTest("gregorian_calendar_rules", TestGregorianCalendarRules);
        RunTest("strict_full_dates", TestStrictFullDates);
        RunTest("strict_rfc3339_rejections", TestStrictRFC3339Rejections);
        RunTest("strict_rfc3339_acceptances", TestStrictRFC3339Acceptances);
        RunTest("positive_integers", TestPositiveIntegers);
        RunTest("public_origins", TestPublicOrigins);
        RunTest("direct_message_recipients", TestDirectMessageRecipients);
        RunTest("allowed_target_files", TestAllowedTargetFiles);
        RunTest("allowed_target_lines", TestAllowedTargetLines);
        RunTest("unicode_code_point_length", TestUnicodeCodePointLength);
        RunTest("safe_message_text", TestSafeMessageText);
        RunTest("safe_filename_components", TestSafeFilenameComponents);
        RunTest("reason_phrases", TestReasonPhrases);
        RunTest("json_content_types", TestJSONContentTypes);
        RunTest("query_parsing", TestQueryParsing);
        RunTest("number_provenance", TestNumberProvenance);
        RunTest("executable_metadata", TestExecutableMetadata);
        RunTest("pinned_chat_not_found", TestPinnedChatNotFound);
        RunTest("scrubbing", TestScrubbing);
        RunTest("attachment_projection", TestAttachmentProjection);
        RunTest("chat_background_projection", TestChatBackgroundProjection);
        RunTest("statistics_projection", TestStatisticsProjection);
        RunTest("accepted_send_projection", TestAcceptedSendProjection);
        RunTest("key_projection", TestKeyProjection);
        RunTest("audit_event_projection", TestAuditEventProjection);
        RunTest("chronological_order", TestChronologicalOrder);
        RunTest("dependency_diagnostics", TestDependencyDiagnostics);
        RunTest("sender_identifier_agreement", TestSenderIdentifierAgreement);
        RunTest("api_key_name_agreement", TestAPIKeyNameAgreement);
        RunTest("messages_read_routes", TestMessagesReadRoutes);
    }

    if (gFailedAssertions > 0) {
        fprintf(stderr, "ERROR: %lu of %lu native server tests failed (%lu assertion%s).\n",
                (unsigned long)gFailedTests, (unsigned long)gExecutedTests, (unsigned long)gFailedAssertions,
                gFailedAssertions == 1 ? "" : "s");
        return 1;
    }
    printf("iMessage Proxy native server unit tests passed (%lu tests).\n", (unsigned long)gExecutedTests);
    return 0;
}

#endif

// The router half of the shims imp-test.h declares, for
// tests/native/test-differential.m. They are compiled in both builds of this
// file so that the rules the differential suite compares are the rules this
// suite's own cases run against, rather than a second compilation with a
// different set of macros in force.

BOOL imp_test_expose_router_sender_identifier_rule(NSString *value) { return IsValidSenderIdentifier(value); }

BOOL imp_test_expose_router_api_key_name_rule(NSString *value, NSString **normalized) {
    return IsValidAPIKeyName(value, normalized);
}

// The one shim here that is a transcription rather than a call. The rule it
// carries is written inline in -[IMPServer responseForRequest:requestID:] at
// src/imessage-proxy-server.m:2909-2911, inside a branch that is only reached
// through an authenticated request against an open key store, so there is no
// way to call it from a process that has neither. It is copied character for
// character from those three lines, including the order of the two length
// comparisons, and it is the reason tests/native/test-differential.m asserts
// the two rules agree on a corpus rather than on a handful of examples: a
// corpus is what makes a copy that has drifted from its original visible.
// Extracting those lines into a named function in src/ would retire this shim,
// and that is the fix if this ever fails for a reason nobody can explain.
BOOL imp_test_expose_router_idempotency_key_rule(NSString *value) {
    NSCharacterSet *invalidKeyCharacters = [[NSCharacterSet
        characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~-"]
        invertedSet];
    if (value.length < 8 || value.length > 128 ||
        [value rangeOfCharacterFromSet:invalidKeyCharacters].location != NSNotFound) {
        return NO;
    }
    return YES;
}

// Every audit action string this file passes to the store, which is every
// literal matching an action shape in src/imessage-proxy-server.m: thirty-four
// occurrences on thirty-two lines, twenty-three of them distinct. Six come
// from MessagesReadAuditAction (:2154), the rest from an `auditAction = @"..."`
// assignment in the router or, for server.overloaded, from the accept loop that
// answers before the router runs. The list is written out because the router
// never holds it in one place; what keeps it honest is that
// tests/native/test-differential.m checks it against the column CHECK
// constraint in both directions, so an action added to one and not the other
// fails there rather than on the audit write that follows a request which had
// already done what it asked.
NSArray<NSString *> *imp_test_expose_router_audit_actions(void) {
    return @[
        @"request.invalid", @"request.rate_limited", @"auth.unavailable", @"auth.rate_limited",
        @"auth.reject",     @"origin.reject",        @"route.not_found",  @"status.read",
        @"chats.list",      @"chats.read",           @"background.read",  @"messages.history",
        @"scheduled.list",  @"statistics.read",      @"messages.send",    @"keys.list",
        @"keys.read",       @"keys.create",          @"keys.revoke",      @"audit.list",
        @"targets.read",    @"targets.replace",      @"server.overloaded"
    ];
}

NSString *imp_test_expose_router_sha256_hex(NSData *data) { return HexDigest(data); }
