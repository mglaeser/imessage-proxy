// Apple's unified logging has no Linux counterpart. The spike defined every
// os_log macro as `do { } while (0)`, which compiles and links but makes the
// operational log unobservable: a change that stopped emitting the shutdown
// fault, or that leaked a key UUID into a %{public} field, would pass silently.
// src/imessage-proxy-server.m treats that log as the operator-facing record of
// what the server did, so the stub records instead of discarding, and exposes
// the recording to tests.
//
// Two deliberate divergences from Darwin. First, os_log's %{public} and
// %{private} annotations are stripped before formatting rather than honoured,
// so the recorded text carries the substituted value in both cases; a test that
// wants to pin which fields are marked private must read the format strings in
// src/, not this buffer. Second, the buffer is bounded and keeps only the most
// recent IMP_LINUX_OS_LOG_RECORD_CAPACITY records, so a test that logs more
// than that and then asserts on the first one is asserting on nothing -
// IMPLinuxOSLogOverwrittenRecordCount reports when that has happened.
//
// This directory is compiled only on Linux and only for the native unit tests.
// The macOS build never sees it, and nothing in here may change what src/ does.

#pragma once

#include <stddef.h>
#include <stdint.h>

typedef struct os_log_s *os_log_t;
typedef uint8_t os_log_type_t;

#define OS_LOG_DEFAULT ((os_log_t)0)

enum {
    OS_LOG_TYPE_DEFAULT = 0x00,
    OS_LOG_TYPE_INFO = 0x01,
    OS_LOG_TYPE_DEBUG = 0x02,
    OS_LOG_TYPE_ERROR = 0x10,
    OS_LOG_TYPE_FAULT = 0x11
};

// The capture is a fixed ring so that a server run cannot grow it without
// bound. These are the sizes a test should size its own buffers from rather
// than guessing.
#define IMP_LINUX_OS_LOG_RECORD_CAPACITY 64
#define IMP_LINUX_OS_LOG_MESSAGE_CAPACITY 512

extern os_log_t os_log_create(const char *subsystem, const char *category);
extern int os_log_type_enabled(os_log_t log, os_log_type_t type);

// The recorder behind every macro below. It is not marked with a printf format
// attribute on purpose: %{public}s is not a printf conversion, and -Wformat
// would reject every real call site in src/.
extern void IMPLinuxOSLogRecord(os_log_t log, os_log_type_t type, const char *format, ...);

// Discards everything captured so far. A test that does not call this first is
// asserting against whatever the preceding test left behind.
extern void IMPLinuxOSLogReset(void);

// How many records are currently retained, at most IMP_LINUX_OS_LOG_RECORD_CAPACITY.
extern size_t IMPLinuxOSLogRecordCount(void);

// How many records have been pushed out of the ring since the last reset. Any
// value other than zero means the transcript is incomplete.
extern unsigned long long IMPLinuxOSLogOverwrittenRecordCount(void);

// Copies record `index`, counted from the oldest retained record, into
// `destination` as a NUL-terminated string, and writes its os_log type to
// `typeOut` when that is not NULL. Returns the length the message would need
// excluding the NUL, so a return of `capacity` or more means it was truncated;
// returns zero for an index that is out of range.
extern size_t IMPLinuxOSLogCopyRecord(size_t index, os_log_type_t *typeOut, char *destination, size_t capacity);

// Copies every retained record into `destination`, one per line and separated
// by newlines, as a NUL-terminated string. Line order is oldest first and the
// os_log type is not included, so this is the accessor for "does the log
// mention X" and IMPLinuxOSLogCopyRecord is the one for "at what level".
// Returns the full transcript length excluding the NUL.
extern size_t IMPLinuxOSLogCopyTranscript(char *destination, size_t capacity);

#define os_log(log, ...) IMPLinuxOSLogRecord((log), OS_LOG_TYPE_DEFAULT, __VA_ARGS__)
#define os_log_info(log, ...) IMPLinuxOSLogRecord((log), OS_LOG_TYPE_INFO, __VA_ARGS__)
#define os_log_debug(log, ...) IMPLinuxOSLogRecord((log), OS_LOG_TYPE_DEBUG, __VA_ARGS__)
#define os_log_error(log, ...) IMPLinuxOSLogRecord((log), OS_LOG_TYPE_ERROR, __VA_ARGS__)
#define os_log_fault(log, ...) IMPLinuxOSLogRecord((log), OS_LOG_TYPE_FAULT, __VA_ARGS__)
#define os_log_with_type(log, type, ...) IMPLinuxOSLogRecord((log), (type), __VA_ARGS__)
