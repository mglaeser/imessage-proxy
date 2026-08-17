// The assertion vocabulary for the native unit tier. It exists instead of
// XCTest because the tier has to run on Linux as well as macOS, and XCTest is
// only on one of them; a test that can only run on the platform the product
// ships on is a test nobody runs until the release is already cut.
//
// Every macro here reports and continues rather than aborting, because a native
// suite that stops at the first bad assertion costs one compile-run cycle per
// defect, and the whole point of moving this tier off CI is that the cycle is
// short enough to fix everything a change broke in one pass.

#ifndef IMP_TEST_H
#define IMP_TEST_H

#import <Foundation/Foundation.h>

typedef void (*IMPTestFunction)(void);

// Both are defined by runner.m. The registry has to live in exactly one
// translation unit: a table with static storage in this header would give each
// test file a private copy, and the runner would then find only the tests that
// happened to be compiled beside it.
void IMPTestRegister(const char *name, IMPTestFunction function);
void IMPTestFail(const char *file, int line, NSString *message);

// A test registers itself from a constructor rather than from a list the runner
// maintains, because a list is a thing to forget and a test that is never
// called passes. The constructor runs before main and therefore before any
// autorelease pool exists, so it stores two pointers and touches no Foundation.
#define IMP_TEST(name)                                                                                                 \
    static void IMPTestBody_##name(void);                                                                              \
    __attribute__((constructor)) static void IMPTestRegistrar_##name(void) {                                           \
        IMPTestRegister(#name, IMPTestBody_##name);                                                                    \
    }                                                                                                                  \
    static void IMPTestBody_##name(void)

// Half the values under test come out of Foundation and half out of libc, so
// the string comparison has to accept either on either side. _Generic selects a
// function rather than a cast because under ARC a cast between id and
// const char * is a hard error even in the branch that is not taken.
static inline NSString *IMPTestStringFromUTF8(const char *value) { return value == NULL ? nil : @(value); }

static inline NSString *IMPTestStringFromObject(id value) {
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : [value description];
}

#define IMP_TEST_STRING(value)                                                                                         \
    _Generic((value),                                                                                                  \
        char *: IMPTestStringFromUTF8,                                                                                 \
        const char *: IMPTestStringFromUTF8,                                                                           \
        default: IMPTestStringFromObject)(value)

static inline NSString *IMPTestHexFromData(NSData *data) {
    if (data == nil) {
        return nil;
    }
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:(data.length * 2)];
    for (NSUInteger index = 0; index < data.length; index++) {
        [hex appendFormat:@"%02x", bytes[index]];
    }
    return hex;
}

// The trailing format arguments are mandatory on every macro. A failure that
// says only which line broke sends the reader back to the source to work out
// what the line was pinning; the observed and expected values are appended
// automatically, so the message is free to state the property instead.
#define IMP_ASSERT(condition, ...)                                                                                     \
    do {                                                                                                               \
        if (!(condition)) {                                                                                            \
            IMPTestFail(__FILE__, __LINE__, [NSString stringWithFormat:__VA_ARGS__]);                                  \
        }                                                                                                              \
    } while (0)

#define IMP_ASSERT_TRUE(value, ...) IMP_ASSERT((value) ? YES : NO, __VA_ARGS__)

#define IMP_ASSERT_FALSE(value, ...) IMP_ASSERT((value) ? NO : YES, __VA_ARGS__)

#define IMP_ASSERT_EQ_INT(actual, expected, ...)                                                                       \
    do {                                                                                                               \
        long long impActualValue = (long long)(actual);                                                                \
        long long impExpectedValue = (long long)(expected);                                                            \
        IMP_ASSERT(impActualValue == impExpectedValue, @"%@ (expected %lld, got %lld)",                                \
                   [NSString stringWithFormat:__VA_ARGS__], impExpectedValue, impActualValue);                         \
    } while (0)

#define IMP_ASSERT_EQ_STR(actual, expected, ...)                                                                       \
    do {                                                                                                               \
        NSString *impActualText = IMP_TEST_STRING(actual);                                                             \
        NSString *impExpectedText = IMP_TEST_STRING(expected);                                                         \
        IMP_ASSERT(impActualText == impExpectedText || [impActualText isEqualToString:impExpectedText],                \
                   @"%@ (expected %@, got %@)", [NSString stringWithFormat:__VA_ARGS__], impExpectedText,              \
                   impActualText);                                                                                     \
    } while (0)

#define IMP_ASSERT_NIL(value, ...)                                                                                     \
    do {                                                                                                               \
        id impObject = (value);                                                                                        \
        IMP_ASSERT(impObject == nil, @"%@ (expected nil, got %@)", [NSString stringWithFormat:__VA_ARGS__],            \
                   impObject);                                                                                         \
    } while (0)

#define IMP_ASSERT_NOT_NIL(value, ...)                                                                                 \
    IMP_ASSERT((value) != nil, @"%@ (expected a value, got nil)", [NSString stringWithFormat:__VA_ARGS__])

#define IMP_ASSERT_DATA_HEX(data, hex, ...)                                                                            \
    do {                                                                                                               \
        NSString *impObserved = IMPTestHexFromData(data);                                                              \
        NSString *impWanted = [IMP_TEST_STRING(hex) lowercaseString];                                                  \
        IMP_ASSERT(impObserved == impWanted || [impObserved isEqualToString:impWanted], @"%@ (expected %@, got %@)",   \
                   [NSString stringWithFormat:__VA_ARGS__], impWanted, impObserved);                                   \
    } while (0)

// The rules below are each written twice in src/: once where a request arrives
// and once where the row it produces is written, and nothing in either file
// mentions the other. tests/native/test-differential.m asserts that the two
// copies still say the same thing, and it cannot include either production
// source to do it - both are already compiled into the two suites, and a third
// copy would give the process two of every class in src/api-key-store.m. It
// links those suites instead and reads their file-static rules through these.
//
// Each shim is named for the rule it exports rather than for the function
// behind it, because which of the two names a rule happens to carry on either
// side of the wire is exactly the detail the suite is written not to trust. The
// router half is defined at the bottom of tests/native/test-imessage-proxy-server.m
// and the store half at the bottom of tests/native/test-api-key-store.m.

BOOL imp_test_expose_router_sender_identifier_rule(NSString *value);
BOOL imp_test_expose_store_sender_identifier_rule(NSString *value);

BOOL imp_test_expose_router_api_key_name_rule(NSString *value, NSString **normalized);
BOOL imp_test_expose_store_api_key_name_rule(NSString *value, NSString **normalized);

BOOL imp_test_expose_router_idempotency_key_rule(NSString *value);
BOOL imp_test_expose_store_idempotency_key_rule(NSString *value);

NSArray<NSString *> *imp_test_expose_router_audit_actions(void);
BOOL imp_test_expose_store_audit_action_rule(NSString *action);
NSArray<NSString *> *imp_test_expose_store_audit_action_check(void);

NSString *imp_test_expose_router_sha256_hex(NSData *data);
NSString *imp_test_expose_store_sha256_hex(NSData *data);

#endif
