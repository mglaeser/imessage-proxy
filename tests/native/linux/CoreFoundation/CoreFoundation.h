// Darwin's CoreFoundation has no Linux counterpart, and src/ reaches into it
// for exactly one question: is this NSNumber really a JSON true/false rather
// than a number. Six call sites ask it - IsIntegerNumber and IsBooleanNumber in
// src/imessage-proxy-server.m, the sender-identifier opt-out and chat-id guards
// beside them, the retention-days guard, and IMPNumberIsIntegerInRange in
// src/api-key-store.m - and every one of them is a validation boundary. A stub
// that makes CFGetTypeID(x) == CFBooleanGetTypeID() answer "never" classifies
// every boolean as a number, so `{"retention_days": true}` would be accepted as
// an integer and the tests would report a pass. That is the defect this header
// exists to avoid, not to reproduce; darwin-shim.c answers it by asking the
// Objective-C runtime for the object's objCType.
//
// Only the two functions src/ calls are declared. CFRetain, CFRelease,
// kCFBooleanTrue and the other type-ID getters are deliberately absent: nothing
// in src/ uses them, and an unbacked declaration would defer the failure to
// link time.
//
// This directory is compiled only on Linux and only for the native unit tests.
// The macOS build never sees it, and nothing in here may change what src/ does.

#pragma once

typedef const void *CFTypeRef;
typedef unsigned long CFTypeID;

extern CFTypeID CFGetTypeID(CFTypeRef cf);
extern CFTypeID CFBooleanGetTypeID(void);
