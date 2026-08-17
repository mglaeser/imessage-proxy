// Force-included into every translation unit of the native unit tier with
// -include, because src/api-key-store.m and src/imessage-proxy-server.m are
// compiled unmodified and neither of them may grow a Linux #ifdef to make this
// build work. Everything here is either a Darwin spelling glibc does not have,
// or a Foundation API that GNUstep base 1.29 has not yet grown.
//
// This directory is compiled only on Linux and only for the native unit tests.
// The macOS build never sees it, and nothing in here may change what src/ does.

#pragma once

// Clang defines these on Darwin through <sys/cdefs.h>; glibc's spells them
// differently and Foundation's nullability and enum-kind macros only exist in
// Apple's headers.
#ifndef __unused
#define __unused __attribute__((unused))
#endif
#ifndef __dead2
#define __dead2 __attribute__((noreturn))
#endif
#ifndef NS_ERROR_ENUM
#define NS_ERROR_ENUM(domain, name) NS_ENUM(NSInteger, name)
#endif
#ifndef NS_TYPED_ENUM
#define NS_TYPED_ENUM
#endif
#ifndef NS_TYPED_EXTENSIBLE_ENUM
#define NS_TYPED_EXTENSIBLE_ENUM
#endif
#ifndef NS_STRING_ENUM
#define NS_STRING_ENUM
#endif
#ifndef NS_EXTENSIBLE_STRING_ENUM
#define NS_EXTENSIBLE_STRING_ENUM
#endif
#ifndef NS_SWIFT_NAME
#define NS_SWIFT_NAME(x)
#endif

// Darwin names the sub-second stat fields after the BSD struct member, glibc
// after the POSIX one. The two are the same struct timespec, so this rename is
// exact and changes no comparison's meaning.
#define st_mtimespec st_mtim
#define st_ctimespec st_ctim
#define st_atimespec st_atim

// st_gen and st_flags are BSD fields that Linux does not have at all. The spike
// aliased them to st_ino and st_nlink so that ExecutableMetadataMatches would
// compile, which quietly turned two thirds of a TOCTOU identity check into a
// tautology: st_ino and st_nlink are already compared on their own two lines,
// so the aliased comparisons could never fail and an attacker who swapped the
// pinned executable for one with a matching inode would have passed. No alias
// belongs here, and there is none: ExecutableMetadataMatches in
// src/imessage-proxy-server.m carries an #if defined(__APPLE__) instead, which
// keeps the full check on the platform that has the fields and drops those two
// terms - visibly - on the platform that does not.

#include <CoreFoundation/CoreFoundation.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>

// GNUstep defines NS_UNAVAILABLE as nothing at all, which turns src/'s
// `- (instancetype)init NS_UNAVAILABLE;` back into an ordinary declaration and
// makes -Wincomplete-implementation demand the very implementation the
// annotation exists to forbid. Apple spells it as the availability attribute,
// and restoring that spelling keeps the diagnostic switched on for the methods
// src/ really has forgotten rather than turning it off for all of them.
#undef NS_UNAVAILABLE
#define NS_UNAVAILABLE __attribute__((unavailable))

// GNUstep base 1.29 accepts no writing options beyond pretty-printing, so this
// makes the call compile but does not make the keys sorted. Every canonical
// JSON encoding on this platform therefore comes out in whatever order the
// dictionary enumerates, which means the config fingerprint computed here does
// not match the one computed on macOS. Nothing in the unit tier may assert on a
// fingerprint value or on key order.
#ifndef NSJSONWritingSortedKeys
#define NSJSONWritingSortedKeys ((NSJSONWritingOptions)(1UL << 1))
#endif

// GNUstep base 1.29 has neither NSDataReadingOptions nor
// +dataWithContentsOfFile:options:error:, and src/ uses both when it reads the
// configuration file and the console assets. Declaring the selector is enough
// to compile but not to run, so darwin-shim.c installs an implementation onto
// NSData at load time; without that, the first configuration read would die on
// an unrecognised selector rather than on anything a test could read. The
// mapping hint is dropped, which is a performance property and not a behaviour
// this tier can observe.
typedef NS_OPTIONS(NSUInteger, IMPStubNSDataReadingOptions) {
    IMPStubNSDataReadingMappedIfSafe = 1UL << 0,
    IMPStubNSDataReadingUncached = 1UL << 1,
    IMPStubNSDataReadingMappedAlways = 1UL << 3,
};

#ifndef NSDataReadingMappedIfSafe
#define NSDataReadingMappedIfSafe IMPStubNSDataReadingMappedIfSafe
#endif

// Every pointer here is annotated explicitly rather than left to
// NS_ASSUME_NONNULL_BEGIN, because this header is force-included ahead of
// Foundation and an unbalanced audited region would leak into src/.
@interface NSData (IMPLinuxDarwinGaps)
+ (nullable instancetype)dataWithContentsOfFile:(NSString *_Nonnull)path
                                        options:(IMPStubNSDataReadingOptions)options
                                          error:(NSError *_Nullable *_Nullable)error;
@end

#endif
