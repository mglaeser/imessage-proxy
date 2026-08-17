// The implementations behind the Darwin headers vendored beside this file. It
// exists so that src/api-key-store.m and src/imessage-proxy-server.m can be
// compiled and linked unmodified on a Linux runner, which is the only way the
// native unit tier can run anywhere except a Mac.
//
// It is written in C rather than Objective-C on purpose: it has to be built
// with the plain C driver, next to sources that are built with ARC, and mixing
// the two in one file would make the ARC flags load-bearing for a file that has
// no Objective-C objects of its own. Where it does need the Objective-C runtime
// - the boolean probe and the NSData gap - it goes through the runtime's C API,
// which needs libobjc2's headers on the include path.
//
// This directory is compiled only on Linux and only for the native unit tests.
// The macOS build never sees it, and nothing in here may change what src/ does.

#define _GNU_SOURCE

#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <dispatch/dispatch.h>
#include <os/log.h>

#include <errno.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// This one is deliberately outside the sorted group above. libobjc2's
// <objc/message.h> uses id and SEL without declaring them, so it only compiles
// after <objc/runtime.h>, and clang-format would sort it above its dependency
// if the two shared an include block.
#include <objc/message.h>

// CommonCrypto.
//
// A compact SHA-256 in the shape CommonCrypto exposes. The digest has to agree
// with Apple's byte for byte, because the API key digest it produces is stored
// and compared, and the pinned-executable digest it produces is compared
// against a value computed on a Mac.

typedef struct {
    uint32_t state[8];
    uint64_t bits;
    unsigned char block[64];
    size_t filled;
} IMPLinuxSHA256Context;

// The header pads CC_SHA256_CTX well past this on purpose; see the comment
// there. This is the assertion that keeps the two in step, because the failure
// it prevents - writing past the end of a caller's stack slot - shows up as a
// wrong digest rather than as a crash, and a wrong digest looks exactly like a
// mismatched key.
_Static_assert(sizeof(IMPLinuxSHA256Context) <= sizeof(CC_SHA256_CTX),
               "CC_SHA256_CTX in CommonCrypto/CommonDigest.h is smaller than the context this shim writes");

