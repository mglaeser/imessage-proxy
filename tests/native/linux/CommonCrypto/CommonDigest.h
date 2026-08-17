// Apple's CommonCrypto has no Linux counterpart, and src/api-key-store.m and
// src/imessage-proxy-server.m both hash with it: the API key digest and the
// pinned-executable digest. This header declares only the SHA-256 surface those
// two files use, and darwin-shim.c supplies the implementation. Nothing else
// from CommonCrypto is declared, because a declaration with no definition turns
// a missing feature into a link error at the end of a long build instead of a
// compile error on the line that asked for it.
//
// This directory is compiled only on Linux and only for the native unit tests.
// The macOS build never sees it, and nothing in here may change what src/ does.

#pragma once

#include <stddef.h>
#include <stdint.h>

typedef uint32_t CC_LONG;

#define CC_SHA256_DIGEST_LENGTH 32

// Callers declare this on the stack and hand its address to the shim, so the
// header's idea of the size is the only bound the shim has. Darwin's real
// CC_SHA256_CTX is 104 bytes (two CC_LONG counters, eight state words and a
// sixteen-word block buffer); the context darwin-shim.c actually writes is 112,
// because it carries a 64-bit bit counter and a size_t fill level instead. Any
// header sized from the Darwin number therefore overruns the caller's frame and
// yields a digest that is wrong in a way no assertion on the digest can
// attribute. It is padded to 256 bytes so that swapping in a different SHA-256
// implementation - OpenSSL's SHA256_CTX is 112 bytes, Nettle's is 128 - cannot
// reintroduce that, and darwin-shim.c carries a _Static_assert that its own
// context still fits.
typedef struct CC_SHA256state_st {
    uint64_t opaque[32];
} CC_SHA256_CTX;

extern int CC_SHA256_Init(CC_SHA256_CTX *context);
extern int CC_SHA256_Update(CC_SHA256_CTX *context, const void *data, CC_LONG length);
extern int CC_SHA256_Final(unsigned char *digest, CC_SHA256_CTX *context);
extern unsigned char *CC_SHA256(const void *data, CC_LONG length, unsigned char *digest);
