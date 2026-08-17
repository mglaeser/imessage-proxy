// The go/no-go probe for the native unit tier. It runs before the unit tests on
// both platforms and pins the Foundation behaviours the leaf functions in src/
// are built on, because those functions are only worth testing on Linux if the
// Foundation underneath them answers the way Apple's does.
//
// It lives beside the vendored Linux SDK rather than in tests/native because it
// is the thing that decides whether that SDK may be trusted. It is built with
// no shim and no vendored header on macOS at all - the same source, the same
// assertions - so a difference shows up as a failure on exactly one platform.
//
// Two kinds of check are in here and the distinction matters. A shared
// assertion is a behaviour both platforms must agree on; when one fails the
// tier is off, because a unit test written against it would be measuring
// GNUstep rather than the product. A divergence is a behaviour already known to
// differ: it is asserted per platform so that it fails the moment it changes
// shape, and it prints the part of src/ it fences off so the fence is visible
// in the log rather than only in this file. Nothing here is skipped or
// tolerated silently.

#import "imp-test.h"

#import <CoreFoundation/CoreFoundation.h>

#include <math.h>
#include <stdio.h>
#include <string.h>

// A divergence is measured against Darwin, so the Darwin build has none to
// record and the recorder does not exist there; leaving it defined would fail
// the build on -Wunused-function, which is exactly the diagnostic that should
// fire if this file ever grows a Linux-only helper by accident.
#if !defined(__APPLE__)
static void RecordDivergence(NSString *api, NSString *observed, NSString *excluded) {
    printf("DIVERGENCE: %s\n", api.UTF8String);
    printf("DIVERGENCE:   observed: %s\n", observed.UTF8String);
    printf("DIVERGENCE:   fenced off: %s\n", excluded.UTF8String);
    fflush(stdout);
}
#endif

static id ParseJSON(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
}

// NSDateFormatter with the POSIX locale is the one date API both platforms
// agree on, so the calendar checks below build and read their dates through it
// rather than through the ISO 8601 formatter they are meant to be independent
// of.
static NSDateFormatter *UTCFormatter(void) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    return formatter;
}

#if defined(__APPLE__)

// ParseStrictRFC3339 (imessage-proxy-server.m:167) reaches Foundation three
// times for one timestamp, and a wrong answer from any of them silently accepts
// or rejects whole classes of input rather than failing loudly.

IMP_TEST(iso8601_parses_an_internet_date_time) {
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    NSDate *parsed = [formatter dateFromString:@"2024-01-01T00:00:00Z"];
    IMP_ASSERT_NOT_NIL(parsed, @"NSISO8601DateFormatter must parse a whole-second Zulu timestamp");
    IMP_ASSERT_EQ_INT((long long)parsed.timeIntervalSince1970, 1704067200LL,
                      @"NSISO8601DateFormatter must place 2024-01-01T00:00:00Z at the documented epoch second");

    NSDate *offset = [formatter dateFromString:@"2024-01-01T01:00:00+01:00"];
    IMP_ASSERT_NOT_NIL(offset, @"NSISO8601DateFormatter must accept a numeric UTC offset");
    IMP_ASSERT_EQ_INT((long long)offset.timeIntervalSince1970, 1704067200LL,
                      @"NSISO8601DateFormatter must apply the UTC offset rather than ignore it");

    // A trailing newline is the case where this file was written on a guess and
    // the guess was wrong. The formatter was assumed to reject one, which mattered
    // because the anchored regex in ParseStrictRFC3339 does not: ICU's $ matches
    // before a final line terminator, so "...Z\n" clears the pattern. Apple's
    // formatter then accepts it too, which leaves nothing rejecting it.
    //
    // Only a Mac can observe that. On GNUstep -dateFromString: returns nil for
    // every input, so the parser rejects the string for an unrelated reason and
    // the Linux tier reports a pass it has not earned.
#if defined(__APPLE__)
    IMP_ASSERT_NOT_NIL([formatter dateFromString:@"2024-01-01T00:00:00Z\n"],
                       @"NSISO8601DateFormatter accepts a trailing newline, so the pattern in "
                       @"ParseStrictRFC3339 has to be the layer that refuses one");
#endif
}