static const uint32_t IMPLinuxSHA256Constants[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

static uint32_t IMPLinuxRotateRight(uint32_t value, unsigned int distance) {
    return (value >> distance) | (value << (32 - distance));
}

static void IMPLinuxSHA256Block(IMPLinuxSHA256Context *context, const unsigned char *block) {
    uint32_t schedule[64];
    for (int index = 0; index < 16; index++) {
        schedule[index] = ((uint32_t)block[index * 4] << 24) | ((uint32_t)block[index * 4 + 1] << 16) |
                          ((uint32_t)block[index * 4 + 2] << 8) | (uint32_t)block[index * 4 + 3];
    }
    for (int index = 16; index < 64; index++) {
        uint32_t low = IMPLinuxRotateRight(schedule[index - 15], 7) ^ IMPLinuxRotateRight(schedule[index - 15], 18) ^
                       (schedule[index - 15] >> 3);
        uint32_t high = IMPLinuxRotateRight(schedule[index - 2], 17) ^ IMPLinuxRotateRight(schedule[index - 2], 19) ^
                        (schedule[index - 2] >> 10);
        schedule[index] = schedule[index - 16] + low + schedule[index - 7] + high;
    }

    uint32_t a = context->state[0];
    uint32_t b = context->state[1];
    uint32_t c = context->state[2];
    uint32_t d = context->state[3];
    uint32_t e = context->state[4];
    uint32_t f = context->state[5];
    uint32_t g = context->state[6];
    uint32_t h = context->state[7];
    for (int index = 0; index < 64; index++) {
        uint32_t first = h + (IMPLinuxRotateRight(e, 6) ^ IMPLinuxRotateRight(e, 11) ^ IMPLinuxRotateRight(e, 25)) +
                         ((e & f) ^ (~e & g)) + IMPLinuxSHA256Constants[index] + schedule[index];
        uint32_t second = (IMPLinuxRotateRight(a, 2) ^ IMPLinuxRotateRight(a, 13) ^ IMPLinuxRotateRight(a, 22)) +
                          ((a & b) ^ (a & c) ^ (b & c));
        h = g;
        g = f;
        f = e;
        e = d + first;
        d = c;
        c = b;
        b = a;
        a = first + second;
    }

    context->state[0] += a;
    context->state[1] += b;
    context->state[2] += c;
    context->state[3] += d;
    context->state[4] += e;
    context->state[5] += f;
    context->state[6] += g;
    context->state[7] += h;
}

int CC_SHA256_Init(CC_SHA256_CTX *context) {
    IMPLinuxSHA256Context *state = (IMPLinuxSHA256Context *)context;
    memset(state, 0, sizeof *state);
    state->state[0] = 0x6a09e667;
    state->state[1] = 0xbb67ae85;
    state->state[2] = 0x3c6ef372;
    state->state[3] = 0xa54ff53a;
    state->state[4] = 0x510e527f;
    state->state[5] = 0x9b05688c;
    state->state[6] = 0x1f83d9ab;
    state->state[7] = 0x5be0cd19;
    return 1;
}

int CC_SHA256_Update(CC_SHA256_CTX *context, const void *data, CC_LONG length) {
    IMPLinuxSHA256Context *state = (IMPLinuxSHA256Context *)context;
    const unsigned char *cursor = data;
    state->bits += (uint64_t)length * 8;
    while (length > 0) {
        size_t take = 64 - state->filled;
        if (take > length)
            take = length;
        memcpy(state->block + state->filled, cursor, take);
        state->filled += take;
        cursor += take;
        length -= (CC_LONG)take;
        if (state->filled == 64) {
            IMPLinuxSHA256Block(state, state->block);
            state->filled = 0;
        }
    }
    return 1;
}

int CC_SHA256_Final(unsigned char *digest, CC_SHA256_CTX *context) {
    IMPLinuxSHA256Context *state = (IMPLinuxSHA256Context *)context;
    uint64_t bits = state->bits;
    unsigned char one = 0x80;
    CC_SHA256_Update(context, &one, 1);
    while (state->filled != 56) {
        unsigned char zero = 0;
        CC_SHA256_Update(context, &zero, 1);
    }
    for (int index = 0; index < 8; index++) {
        state->block[56 + index] = (unsigned char)(bits >> ((7 - index) * 8));
    }
    IMPLinuxSHA256Block(state, state->block);
    state->filled = 0;
    for (int index = 0; index < 8; index++) {
        digest[index * 4] = (unsigned char)(state->state[index] >> 24);
        digest[index * 4 + 1] = (unsigned char)(state->state[index] >> 16);
        digest[index * 4 + 2] = (unsigned char)(state->state[index] >> 8);
        digest[index * 4 + 3] = (unsigned char)state->state[index];
    }
    return 1;
}

unsigned char *CC_SHA256(const void *data, CC_LONG length, unsigned char *digest) {
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    CC_SHA256_Update(&context, data, length);
    CC_SHA256_Final(digest, &context);
    return digest;
}

// Security.framework.

const SecRandomRef kSecRandomDefault = NULL;

int SecRandomCopyBytes(SecRandomRef source, size_t count, void *bytes) {
    (void)source;
    if (bytes == NULL && count > 0)
        return errSecParam;
    FILE *entropy = fopen("/dev/urandom", "rb");
    if (entropy == NULL)
        return errSecParam;
    size_t read = fread(bytes, 1, count, entropy);
    fclose(entropy);
    return read == count ? errSecSuccess : errSecParam;
}

// CoreFoundation.
//
// The only thing src/ asks CoreFoundation is whether an NSNumber came out of
// JSON as a boolean, and it asks by comparing type IDs. Two stable sentinels
// are enough for that, provided CFGetTypeID actually answers the question: the
// spike returned a constant that could never equal CFBooleanGetTypeID(), which
// made every boolean look like a number to all six call sites.
//
// The known divergence, which decides how the tests must be written. On Darwin
// NSJSONSerialization produces __NSCFBoolean for true and false, and
// @encode(BOOL) there is "c" - the same encoding a hand-built char-valued
// NSNumber such as @('x') carries, so on Darwin this probe would call that char
// a boolean. It is a real hole in the technique, not in this shim, and it is
// invisible here because GNUstep encodes BOOL as "C" and a char-valued NSNumber
// as "c" or "q" instead. A test that builds its input by hand is therefore
// testing a different thing on each platform. Every test of these six call
// sites must take its numbers from parsed JSON, never from @('x') or any other
// literal whose encoding is an accident of the Foundation in use.
//
// The reference encoding is read off the return type of -[NSNumber boolValue]
// rather than hard-coded, because that is @encode(BOOL) for whichever
// Foundation is actually linked, and hard-coding "c" would have been wrong on
// this one.

static const CFTypeID IMPLinuxCFBooleanTypeID = 0x424f4f4cul;
static const CFTypeID IMPLinuxCFOtherTypeID = 0x4f544845ul;

static pthread_once_t IMPLinuxBooleanProbeOnce = PTHREAD_ONCE_INIT;
static Class IMPLinuxNumberClass;
static SEL IMPLinuxObjCTypeSelector;
static char IMPLinuxBooleanEncoding[16];

static void IMPLinuxResolveBooleanProbe(void) {
    IMPLinuxObjCTypeSelector = sel_registerName("objCType");
    IMPLinuxNumberClass = (Class)objc_getClass("NSNumber");
    if (IMPLinuxNumberClass == Nil)
        return;
    Method boolValue = class_getInstanceMethod(IMPLinuxNumberClass, sel_registerName("boolValue"));
    if (boolValue == NULL)
        return;
    method_getReturnType(boolValue, IMPLinuxBooleanEncoding, sizeof IMPLinuxBooleanEncoding);
}

CFTypeID CFBooleanGetTypeID(void) { return IMPLinuxCFBooleanTypeID; }

CFTypeID CFGetTypeID(CFTypeRef cf) {
    if (cf == NULL)
        return IMPLinuxCFOtherTypeID;
    pthread_once(&IMPLinuxBooleanProbeOnce, IMPLinuxResolveBooleanProbe);
    if (IMPLinuxNumberClass == Nil || IMPLinuxBooleanEncoding[0] == '\0')
        return IMPLinuxCFOtherTypeID;

    Class candidate = object_getClass((id)cf);
    Class ancestor = candidate;
    while (ancestor != Nil && ancestor != IMPLinuxNumberClass) {
        ancestor = class_getSuperclass(ancestor);
    }
    if (ancestor == Nil)
        return IMPLinuxCFOtherTypeID;

    Method objCType = class_getInstanceMethod(candidate, IMPLinuxObjCTypeSelector);
    if (objCType == NULL)
        return IMPLinuxCFOtherTypeID;
    const char *(*read)(id, SEL) = (const char *(*)(id, SEL))method_getImplementation(objCType);
    const char *encoding = read((id)cf, IMPLinuxObjCTypeSelector);
    if (encoding == NULL)
        return IMPLinuxCFOtherTypeID;
    return strcmp(encoding, IMPLinuxBooleanEncoding) == 0 ? IMPLinuxCFBooleanTypeID : IMPLinuxCFOtherTypeID;
}

// Unified logging.
//
// A bounded ring, so that a long run cannot grow it and a test can read back
// exactly what the code under test emitted. See os/log.h for the two
// divergences from Darwin this carries.

static pthread_mutex_t IMPLinuxLogLock = PTHREAD_MUTEX_INITIALIZER;

static struct {
    os_log_type_t type;
    char message[IMP_LINUX_OS_LOG_MESSAGE_CAPACITY];
} IMPLinuxLogRecords[IMP_LINUX_OS_LOG_RECORD_CAPACITY];

static size_t IMPLinuxLogOldest;
static size_t IMPLinuxLogCount;
static unsigned long long IMPLinuxLogOverwritten;

static char IMPLinuxSharedLogStorage;

// os_log's %{public} and %{private} annotations are not printf conversions.
// Handing them to vsnprintf produces an undefined conversion that consumes no
// argument, which walks the remaining varargs out of step with the format and
// reads a char pointer out of an integer - a crash, in the shim, blamed on the
// code under test. Removing the braced annotation leaves a format glibc
// understands and an argument list that still lines up. %@ has no equivalent
// rescue and src/ does not use it in an os_log format; if one ever appears here
// it will format as garbage rather than as a description.
static void IMPLinuxStripLogAnnotations(const char *format, char *destination, size_t capacity) {
    size_t out = 0;
    for (size_t in = 0; format[in] != '\0' && out + 1 < capacity; in++) {
        destination[out++] = format[in];
        if (format[in] != '%')
            continue;
        if (format[in + 1] == '%') {
            if (out + 1 >= capacity)
                break;
            destination[out++] = format[++in];
            continue;
        }
        if (format[in + 1] != '{')
            continue;
        size_t scan = in + 2;
        while (format[scan] != '\0' && format[scan] != '}') {
            scan++;
        }
        if (format[scan] == '}')
            in = scan;
    }
    destination[out] = '\0';
}

void IMPLinuxOSLogRecord(os_log_t log, os_log_type_t type, const char *format, ...) {
    (void)log;
    if (format == NULL)
        return;

    char sanitised[IMP_LINUX_OS_LOG_MESSAGE_CAPACITY];
    IMPLinuxStripLogAnnotations(format, sanitised, sizeof sanitised);

    char message[IMP_LINUX_OS_LOG_MESSAGE_CAPACITY];
    va_list arguments;
    va_start(arguments, format);
    int written = vsnprintf(message, sizeof message, sanitised, arguments);
    va_end(arguments);
    if (written < 0)
        snprintf(message, sizeof message, "<os_log record could not be formatted>");

    pthread_mutex_lock(&IMPLinuxLogLock);
    size_t slot = (IMPLinuxLogOldest + IMPLinuxLogCount) % IMP_LINUX_OS_LOG_RECORD_CAPACITY;
    if (IMPLinuxLogCount == IMP_LINUX_OS_LOG_RECORD_CAPACITY) {
        IMPLinuxLogOldest = (IMPLinuxLogOldest + 1) % IMP_LINUX_OS_LOG_RECORD_CAPACITY;
        IMPLinuxLogOverwritten++;
    } else {
        IMPLinuxLogCount++;
    }
    IMPLinuxLogRecords[slot].type = type;
    memcpy(IMPLinuxLogRecords[slot].message, message, sizeof IMPLinuxLogRecords[slot].message);
    IMPLinuxLogRecords[slot].message[IMP_LINUX_OS_LOG_MESSAGE_CAPACITY - 1] = '\0';
    pthread_mutex_unlock(&IMPLinuxLogLock);
}

void IMPLinuxOSLogReset(void) {
    pthread_mutex_lock(&IMPLinuxLogLock);
    IMPLinuxLogOldest = 0;
    IMPLinuxLogCount = 0;
    IMPLinuxLogOverwritten = 0;
    pthread_mutex_unlock(&IMPLinuxLogLock);
}

size_t IMPLinuxOSLogRecordCount(void) {
    pthread_mutex_lock(&IMPLinuxLogLock);
    size_t count = IMPLinuxLogCount;
    pthread_mutex_unlock(&IMPLinuxLogLock);
    return count;
}

unsigned long long IMPLinuxOSLogOverwrittenRecordCount(void) {
    pthread_mutex_lock(&IMPLinuxLogLock);
    unsigned long long overwritten = IMPLinuxLogOverwritten;
    pthread_mutex_unlock(&IMPLinuxLogLock);
    return overwritten;
}

size_t IMPLinuxOSLogCopyRecord(size_t index, os_log_type_t *typeOut, char *destination, size_t capacity) {
    pthread_mutex_lock(&IMPLinuxLogLock);
    if (index >= IMPLinuxLogCount) {
        pthread_mutex_unlock(&IMPLinuxLogLock);
        if (destination != NULL && capacity > 0)
            destination[0] = '\0';
        return 0;
    }
    size_t slot = (IMPLinuxLogOldest + index) % IMP_LINUX_OS_LOG_RECORD_CAPACITY;
    if (typeOut != NULL)
        *typeOut = IMPLinuxLogRecords[slot].type;
    size_t length = strlen(IMPLinuxLogRecords[slot].message);
    if (destination != NULL && capacity > 0) {
        size_t copied = length < capacity - 1 ? length : capacity - 1;
        memcpy(destination, IMPLinuxLogRecords[slot].message, copied);
        destination[copied] = '\0';
    }
    pthread_mutex_unlock(&IMPLinuxLogLock);
    return length;
}

size_t IMPLinuxOSLogCopyTranscript(char *destination, size_t capacity) {
    size_t total = 0;
    size_t out = 0;
    pthread_mutex_lock(&IMPLinuxLogLock);
    for (size_t index = 0; index < IMPLinuxLogCount; index++) {
        size_t slot = (IMPLinuxLogOldest + index) % IMP_LINUX_OS_LOG_RECORD_CAPACITY;
        const char *message = IMPLinuxLogRecords[slot].message;
        for (size_t byte = 0; message[byte] != '\0'; byte++) {
            if (destination != NULL && capacity > 0 && out + 1 < capacity)
                destination[out++] = message[byte];
            total++;
        }
        if (index + 1 < IMPLinuxLogCount) {
            if (destination != NULL && capacity > 0 && out + 1 < capacity)
                destination[out++] = '\n';
            total++;
        }
    }
    if (destination != NULL && capacity > 0)
        destination[out] = '\0';
    pthread_mutex_unlock(&IMPLinuxLogLock);
    return total;
}

// The subsystem and category are discarded because src/ creates exactly one log
// and nothing distinguishes records by handle. A test that wants to pin the
// subsystem string should read it out of src/, where it is a literal.
os_log_t os_log_create(const char *subsystem, const char *category) {
    (void)subsystem;
    (void)category;
    return (os_log_t)&IMPLinuxSharedLogStorage;
}

// Every level is enabled, because the whole point of the capture is that the
// test sees what the code chose to emit rather than what a log configuration
// chose to keep.
int os_log_type_enabled(os_log_t log, os_log_type_t type) {
    (void)log;
    (void)type;
    return 1;
}

// libdispatch.
//
// Enough to link and to make the lazy log handle work. Read the warning at the
// top of dispatch/dispatch.h before writing anything that depends on any of it:
// the unit tier does not exercise concurrency, so none of this has ever been
// under test and none of it should be trusted until something exercises it.

struct dispatch_queue_s {
    pthread_mutex_t lock;
};

struct dispatch_group_s {
    pthread_mutex_t lock;
    pthread_cond_t idle;
    long outstanding;
};

struct dispatch_semaphore_s {
    sem_t counter;
};

void dispatch_once(dispatch_once_t *predicate, dispatch_block_t block) {
    static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&gate);
    if (*predicate == 0) {
        *predicate = 1;
        pthread_mutex_unlock(&gate);
        block();
        pthread_mutex_lock(&gate);
        *predicate = 2;
    }
    while (*predicate != 2) {
        pthread_mutex_unlock(&gate);
        usleep(200);
        pthread_mutex_lock(&gate);
    }
    pthread_mutex_unlock(&gate);
}

