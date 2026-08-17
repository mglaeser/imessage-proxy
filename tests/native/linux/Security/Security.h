// Security.framework has no Linux counterpart, and src/api-key-store.m uses one
// call from it: SecRandomCopyBytes, to draw the raw bytes of a new API key. The
// shim reads /dev/urandom, which is the same guarantee on this platform, so a
// unit test that only checks key length and uniqueness measures the same thing
// it would on macOS. A test that wants to pin the *source* of entropy cannot be
// written against this file and must stay in the macOS tier.
//
// This directory is compiled only on Linux and only for the native unit tests.
// The macOS build never sees it, and nothing in here may change what src/ does.

#pragma once

#include <stddef.h>
#include <stdint.h>

#include <CoreFoundation/CoreFoundation.h>

typedef int32_t OSStatus;

enum { errSecSuccess = 0, errSecParam = -50 };

// SecRandomRef is a pointer to an incomplete type on Darwin too, so there is no
// size here to get wrong; kSecRandomDefault is a sentinel the shim never
// dereferences.
typedef struct __SecRandom *SecRandomRef;

extern const SecRandomRef kSecRandomDefault;

extern int SecRandomCopyBytes(SecRandomRef source, size_t count, void *bytes);