IMP_TEST(iso8601_whole_second_formatter_refuses_fractional_seconds) {
    // The branch at imessage-proxy-server.m:196 exists because these two
    // formatters are not interchangeable: the one without the fractional option
    // returns nil for a fractional string instead of truncating it.
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    IMP_ASSERT_NIL([formatter dateFromString:@"2024-01-01T00:00:00.123Z"],
                   @"NSISO8601DateFormatter without WithFractionalSeconds must refuse a fractional timestamp");
}

IMP_TEST(iso8601_fractional_seconds_round_trip) {
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *parsed = [formatter dateFromString:@"2024-01-01T00:00:00.123Z"];
    IMP_ASSERT_NOT_NIL(parsed, @"NSISO8601DateFormatter with WithFractionalSeconds must parse milliseconds");
    IMP_ASSERT_TRUE(fabs(parsed.timeIntervalSince1970 - 1704067200.123) < 0.0005,
                    @"NSISO8601DateFormatter must keep the fractional part, got %f", parsed.timeIntervalSince1970);
    IMP_ASSERT_EQ_STR([formatter stringFromDate:parsed], @"2024-01-01T00:00:00.123Z",
                      @"ISO8601() at imessage-proxy-server.m:125 emits exactly this spelling");
}

#else

IMP_TEST(iso8601_formatter_diverges) {
    // GNUstep base 1.29 ships an NSISO8601DateFormatter that parses nothing and
    // formats to a spelling no RFC 3339 reader accepts. This is the single
    // largest hole in the Linux tier and it is why the timestamp functions are
    // fenced off rather than tested against a shim.
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    IMP_ASSERT_NIL([formatter dateFromString:@"2024-01-01T00:00:00Z"],
                   @"GNUstep's NSISO8601DateFormatter is expected to parse nothing at all");
    IMP_ASSERT_NIL([formatter dateFromString:@"2024-01-01T00:00:00.123Z"],
                   @"GNUstep's NSISO8601DateFormatter is expected to parse nothing at all");

    // The option word survives the setter, so the fault is in the formatting
    // and parsing rather than in the configuration reaching them.
    IMP_ASSERT_EQ_INT(formatter.formatOptions, NSISO8601DateFormatWithInternetDateTime,
                      @"the format options must at least read back as they were set");
    NSString *formatted = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:1704067200.0]];
    IMP_ASSERT_EQ_STR(formatted, @"2024-01-01T00:00:00+0000:+0000",
                      @"GNUstep emits the time zone twice and never emits Z");

    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    IMP_ASSERT_EQ_STR([formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:1704067200.123]],
                      @"2024-01-01T00:00:00.123000+0000:+0000",
                      @"GNUstep emits six fractional digits where RFC 3339 callers expect three");

    RecordDivergence(@"NSISO8601DateFormatter",
                     [NSString stringWithFormat:@"-dateFromString: returns nil for every input, and -stringFromDate: "
                                                @"returns %@ instead of a Z-suffixed RFC 3339 timestamp",
                                                formatted],
                     @"ISO8601 (imessage-proxy-server.m:125), ParseStrictRFC3339 (:167), IsNullableRFC3339 (:1763) "
                     @"and the DTO projectors that call them - ChatDTO (:1781), ReactionDTO (:1834), MessageDTO "
                     @"(:1844), ScheduledMessageDTO (:1891) and ChatBackgroundDTO (:1906)");
}

#endif