dispatch_time_t dispatch_time(dispatch_time_t base, int64_t delta) {
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    dispatch_time_t absolute = (dispatch_time_t)now.tv_sec * NSEC_PER_SEC + (dispatch_time_t)now.tv_nsec;
    return (base != DISPATCH_TIME_NOW ? base : absolute) + (dispatch_time_t)delta;
}

dispatch_queue_t dispatch_queue_create(const char *label, dispatch_queue_attr_t attribute) {
    (void)label;
    (void)attribute;
    dispatch_queue_t queue = calloc(1, sizeof *queue);
    if (queue == NULL)
        return NULL;
    pthread_mutex_init(&queue->lock, NULL);
    return queue;
}

dispatch_group_t dispatch_group_create(void) {
    dispatch_group_t group = calloc(1, sizeof *group);
    if (group == NULL)
        return NULL;
    pthread_mutex_init(&group->lock, NULL);
    pthread_cond_init(&group->idle, NULL);
    return group;
}

struct IMPLinuxGroupWork {
    dispatch_group_t group;
    dispatch_block_t block;
};

static void *IMPLinuxRunGroupWork(void *argument) {
    struct IMPLinuxGroupWork *work = argument;
    work->block();
    pthread_mutex_lock(&work->group->lock);
    work->group->outstanding--;
    pthread_cond_broadcast(&work->group->idle);
    pthread_mutex_unlock(&work->group->lock);
    free(work);
    return NULL;
}

