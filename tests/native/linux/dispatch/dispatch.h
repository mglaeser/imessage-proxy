// libdispatch is not packaged for Debian and swift-corelibs-libdispatch is a
// build of its own, so this declares the nine dispatch entry points
// src/imessage-proxy-server.m needs in order to link, and darwin-shim.c backs
// them with pthreads and POSIX semaphores.
//
// Read this before you trust anything below. The unit tier does not exercise
// concurrency: it calls pure and Foundation-light functions on one thread, and
// the only dispatch call it actually reaches is dispatch_once behind the lazy
// log handle. The queue here is not a queue - dispatch_queue_create ignores its
// attribute entirely and dispatch_group_async spawns a detached thread per
// block, so serial ordering, quality-of-service and the concurrency limit are
// all absent. Nothing may assert on ordering, throughput or timing against this
// file until someone has replaced it with a real implementation and said so
// here. The macOS integration suite is where the concurrency behaviour is
// pinned.
//
// Only what src/ calls is declared. dispatch_async, dispatch_sync,
// dispatch_after, dispatch_group_enter/leave/notify, dispatch_apply and the
// global and main queue accessors are deliberately absent rather than declared
// and unimplemented, so that reaching for one fails on the line that asked for
// it instead of at link time.
//
// This directory is compiled only on Linux and only for the native unit tests.
// The macOS build never sees it, and nothing in here may change what src/ does.

#pragma once

#include <stddef.h>
#include <stdint.h>

typedef long dispatch_once_t;
typedef uint64_t dispatch_time_t;

// Every one of these is a pointer to an incomplete type, as it is on Darwin, so
// no caller can allocate one by value and none of them can be sized wrongly.
typedef struct dispatch_queue_s *dispatch_queue_t;
typedef struct dispatch_group_s *dispatch_group_t;
typedef struct dispatch_semaphore_s *dispatch_semaphore_t;
typedef struct dispatch_queue_attr_s *dispatch_queue_attr_t;

typedef void (^dispatch_block_t)(void);

#define DISPATCH_TIME_NOW ((dispatch_time_t)0ull)
#define DISPATCH_TIME_FOREVER (~0ull)

#define NSEC_PER_SEC 1000000000ull
#define NSEC_PER_MSEC 1000000ull
#define NSEC_PER_USEC 1000ull
#define USEC_PER_SEC 1000000ull

// Both attributes are accepted and both are ignored, which is the single
// largest divergence in this file.
#define DISPATCH_QUEUE_SERIAL ((dispatch_queue_attr_t)0)
#define DISPATCH_QUEUE_CONCURRENT ((dispatch_queue_attr_t)1)

extern void dispatch_once(dispatch_once_t *predicate, dispatch_block_t block);
extern dispatch_time_t dispatch_time(dispatch_time_t base, int64_t delta);

extern dispatch_queue_t dispatch_queue_create(const char *label, dispatch_queue_attr_t attribute);

extern dispatch_group_t dispatch_group_create(void);
extern void dispatch_group_async(dispatch_group_t group, dispatch_queue_t queue, dispatch_block_t block);
extern long dispatch_group_wait(dispatch_group_t group, dispatch_time_t timeout);

extern dispatch_semaphore_t dispatch_semaphore_create(long value);
extern long dispatch_semaphore_wait(dispatch_semaphore_t semaphore, dispatch_time_t timeout);
extern long dispatch_semaphore_signal(dispatch_semaphore_t semaphore);