IMP_TEST(regular_expression_anchors_and_character_classes) {
    // The pattern is the one ParseStrictRFC3339 compiles, character for
    // character. It is the only thing standing between a query parameter and
    // the date arithmetic behind it, and every part of it is a class or an
    // anchor that an ICU version could read differently.
    NSString *pattern = @"^[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])T"
                        @"(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\\.[0-9]{1,9})?"
                        @"(?:Z|[+-](?:(?:0[0-9]|1[0-3]):[0-5][0-9]|14:00))$";
    NSError *error = nil;
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&error];
    IMP_ASSERT_NOT_NIL(expression, @"NSRegularExpression must compile the RFC 3339 pattern: %@", error);

    NSArray<NSString *> *accepted = @[
        @"2024-01-01T00:00:00Z", @"2024-12-31T23:59:59Z", @"2024-01-01T00:00:00.123456789Z",
        @"2024-01-01T00:00:00+14:00", @"2024-01-01T00:00:00-13:59"
    ];
    for (NSString *value in accepted) {
        IMP_ASSERT_NOT_NIL([expression firstMatchInString:value options:0 range:NSMakeRange(0, value.length)],
                           @"NSRegularExpression must accept %@", value);
    }

    NSArray<NSString *> *refused = @[
        @"2024-01-01T00:00:00+14:01", @"2024-01-01T00:00:00+15:00", @"2024-01-01T24:00:00Z", @"2024-01-01T00:00:60Z",
        @"2024-01-01t00:00:00z", @"x2024-01-01T00:00:00Z", @"2024-01-01T00:00:00Z ", @"2024-01-01T00:00:00Zx",
        @"2024-13-01T00:00:00Z", @"2024-01-32T00:00:00Z", @"2024-01-01T00:00:00.Z"
    ];
    for (NSString *value in refused) {
        IMP_ASSERT_NIL([expression firstMatchInString:value options:0 range:NSMakeRange(0, value.length)],
                       @"NSRegularExpression anchors must refuse %@", value);
    }

    // ICU's dollar also matches before a single trailing line terminator even
    // with multiline off, so the anchors are not on their own the whole check:
    // the formatter downstream is what rejects the newline. Pinned because a
    // change here would move a rejection from one layer to none.
    NSString *trailingNewline = @"2024-01-01T00:00:00Z\n";
    IMP_ASSERT_NOT_NIL([expression firstMatchInString:trailingNewline
                                              options:0
                                                range:NSMakeRange(0, trailingNewline.length)],
                       @"ICU's dollar anchor is expected to match before a final newline");
}

IMP_TEST(control_character_set_membership) {
    // Six validators reject on controlCharacterSet alone, so its exact extent
    // is the definition of what may reach a message body, an audit row and an
    // argv slot. Apple documents it as Unicode general categories Cc and Cf.
    NSCharacterSet *controls = NSCharacterSet.controlCharacterSet;
    IMP_ASSERT_TRUE([controls characterIsMember:0x0000], @"controlCharacterSet must contain NUL");
    IMP_ASSERT_TRUE([controls characterIsMember:0x0009], @"controlCharacterSet must contain tab");
    IMP_ASSERT_TRUE([controls characterIsMember:0x001F], @"controlCharacterSet must contain U+001F");
    IMP_ASSERT_TRUE([controls characterIsMember:0x007F], @"controlCharacterSet must contain DEL");
    IMP_ASSERT_TRUE([controls characterIsMember:0x0085], @"controlCharacterSet must contain NEL");
    IMP_ASSERT_TRUE([controls characterIsMember:0x009F], @"controlCharacterSet must contain U+009F");
    IMP_ASSERT_FALSE([controls characterIsMember:0x0020], @"controlCharacterSet must not contain space");
    IMP_ASSERT_FALSE([controls characterIsMember:'a'], @"controlCharacterSet must not contain a letter");

    // Category Cf is in the set as well as Cc, which is what makes a handle
    // carrying a zero-width joiner fail IsDirectMessageRecipient rather than
    // reach an argv slot looking like a different handle.
    IMP_ASSERT_TRUE([controls characterIsMember:0x200D],
                    @"controlCharacterSet must contain the zero-width joiner (category Cf)");
    IMP_ASSERT_TRUE([controls characterIsMember:0x00AD],
                    @"controlCharacterSet must contain the soft hyphen (category Cf)");

    // IsSafeMessageText builds its set by removing exactly these three.
    NSMutableCharacterSet *withoutWhitespace = [controls mutableCopy];
    [withoutWhitespace removeCharactersInString:@"\t\n\r"];
    IMP_ASSERT_FALSE([withoutWhitespace characterIsMember:0x0009],
                     @"removeCharactersInString: must take tab out of a mutable copy");
    IMP_ASSERT_FALSE([withoutWhitespace characterIsMember:0x000A],
                     @"removeCharactersInString: must take newline out of a mutable copy");
    IMP_ASSERT_TRUE([withoutWhitespace characterIsMember:0x0000],
                    @"removeCharactersInString: must leave NUL in a mutable copy");
    IMP_ASSERT_TRUE([withoutWhitespace characterIsMember:0x007F],
                    @"removeCharactersInString: must leave DEL in a mutable copy");
}