void dispatch_group_async(dispatch_group_t group, dispatch_queue_t queue, dispatch_block_t block) {
    (void)queue;
    struct IMPLinuxGroupWork *work = malloc(sizeof *work);
    if (work == NULL)
        return;
    work->group = group;
    work->block = block;
    pthread_mutex_lock(&group->lock);
    group->outstanding++;
    pthread_mutex_unlock(&group->lock);
    pthread_t thread;
    if (pthread_create(&thread, NULL, IMPLinuxRunGroupWork, work) != 0) {
        pthread_mutex_lock(&group->lock);
        group->outstanding--;
        pthread_cond_broadcast(&group->idle);
        pthread_mutex_unlock(&group->lock);
        free(work);
        return;
    }
    pthread_detach(thread);
}

long dispatch_group_wait(dispatch_group_t group, dispatch_time_t timeout) {
    struct timespec deadline;
    deadline.tv_sec = (time_t)(timeout / NSEC_PER_SEC);
    deadline.tv_nsec = (long)(timeout % NSEC_PER_SEC);
    long timedOut = 0;
    pthread_mutex_lock(&group->lock);
    while (group->outstanding > 0) {
        if (timeout == DISPATCH_TIME_FOREVER) {
            pthread_cond_wait(&group->idle, &group->lock);
        } else if (pthread_cond_timedwait(&group->idle, &group->lock, &deadline) != 0) {
            timedOut = 1;
            break;
        }
    }
    pthread_mutex_unlock(&group->lock);
    return timedOut;
}