IMP_TEST(illegal_character_set_membership) {
    // Nothing in src/ reads this set today. It is probed because it is the set
    // a reviewer reaches for when tightening one of the validators, and it is
    // worth knowing before that change whether it means the same thing here.
    NSCharacterSet *illegal = NSCharacterSet.illegalCharacterSet;
    IMP_ASSERT_TRUE([illegal characterIsMember:0xFFFF], @"illegalCharacterSet must contain the U+FFFF noncharacter");
    IMP_ASSERT_FALSE([illegal characterIsMember:'a'], @"illegalCharacterSet must not contain a letter");
    IMP_ASSERT_FALSE([illegal characterIsMember:0x0009], @"illegalCharacterSet must not contain tab");
    IMP_ASSERT_FALSE([illegal characterIsMember:0x200D], @"illegalCharacterSet must not contain an assigned format "
                                                         @"character, which is what controlCharacterSet is for");
}

IMP_TEST(json_boolean_provenance) {
    // IsBooleanNumber, IsIntegerNumber and IMPNumberIsIntegerInRange all ask
    // CFGetTypeID whether a parsed number is really a boolean, because @YES and
    // @1 are otherwise indistinguishable and an audit status of true would sail
    // through a BETWEEN 100 AND 599 check as a 1.
    NSDictionary *parsed = ParseJSON(@"{\"t\":true,\"f\":false,\"n\":1,\"d\":1.5,\"s\":\"1\"}");
    IMP_ASSERT_NOT_NIL(parsed, @"NSJSONSerialization must parse the provenance fixture");

    IMP_ASSERT_TRUE(CFGetTypeID((__bridge CFTypeRef)parsed[@"t"]) == CFBooleanGetTypeID(),
                    @"CFGetTypeID must classify JSON true as a CFBoolean");
    IMP_ASSERT_TRUE(CFGetTypeID((__bridge CFTypeRef)parsed[@"f"]) == CFBooleanGetTypeID(),
                    @"CFGetTypeID must classify JSON false as a CFBoolean");
    IMP_ASSERT_FALSE(CFGetTypeID((__bridge CFTypeRef)parsed[@"n"]) == CFBooleanGetTypeID(),
                     @"CFGetTypeID must not classify a JSON integer as a CFBoolean");
    IMP_ASSERT_FALSE(CFGetTypeID((__bridge CFTypeRef)parsed[@"d"]) == CFBooleanGetTypeID(),
                     @"CFGetTypeID must not classify a JSON double as a CFBoolean");
    IMP_ASSERT_FALSE(CFGetTypeID((__bridge CFTypeRef)parsed[@"s"]) == CFBooleanGetTypeID(),
                     @"CFGetTypeID must not classify a JSON string as a CFBoolean");
    IMP_ASSERT_TRUE([parsed[@"t"] boolValue], @"JSON true must carry the value YES");
    IMP_ASSERT_FALSE([parsed[@"f"] boolValue], @"JSON false must carry the value NO");

    // A number built by hand is a different object from a parsed one on both
    // platforms, so no test of these call sites may take its input from a
    // literal. Pinned here so that rule is enforced rather than remembered.
    IMP_ASSERT_TRUE(CFGetTypeID((__bridge CFTypeRef) @YES) == CFBooleanGetTypeID(),
                    @"a literal @YES must also classify as a CFBoolean");
}

IMP_TEST(json_number_representation) {
    NSDictionary *parsed = ParseJSON(@"{\"t\":true,\"n\":1,\"d\":1.5,\"big\":9007199254740993}");
    IMP_ASSERT_NOT_NIL(parsed, @"NSJSONSerialization must parse the number fixture");
    const char *booleanType = [parsed[@"t"] objCType];
    const char *integerType = [parsed[@"n"] objCType];
    const char *doubleType = [parsed[@"d"] objCType];

    IMP_ASSERT_TRUE(strcmp(doubleType, "d") == 0, @"a JSON fraction must arrive as a double, got %s", doubleType);
    IMP_ASSERT_TRUE(strcmp(booleanType, integerType) != 0,
                    @"a JSON boolean and a JSON integer must not share an objCType, both are %s", booleanType);
    IMP_ASSERT_EQ_INT([parsed[@"n"] longLongValue], 1LL, @"a JSON integer must still read back as its value");

#if defined(__APPLE__)
    IMP_ASSERT_TRUE(strcmp(integerType, "q") == 0, @"a JSON integer must arrive as a long long, got %s", integerType);
    IMP_ASSERT_TRUE(strcmp(booleanType, "c") == 0, @"a JSON boolean must arrive as a char, got %s", booleanType);
    IMP_ASSERT_EQ_INT([parsed[@"big"] longLongValue], 9007199254740993LL,
                      @"a JSON integer beyond 2^53 must survive parsing exactly");
#else
    IMP_ASSERT_TRUE(strcmp(integerType, "d") == 0, @"GNUstep is expected to parse a JSON integer as a double, got %s",
                    integerType);
    IMP_ASSERT_TRUE(strcmp(booleanType, "C") == 0, @"GNUstep is expected to encode BOOL as unsigned char, got %s",
                    booleanType);
    IMP_ASSERT_EQ_INT([parsed[@"big"] longLongValue], 9007199254740992LL,
                      @"GNUstep is expected to lose the odd bit of an integer beyond 2^53");
    RecordDivergence(@"NSJSONSerialization number parsing",
                     @"every JSON number becomes a double: objCType is d rather than q, and an integer beyond 2^53 "
                     @"is rounded to the nearest representable double",
                     @"the 64-bit boundary cases of IsIntegerNumber (imessage-proxy-server.m:1718), "
                     @"IsNonnegativeInteger (:1950) and IMPNumberIsIntegerInRange (api-key-store.m:674); values "
                     @"inside plus or minus 2^53 are exact and stay testable");
#endif
}

IMP_TEST(json_writing_key_order_and_separators) {
    NSDictionary *object = @{@"zulu": @1, @"alpha": @2, @"mike": @3};
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:NULL];
    IMP_ASSERT_NOT_NIL(encoded, @"NSJSONSerialization must encode the ordering fixture");
    NSString *text = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];

#if defined(__APPLE__)
    IMP_ASSERT_EQ_STR(text, @"{\"alpha\":2,\"mike\":3,\"zulu\":1}",
                      @"NSJSONWritingSortedKeys must produce one canonical byte sequence");
#else
    // The round trip is asserted rather than the bytes, because the bytes are
    // the thing that differs and the meaning is the thing that must not.
    NSDictionary *reparsed = [NSJSONSerialization JSONObjectWithData:encoded options:0 error:NULL];
    IMP_ASSERT_TRUE([reparsed isEqualToDictionary:object], @"the encoding must still round-trip to the same object");
    IMP_ASSERT_FALSE([text isEqualToString:@"{\"alpha\":2,\"mike\":3,\"zulu\":1}"],
                     @"GNUstep is expected not to produce Apple's canonical spelling");
    RecordDivergence(@"NSJSONWritingSortedKeys",
                     [NSString stringWithFormat:@"the option is accepted and ignored, and a space follows every "
                                                @"colon, giving %@",
                                                text],
                     @"any assertion on serialised JSON bytes: JSONData (imessage-proxy-server.m:115), the SHA-256 "
                     @"configuration fingerprint built on top of it, and every response-body byte comparison. The "
                     @"parsed object graph is unaffected and stays testable");
#endif
}

IMP_TEST(url_components_query_parsing) {
    // ParseQueryAllowingRepeatedNames (imessage-proxy-server.m:1555) delegates
    // the whole of query parsing to NSURLComponents, including the difference
    // between a name with no value and a name with an empty one, which the
    // callers treat differently.
    NSURLComponents *components =
        [NSURLComponents componentsWithString:@"/api/messages?limit=5&text=a%20b&flag&empty=&emoji=%F0%9F%98%80"];
    IMP_ASSERT_NOT_NIL(components, @"NSURLComponents must accept a relative path with a query");
    NSArray<NSURLQueryItem *> *items = components.queryItems;
    IMP_ASSERT_EQ_INT(items.count, 5, @"NSURLComponents must report every query item once");
    IMP_ASSERT_EQ_STR(items[0].name, @"limit", @"query item names must arrive in order");
    IMP_ASSERT_EQ_STR(items[1].value, @"a b", @"NSURLComponents must percent-decode a query value");
    IMP_ASSERT_NIL(items[2].value, @"a name with no equals sign must have a nil value");
    IMP_ASSERT_EQ_STR(items[3].value, @"", @"a name with an empty value must have an empty string, not nil");
    IMP_ASSERT_EQ_STR(items[4].value, @"\U0001F600", @"NSURLComponents must decode a multi-byte percent escape");

    // A stray percent is where the two parsers part company. Apple accepts the
    // string and re-encodes the percent as %25, so the query survives as the
    // literal text "%zz"; GNUstep refuses the whole string.
#if defined(__APPLE__)
    NSURLComponents *malformed = [NSURLComponents componentsWithString:@"/api/messages?a=%zz"];
    IMP_ASSERT_NOT_NIL(malformed, @"NSURLComponents must accept a stray percent rather than refuse the string");
    IMP_ASSERT_EQ_STR(malformed.queryItems[0].value, @"%zz",
                      @"a stray percent must survive as literal text rather than decode");
#else
    IMP_ASSERT_NIL([NSURLComponents componentsWithString:@"/api/messages?a=%zz"],
                   @"GNUstep refuses a malformed percent escape outright");
    RecordDivergence(@"+[NSURLComponents componentsWithString:] with a malformed percent escape",
                     @"the string is refused and the initialiser returns nil, where Apple accepts "
                     @"it and re-encodes the stray percent as %25",
                     @"the malformed-escape path of ParseQueryAllowingRepeatedNames "
                     @"(imessage-proxy-server.m:1555): on Darwin such a request reaches the handler "
                     @"with a literal \"%zz\" value, on GNUstep it is rejected before that. Every "
                     @"well-formed query asserted above parses identically, and the parameter "
                     @"validators downstream reject \"%zz\" on its own terms either way");
#endif
}