dispatch_semaphore_t dispatch_semaphore_create(long value) {
    dispatch_semaphore_t semaphore = calloc(1, sizeof *semaphore);
    if (semaphore == NULL)
        return NULL;
    sem_init(&semaphore->counter, 0, (unsigned int)value);
    return semaphore;
}

long dispatch_semaphore_signal(dispatch_semaphore_t semaphore) {
    sem_post(&semaphore->counter);
    return 0;
}

long dispatch_semaphore_wait(dispatch_semaphore_t semaphore, dispatch_time_t timeout) {
    if (timeout == DISPATCH_TIME_FOREVER) {
        while (sem_wait(&semaphore->counter) != 0 && errno == EINTR) {
        }
        return 0;
    }
    struct timespec deadline;
    deadline.tv_sec = (time_t)(timeout / NSEC_PER_SEC);
    deadline.tv_nsec = (long)(timeout % NSEC_PER_SEC);
    return sem_timedwait(&semaphore->counter, &deadline) == 0 ? 0 : 1;
}

// Foundation gaps.
//
// GNUstep base 1.29 has no +dataWithContentsOfFile:options:error:, and src/
// reads both the configuration file and every console asset through it.
// Declaring the selector in compat/darwin-compat.h is enough to compile, but a
// declared selector with nothing behind it dies at the first configuration read
// with an unrecognised-selector abort that names neither the file nor the
// caller. Installing it here at load time keeps that failure out of the tier
// entirely. class_addMethod does not replace an existing method, so if GNUstep
// ever grows the real one this becomes a no-op rather than a regression.