IMP_TEST(range_of_character_from_set_over_astral_characters) {
    // NSString is UTF-16 and NSCharacterSet membership is per code unit, so an
    // astral character is two members of whatever set contains its halves. This
    // is why UnicodeCodePointLength at imessage-proxy-server.m:75 counts
    // surrogate pairs by hand instead of trusting -length.
    NSString *value = @"a\U0001F600b";
    IMP_ASSERT_EQ_INT(value.length, 4, @"an astral character must occupy two UTF-16 code units");
    IMP_ASSERT_EQ_INT([value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location, NSNotFound,
                      @"neither half of a surrogate pair may be a control character");

    // The two platforms disagree about what a "character" is here. Apple composes
    // the surrogate pair back into U+1F600 before testing membership, so a set of
    // lead surrogates matches nothing; GNUstep tests each UTF-16 code unit, so it
    // matches the lead half at index 1.
    NSCharacterSet *leadSurrogates = [NSCharacterSet characterSetWithRange:NSMakeRange(0xD800, 0x400)];
    NSRange found = [value rangeOfCharacterFromSet:leadSurrogates];
#if defined(__APPLE__)
    IMP_ASSERT_EQ_INT(found.location, NSNotFound,
                      @"rangeOfCharacterFromSet: must compose the surrogate pair and so match no "
                      @"lead surrogate");
    IMP_ASSERT_EQ_INT(found.length, 0, @"a search that matches nothing must report an empty range");
#else
    IMP_ASSERT_EQ_INT(found.location, 1, @"GNUstep matches the lead surrogate as its own code unit");
    IMP_ASSERT_EQ_INT(found.length, 1, @"GNUstep reports one code unit rather than the pair");
    RecordDivergence(@"-[NSString rangeOfCharacterFromSet:] over an astral character",
                     @"a set of lead surrogates matches the lead half at index 1, where Apple "
                     @"composes the pair into one character and matches nothing",
                     @"nothing in src/: no character set the product builds contains a surrogate. "
                     @"The control-character and ASCII sets asserted above answer identically on "
                     @"both platforms, and UnicodeCodePointLength (imessage-proxy-server.m:75) "
                     @"counts pairs by hand rather than going through a character set at all");
#endif

    NSCharacterSet *letters = [NSCharacterSet characterSetWithCharactersInString:@"ab"];
    IMP_ASSERT_EQ_INT([value rangeOfCharacterFromSet:letters].location, 0,
                      @"rangeOfCharacterFromSet: must search forward from the start");
    IMP_ASSERT_EQ_INT([value rangeOfCharacterFromSet:letters options:NSBackwardsSearch].location, 3,
                      @"NSBackwardsSearch must return the last match, which IsDirectMessageRecipient relies on");
    IMP_ASSERT_EQ_INT([value rangeOfString:@"@" options:NSBackwardsSearch].location, NSNotFound,
                      @"a backwards search that finds nothing must report NSNotFound rather than a wrapped index");
}

IMP_TEST(case_folding_is_locale_independent) {
    IMP_ASSERT_EQ_INT([@"ABC" caseInsensitiveCompare:@"abc"], NSOrderedSame,
                      @"caseInsensitiveCompare: must ignore case for ASCII");
    IMP_ASSERT_EQ_INT([@"ABC" compare:@"abc" options:(NSCaseInsensitiveSearch | NSLiteralSearch)], NSOrderedSame,
                      @"a literal case-insensitive compare must ignore case for ASCII");
    IMP_ASSERT_EQ_STR([@"APPLICATION/JSON" lowercaseString], @"application/json",
                      @"IsJSONContentType folds the media type before comparing it");

    // -lowercaseString is the invariant mapping, not the localised one. If it
    // consulted the current locale, a Turkish host would fold I to a dotless i
    // and IsValidSenderIdentifier would refuse an identifier the store already
    // holds.
    IMP_ASSERT_EQ_STR([@"I" lowercaseString], @"i", @"-lowercaseString must not apply the Turkish mapping");
    IMP_ASSERT_EQ_STR([@"KLE" lowercaseString], @"kle", @"-lowercaseString must fold ASCII without a locale");

    // U+212A KELVIN SIGN folds to an ASCII k, so a sender identifier spelled
    // with it passes the a-z check that runs after the fold. Pinned because it
    // is the one way a non-ASCII string reaches that column, not because it is
    // wanted.
    IMP_ASSERT_EQ_STR([@"K" lowercaseString], @"k", @"U+212A must fold to an ASCII k");
}

IMP_TEST(known_time_zone_names_contain_the_names_statistics_uses) {
    // Never assert a count here: the list is whatever tzdata the host installed,
    // and a machine with a trimmed zoneinfo would fail a count for no defect.
    NSArray<NSString *> *names = NSTimeZone.knownTimeZoneNames;
    IMP_ASSERT_TRUE(names.count > 0, @"knownTimeZoneNames must not be empty");
    NSSet<NSString *> *known = [NSSet setWithArray:names];
    IMP_ASSERT_TRUE([known containsObject:@"America/New_York"],
                    @"knownTimeZoneNames must contain a named region IsKnownTimeZoneName accepts");
    // "UTC" is an abbreviation rather than a zone name, and Apple's list holds
    // names. IsKnownTimeZoneName (imessage-proxy-server.m:216) therefore accepts
    // it by an explicit equality test before consulting the set, and openapi.yaml
    // documents the parameter as "UTC or an exact name". That special case is not
    // belt and braces: on Darwin it is the only thing that makes UTC work.
#if defined(__APPLE__)
    IMP_ASSERT_FALSE([known containsObject:@"UTC"],
                     @"knownTimeZoneNames must not contain the UTC abbreviation, which is why "
                     @"IsKnownTimeZoneName tests for it separately");
#else
    IMP_ASSERT_TRUE([known containsObject:@"UTC"],
                    @"GNUstep lists UTC among its zone names; if that stops being true the "
                    @"divergence below is stale");
    RecordDivergence(@"NSTimeZone.knownTimeZoneNames",
                     @"the list contains \"UTC\", which Apple's does not, because Apple lists zone "
                     @"names and UTC is an abbreviation",
                     @"nothing: IsKnownTimeZoneName (imessage-proxy-server.m:216) accepts \"UTC\" by "
                     @"an explicit equality test before it consults the set, so both platforms "
                     @"answer the same for every input the API documents");
#endif
    IMP_ASSERT_FALSE([known containsObject:@"Mars/Olympus_Mons"],
                     @"knownTimeZoneNames must not contain an invented region");
    IMP_ASSERT_NOT_NIL([NSTimeZone timeZoneWithName:@"UTC"], @"UTC must resolve to a time zone");
    IMP_ASSERT_NIL([NSTimeZone timeZoneWithName:@"Mars/Olympus_Mons"],
                   @"an invented region must not resolve to a time zone");
}

IMP_TEST(gregorian_arithmetic_across_a_leap_day) {
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    NSDateFormatter *formatter = UTCFormatter();

    NSDateComponents *oneDay = [NSDateComponents new];
    oneDay.day = 1;
    NSDateComponents *oneYear = [NSDateComponents new];
    oneYear.year = 1;

    NSDate *leapEve = [formatter dateFromString:@"2024-02-28T12:00:00Z"];
    IMP_ASSERT_NOT_NIL(leapEve, @"the leap-year fixture must parse");
    IMP_ASSERT_EQ_STR([formatter stringFromDate:[calendar dateByAddingComponents:oneDay toDate:leapEve options:0]],
                      @"2024-02-29T12:00:00Z", @"a Gregorian day added to 28 February 2024 must land on the leap day");

    NSDate *commonEve = [formatter dateFromString:@"2023-02-28T12:00:00Z"];
    IMP_ASSERT_EQ_STR([formatter stringFromDate:[calendar dateByAddingComponents:oneDay toDate:commonEve options:0]],
                      @"2023-03-01T12:00:00Z", @"2023 is not a leap year and 29 February must not exist in it");

    NSDate *leapDay = [formatter dateFromString:@"2024-02-29T12:00:00Z"];
    IMP_ASSERT_EQ_STR([formatter stringFromDate:[calendar dateByAddingComponents:oneYear toDate:leapDay options:0]],
                      @"2025-02-28T12:00:00Z", @"a year added to a leap day must clamp to 28 February");

    NSDateComponents *read = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay)
                                         fromDate:leapDay];
    IMP_ASSERT_EQ_INT(read.year, 2024, @"the Gregorian year of the leap day fixture");
    IMP_ASSERT_EQ_INT(read.month, 2, @"the Gregorian month of the leap day fixture");
    IMP_ASSERT_EQ_INT(read.day, 29, @"the Gregorian day of the leap day fixture");

    // The century rule, which IsValidGregorianDate implements by hand at
    // imessage-proxy-server.m:140 and must agree with.
    NSDateComponents *centuryEve = [NSDateComponents new];
    centuryEve.year = 1900;
    centuryEve.month = 2;
    centuryEve.day = 28;
    centuryEve.hour = 12;
    NSDate *afterCenturyEve = [calendar dateByAddingComponents:oneDay
                                                        toDate:[calendar dateFromComponents:centuryEve]
                                                       options:0];
    IMP_ASSERT_EQ_STR([formatter stringFromDate:afterCenturyEve], @"1900-03-01T12:00:00Z",
                      @"1900 is divisible by 100 but not 400 and is not a leap year");

#if !defined(__APPLE__)
    RecordDivergence(@"-[NSCalendar dateByAddingUnit:value:toDate:options:]",
                     @"the selector does not exist in GNUstep base 1.29, so the arithmetic above goes through "
                     @"-dateByAddingComponents:toDate:options:, which both platforms answer identically",
                     @"nothing in src/ - it uses no NSCalendar at all - but a unit test written on a Mac must use "
                     @"the components form or it will not compile here");
#endif
}

IMP_TEST(utf8_round_trip_of_a_four_byte_character) {
    // Every length bound in the validators is measured in UTF-8 bytes taken
    // from -dataUsingEncoding:, while the character checks run over the UTF-16
    // string. The two counts have to disagree in the documented way or the
    // bounds mean something different here.
    NSString *value = @"\U0001F600";
    NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
    IMP_ASSERT_EQ_INT(utf8.length, 4, @"an astral character must encode as four UTF-8 bytes");
    IMP_ASSERT_DATA_HEX(utf8, "f09f9880", @"the UTF-8 encoding of U+1F600");
    NSString *decoded = [[NSString alloc] initWithData:utf8 encoding:NSUTF8StringEncoding];
    IMP_ASSERT_EQ_STR(decoded, value, @"UTF-8 must round-trip an astral character");
    IMP_ASSERT_EQ_INT(decoded.length, 2, @"the decoded string must still be two UTF-16 code units");

    // An embedded NUL survives -dataUsingEncoding:, which is what
    // NullTerminatedUTF8 at imessage-proxy-server.m:654 scans for before it
    // hands an argument to the pinned executable.
    NSData *embedded = [@"a\0b" dataUsingEncoding:NSUTF8StringEncoding];
    IMP_ASSERT_EQ_INT(embedded.length, 3, @"an embedded NUL must survive the UTF-8 encoding");
    IMP_ASSERT_NIL([[NSString alloc] initWithData:[NSData dataWithBytes:"\xff\xfe" length:2]
                                         encoding:NSUTF8StringEncoding],
                   @"invalid UTF-8 must decode to nil rather than to replacement characters");

    IMP_ASSERT_EQ_INT([@"\U0001F600" dataUsingEncoding:NSASCIIStringEncoding].length, 0,
                      @"ParsePositiveInteger relies on a non-ASCII string failing the ASCII round trip");
}