// Class methods go through objc_msgSend rather than through an IMP taken from
// the metaclass, because libobjc2 puts the lazy +initialize trampoline in that
// slot: calling the IMP directly on a class nothing has messaged yet aborts
// inside the runtime with no diagnostic. The instance method below is safe to
// call directly only because receiving a message is what proves its class is
// already initialised.
extern id NSPOSIXErrorDomain;

static id IMPLinuxNSDataReadFile(id self, SEL selector, id path, unsigned long options, id *error) {
    (void)selector;
    (void)options;
    id (*send)(id, SEL, id) = (id(*)(id, SEL, id))objc_msgSend;
    errno = 0;
    id data = send(self, sel_registerName("dataWithContentsOfFile:"), path);
    if (data != NULL || error == NULL)
        return data;

    // errno is the best diagnosis available here, and it is only approximate:
    // GNUstep may have made further syscalls between the failure and the
    // return. Nothing may assert on the code, only on the fact that an error
    // object came back at all.
    int failure = errno != 0 ? errno : ENOENT;
    id errorClass = objc_getClass("NSError");
    if (errorClass == NULL)
        return NULL;
    id (*build)(id, SEL, id, long, id) = (id(*)(id, SEL, id, long, id))objc_msgSend;
    *error =
        build(errorClass, sel_registerName("errorWithDomain:code:userInfo:"), NSPOSIXErrorDomain, (long)failure, NULL);
    return NULL;
}

__attribute__((constructor)) static void IMPLinuxInstallFoundationGaps(void) {
    Class data = (Class)objc_getClass("NSData");
    if (data == Nil)
        return;
    class_addMethod(object_getClass((id)data), sel_registerName("dataWithContentsOfFile:options:error:"),
                    (IMP)IMPLinuxNSDataReadFile, "@@:@Q^@");
}
