#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <math.h>
#import <os/log.h>
#import <poll.h>
#import <signal.h>
#import <spawn.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <sys/un.h>
#import <sys/wait.h>
#import <time.h>
#import <unistd.h>

#import "api-key-store.h"

#ifndef IMESSAGE_PROXY_VERSION
#define IMESSAGE_PROXY_VERSION "1.0.0"
#endif

static NSString *const ServerVersion = @IMESSAGE_PROXY_VERSION;
static NSString *const RequiredIMSGVersion = @"0.13.4";
static NSString *const ServerErrorDomain = @"io.github.mglaeser.imessage-proxy.server";
static NSString *const RequestContextThreadKey = @"io.github.mglaeser.imessage-proxy.request-id";
static NSString *const RequestSourceThreadKey = @"io.github.mglaeser.imessage-proxy.request-source";
static const NSUInteger MaxHeaderBytes = 16 * 1024;
static const NSUInteger MaxRequestBytes = 64 * 1024;
static const NSUInteger MaxCommandOutputBytes = 4 * 1024 * 1024;
static const NSUInteger MaxCommandDiagnosticBytes = 64 * 1024;
static const NSUInteger MaxStatisticsDimensionItems = 100;
static volatile sig_atomic_t stopRequested = 0;
static NSObject *childProcessLock;
static NSMutableSet<NSNumber *> *childProcessGroups;

static os_log_t ServerOperationalLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("io.github.mglaeser.imessage-proxy", "native-server");
    });
    return log;
}

static void LogOperationalFailure(const char *action, const char *reason, NSError *error) {
    const char *detail = error.localizedDescription.UTF8String;
    if (detail == NULL)
        detail = "unavailable";
    os_log_with_type(ServerOperationalLog(), OS_LOG_TYPE_FAULT,
                     "action=%{public}s status=failed reason=%{public}s detail=%{private}s", action, reason, detail);
}

typedef NS_ENUM(NSInteger, IMPServerErrorCode) {
    IMPServerErrorInvalidConfiguration = 1,
    IMPServerErrorRequest,
    IMPServerErrorUpstream,
    IMPServerErrorTimeout,
    IMPServerErrorNotFound,
};

static NSError *ServerError(IMPServerErrorCode code, NSString *message) {
    return [NSError errorWithDomain:ServerErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"server error"}];
}

static NSUInteger UnicodeCodePointLength(NSString *value) {
    NSUInteger count = 0;
    for (NSUInteger index = 0; index < value.length; index++, count++) {
        unichar character = [value characterAtIndex:index];
        if (character >= 0xd800 && character <= 0xdbff && index + 1 < value.length) {
            unichar next = [value characterAtIndex:index + 1];
            if (next >= 0xdc00 && next <= 0xdfff)
                index++;
        }
    }
    return count;
}

static NSString *Trim(NSString *value) {
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL IsSafeMessageText(NSString *value) {
    if (value == nil)
        return NO;
    static NSCharacterSet *disallowedControls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *controls = [NSCharacterSet.controlCharacterSet mutableCopy];
        [controls removeCharactersInString:@"\t\n\r"];
        disallowedControls = [controls copy];
    });
    return [value rangeOfCharacterFromSet:disallowedControls].location == NSNotFound;
}

static NSString *HexDigest(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [result appendFormat:@"%02x", digest[index]];
    }
    return result;
}

static NSData *JSONData(id object, NSError **error) {
    if (![NSJSONSerialization isValidJSONObject:object]) {
        if (error != NULL) {
            *error = ServerError(IMPServerErrorRequest, @"invalid JSON object");
        }
        return nil;
    }
    return [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:error];
}

static NSString *ISO8601(NSDate *date) {
    if (date == nil) {
        return nil;
    }
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSISO8601DateFormatter new];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    @synchronized(formatter) {
        return [formatter stringFromDate:date];
    }
}

static BOOL IsValidGregorianDate(NSInteger year, NSInteger month, NSInteger day) {
    if (year < 1 || month < 1 || month > 12 || day < 1)
        return NO;
    static const NSInteger daysByMonth[] = {0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    NSInteger maximumDay = daysByMonth[month];
    BOOL leapYear = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    if (month == 2 && leapYear)
        maximumDay = 29;
    return day <= maximumDay;
}

static BOOL IsStrictFullDate(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length != 10 || [value characterAtIndex:4] != '-' ||
        [value characterAtIndex:7] != '-')
        return NO;
    for (NSUInteger index = 0; index < value.length; index++) {
        if (index == 4 || index == 7)
            continue;
        unichar character = [value characterAtIndex:index];
        if (character < '0' || character > '9')
            return NO;
    }
    return IsValidGregorianDate([[value substringWithRange:NSMakeRange(0, 4)] integerValue],
                                [[value substringWithRange:NSMakeRange(5, 2)] integerValue],
                                [[value substringWithRange:NSMakeRange(8, 2)] integerValue]);
}

static BOOL ParseStrictRFC3339(NSString *value, NSDate **dateOut) {
    if (![value isKindOfClass:NSString.class] || value.length < 20 || value.length > 35)
        return NO;
    static NSRegularExpression *expression;
    static NSISO8601DateFormatter *wholeSecondsFormatter;
    static NSISO8601DateFormatter *fractionalFormatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression
            regularExpressionWithPattern:@"^[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])T"
                                         @"(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\\.[0-9]{1,9})?"
                                         @"(?:Z|[+-](?:(?:0[0-9]|1[0-3]):[0-5][0-9]|14:00))$"
                                 options:0
                                   error:nil];
        wholeSecondsFormatter = [NSISO8601DateFormatter new];
        wholeSecondsFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        fractionalFormatter = [NSISO8601DateFormatter new];
        fractionalFormatter.formatOptions =
            NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    if ([expression firstMatchInString:value options:0 range:NSMakeRange(0, value.length)] == nil)
        return NO;
    NSInteger year = [[value substringWithRange:NSMakeRange(0, 4)] integerValue];
    NSInteger month = [[value substringWithRange:NSMakeRange(5, 2)] integerValue];
    NSInteger day = [[value substringWithRange:NSMakeRange(8, 2)] integerValue];
    if (!IsValidGregorianDate(year, month, day))
        return NO;
    NSISO8601DateFormatter *formatter = [value containsString:@"."] ? fractionalFormatter : wholeSecondsFormatter;
    NSDate *parsed = nil;
    @synchronized(formatter) {
        parsed = [formatter dateFromString:value];
    }
    if (parsed == nil)
        return NO;
    if (dateOut != NULL)
        *dateOut = parsed;
    return YES;
}

static BOOL IsKnownTimeZoneName(NSString *value) {
    if (![value isKindOfClass:NSString.class])
        return NO;
    NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (utf8.length == 0 || utf8.length > 64)
        return NO;
    static NSSet<NSString *> *knownNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        knownNames = [NSSet setWithArray:NSTimeZone.knownTimeZoneNames];
    });
    return [value isEqualToString:@"UTC"] || [knownNames containsObject:value];
}

static BOOL IsValidAPIKeyName(NSString *value, NSString **normalizedOut) {
    if (![value isKindOfClass:NSString.class])
        return NO;
    NSString *normalized = Trim(value);
    NSData *utf8 = [normalized dataUsingEncoding:NSUTF8StringEncoding];
    if (utf8.length == 0 || utf8.length > 80 ||
        [normalized rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return NO;
    if (normalizedOut != NULL)
        *normalizedOut = normalized;
    return YES;
}

static BOOL IsPrivateRegularFile(NSString *path, NSData **dataOut, NSError **error) {
    struct stat metadata;
    if (lstat(path.fileSystemRepresentation, &metadata) != 0 || !S_ISREG(metadata.st_mode) ||
        metadata.st_uid != getuid() || (metadata.st_mode & 077) != 0) {
        if (error != NULL) {
            *error = ServerError(IMPServerErrorInvalidConfiguration,
                                 [NSString stringWithFormat:@"%@ must be a private user-owned regular file", path]);
        }
        return NO;
    }
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
    if (data == nil) {
        return NO;
    }
    if (dataOut != NULL) {
        *dataOut = data;
    }
    return YES;
}

// Paths this project creates itself are fully private: no group or other access
// at all. The Messages database is different. It is Apple-managed state that
// macOS ships world-readable inside a TCC-protected directory, so requiring
// 0600 there would force an operator to weaken their own system just to install
// this service. Group or other *write* stays refused everywhere, because that is
// what would let another account tamper with the data this service reads.
static const mode_t IMPModeMaskPrivate = 077;
static const mode_t IMPModeMaskNotWritable = 022;

static NSString *ModeRequirementDescription(mode_t forbiddenModeBits) {
    if ((forbiddenModeBits & 055) != 0) {
        return @"no group or other access";
    }
    return @"no group or other write access";
}

static BOOL ValidateParentDirectory(NSString *path, mode_t forbiddenModeBits, NSError **error) {
    NSString *parent = path.stringByDeletingLastPathComponent;
    NSString *current = parent.stringByStandardizingPath;
    BOOL finalComponent = YES;
    struct stat metadata;
    while (current.length > 0) {
        if (lstat(current.fileSystemRepresentation, &metadata) != 0 || !S_ISDIR(metadata.st_mode) ||
            (finalComponent && (metadata.st_uid != getuid() || (metadata.st_mode & forbiddenModeBits) != 0))) {
            if (error != NULL) {
                NSString *requirement = ModeRequirementDescription(forbiddenModeBits);
                NSString *message =
                    [NSString stringWithFormat:@"%@ must be a real user-owned directory with %@", current, requirement];
                *error = ServerError(IMPServerErrorInvalidConfiguration, message);
            }
            return NO;
        }
        if ([current isEqualToString:@"/"])
            break;
        NSString *next = current.stringByDeletingLastPathComponent;
        if ([next isEqualToString:current])
            break;
        current = next;
        finalComponent = NO;
    }
    return YES;
}

static BOOL ValidateMessagesDatabase(NSString *path, NSError **error) {
    struct stat metadata;
    if (![path hasPrefix:@"/"] || !ValidateParentDirectory(path, IMPModeMaskNotWritable, error) ||
        lstat(path.fileSystemRepresentation, &metadata) != 0 || !S_ISREG(metadata.st_mode) ||
        metadata.st_uid != getuid() || (metadata.st_mode & IMPModeMaskNotWritable) != 0 ||
        access(path.fileSystemRepresentation, R_OK) != 0) {
        if (error != NULL && *error == nil) {
            NSString *requirement = ModeRequirementDescription(IMPModeMaskNotWritable);
            NSString *message =
                [NSString stringWithFormat:@"%@ must be a readable user-owned file with %@", path, requirement];
            *error = ServerError(IMPServerErrorInvalidConfiguration, message);
        }
        return NO;
    }
    return YES;
}

static BOOL ParsePositiveInteger(NSString *value, NSUInteger maximum, NSUInteger *result) {
    if (value.length == 0 || value.length > 20) {
        return NO;
    }
    NSData *bytes = [value dataUsingEncoding:NSASCIIStringEncoding];
    if (bytes == nil || bytes.length != value.length) {
        return NO;
    }
    const uint8_t *characters = bytes.bytes;
    for (NSUInteger index = 0; index < bytes.length; index++) {
        if (characters[index] < '0' || characters[index] > '9')
            return NO;
    }
    errno = 0;
    char *end = NULL;
    const char *ascii = value.UTF8String;
    unsigned long long parsed = strtoull(ascii, &end, 10);
    if (errno == ERANGE || end == ascii || *end != '\0')
        return NO;
    if (parsed == 0 || parsed > maximum) {
        return NO;
    }
    if (result != NULL) {
        *result = (NSUInteger)parsed;
    }
    return YES;
}

static BOOL IsDirectMessageRecipient(NSString *value) {
    NSUInteger length = UnicodeCodePointLength(value);
    if (length == 0 || length > 256 || [value hasPrefix:@"-"] ||
        [value rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound ||
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        return NO;
    }
    if ([value hasPrefix:@"+"]) {
        NSString *digits = [value substringFromIndex:1];
        NSCharacterSet *nonASCIIDigit = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
        if (digits.length >= 7 && digits.length <= 15 && ![digits hasPrefix:@"0"] &&
            [digits rangeOfCharacterFromSet:nonASCIIDigit].location == NSNotFound) {
            return YES;
        }
    }
    NSRange firstAt = [value rangeOfString:@"@"];
    NSRange lastAt = [value rangeOfString:@"@" options:NSBackwardsSearch];
    return firstAt.location != NSNotFound && firstAt.location == lastAt.location && firstAt.location > 0 &&
           NSMaxRange(firstAt) < value.length;
}

@interface IMPConfiguration : NSObject
@property (nonatomic, copy) NSString *socketPath;
@property (nonatomic, copy) NSString *databasePath;
@property (nonatomic, copy) NSString *messagesDatabasePath;
@property (nonatomic, copy) NSString *allowedTargetsPath;
@property (nonatomic, copy) NSData *allowedTargetsBytes;
@property (nonatomic, copy) NSSet<NSString *> *allowedRecipients;
@property (nonatomic, copy) NSSet<NSString *> *allowedChatIDs;
@property (nonatomic, copy) NSString *imsgPath;
@property (nonatomic, copy) NSString *imsgSHA256;
@property (nonatomic, copy) NSString *publicOrigin;
@property (nonatomic) NSTimeInterval readTimeout;
@property (nonatomic) NSTimeInterval sendTimeout;
@property (nonatomic) NSTimeInterval socketTimeout;
@property (nonatomic) NSUInteger maximumConcurrency;
@property (nonatomic, copy) NSString *fingerprint;
@end

@implementation IMPConfiguration
@end

@interface IMPProcessResult : NSObject
@property (nonatomic, copy) NSData *standardOutput;
@property (nonatomic) int terminationStatus;
@property (nonatomic) BOOL launched;
@end

@implementation IMPProcessResult
@end

static BOOL IsPinnedChatNotFoundResult(IMPProcessResult *result, NSArray<NSString *> *arguments) {
    if (result.terminationStatus == 0) {
        return NO;
    }
    NSString *output = [[NSString alloc] initWithData:result.standardOutput encoding:NSUTF8StringEncoding];
    if (output == nil) {
        return NO;
    }
    if (arguments.count == 3 && [arguments[0] isEqualToString:@"group"] &&
        [arguments[1] isEqualToString:@"--chat-id"]) {
        NSString *expected = [NSString stringWithFormat:@"Chat not found: %@", arguments[2]];
        return [Trim(output) isEqualToString:expected];
    }
    if (arguments.count >= 3 && [arguments[0] isEqualToString:@"stats"] &&
        [arguments[1] isEqualToString:@"--chat-id"]) {
        NSString *expected = [NSString stringWithFormat:@"chat_id %@ does not exist", arguments[2]];
        return [Trim(output) isEqualToString:expected];
    }
    return arguments.count == 4 && [arguments[0] isEqualToString:@"chat-background"] &&
           [arguments[1] isEqualToString:@"status"] && [arguments[2] isEqualToString:@"--chat-id"] &&
           [Trim(output) isEqualToString:@"chat not found"];
}

static BOOL SetCloseOnExec(int descriptor) {
    int flags = fcntl(descriptor, F_GETFD);
    return flags >= 0 && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0;
}

static BOOL SetNonblocking(int descriptor) {
    int flags = fcntl(descriptor, F_GETFL);
    return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0;
}

static void CloseDescriptor(int *descriptor) {
    if (*descriptor >= 0) {
        close(*descriptor);
        *descriptor = -1;
    }
}

static void EnsureChildProcessRegistry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        childProcessLock = [NSObject new];
        childProcessGroups = [NSMutableSet set];
    });
}

static void RegisterChildProcessGroup(pid_t processID) {
    EnsureChildProcessRegistry();
    @synchronized(childProcessLock) {
        [childProcessGroups addObject:@(processID)];
    }
}

static void UnregisterChildProcessGroup(pid_t processID) {
    EnsureChildProcessRegistry();
    @synchronized(childProcessLock) {
        [childProcessGroups removeObject:@(processID)];
    }
}

static void SignalAllChildProcessGroups(int signalNumber) {
    EnsureChildProcessRegistry();
    NSArray<NSNumber *> *snapshot;
    @synchronized(childProcessLock) {
        snapshot = childProcessGroups.allObjects;
    }
    for (NSNumber *processID in snapshot)
        kill((pid_t)-processID.intValue, signalNumber);
}

static BOOL MoveDescriptorAboveStandardIO(int *descriptor) {
    if (*descriptor > STDERR_FILENO)
        return YES;
#ifdef F_DUPFD_CLOEXEC
    int moved = fcntl(*descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
#else
    int moved = fcntl(*descriptor, F_DUPFD, STDERR_FILENO + 1);
#endif
    if (moved < 0)
        return NO;
    close(*descriptor);
    *descriptor = moved;
    return SetCloseOnExec(moved);
}

static NSTimeInterval MonotonicSeconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0)
        return 0;
    return (NSTimeInterval)value.tv_sec + (NSTimeInterval)value.tv_nsec / 1000000000.0;
}

static void ReapChildNonblocking(pid_t processID, int *waitStatus, BOOL *reaped, BOOL *failed) {
    if (*reaped || *failed)
        return;
    while (YES) {
        pid_t result = waitpid(processID, waitStatus, WNOHANG);
        if (result == processID) {
            *reaped = YES;
            return;
        }
        if (result == 0)
            return;
        if (errno == EINTR)
            continue;
        *failed = YES;
        return;
    }
}

static void DrainProcessPipe(int *descriptor, NSMutableData *captured, NSUInteger limit, NSUInteger *observedBytes,
                             BOOL *exceeded, BOOL *failed) {
    uint8_t buffer[32 * 1024];
    while (*descriptor >= 0) {
        ssize_t count = read(*descriptor, buffer, sizeof(buffer));
        if (count > 0) {
            NSUInteger amount = (NSUInteger)count;
            NSUInteger room = *observedBytes < limit ? limit - *observedBytes : 0;
            NSUInteger kept = MIN(room, amount);
            if (captured != nil && kept > 0)
                [captured appendBytes:buffer length:kept];
            *observedBytes = amount > NSUIntegerMax - *observedBytes ? NSUIntegerMax : *observedBytes + amount;
            if (amount > room) {
                *exceeded = YES;
                return;
            }
            continue;
        }
        if (count == 0) {
            CloseDescriptor(descriptor);
            return;
        }
        if (errno == EINTR)
            continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return;
        *failed = YES;
        CloseDescriptor(descriptor);
        return;
    }
}

static BOOL PumpProcess(pid_t processID, int *outputDescriptor, int *diagnosticDescriptor,
                        NSMutableData *standardOutput, NSUInteger *outputBytes, NSUInteger *diagnosticBytes,
                        BOOL *outputExceeded, BOOL *diagnosticExceeded, BOOL *readFailed, int *waitStatus, BOOL *reaped,
                        BOOL *waitFailed, NSTimeInterval deadline, BOOL *deadlineReached) {
    while (YES) {
        DrainProcessPipe(outputDescriptor, standardOutput, MaxCommandOutputBytes, outputBytes, outputExceeded,
                         readFailed);
        DrainProcessPipe(diagnosticDescriptor, nil, MaxCommandDiagnosticBytes, diagnosticBytes, diagnosticExceeded,
                         readFailed);
        ReapChildNonblocking(processID, waitStatus, reaped, waitFailed);
        if (*reaped && *outputDescriptor < 0 && *diagnosticDescriptor < 0)
            return YES;
        if (*outputExceeded || *diagnosticExceeded || *readFailed || *waitFailed)
            return NO;

        NSTimeInterval remaining = deadline - MonotonicSeconds();
        if (remaining <= 0) {
            *deadlineReached = YES;
            return NO;
        }
        struct pollfd descriptors[2];
        nfds_t descriptorCount = 0;
        if (*outputDescriptor >= 0) {
            descriptors[descriptorCount++] =
                (struct pollfd){.fd = *outputDescriptor, .events = POLLIN | POLLHUP | POLLERR, .revents = 0};
        }
        if (*diagnosticDescriptor >= 0) {
            descriptors[descriptorCount++] =
                (struct pollfd){.fd = *diagnosticDescriptor, .events = POLLIN | POLLHUP | POLLERR, .revents = 0};
        }
        int milliseconds = (int)MIN(50.0, ceil(remaining * 1000.0));
        if (milliseconds < 1)
            milliseconds = 1;
        int pollResult = poll(descriptors, descriptorCount, milliseconds);
        if (pollResult < 0 && errno == EINTR)
            continue;
        if (pollResult < 0) {
            *readFailed = YES;
            return NO;
        }
    }
}

static void ReapChildUntil(pid_t processID, int *waitStatus, BOOL *reaped, BOOL *failed, NSTimeInterval deadline) {
    while (!*reaped && !*failed && MonotonicSeconds() < deadline) {
        ReapChildNonblocking(processID, waitStatus, reaped, failed);
        if (!*reaped && !*failed) {
            struct timespec pause = {.tv_sec = 0, .tv_nsec = 10 * 1000 * 1000};
            nanosleep(&pause, NULL);
        }
    }
}

static NSData *NullTerminatedUTF8(NSString *value) {
    NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (utf8 == nil || (utf8.length > 0 && memchr(utf8.bytes, 0, utf8.length) != NULL))
        return nil;
    NSMutableData *terminated = [utf8 mutableCopy];
    uint8_t zero = 0;
    [terminated appendBytes:&zero length:1];
    return terminated;
}

static BOOL ExecutableMetadataMatches(const struct stat *expected, const struct stat *actual) {
    return S_ISREG(expected->st_mode) && S_ISREG(actual->st_mode) && expected->st_dev == actual->st_dev &&
           expected->st_ino == actual->st_ino && expected->st_gen == actual->st_gen &&
           expected->st_mode == actual->st_mode && expected->st_uid == actual->st_uid &&
           expected->st_gid == actual->st_gid && expected->st_nlink == actual->st_nlink &&
           expected->st_size == actual->st_size && expected->st_flags == actual->st_flags &&
           expected->st_mtimespec.tv_sec == actual->st_mtimespec.tv_sec &&
           expected->st_mtimespec.tv_nsec == actual->st_mtimespec.tv_nsec &&
           expected->st_ctimespec.tv_sec == actual->st_ctimespec.tv_sec &&
           expected->st_ctimespec.tv_nsec == actual->st_ctimespec.tv_nsec;
}

static int OpenPinnedExecutable(NSString *path, NSString *expectedDigest, struct stat *metadataOut, NSError **error);

static int ReopenPinnedExecutable(NSString *path, const struct stat *expectedMetadata) {
    errno = 0;
    if (!ValidateParentDirectory(path, IMPModeMaskPrivate, NULL)) {
        if (errno == 0)
            errno = ESTALE;
        return -1;
    }
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor >= 0 && !MoveDescriptorAboveStandardIO(&descriptor)) {
        int savedError = errno;
        close(descriptor);
        descriptor = -1;
        errno = savedError != 0 ? savedError : EMFILE;
    }
    struct stat metadata;
    if (descriptor < 0)
        return -1;
    if (fstat(descriptor, &metadata) != 0) {
        int savedError = errno;
        close(descriptor);
        errno = savedError;
        return -1;
    }
    if (!ExecutableMetadataMatches(expectedMetadata, &metadata)) {
        if (descriptor >= 0)
            close(descriptor);
        errno = ESTALE;
        return -1;
    }
    return descriptor;
}

static IMPProcessResult *RunProcess(NSString *executable, NSString *expectedDigest, NSArray<NSString *> *arguments,
                                    NSString *home, NSTimeInterval timeout, NSError **error) {
    struct stat executableMetadata;
    int executableDescriptor = OpenPinnedExecutable(executable, expectedDigest, &executableMetadata, error);
    if (executableDescriptor < 0)
        return nil;
    int outputPipe[2] = {-1, -1};
    int diagnosticPipe[2] = {-1, -1};
    if (pipe(outputPipe) != 0 || pipe(diagnosticPipe) != 0 || !MoveDescriptorAboveStandardIO(&outputPipe[0]) ||
        !MoveDescriptorAboveStandardIO(&outputPipe[1]) || !MoveDescriptorAboveStandardIO(&diagnosticPipe[0]) ||
        !MoveDescriptorAboveStandardIO(&diagnosticPipe[1]) || !SetCloseOnExec(outputPipe[0]) ||
        !SetCloseOnExec(outputPipe[1]) || !SetCloseOnExec(diagnosticPipe[0]) || !SetCloseOnExec(diagnosticPipe[1])) {
        int descriptors[] = {outputPipe[0], outputPipe[1], diagnosticPipe[0], diagnosticPipe[1]};
        for (NSUInteger index = 0; index < sizeof(descriptors) / sizeof(descriptors[0]); index++) {
            if (descriptors[index] >= 0)
                close(descriptors[index]);
        }
        close(executableDescriptor);
        if (error != NULL)
            *error = ServerError(IMPServerErrorUpstream, @"dependency pipes could not be created");
        return nil;
    }

    NSMutableArray<NSData *> *argumentStorage = [NSMutableArray array];
    NSData *executableData = NullTerminatedUTF8(executable);
    const char *executablePath = executable.fileSystemRepresentation;
    if (executableData == nil || executablePath == NULL) {
        close(outputPipe[0]);
        close(outputPipe[1]);
        close(diagnosticPipe[0]);
        close(diagnosticPipe[1]);
        close(executableDescriptor);
        if (error != NULL)
            *error = ServerError(IMPServerErrorUpstream, @"dependency path is invalid");
        return nil;
    }
    [argumentStorage addObject:executableData];
    for (NSString *argument in arguments) {
        NSData *data = NullTerminatedUTF8(argument);
        if (data == nil) {
            close(outputPipe[0]);
            close(outputPipe[1]);
            close(diagnosticPipe[0]);
            close(diagnosticPipe[1]);
            close(executableDescriptor);
            if (error != NULL)
                *error = ServerError(IMPServerErrorUpstream, @"dependency argument is invalid");
            return nil;
        }
        [argumentStorage addObject:data];
    }
    char **argv = calloc(argumentStorage.count + 1, sizeof(char *));
    if (argv == NULL) {
        close(outputPipe[0]);
        close(outputPipe[1]);
        close(diagnosticPipe[0]);
        close(diagnosticPipe[1]);
        close(executableDescriptor);
        if (error != NULL)
            *error = ServerError(IMPServerErrorUpstream, @"dependency arguments could not be allocated");
        return nil;
    }
    for (NSUInteger index = 0; index < argumentStorage.count; index++) {
        argv[index] = (char *)argumentStorage[index].bytes;
    }

    NSString *temporary = NSProcessInfo.processInfo.environment[@"TMPDIR"];
    NSArray<NSString *> *environmentStrings = @[
        [@"HOME=" stringByAppendingString:home.length > 0 ? home : @"/"],
        [@"TMPDIR=" stringByAppendingString:temporary.length > 0 ? temporary : @"/tmp"], @"PATH=/usr/bin:/bin",
        @"LANG=en_US.UTF-8"
    ];
    NSMutableArray<NSData *> *environmentStorage = [NSMutableArray array];
    for (NSString *entry in environmentStrings) {
        NSData *data = NullTerminatedUTF8(entry);
        if (data == nil) {
            free(argv);
            close(outputPipe[0]);
            close(outputPipe[1]);
            close(diagnosticPipe[0]);
            close(diagnosticPipe[1]);
            close(executableDescriptor);
            if (error != NULL)
                *error = ServerError(IMPServerErrorUpstream, @"dependency environment is invalid");
            return nil;
        }
        [environmentStorage addObject:data];
    }
    char **environment = calloc(environmentStorage.count + 1, sizeof(char *));
    if (environment == NULL) {
        free(argv);
        close(outputPipe[0]);
        close(outputPipe[1]);
        close(diagnosticPipe[0]);
        close(diagnosticPipe[1]);
        close(executableDescriptor);
        if (error != NULL)
            *error = ServerError(IMPServerErrorUpstream, @"dependency environment could not be allocated");
        return nil;
    }
    for (NSUInteger index = 0; index < environmentStorage.count; index++) {
        environment[index] = (char *)environmentStorage[index].bytes;
    }

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    BOOL actionsInitialized = NO;
    BOOL attributesInitialized = NO;
    int spawnResult = posix_spawn_file_actions_init(&actions);
    if (spawnResult == 0)
        actionsInitialized = YES;
    if (spawnResult == 0) {
        spawnResult = posix_spawnattr_init(&attributes);
        if (spawnResult == 0)
            attributesInitialized = YES;
    }
    if (spawnResult == 0)
        spawnResult = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (spawnResult == 0)
        spawnResult = posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO);
    if (spawnResult == 0)
        spawnResult = posix_spawn_file_actions_adddup2(&actions, diagnosticPipe[1], STDERR_FILENO);
    if (spawnResult == 0)
        spawnResult = posix_spawn_file_actions_addclose(&actions, outputPipe[0]);
    if (spawnResult == 0)
        spawnResult = posix_spawn_file_actions_addclose(&actions, diagnosticPipe[0]);
    short spawnFlags = (short)POSIX_SPAWN_SETPGROUP;
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    spawnFlags = (short)(spawnFlags | POSIX_SPAWN_CLOEXEC_DEFAULT);
#endif
    if (spawnResult == 0)
        spawnResult = posix_spawnattr_setflags(&attributes, spawnFlags);
    if (spawnResult == 0)
        spawnResult = posix_spawnattr_setpgroup(&attributes, 0);
    pid_t processID = -1;
    BOOL executableRevalidationFailed = NO;
    int currentExecutableDescriptor = -1;
    // Darwin has no fexecve/execveat primitive. Keep the verified descriptor open and reject
    // pathname replacement immediately before the path-only spawn. Same-UID processes remain
    // inside the documented user-level trust boundary.
    if (spawnResult == 0) {
        currentExecutableDescriptor = ReopenPinnedExecutable(executable, &executableMetadata);
        if (currentExecutableDescriptor < 0) {
            executableRevalidationFailed = YES;
            spawnResult = errno != 0 ? errno : ESTALE;
        }
    }
    if (spawnResult == 0) {
        spawnResult = posix_spawn(&processID, executablePath, &actions, &attributes, argv, environment);
    }
    if (actionsInitialized)
        posix_spawn_file_actions_destroy(&actions);
    if (attributesInitialized)
        posix_spawnattr_destroy(&attributes);
    free(argv);
    free(environment);
    close(outputPipe[1]);
    close(diagnosticPipe[1]);
    if (currentExecutableDescriptor >= 0)
        close(currentExecutableDescriptor);
    close(executableDescriptor);
    if (spawnResult != 0 || processID <= 0) {
        os_log_with_type(ServerOperationalLog(), OS_LOG_TYPE_ERROR,
                         "action=dependency.spawn status=failed code=%{public}d revalidation_failed=%{public}s",
                         spawnResult, executableRevalidationFailed ? "yes" : "no");
        close(outputPipe[0]);
        close(diagnosticPipe[0]);
        if (error != NULL) {
            *error = executableRevalidationFailed
                         ? ServerError(IMPServerErrorInvalidConfiguration,
                                       @"IMESSAGE_PROXY_IMSG_BIN could not be revalidated before launch")
                         : ServerError(IMPServerErrorUpstream, @"dependency could not be started");
        }
        return nil;
    }
    RegisterChildProcessGroup(processID);
    BOOL setupFailed = !SetNonblocking(outputPipe[0]) || !SetNonblocking(diagnosticPipe[0]);
    NSMutableData *stdoutData = [NSMutableData data];
    NSUInteger stdoutBytes = 0;
    NSUInteger stderrBytes = 0;
    BOOL stdoutExceeded = NO;
    BOOL stderrExceeded = NO;
    BOOL readFailed = setupFailed;
    int waitStatus = 0;
    BOOL childReaped = NO;
    BOOL waitFailed = NO;
    BOOL deadlineReached = NO;
    BOOL completed = setupFailed
                         ? NO
                         : PumpProcess(processID, &outputPipe[0], &diagnosticPipe[0], stdoutData, &stdoutBytes,
                                       &stderrBytes, &stdoutExceeded, &stderrExceeded, &readFailed, &waitStatus,
                                       &childReaped, &waitFailed, MonotonicSeconds() + timeout, &deadlineReached);
    BOOL timedOut = !completed && deadlineReached;
    if (!completed) {
        kill(-processID, SIGTERM);
        CloseDescriptor(&outputPipe[0]);
        CloseDescriptor(&diagnosticPipe[0]);
        ReapChildUntil(processID, &waitStatus, &childReaped, &waitFailed, MonotonicSeconds() + 2);
        kill(-processID, SIGKILL);
        ReapChildUntil(processID, &waitStatus, &childReaped, &waitFailed, MonotonicSeconds() + 2);
    }
    CloseDescriptor(&outputPipe[0]);
    CloseDescriptor(&diagnosticPipe[0]);
    if (!childReaped)
        waitFailed = YES;
    UnregisterChildProcessGroup(processID);

    if (timedOut) {
        if (error != NULL) {
            *error = ServerError(IMPServerErrorTimeout, @"dependency timed out");
        }
        return nil;
    }
    if (waitFailed || readFailed || stdoutExceeded || stderrExceeded) {
        if (error != NULL) {
            *error = ServerError(IMPServerErrorUpstream, @"dependency output was invalid");
        }
        return nil;
    }
    IMPProcessResult *result = [IMPProcessResult new];
    result.standardOutput = stdoutData;
    result.terminationStatus =
        WIFEXITED(waitStatus) ? WEXITSTATUS(waitStatus) : (WIFSIGNALED(waitStatus) ? 128 + WTERMSIG(waitStatus) : 1);
    result.launched = YES;
    return result;
}

static NSString *DependencyVersion(IMPConfiguration *configuration, NSError **error) {
    IMPProcessResult *result =
        RunProcess(configuration.imsgPath, configuration.imsgSHA256, @[@"--version"], NSHomeDirectory(), 5, error);
    if (result == nil || result.terminationStatus != 0) {
        if (error != NULL && *error == nil) {
            *error = ServerError(IMPServerErrorUpstream, @"dependency version check failed");
        }
        return nil;
    }
    NSString *text = [[NSString alloc] initWithData:result.standardOutput encoding:NSUTF8StringEncoding];
    NSString *version = Trim(text ?: @"");
    if (![version isEqualToString:RequiredIMSGVersion]) {
        if (error != NULL) {
            *error = ServerError(IMPServerErrorInvalidConfiguration,
                                 [NSString stringWithFormat:@"imsg %@ is required", RequiredIMSGVersion]);
        }
        return nil;
    }
    return version;
}

static int OpenPinnedExecutable(NSString *path, NSString *expectedDigest, struct stat *metadataOut, NSError **error) {
    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    if (expectedDigest.length != CC_SHA256_DIGEST_LENGTH * 2 ||
        [expectedDigest rangeOfCharacterFromSet:nonHex].location != NSNotFound) {
        if (error != NULL) {
            *error = ServerError(IMPServerErrorInvalidConfiguration,
                                 @"IMESSAGE_PROXY_IMSG_SHA256 must be 64 lowercase hexadecimal characters");
        }
        return -1;
    }
    if (![path hasPrefix:@"/"]) {
        if (error != NULL)
            *error = ServerError(IMPServerErrorInvalidConfiguration, @"IMESSAGE_PROXY_IMSG_BIN must be absolute");
        return -1;
    }
    if (!ValidateParentDirectory(path, IMPModeMaskPrivate, error))
        return -1;
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor >= 0 && !MoveDescriptorAboveStandardIO(&descriptor)) {
        close(descriptor);
        descriptor = -1;
    }
    struct stat metadata;
    if (descriptor < 0 || fstat(descriptor, &metadata) != 0 || !S_ISREG(metadata.st_mode) ||
        metadata.st_uid != getuid() || metadata.st_nlink != 1 || (metadata.st_mode & 0222) != 0 ||
        (metadata.st_mode & S_IXUSR) == 0 || metadata.st_size <= 0 || metadata.st_size > 256 * 1024 * 1024) {
        if (descriptor >= 0)
            close(descriptor);
        if (error != NULL) {
            *error =
                ServerError(IMPServerErrorInvalidConfiguration,
                            @"IMESSAGE_PROXY_IMSG_BIN must be a bounded, user-owned, non-writable regular executable");
        }
        return -1;
    }
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    BOOL readOK = YES;
    uint8_t buffer[64 * 1024];
    while (YES) {
        ssize_t count = read(descriptor, buffer, sizeof(buffer));
        if (count == 0)
            break;
        if (count < 0 && errno == EINTR)
            continue;
        if (count < 0) {
            readOK = NO;
            break;
        }
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *actualDigest = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [actualDigest appendFormat:@"%02x", digest[index]];
    }
    struct stat verifiedMetadata;
    BOOL metadataMatches =
        fstat(descriptor, &verifiedMetadata) == 0 && ExecutableMetadataMatches(&metadata, &verifiedMetadata);
    if (!readOK || !metadataMatches || ![actualDigest isEqualToString:expectedDigest]) {
        close(descriptor);
        if (error != NULL) {
            *error = ServerError(
                IMPServerErrorInvalidConfiguration,
                @"IMESSAGE_PROXY_IMSG_BIN does not match IMESSAGE_PROXY_IMSG_SHA256 or changed during verification");
        }
        return -1;
    }
    if (lseek(descriptor, 0, SEEK_SET) < 0) {
        close(descriptor);
        if (error != NULL) {
            *error = ServerError(IMPServerErrorInvalidConfiguration,
                                 @"IMESSAGE_PROXY_IMSG_BIN could not be prepared for execution");
        }
        return -1;
    }
    if (metadataOut != NULL)
        *metadataOut = verifiedMetadata;
    return descriptor;
}

static BOOL ValidatePinnedExecutable(NSString *path, NSString *expectedDigest, NSError **error) {
    int descriptor = OpenPinnedExecutable(path, expectedDigest, NULL, error);
    if (descriptor < 0)
        return NO;
    close(descriptor);
    return YES;
}

static IMPConfiguration *LoadConfiguration(NSError **error) {
    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    NSSet<NSString *> *recognized = [NSSet setWithArray:@[
        @"IMESSAGE_PROXY_SOCKET_PATH",
        @"IMESSAGE_PROXY_DATABASE_PATH",
        @"IMESSAGE_PROXY_MESSAGES_DATABASE_PATH",
        @"IMESSAGE_PROXY_ALLOWED_TARGETS_FILE",
        @"IMESSAGE_PROXY_IMSG_BIN",
        @"IMESSAGE_PROXY_PUBLIC_ORIGIN",
        @"IMESSAGE_PROXY_EXPECTED_IMSG_VERSION",
        @"IMESSAGE_PROXY_IMSG_SHA256",
        @"IMESSAGE_PROXY_MAX_CONCURRENCY",
        @"IMESSAGE_PROXY_READ_TIMEOUT_SECONDS",
        @"IMESSAGE_PROXY_SEND_TIMEOUT_SECONDS",
        @"IMESSAGE_PROXY_SOCKET_TIMEOUT_SECONDS",
        @"IMESSAGE_PROXY_ACME_EMAIL",
        @"IMESSAGE_PROXY_API_HOST",
        @"IMESSAGE_PROXY_API_KEY",
        @"IMESSAGE_PROXY_CADDY_BIN",
        @"IMESSAGE_PROXY_CADDY_SHA256",
        @"IMESSAGE_PROXY_ENABLE_PUBLIC_HTTPS",
        @"IMESSAGE_PROXY_HOME",
        @"IMESSAGE_PROXY_HTTPS_PORT",
        @"IMESSAGE_PROXY_HTTP_PORT",
        @"IMESSAGE_PROXY_PUBLIC_BIND",
        @"IMESSAGE_PROXY_SOURCE_DIR",
        @"IMESSAGE_PROXY_UI_DIR",
        @"IMESSAGE_PROXY_URL",
        @"IMESSAGE_PROXY_VERSION"
    ]];
    for (NSString *name in environment) {
        if ([name hasPrefix:@"IMESSAGE_PROXY_"] && ![recognized containsObject:name]) {
            if (error != NULL) {
                *error = ServerError(IMPServerErrorInvalidConfiguration,
                                     [NSString stringWithFormat:@"unrecognized iMessage Proxy setting: %@", name]);
            }
            return nil;
        }
    }

    IMPConfiguration *configuration = [IMPConfiguration new];
    configuration.socketPath = environment[@"IMESSAGE_PROXY_SOCKET_PATH"] ?: @"";
    configuration.databasePath = environment[@"IMESSAGE_PROXY_DATABASE_PATH"] ?: @"";
    configuration.allowedTargetsPath = environment[@"IMESSAGE_PROXY_ALLOWED_TARGETS_FILE"] ?: @"";
    configuration.imsgPath = environment[@"IMESSAGE_PROXY_IMSG_BIN"] ?: @"/opt/homebrew/bin/imsg";
    configuration.imsgSHA256 = environment[@"IMESSAGE_PROXY_IMSG_SHA256"] ?: @"";
    configuration.messagesDatabasePath =
        environment[@"IMESSAGE_PROXY_MESSAGES_DATABASE_PATH"]
            ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Messages/chat.db"];
    configuration.publicOrigin = environment[@"IMESSAGE_PROXY_PUBLIC_ORIGIN"] ?: @"";

    NSString *expectedVersion = environment[@"IMESSAGE_PROXY_EXPECTED_IMSG_VERSION"] ?: RequiredIMSGVersion;
    if (![expectedVersion isEqualToString:RequiredIMSGVersion]) {
        if (error != NULL) {
            *error = ServerError(
                IMPServerErrorInvalidConfiguration,
                [NSString stringWithFormat:@"IMESSAGE_PROXY_EXPECTED_IMSG_VERSION must be %@", RequiredIMSGVersion]);
        }
        return nil;
    }

    if (![configuration.socketPath hasPrefix:@"/"] || configuration.socketPath.length == 0 ||
        [configuration.socketPath fileSystemRepresentation] == NULL ||
        strlen(configuration.socketPath.fileSystemRepresentation) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        if (error != NULL) {
            *error = ServerError(IMPServerErrorInvalidConfiguration, @"IMESSAGE_PROXY_SOCKET_PATH is invalid");
        }
        return nil;
    }
    if (![configuration.databasePath hasPrefix:@"/"] || configuration.databasePath.length == 0 ||
        !ValidateParentDirectory(configuration.socketPath, IMPModeMaskPrivate, error) ||
        !ValidateParentDirectory(configuration.databasePath, IMPModeMaskPrivate, error)) {
        if (error != NULL && *error == nil) {
            *error = ServerError(IMPServerErrorInvalidConfiguration, @"IMESSAGE_PROXY_DATABASE_PATH is invalid");
        }
        return nil;
    }
    if (configuration.allowedTargetsPath.length == 0 || configuration.messagesDatabasePath.length == 0) {
        if (error != NULL) {
            *error = ServerError(IMPServerErrorInvalidConfiguration, @"required file configuration is missing");
        }
        return nil;
    }
    if (!ValidateMessagesDatabase(configuration.messagesDatabasePath, error)) {
        return nil;
    }
    if (!ValidatePinnedExecutable(configuration.imsgPath, configuration.imsgSHA256, error))
        return nil;

    NSData *targetsData = nil;
    if (!ValidateParentDirectory(configuration.allowedTargetsPath, IMPModeMaskPrivate, error) ||
        !IsPrivateRegularFile(configuration.allowedTargetsPath, &targetsData, error)) {
        return nil;
    }
    NSString *targetsText = [[NSString alloc] initWithData:targetsData encoding:NSUTF8StringEncoding];
    if (targetsText == nil || targetsData.length > 64 * 1024) {
        if (error != NULL) {
            *error = ServerError(IMPServerErrorInvalidConfiguration, @"target allowlist is invalid");
        }
        return nil;
    }
    NSMutableSet<NSString *> *recipients = [NSMutableSet set];
    NSMutableSet<NSString *> *chatIDs = [NSMutableSet set];
    for (NSString *rawLine in [targetsText componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = Trim(rawLine);
        if (line.length == 0 || [line hasPrefix:@"#"]) {
            continue;
        }
        BOOL valid = NO;
        if ([line hasPrefix:@"chat_id:"]) {
            NSString *chatID = [line substringFromIndex:@"chat_id:".length];
            NSUInteger parsedChatID = 0;
            valid = ParsePositiveInteger(chatID, NSIntegerMax, &parsedChatID) &&
                    [line isEqualToString:[NSString stringWithFormat:@"chat_id:%lu", (unsigned long)parsedChatID]];
            if (valid)
                [chatIDs addObject:chatID];
        } else if (IsDirectMessageRecipient(line)) {
            valid = YES;
            [recipients addObject:line];
        }
        if (!valid) {
            if (error != NULL) {
                *error = ServerError(IMPServerErrorInvalidConfiguration, @"target allowlist contains an invalid entry");
            }
            return nil;
        }
    }
    configuration.allowedTargetsBytes = targetsData;
    configuration.allowedRecipients = [recipients copy];
    configuration.allowedChatIDs = [chatIDs copy];

    NSString *readTimeoutText = environment[@"IMESSAGE_PROXY_READ_TIMEOUT_SECONDS"] ?: @"30";
    NSUInteger readTimeout = 0;
    if (!ParsePositiveInteger(readTimeoutText, 300, &readTimeout)) {
        if (error != NULL) {
            *error = ServerError(IMPServerErrorInvalidConfiguration, @"read timeout is invalid");
        }
        return nil;
    }
    configuration.readTimeout = readTimeout;
    NSString *sendTimeoutText = environment[@"IMESSAGE_PROXY_SEND_TIMEOUT_SECONDS"] ?: @"180";
    NSUInteger sendTimeout = 0;
    if (!ParsePositiveInteger(sendTimeoutText, 180, &sendTimeout)) {
        if (error != NULL) {
            *error = ServerError(IMPServerErrorInvalidConfiguration, @"send timeout is invalid");
        }
        return nil;
    }
    configuration.sendTimeout = sendTimeout;
    NSString *socketTimeoutText = environment[@"IMESSAGE_PROXY_SOCKET_TIMEOUT_SECONDS"] ?: @"10";
    NSUInteger socketTimeout = 0;
    if (!ParsePositiveInteger(socketTimeoutText, 60, &socketTimeout)) {
        if (error != NULL) {
            *error = ServerError(IMPServerErrorInvalidConfiguration, @"socket timeout is invalid");
        }
        return nil;
    }
    configuration.socketTimeout = socketTimeout;
    NSString *maximumConcurrencyText = environment[@"IMESSAGE_PROXY_MAX_CONCURRENCY"] ?: @"8";
    NSUInteger maximumConcurrency = 0;
    if (!ParsePositiveInteger(maximumConcurrencyText, 64, &maximumConcurrency)) {
        if (error != NULL) {
            *error = ServerError(IMPServerErrorInvalidConfiguration, @"maximum concurrency is invalid");
        }
        return nil;
    }
    configuration.maximumConcurrency = maximumConcurrency;

    if (configuration.publicOrigin.length > 0) {
        NSURLComponents *origin = [NSURLComponents componentsWithString:configuration.publicOrigin];
        if (![origin.scheme isEqualToString:@"https"] || origin.host.length == 0 || origin.user != nil ||
            origin.password != nil || origin.query != nil || origin.fragment != nil || origin.path.length > 0) {
            if (error != NULL) {
                *error = ServerError(IMPServerErrorInvalidConfiguration, @"IMESSAGE_PROXY_PUBLIC_ORIGIN is invalid");
            }
            return nil;
        }
    }
    if (DependencyVersion(configuration, error) == nil) {
        return nil;
    }
    IMPAPIKeyStore *store = [[IMPAPIKeyStore alloc] initWithPath:configuration.databasePath error:error];
    if (store == nil) {
        return nil;
    }
    (void)store;

    NSDictionary *fingerprintObject = @{
        @"socket_path": configuration.socketPath,
        @"database_path": configuration.databasePath,
        @"messages_database_path": configuration.messagesDatabasePath,
        @"allowed_targets_path": configuration.allowedTargetsPath,
        @"allowed_targets_bytes": [configuration.allowedTargetsBytes base64EncodedStringWithOptions:0],
        @"imsg_path": configuration.imsgPath,
        @"imsg_sha256": configuration.imsgSHA256,
        @"imsg_version": RequiredIMSGVersion,
        @"public_origin": configuration.publicOrigin,
        @"read_timeout": @(configuration.readTimeout),
        @"send_timeout": @(configuration.sendTimeout),
        @"socket_timeout": @(configuration.socketTimeout),
        @"maximum_concurrency": @(configuration.maximumConcurrency),
        @"server_version": ServerVersion,
    };
    configuration.fingerprint = [@"sha256:" stringByAppendingString:HexDigest(JSONData(fingerprintObject, nil))];
    return configuration;
}

@interface IMPHTTPRequest : NSObject
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, copy) NSData *body;
@end

@implementation IMPHTTPRequest
@end

@interface IMPHTTPResponse : NSObject
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSData *body;
@property (nonatomic, copy) NSString *contentType;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, copy, nullable) NSString *auditTargetKeyUUID;
@end

@implementation IMPHTTPResponse
@end

static NSString *ReasonPhrase(NSInteger status) {
    switch (status) {
    case 200:
        return @"OK";
    case 201:
        return @"Created";
    case 202:
        return @"Accepted";
    case 204:
        return @"No Content";
    case 400:
        return @"Bad Request";
    case 401:
        return @"Unauthorized";
    case 403:
        return @"Forbidden";
    case 404:
        return @"Not Found";
    case 409:
        return @"Conflict";
    case 413:
        return @"Payload Too Large";
    case 415:
        return @"Unsupported Media Type";
    case 429:
        return @"Too Many Requests";
    case 431:
        return @"Request Header Fields Too Large";
    case 500:
        return @"Internal Server Error";
    case 502:
        return @"Bad Gateway";
    case 503:
        return @"Service Unavailable";
    case 504:
        return @"Gateway Timeout";
    default:
        return @"Error";
    }
}

static IMPHTTPResponse *JSONResponse(NSInteger status, id object) {
    IMPHTTPResponse *response = [IMPHTTPResponse new];
    response.status = status;
    response.body = status == 204 ? [NSData data] : (JSONData(object, nil) ?: [NSData data]);
    response.contentType = @"application/json";
    response.headers = @{};
    return response;
}

static NSString *NewRequestUUID(void) { return NSUUID.UUID.UUIDString.lowercaseString; }

static IMPHTTPResponse *ProblemWithRequestID(NSInteger status, NSString *code, NSString *detail, NSString *requestID) {
    IMPHTTPResponse *response = JSONResponse(
        status, @{
            @"type": [@"https://github.com/mglaeser/imessage-proxy/problems/" stringByAppendingString:code],
            @"title": ReasonPhrase(status),
            @"status": @(status),
            @"detail": detail,
            @"request_id": requestID,
        });
    response.contentType = @"application/problem+json";
    return response;
}

static IMPHTTPResponse *Problem(NSInteger status, NSString *code, NSString *detail) {
    NSString *requestID = NSThread.currentThread.threadDictionary[RequestContextThreadKey];
    return ProblemWithRequestID(status, code, detail, requestID ?: NewRequestUUID());
}

static IMPHTTPResponse *UnauthorizedResponse(NSString *requestID) {
    IMPHTTPResponse *response = ProblemWithRequestID(401, @"unauthorized", @"Authentication is required.", requestID);
    response.headers = @{@"WWW-Authenticate": @"Bearer"};
    return response;
}

static IMPHTTPResponse *RateLimitedResponse(NSString *requestID, NSString *code, NSString *detail) {
    IMPHTTPResponse *response = ProblemWithRequestID(429, code, detail, requestID);
    response.headers = @{@"Retry-After": @"60"};
    return response;
}

static void SetResponseHeader(IMPHTTPResponse *response, NSString *name, NSString *value) {
    NSMutableDictionary *headers = [response.headers mutableCopy] ?: [NSMutableDictionary dictionary];
    headers[name] = value;
    response.headers = headers;
}

static BOOL ConfigureClient(int fileDescriptor, NSTimeInterval seconds) {
    struct timeval timeout = {.tv_sec = (time_t)seconds, .tv_usec = 0};
    int flags = fcntl(fileDescriptor, F_GETFD);
    return flags >= 0 && fcntl(fileDescriptor, F_SETFD, flags | FD_CLOEXEC) == 0 &&
           setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0 &&
           setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) == 0;
}

static IMPHTTPRequest *ReadRequest(int fileDescriptor, NSTimeInterval absoluteTimeout, NSInteger *errorStatus,
                                   NSError **error) {
    if (errorStatus != NULL)
        *errorStatus = 400;
    NSTimeInterval deadline = MonotonicSeconds() + absoluteTimeout;
    NSMutableData *received = [NSMutableData data];
    NSData *marker = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange headerEnd = NSMakeRange(NSNotFound, 0);
    while (headerEnd.location == NSNotFound) {
        if (MonotonicSeconds() >= deadline) {
            if (error != NULL)
                *error = ServerError(IMPServerErrorRequest, @"request deadline exceeded");
            return nil;
        }
        if (received.length >= MaxHeaderBytes) {
            if (errorStatus != NULL)
                *errorStatus = 431;
            if (error != NULL)
                *error = ServerError(IMPServerErrorRequest, @"headers too large");
            return nil;
        }
        uint8_t buffer[4096];
        ssize_t count = recv(fileDescriptor, buffer, sizeof(buffer), 0);
        if (count <= 0) {
            if (error != NULL)
                *error = ServerError(IMPServerErrorRequest, @"incomplete request");
            return nil;
        }
        [received appendBytes:buffer length:(NSUInteger)count];
        headerEnd = [received rangeOfData:marker options:0 range:NSMakeRange(0, received.length)];
    }
    if (headerEnd.location > MaxHeaderBytes) {
        if (errorStatus != NULL)
            *errorStatus = 431;
        if (error != NULL)
            *error = ServerError(IMPServerErrorRequest, @"headers too large");
        return nil;
    }
    NSString *headerText = [[NSString alloc] initWithData:[received subdataWithRange:NSMakeRange(0, headerEnd.location)]
                                                 encoding:NSUTF8StringEncoding];
    if (headerText == nil) {
        if (error != NULL)
            *error = ServerError(IMPServerErrorRequest, @"invalid headers");
        return nil;
    }
    NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *rawParts = [lines.firstObject componentsSeparatedByString:@" "];
    if (rawParts.count != 3 || [rawParts containsObject:@""] ||
        ![@[@"HTTP/1.0", @"HTTP/1.1"] containsObject:rawParts[2]]) {
        if (error != NULL)
            *error = ServerError(IMPServerErrorRequest, @"invalid request line");
        return nil;
    }
    NSArray<NSString *> *parts = rawParts;
    NSCharacterSet *invalidMethod = [[NSCharacterSet
        characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"] invertedSet];
    if (parts[0].length == 0 || parts[0].length > 32 ||
        [parts[0] rangeOfCharacterFromSet:invalidMethod].location != NSNotFound) {
        if (error != NULL)
            *error = ServerError(IMPServerErrorRequest, @"invalid HTTP method");
        return nil;
    }
    NSString *target = parts[1];
    if (target.length == 0 || target.length > 2048 || ![target hasPrefix:@"/"] ||
        [target rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        if (error != NULL)
            *error = ServerError(IMPServerErrorRequest, @"invalid request target");
        return nil;
    }
    NSRange question = [target rangeOfString:@"?"];
    NSString *path = question.location == NSNotFound ? target : [target substringToIndex:question.location];
    NSString *query = question.location == NSNotFound ? @"" : [target substringFromIndex:NSMaxRange(question)];
    if ([path containsString:@"//"] || [path containsString:@"%"] || [path containsString:@"\\"] ||
        [path componentsSeparatedByString:@"/"].count > 8) {
        if (error != NULL)
            *error = ServerError(IMPServerErrorRequest, @"invalid request path");
        return nil;
    }

    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    for (NSUInteger index = 1; index < lines.count; index++) {
        NSString *line = lines[index];
        NSRange separator = [line rangeOfString:@":"];
        if (separator.location == NSNotFound || separator.location == 0) {
            if (error != NULL)
                *error = ServerError(IMPServerErrorRequest, @"invalid header");
            return nil;
        }
        NSString *rawName = [line substringToIndex:separator.location];
        NSString *name = rawName.lowercaseString;
        NSString *value = Trim([line substringFromIndex:NSMaxRange(separator)]);
        NSMutableCharacterSet *invalidValueCharacters = [NSCharacterSet.controlCharacterSet mutableCopy];
        [invalidValueCharacters removeCharactersInString:@"\t"];
        if (![rawName isEqualToString:Trim(rawName)] || name.length == 0 || headers[name] != nil ||
            [name
                rangeOfCharacterFromSet:[[NSCharacterSet
                                            characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-"]
                                            invertedSet]]
                    .location != NSNotFound ||
            [value rangeOfCharacterFromSet:invalidValueCharacters].location != NSNotFound) {
            if (error != NULL)
                *error = ServerError(IMPServerErrorRequest, @"invalid or duplicate header");
            return nil;
        }
        headers[name] = value;
    }
    if (headers[@"transfer-encoding"] != nil) {
        if (error != NULL)
            *error = ServerError(IMPServerErrorRequest, @"transfer encoding is unsupported");
        return nil;
    }
    if ([parts[2] isEqualToString:@"HTTP/1.1"] && [headers[@"host"] length] == 0) {
        if (error != NULL)
            *error = ServerError(IMPServerErrorRequest, @"Host is required");
        return nil;
    }
    NSString *lengthText = headers[@"content-length"] ?: @"0";
    NSUInteger contentLength = 0;
    if ([lengthText isEqualToString:@"0"]) {
        contentLength = 0;
    } else if (!ParsePositiveInteger(lengthText, MaxRequestBytes, &contentLength)) {
        NSCharacterSet *nonDigits = [NSCharacterSet.decimalDigitCharacterSet invertedSet];
        if (lengthText.length > 0 && [lengthText rangeOfCharacterFromSet:nonDigits].location == NSNotFound &&
            strtoull(lengthText.UTF8String, NULL, 10) > MaxRequestBytes && errorStatus != NULL) {
            *errorStatus = 413;
        }
        if (error != NULL)
            *error = ServerError(IMPServerErrorRequest, @"invalid content length");
        return nil;
    }
    NSUInteger bodyStart = NSMaxRange(headerEnd);
    NSUInteger required = bodyStart + contentLength;
    while (received.length < required) {
        if (MonotonicSeconds() >= deadline) {
            if (error != NULL)
                *error = ServerError(IMPServerErrorRequest, @"request deadline exceeded");
            return nil;
        }
        uint8_t buffer[4096];
        NSUInteger remaining = required - received.length;
        ssize_t count = recv(fileDescriptor, buffer, MIN(sizeof(buffer), remaining), 0);
        if (count <= 0) {
            if (error != NULL)
                *error = ServerError(IMPServerErrorRequest, @"incomplete request body");
            return nil;
        }
        [received appendBytes:buffer length:(NSUInteger)count];
    }
    if (received.length != required) {
        if (error != NULL)
            *error = ServerError(IMPServerErrorRequest, @"request pipelining is unsupported");
        return nil;
    }
    IMPHTTPRequest *request = [IMPHTTPRequest new];
    request.method = parts[0];
    request.path = path;
    request.query = query;
    request.headers = headers;
    request.body = [received subdataWithRange:NSMakeRange(bodyStart, contentLength)];
    return request;
}

static NSDictionary<NSString *, id> *ParseQueryAllowingRepeatedNames(NSString *query, NSSet<NSString *> *repeatedNames,
                                                                     NSError **error) {
    if (query.length == 0) {
        return @{};
    }
    NSURLComponents *components =
        [NSURLComponents componentsWithString:[@"https://local.invalid/?" stringByAppendingString:query]];
    if (components == nil) {
        if (error != NULL)
            *error = ServerError(IMPServerErrorRequest, @"invalid query");
        return nil;
    }
    NSMutableDictionary<NSString *, id> *values = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        if (item.name.length == 0 || item.value == nil || UnicodeCodePointLength(item.name) > 64 ||
            UnicodeCodePointLength(item.value) > 512) {
            if (error != NULL)
                *error = ServerError(IMPServerErrorRequest, @"invalid or duplicate query parameter");
            return nil;
        }
        if ([repeatedNames containsObject:item.name]) {
            NSMutableArray<NSString *> *items = values[item.name];
            if (items == nil) {
                items = [NSMutableArray array];
                values[item.name] = items;
            }
            [items addObject:item.value];
        } else {
            if (values[item.name] != nil) {
                if (error != NULL) {
                    *error = ServerError(IMPServerErrorRequest, @"invalid or duplicate query parameter");
                }
                return nil;
            }
            values[item.name] = item.value;
        }
    }
    return values;
}

static NSDictionary<NSString *, id> *ParseQuery(NSString *query, NSError **error) {
    return ParseQueryAllowingRepeatedNames(query, [NSSet set], error);
}

static BOOL IsJSONContentType(NSString *value) {
    NSString *media = Trim([[value componentsSeparatedByString:@";"] firstObject]).lowercaseString;
    return [media isEqualToString:@"application/json"];
}

static id ScrubValue(id value) {
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *result = [NSMutableArray array];
        for (id item in value)
            [result addObject:ScrubValue(item) ?: NSNull.null];
        return result;
    }
    if (![value isKindOfClass:NSDictionary.class]) {
        return value;
    }
    NSSet<NSString *> *forbidden = [NSSet setWithArray:@[
        @"account_id", @"account_login", @"last_addressed_handle", @"destination_caller_id", @"original_path",
        @"converted_path", @"cache_path", @"watch_background_path", @"file_path", @"upstream_private"
    ]];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id object, __unused BOOL *stop) {
        if (![key isKindOfClass:NSString.class] || [forbidden containsObject:key] || [key hasSuffix:@"_path"]) {
            return;
        }
        result[key] = ScrubValue(object) ?: NSNull.null;
    }];
    return result;
}

static NSArray<NSDictionary *> *ParseJSONLines(NSData *data, NSUInteger maximumItems, NSError **error) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text == nil) {
        if (error != NULL)
            *error = ServerError(IMPServerErrorUpstream, @"dependency returned invalid UTF-8");
        return nil;
    }
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (line.length == 0)
            continue;
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        id object = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
        if (![object isKindOfClass:NSDictionary.class] || items.count >= maximumItems) {
            if (error != NULL)
                *error = ServerError(IMPServerErrorUpstream, @"dependency returned an invalid response");
            return nil;
        }
        [items addObject:ScrubValue(object)];
    }
    return items;
}

static IMPProcessResult *RunConfiguredIMSGArguments(IMPConfiguration *configuration, NSArray<NSString *> *arguments,
                                                    NSTimeInterval timeout, NSError **error) {
    NSMutableArray<NSString *> *complete = [arguments mutableCopy];
    [complete addObjectsFromArray:@[@"--db", configuration.messagesDatabasePath, @"--json"]];
    return RunProcess(configuration.imsgPath, configuration.imsgSHA256, complete, NSHomeDirectory(), timeout, error);
}

static NSArray<NSDictionary *> *RunConfiguredJSONLines(IMPConfiguration *configuration, NSArray<NSString *> *arguments,
                                                       NSUInteger maximumItems, NSTimeInterval timeout,
                                                       NSError **error) {
    IMPProcessResult *result = RunConfiguredIMSGArguments(configuration, arguments, timeout, error);
    if (result == nil) {
        return nil;
    }
    if (result.terminationStatus != 0) {
        if (error != NULL) {
            *error = IsPinnedChatNotFoundResult(result, arguments)
                         ? ServerError(IMPServerErrorNotFound, @"chat not found")
                         : ServerError(IMPServerErrorUpstream, @"dependency command failed");
        }
        return nil;
    }
    return ParseJSONLines(result.standardOutput, maximumItems, error);
}

static BOOL IsIntegerNumber(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    NSDecimal decimal = [value decimalValue];
    if (NSDecimalIsNotANumber(&decimal))
        return NO;
    NSDecimal minimum = [@(LLONG_MIN) decimalValue];
    NSDecimal maximum = [@(LLONG_MAX) decimalValue];
    if (NSDecimalCompare(&decimal, &minimum) == NSOrderedAscending ||
        NSDecimalCompare(&decimal, &maximum) == NSOrderedDescending)
        return NO;
    NSDecimal rounded;
    NSDecimalRound(&rounded, &decimal, 0, NSRoundPlain);
    return NSDecimalCompare(&decimal, &rounded) == NSOrderedSame;
}

static BOOL IsBooleanNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL IsStringArray(id value) {
    if (![value isKindOfClass:NSArray.class])
        return NO;
    for (id item in value) {
        if (![item isKindOfClass:NSString.class])
            return NO;
    }
    return YES;
}

static NSMutableDictionary *ProjectKeys(NSDictionary *source, NSArray<NSString *> *keys) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in keys) {
        id value = source[key];
        if (value != nil)
            result[key] = ScrubValue(value) ?: NSNull.null;
    }
    return result;
}

static BOOL IsNullableString(id value) {
    return value == nil || value == NSNull.null || [value isKindOfClass:NSString.class];
}

static BOOL IsNullableRFC3339(id value) {
    return value == nil || value == NSNull.null || ParseStrictRFC3339(value, NULL);
}

static BOOL IsNullableBoolean(id value) { return value == nil || value == NSNull.null || IsBooleanNumber(value); }

static BOOL IsNullableInteger(id value) { return value == nil || value == NSNull.null || IsIntegerNumber(value); }

static BOOL IsNullableNonnegativeInteger(id value) {
    return value == nil || value == NSNull.null || (IsIntegerNumber(value) && [value longLongValue] >= 0);
}

static BOOL IsSafeFilenameComponent(NSString *value) {
    return value.length > 0 && ![value isEqualToString:@"."] && ![value isEqualToString:@".."] &&
           [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound &&
           [value rangeOfString:@"/"].location == NSNotFound && [value rangeOfString:@"\\"].location == NSNotFound;
}

static NSDictionary *ChatDTO(NSDictionary *source) {
    if (!IsIntegerNumber(source[@"id"]) || [source[@"id"] longLongValue] <= 0 ||
        ![source[@"name"] isKindOfClass:NSString.class] || ![source[@"identifier"] isKindOfClass:NSString.class] ||
        ![source[@"service"] isKindOfClass:NSString.class] || !IsBooleanNumber(source[@"is_group"]) ||
        !IsStringArray(source[@"participants"]) || !IsNullableString(source[@"display_name"]) ||
        !IsNullableString(source[@"contact_name"]) || !IsNullableString(source[@"guid"]) ||
        !IsNullableRFC3339(source[@"last_message_at"]) || !IsNullableNonnegativeInteger(source[@"unread_count"])) {
        return nil;
    }
    return ProjectKeys(source, @[
        @"id", @"name", @"display_name", @"contact_name", @"identifier", @"guid", @"service", @"is_group",
        @"participants", @"last_message_at", @"unread_count"
    ]);
}

static NSDictionary *AttachmentDTO(NSDictionary *source) {
    if (!IsNullableString(source[@"filename"]) || !IsNullableString(source[@"mime_type"]) ||
        !IsNullableString(source[@"uti"]) || !IsNullableBoolean(source[@"is_sticker"]))
        return nil;
    NSMutableDictionary *result = ProjectKeys(source, @[@"mime_type", @"uti", @"is_sticker"]);
    NSString *safeFilename = nil;
    id transferName = source[@"transfer_name"];
    if ([transferName isKindOfClass:NSString.class] && IsSafeFilenameComponent(transferName)) {
        safeFilename = transferName;
    }
    id rawFilename = source[@"filename"];
    if (safeFilename == nil && [rawFilename isKindOfClass:NSString.class]) {
        if ([rawFilename length] == 0) {
            result[@"filename"] = NSNull.null;
        } else {
            if ([rawFilename rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
                return nil;
            }
            NSString *normalizedPath = [rawFilename stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
            NSString *component = normalizedPath.lastPathComponent;
            if (!IsSafeFilenameComponent(component))
                return nil;
            safeFilename = component;
        }
    }
    if (safeFilename != nil) {
        result[@"filename"] = safeFilename;
    } else {
        result[@"filename"] = NSNull.null;
    }
    id byteSize = source[@"byte_size"] != nil ? source[@"byte_size"] : source[@"total_bytes"];
    if (!IsNullableNonnegativeInteger(byteSize))
        return nil;
    if (byteSize != nil)
        result[@"byte_size"] = byteSize;
    return result;
}

static NSDictionary *ReactionDTO(NSDictionary *source) {
    if (!IsIntegerNumber(source[@"id"]) || ![source[@"type"] isKindOfClass:NSString.class] ||
        ![source[@"emoji"] isKindOfClass:NSString.class] || ![source[@"sender"] isKindOfClass:NSString.class] ||
        !IsBooleanNumber(source[@"is_from_me"]) || !ParseStrictRFC3339(source[@"created_at"], NULL) ||
        !IsNullableString(source[@"sender_name"])) {
        return nil;
    }
    return ProjectKeys(source, @[@"id", @"type", @"emoji", @"sender", @"sender_name", @"is_from_me", @"created_at"]);
}

static NSDictionary *MessageDTO(NSDictionary *source) {
    if (!IsIntegerNumber(source[@"id"]) || !IsIntegerNumber(source[@"chat_id"]) ||
        ![source[@"guid"] isKindOfClass:NSString.class] || ![source[@"sender"] isKindOfClass:NSString.class] ||
        !IsBooleanNumber(source[@"is_from_me"]) || ![source[@"text"] isKindOfClass:NSString.class] ||
        !ParseStrictRFC3339(source[@"created_at"], NULL) || !IsNullableString(source[@"reply_to_guid"]) ||
        !IsNullableString(source[@"reply_to_text"]) || !IsNullableString(source[@"reply_to_sender"]) ||
        !IsNullableString(source[@"sender_name"]) || !IsNullableBoolean(source[@"is_read"]) ||
        !IsNullableRFC3339(source[@"date_read"])) {
        return nil;
    }
    NSMutableDictionary *result = ProjectKeys(source, @[
        @"id", @"chat_id", @"guid", @"reply_to_guid", @"reply_to_text", @"reply_to_sender", @"sender", @"sender_name",
        @"is_from_me", @"text", @"created_at", @"is_read", @"date_read"
    ]);
    id rawAttachments = source[@"attachments"];
    if (rawAttachments != nil) {
        if (![rawAttachments isKindOfClass:NSArray.class])
            return nil;
        NSMutableArray *attachments = [NSMutableArray array];
        for (id rawAttachment in rawAttachments) {
            if (![rawAttachment isKindOfClass:NSDictionary.class])
                return nil;
            NSDictionary *attachment = AttachmentDTO(rawAttachment);
            if (attachment == nil)
                return nil;
            [attachments addObject:attachment];
        }
        result[@"attachments"] = attachments;
    }
    id rawReactions = source[@"reactions"];
    if (rawReactions != nil) {
        if (![rawReactions isKindOfClass:NSArray.class])
            return nil;
        NSMutableArray *reactions = [NSMutableArray array];
        for (id rawReaction in rawReactions) {
            if (![rawReaction isKindOfClass:NSDictionary.class])
                return nil;
            NSDictionary *reaction = ReactionDTO(rawReaction);
            if (reaction == nil)
                return nil;
            [reactions addObject:reaction];
        }
        result[@"reactions"] = reactions;
    }
    return result;
}

static NSDictionary *ScheduledMessageDTO(NSDictionary *source) {
    if (!IsIntegerNumber(source[@"id"]) || ![source[@"guid"] isKindOfClass:NSString.class] ||
        !IsIntegerNumber(source[@"chat_id"]) || ![source[@"chat_name"] isKindOfClass:NSString.class] ||
        ![source[@"text"] isKindOfClass:NSString.class] || ![source[@"service"] isKindOfClass:NSString.class] ||
        !ParseStrictRFC3339(source[@"scheduled_at"], NULL) ||
        (source[@"schedule_state"] != nil && !IsIntegerNumber(source[@"schedule_state"])) ||
        (source[@"schedule_type"] != nil && !IsIntegerNumber(source[@"schedule_type"]))) {
        return nil;
    }
    return ProjectKeys(source, @[
        @"id", @"guid", @"chat_id", @"chat_name", @"text", @"service", @"scheduled_at", @"schedule_state",
        @"schedule_type"
    ]);
}

static NSDictionary *ChatBackgroundDTO(NSDictionary *source, long long expectedChatID) {
    NSSet *allowed = [NSSet setWithArray:@[
        @"ok", @"chat_id", @"chat_guid", @"background_set", @"background_channel_guid", @"asset_url", @"asset_id",
        @"object_id", @"file_size", @"poster_version", @"communication_safety_state", @"version", @"cache_exists",
        @"watch_background_exists", @"latest_event"
    ]];
    if (![[NSSet setWithArray:source.allKeys] isSubsetOfSet:allowed] || !IsBooleanNumber(source[@"ok"]) ||
        ![source[@"ok"] boolValue] || !IsIntegerNumber(source[@"chat_id"]) ||
        [source[@"chat_id"] longLongValue] != expectedChatID || ![source[@"chat_guid"] isKindOfClass:NSString.class] ||
        !IsBooleanNumber(source[@"background_set"]) || !IsNullableString(source[@"background_channel_guid"]) ||
        !IsNullableString(source[@"asset_url"]) || !IsNullableString(source[@"asset_id"]) ||
        !IsNullableString(source[@"object_id"]) || !IsNullableNonnegativeInteger(source[@"file_size"]) ||
        !IsNullableInteger(source[@"poster_version"]) || !IsNullableInteger(source[@"communication_safety_state"]) ||
        !IsNullableInteger(source[@"version"]) || !IsNullableBoolean(source[@"cache_exists"]) ||
        !IsNullableBoolean(source[@"watch_background_exists"])) {
        return nil;
    }

    id latestEventValue = source[@"latest_event"];
    id latestEvent = NSNull.null;
    if (latestEventValue != nil && latestEventValue != NSNull.null) {
        if (![latestEventValue isKindOfClass:NSDictionary.class]) {
            return nil;
        }
        NSDictionary *rawEvent = latestEventValue;
        NSSet *eventKeys = [NSSet setWithArray:@[@"row_id", @"guid", @"action", @"date"]];
        if (![[NSSet setWithArray:rawEvent.allKeys] isSubsetOfSet:eventKeys] || rawEvent.count != eventKeys.count ||
            !IsIntegerNumber(rawEvent[@"row_id"]) || ![rawEvent[@"guid"] isKindOfClass:NSString.class] ||
            ![@[@"set", @"clear"] containsObject:rawEvent[@"action"]] || !ParseStrictRFC3339(rawEvent[@"date"], NULL)) {
            return nil;
        }
        latestEvent = @{@"action": rawEvent[@"action"], @"date": rawEvent[@"date"]};
    }

    return @{
        @"chat_id": source[@"chat_id"],
        @"background_set": source[@"background_set"],
        @"file_size": source[@"file_size"] ?: NSNull.null,
        @"cache_exists": source[@"cache_exists"] ?: NSNull.null,
        @"watch_background_exists": source[@"watch_background_exists"] ?: NSNull.null,
        @"latest_event": latestEvent,
    };
}

static BOOL IsNonnegativeInteger(id value) { return IsIntegerNumber(value) && [value longLongValue] >= 0; }

static NSArray *ProjectStatisticsArray(id rawItems, NSDictionary * (^projector)(NSDictionary *)) {
    if (![rawItems isKindOfClass:NSArray.class])
        return nil;
    NSArray *rawArray = rawItems;
    NSUInteger count = MIN(rawArray.count, MaxStatisticsDimensionItems);
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        id rawItem = rawArray[index];
        if (![rawItem isKindOfClass:NSDictionary.class])
            return nil;
        NSDictionary *item = projector(rawItem);
        if (item == nil)
            return nil;
        [items addObject:item];
    }
    return items;
}

static NSDictionary *StatisticsDTO(NSDictionary *source) {
    if (!IsNonnegativeInteger(source[@"total_messages"]) || !IsNonnegativeInteger(source[@"sent_messages"]) ||
        !IsNonnegativeInteger(source[@"received_messages"]) || !IsKnownTimeZoneName(source[@"time_zone"]))
        return nil;

    NSArray *chats = ProjectStatisticsArray(source[@"chats"], ^NSDictionary *(NSDictionary *item) {
        if (!IsIntegerNumber(item[@"chat_id"]) || [item[@"chat_id"] longLongValue] <= 0 ||
            ![item[@"identifier"] isKindOfClass:NSString.class] || ![item[@"name"] isKindOfClass:NSString.class] ||
            ![item[@"service"] isKindOfClass:NSString.class] || !IsNonnegativeInteger(item[@"message_count"]))
            return nil;
        return ProjectKeys(item, @[@"chat_id", @"identifier", @"name", @"service", @"message_count"]);
    });
    NSArray *senders = ProjectStatisticsArray(source[@"senders"], ^NSDictionary *(NSDictionary *item) {
        if (![item[@"handle"] isKindOfClass:NSString.class] || !IsNonnegativeInteger(item[@"message_count"]))
            return nil;
        return ProjectKeys(item, @[@"handle", @"message_count"]);
    });
    NSArray *services = ProjectStatisticsArray(source[@"services"], ^NSDictionary *(NSDictionary *item) {
        if (![item[@"service"] isKindOfClass:NSString.class] || !IsNonnegativeInteger(item[@"message_count"]))
            return nil;
        return ProjectKeys(item, @[@"service", @"message_count"]);
    });
    NSArray *dates = ProjectStatisticsArray(source[@"dates"], ^NSDictionary *(NSDictionary *item) {
        NSString *date = [item[@"date"] isKindOfClass:NSString.class] ? item[@"date"] : nil;
        if (!IsStrictFullDate(date) || !IsNonnegativeInteger(item[@"message_count"]))
            return nil;
        return ProjectKeys(item, @[@"date", @"message_count"]);
    });
    if (chats == nil || senders == nil || services == nil || dates == nil)
        return nil;
    NSMutableArray<NSString *> *truncatedDimensions = [NSMutableArray array];
    if ([(NSArray *)source[@"chats"] count] > MaxStatisticsDimensionItems) {
        [truncatedDimensions addObject:@"chats"];
    }
    if ([(NSArray *)source[@"senders"] count] > MaxStatisticsDimensionItems) {
        [truncatedDimensions addObject:@"senders"];
    }
    if ([(NSArray *)source[@"services"] count] > MaxStatisticsDimensionItems) {
        [truncatedDimensions addObject:@"services"];
    }
    if ([(NSArray *)source[@"dates"] count] > MaxStatisticsDimensionItems) {
        [truncatedDimensions addObject:@"dates"];
    }

    id mediaValue = source[@"media"];
    id media = NSNull.null;
    if (mediaValue != nil && mediaValue != NSNull.null) {
        if (![mediaValue isKindOfClass:NSDictionary.class] || !IsNonnegativeInteger(mediaValue[@"total_attachments"]) ||
            !IsNonnegativeInteger(mediaValue[@"total_bytes"]))
            return nil;
        NSArray *types = ProjectStatisticsArray(mediaValue[@"types"], ^NSDictionary *(NSDictionary *item) {
            if (![item[@"uti"] isKindOfClass:NSString.class] || ![item[@"mime_type"] isKindOfClass:NSString.class] ||
                !IsNonnegativeInteger(item[@"attachment_count"]) || !IsNonnegativeInteger(item[@"total_bytes"]))
                return nil;
            return ProjectKeys(item, @[@"uti", @"mime_type", @"attachment_count", @"total_bytes"]);
        });
        NSArray *mediaChats = ProjectStatisticsArray(mediaValue[@"chats"], ^NSDictionary *(NSDictionary *item) {
            if (!IsIntegerNumber(item[@"chat_id"]) || [item[@"chat_id"] longLongValue] <= 0 ||
                ![item[@"identifier"] isKindOfClass:NSString.class] || ![item[@"name"] isKindOfClass:NSString.class] ||
                !IsNonnegativeInteger(item[@"attachment_count"]) || !IsNonnegativeInteger(item[@"total_bytes"]))
                return nil;
            return ProjectKeys(item, @[@"chat_id", @"identifier", @"name", @"attachment_count", @"total_bytes"]);
        });
        if (types == nil || mediaChats == nil)
            return nil;
        if ([(NSArray *)mediaValue[@"types"] count] > MaxStatisticsDimensionItems) {
            [truncatedDimensions addObject:@"media.types"];
        }
        if ([(NSArray *)mediaValue[@"chats"] count] > MaxStatisticsDimensionItems) {
            [truncatedDimensions addObject:@"media.chats"];
        }
        media = @{
            @"total_attachments": mediaValue[@"total_attachments"],
            @"total_bytes": mediaValue[@"total_bytes"],
            @"types": types,
            @"chats": mediaChats,
        };
    }
    return @{
        @"total_messages": source[@"total_messages"],
        @"sent_messages": source[@"sent_messages"],
        @"received_messages": source[@"received_messages"],
        @"time_zone": source[@"time_zone"],
        @"chats": chats,
        @"senders": senders,
        @"services": services,
        @"dates": dates,
        @"media": media,
        @"truncated_dimensions": truncatedDimensions,
    };
}

static NSDictionary *AcceptedSendDTO(NSDictionary *source, NSString *operationUUID) {
    if (![source[@"status"] isKindOfClass:NSString.class] ||
        ![[source[@"status"] lowercaseString] isEqualToString:@"sent"] ||
        (source[@"id"] != nil && (!IsIntegerNumber(source[@"id"]) || [source[@"id"] longLongValue] <= 0)) ||
        (source[@"guid"] != nil && ![source[@"guid"] isKindOfClass:NSString.class])) {
        return nil;
    }
    NSMutableDictionary *result = [@{@"operation_id": operationUUID, @"state": @"accepted"} mutableCopy];
    if (source[@"id"] != nil)
        result[@"message_id"] = source[@"id"];
    if ([source[@"guid"] length] > 0)
        result[@"guid"] = source[@"guid"];
    return result;
}

static NSArray<NSDictionary *> *ProjectItems(NSArray<NSDictionary *> *items,
                                             NSDictionary * (^projector)(NSDictionary *)) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:items.count];
    for (NSDictionary *item in items) {
        NSDictionary *projected = projector(item);
        if (projected == nil)
            return nil;
        [result addObject:projected];
    }
    return result;
}

static BOOL CheckMessagesReadPath(IMPConfiguration *configuration, NSError **error) {
    NSArray<NSDictionary *> *items =
        RunConfiguredJSONLines(configuration, @[@"chats", @"--limit", @"1"], 1, configuration.readTimeout, error);
    if (items == nil) {
        if (error != NULL && (*error == nil || (*error).code != IMPServerErrorTimeout)) {
            *error = ServerError(IMPServerErrorUpstream, @"Messages read-path preflight failed");
        }
        return NO;
    }
    if (ProjectItems(items, ^NSDictionary *(NSDictionary *item) {
            return ChatDTO(item);
        }) == nil) {
        if (error != NULL) {
            *error = ServerError(IMPServerErrorUpstream, @"Messages read-path preflight returned invalid data");
        }
        return NO;
    }
    return YES;
}

static NSArray<NSDictionary *> *MessagesInChronologicalOrder(NSArray<NSDictionary *> *messages) {
    return [messages sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSDate *leftDate = nil;
        NSDate *rightDate = nil;
        if (!ParseStrictRFC3339(left[@"created_at"], &leftDate) ||
            !ParseStrictRFC3339(right[@"created_at"], &rightDate))
            return NSOrderedSame;
        NSComparisonResult dateOrder = [leftDate compare:rightDate];
        if (dateOrder != NSOrderedSame)
            return dateOrder;
        long long leftID = [left[@"id"] longLongValue];
        long long rightID = [right[@"id"] longLongValue];
        return leftID < rightID ? NSOrderedAscending : (leftID > rightID ? NSOrderedDescending : NSOrderedSame);
    }];
}

static NSDictionary *KeyDTO(IMPAPIKeyRecord *record) {
    return @{
        @"id": record.uuid,
        @"name": record.name,
        @"key_prefix": record.keyPrefix ?: @"imp_",
        @"scopes": record.scopes,
        @"created_at": ISO8601(record.createdAt),
        @"expires_at": ISO8601(record.expiresAt) ?: NSNull.null,
        @"revoked_at": ISO8601(record.revokedAt) ?: NSNull.null,
        @"last_used_at": ISO8601(record.lastUsedAt) ?: NSNull.null,
    };
}

static NSDictionary *AuditEventDTO(IMPAuditRecord *record) {
    NSString *phase = record.phase == IMPAuditPhaseAttempted ? @"attempted" : @"final";
    return @{
        @"request_id": record.requestUUID,
        @"key_id": record.keyUUID ?: NSNull.null,
        @"target_key_id": record.targetKeyUUID ?: NSNull.null,
        @"source": record.source,
        @"action": record.action,
        @"phase": phase,
        @"status": record.status ?: NSNull.null,
        @"duration_ms": record.durationMilliseconds ?: NSNull.null,
        @"created_at": ISO8601(record.createdAt),
    };
}

@interface IMPServer : NSObject
@property (nonatomic, strong) IMPConfiguration *configuration;
@property (nonatomic, strong) IMPAPIKeyStore *keyStore;
@property (nonatomic, strong) NSDate *startedAt;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *rateState;
@property (nonatomic, strong) NSObject *rateLock;
- (instancetype)initWithConfiguration:(IMPConfiguration *)configuration error:(NSError **)error;
- (IMPHTTPResponse *)responseForRequest:(IMPHTTPRequest *)request requestID:(NSString *)requestID;
- (IMPHTTPResponse *)finishResponse:(IMPHTTPResponse *)response
                          requestID:(NSString *)requestID
                              actor:(nullable IMPAPIKeyRecord *)actor
                             action:(NSString *)action
                            started:(NSDate *)started;
@end

@implementation IMPServer

- (instancetype)initWithConfiguration:(IMPConfiguration *)configuration error:(NSError **)error {
    self = [super init];
    if (self != nil) {
        _configuration = configuration;
        _keyStore = [[IMPAPIKeyStore alloc] initWithPath:configuration.databasePath error:error];
        if (_keyStore == nil)
            return nil;
        if (![_keyStore prepareForServerStartup:error])
            return nil;
        _startedAt = [NSDate date];
        _rateState = [NSMutableDictionary dictionary];
        _rateLock = [NSObject new];
    }
    return self;
}

- (BOOL)allowRateForPrincipal:(NSString *)principal category:(NSString *)category limit:(NSUInteger)limit {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSString *key = [NSString stringWithFormat:@"%@:%@", principal, category];
    @synchronized(self.rateLock) {
        if (self.rateState.count >= 4096) {
            NSMutableArray<NSString *> *expired = [NSMutableArray array];
            [self.rateState enumerateKeysAndObjectsUsingBlock:^(
                                NSString *candidate, NSMutableDictionary *candidateEntry, __unused BOOL *stop) {
                if (now - [candidateEntry[@"start"] doubleValue] >= 120)
                    [expired addObject:candidate];
            }];
            [self.rateState removeObjectsForKeys:expired];
        }
        NSMutableDictionary *entry = self.rateState[key];
        if (entry == nil || now - [entry[@"start"] doubleValue] >= 60) {
            if (entry == nil && self.rateState.count >= 4096)
                return NO;
            self.rateState[key] = [@{@"start": @(now), @"count": @1} mutableCopy];
            return YES;
        }
        NSUInteger count = [entry[@"count"] unsignedIntegerValue];
        if (count >= limit)
            return NO;
        entry[@"count"] = @(count + 1);
        return YES;
    }
}

- (NSString *)sourceForRequest:(IMPHTTPRequest *)request valid:(BOOL *)valid {
    NSString *source = request.headers[@"x-api-client-ip"];
    if (source.length == 0) {
        if (valid != NULL)
            *valid = YES;
        return @"local";
    }
    struct in_addr ipv4;
    struct in6_addr ipv6;
    BOOL isAddress = source.length <= INET6_ADDRSTRLEN && (inet_pton(AF_INET, source.UTF8String, &ipv4) == 1 ||
                                                           inet_pton(AF_INET6, source.UTF8String, &ipv6) == 1);
    if (valid != NULL)
        *valid = isAddress;
    return isAddress ? source : @"invalid";
}

- (IMPProcessResult *)runIMSGArguments:(NSArray<NSString *> *)arguments
                               timeout:(NSTimeInterval)timeout
                                 error:(NSError **)error {
    return RunConfiguredIMSGArguments(self.configuration, arguments, timeout, error);
}

- (NSArray<NSDictionary *> *)runJSONLines:(NSArray<NSString *> *)arguments
                             maximumItems:(NSUInteger)maximumItems
                                    error:(NSError **)error {
    return [self runJSONLines:arguments maximumItems:maximumItems timeout:self.configuration.readTimeout error:error];
}

- (NSArray<NSDictionary *> *)runJSONLines:(NSArray<NSString *> *)arguments
                             maximumItems:(NSUInteger)maximumItems
                                  timeout:(NSTimeInterval)timeout
                                    error:(NSError **)error {
    return RunConfiguredJSONLines(self.configuration, arguments, maximumItems, timeout, error);
}

- (IMPHTTPResponse *)upstreamProblem:(NSError *)error {
    NSInteger status = error.code == IMPServerErrorTimeout ? 504 : 502;
    NSString *code = status == 504 ? @"dependency-timeout" : @"dependency-failed";
    return Problem(status, code, @"The Messages dependency could not complete the request.");
}

- (IMPHTTPResponse *)scopeProblem {
    return Problem(403, @"insufficient-scope", @"The API key does not grant this operation.");
}

- (BOOL)originAllowed:(IMPHTTPRequest *)request {
    NSString *origin = request.headers[@"origin"];
    if (origin.length == 0)
        return YES;
    return self.configuration.publicOrigin.length > 0 && [origin isEqualToString:self.configuration.publicOrigin];
}

- (BOOL)recordAttemptForRequestID:(NSString *)requestID
                            actor:(IMPAPIKeyRecord *)actor
                           action:(NSString *)action
                    targetKeyUUID:(NSString *)targetKeyUUID {
    NSError *auditError = nil;
    NSString *source = NSThread.currentThread.threadDictionary[RequestSourceThreadKey] ?: @"local";
    BOOL recorded = [self.keyStore recordAuditForRequestUUID:requestID
                                                     keyUUID:actor.uuid
                                               targetKeyUUID:targetKeyUUID
                                                      source:source
                                                      action:action
                                                       phase:IMPAuditPhaseAttempted
                                                      status:nil
                                        durationMilliseconds:nil
                                                       error:&auditError];
    if (!recorded) {
        os_log_with_type(ServerOperationalLog(), OS_LOG_TYPE_ERROR,
                         "request_id=%{public}s action=audit.write_failed phase=attempted", requestID.UTF8String);
    }
    return recorded;
}

- (IMPHTTPResponse *)finishResponse:(IMPHTTPResponse *)response
                          requestID:(NSString *)requestID
                              actor:(IMPAPIKeyRecord *)actor
                             action:(NSString *)action
                            started:(NSDate *)started {
    NSInteger milliseconds = MAX(0, (NSInteger)(-[started timeIntervalSinceNow] * 1000));
    SetResponseHeader(response, @"X-Request-ID", requestID);
    NSError *auditError = nil;
    NSString *source = NSThread.currentThread.threadDictionary[RequestSourceThreadKey] ?: @"local";
    if (![self.keyStore recordAuditForRequestUUID:requestID
                                          keyUUID:actor.uuid
                                    targetKeyUUID:response.auditTargetKeyUUID
                                           source:source
                                           action:action
                                            phase:IMPAuditPhaseFinal
                                           status:@(response.status)
                             durationMilliseconds:@(milliseconds)
                                            error:&auditError]) {
        os_log_with_type(ServerOperationalLog(), OS_LOG_TYPE_ERROR,
                         "request_id=%{public}s action=audit.write_failed phase=final", requestID.UTF8String);
    }
    const char *caller = actor == nil ? "unauthenticated" : actor.uuid.UTF8String;
    os_log_with_type(ServerOperationalLog(), OS_LOG_TYPE_INFO,
                     "request_id=%{public}s caller=%{public}s action=%{public}s status=%ld duration_ms=%ld",
                     requestID.UTF8String, caller, action.UTF8String, (long)response.status, (long)milliseconds);
    [NSThread.currentThread.threadDictionary removeObjectForKey:RequestContextThreadKey];
    [NSThread.currentThread.threadDictionary removeObjectForKey:RequestSourceThreadKey];
    return response;
}

- (IMPHTTPResponse *)responseForRequest:(IMPHTTPRequest *)request requestID:(NSString *)requestID {
    NSDate *started = [NSDate date];
    NSThread.currentThread.threadDictionary[RequestContextThreadKey] = requestID;
    BOOL sourceValid = NO;
    NSString *source = [self sourceForRequest:request valid:&sourceValid];
    NSThread.currentThread.threadDictionary[RequestSourceThreadKey] = source;
    if (!sourceValid) {
        return [self finishResponse:Problem(400, @"invalid-source", @"The client source metadata is invalid.")
                          requestID:requestID
                              actor:nil
                             action:@"request.invalid"
                            started:started];
    }
    if (![self allowRateForPrincipal:source category:@"source" limit:240]) {
        return [self finishResponse:RateLimitedResponse(requestID, @"rate-limited", @"Too many requests.")
                          requestID:requestID
                              actor:nil
                             action:@"request.rate_limited"
                            started:started];
    }
    NSString *authorization = request.headers[@"authorization"];
    IMPAPIKeyRecord *actor = nil;
    NSError *authenticationError = nil;
    if ([authorization hasPrefix:@"Bearer "] && authorization.length > 7 &&
        [authorization rangeOfString:@","].location == NSNotFound) {
        actor = [self.keyStore authenticateToken:[authorization substringFromIndex:7] error:&authenticationError];
    }
    if (actor == nil) {
        if (authenticationError != nil && ![authenticationError.domain isEqualToString:IMPAPIKeyStoreErrorDomain]) {
            return [self finishResponse:ProblemWithRequestID(503, @"key-store-unavailable",
                                                             @"Authentication is temporarily unavailable.", requestID)
                              requestID:requestID
                                  actor:nil
                                 action:@"auth.unavailable"
                                started:started];
        }
        if (authenticationError != nil && [authenticationError.domain isEqualToString:IMPAPIKeyStoreErrorDomain] &&
            authenticationError.code != IMPAPIKeyStoreErrorAuthenticationFailed) {
            return [self finishResponse:ProblemWithRequestID(503, @"key-store-unavailable",
                                                             @"Authentication is temporarily unavailable.", requestID)
                              requestID:requestID
                                  actor:nil
                                 action:@"auth.unavailable"
                                started:started];
        }
        if (![self allowRateForPrincipal:source category:@"auth" limit:60]) {
            return [self finishResponse:RateLimitedResponse(requestID, @"rate-limited", @"Too many requests.")
                              requestID:requestID
                                  actor:nil
                                 action:@"auth.rate_limited"
                                started:started];
        }
        return [self finishResponse:UnauthorizedResponse(requestID)
                          requestID:requestID
                              actor:nil
                             action:@"auth.reject"
                            started:started];
    }
    if (![self originAllowed:request]) {
        return [self finishResponse:ProblemWithRequestID(403, @"origin-forbidden",
                                                         @"The request origin is not allowed.", requestID)
                          requestID:requestID
                              actor:actor
                             action:@"origin.reject"
                            started:started];
    }
    if (![self allowRateForPrincipal:actor.uuid category:@"all" limit:180]) {
        return [self finishResponse:RateLimitedResponse(requestID, @"rate-limited", @"Too many requests.")
                          requestID:requestID
                              actor:actor
                             action:@"request.rate_limited"
                            started:started];
    }

    IMPHTTPResponse *response = nil;
    NSString *auditAction = @"route.not_found";
    if ([request.method isEqualToString:@"GET"] && [request.path isEqualToString:@"/api/status"]) {
        auditAction = @"status.read";
        if (request.query.length > 0 || request.body.length > 0) {
            response = Problem(400, @"invalid-request", @"This route accepts no body or query.");
        } else {
            NSError *versionError = nil;
            NSString *dependencyVersion = DependencyVersion(self.configuration, &versionError);
            NSError *readinessError = nil;
            if (dependencyVersion == nil || !CheckMessagesReadPath(self.configuration, &readinessError)) {
                response = Problem(503, @"messages-unavailable", @"The Messages read path is unavailable.");
            } else {
                response = JSONResponse(200, @{
                    @"status": @"ok",
                    @"version": ServerVersion,
                    @"uptime_seconds": @((NSUInteger) - [self.startedAt timeIntervalSinceNow]),
                    @"messages": @{@"status": @"ready", @"dependency_version": dependencyVersion},
                    @"key": @{
                        @"id": actor.uuid,
                        @"name": actor.name,
                        @"key_prefix": actor.keyPrefix ?: @"imp_",
                        @"scopes": actor.scopes,
                        @"expires_at": ISO8601(actor.expiresAt) ?: NSNull.null,
                    },
                });
            }
        }
    } else if ([request.method isEqualToString:@"GET"] && [request.path isEqualToString:@"/api/chats"]) {
        auditAction = @"chats.list";
        if (![actor hasScope:IMPAPIKeyScopeMessagesRead]) {
            response = [self scopeProblem];
        } else if (request.body.length > 0) {
            response = Problem(400, @"invalid-request", @"This route accepts no body.");
        } else {
            NSError *queryError = nil;
            NSDictionary *query = ParseQuery(request.query, &queryError);
            NSSet *allowed = [NSSet setWithArray:@[@"limit", @"unread_only"]];
            if (query == nil || ![[NSSet setWithArray:query.allKeys] isSubsetOfSet:allowed]) {
                response = Problem(400, @"invalid-query", @"The query parameters are invalid.");
            } else {
                NSUInteger limit = 20;
                if (query[@"limit"] != nil && !ParsePositiveInteger(query[@"limit"], 100, &limit)) {
                    response = Problem(400, @"invalid-limit", @"limit must be between 1 and 100.");
                } else if (query[@"unread_only"] != nil &&
                           ![@[@"true", @"false"] containsObject:query[@"unread_only"]]) {
                    response = Problem(400, @"invalid-unread-filter", @"unread_only must be true or false.");
                } else {
                    NSMutableArray *arguments =
                        [NSMutableArray arrayWithArray:@[@"chats", @"--limit", [@(limit) stringValue]]];
                    if ([query[@"unread_only"] isEqualToString:@"true"])
                        [arguments addObject:@"--unread-only"];
                    NSError *upstreamError = nil;
                    NSArray *items = [self runJSONLines:arguments maximumItems:limit error:&upstreamError];
                    NSArray *chats = items == nil ? nil : ProjectItems(items, ^NSDictionary *(NSDictionary *item) {
                        return ChatDTO(item);
                    });
                    response = chats == nil ? [self upstreamProblem:upstreamError
                                                                        ?: ServerError(IMPServerErrorUpstream,
                                                                                       @"invalid chat response")]
                                            : JSONResponse(200, @{@"chats": chats});
                }
            }
        }
    } else {
        NSRegularExpression *chatExpression =
            [NSRegularExpression regularExpressionWithPattern:@"^/api/chats/([1-9][0-9]*)(/messages)?$"
                                                      options:0
                                                        error:nil];
        NSTextCheckingResult *chatMatch = [chatExpression firstMatchInString:request.path
                                                                     options:0
                                                                       range:NSMakeRange(0, request.path.length)];
        if ([request.method isEqualToString:@"GET"] && chatMatch != nil) {
            BOOL messagesRoute = [request.path hasSuffix:@"/messages"];
            auditAction = messagesRoute ? @"messages.history" : @"chats.read";
            if (![actor hasScope:IMPAPIKeyScopeMessagesRead]) {
                response = [self scopeProblem];
            } else if (request.body.length > 0) {
                response = Problem(400, @"invalid-request", @"This route accepts no body.");
            } else {
                NSString *chatID = [request.path substringWithRange:[chatMatch rangeAtIndex:1]];
                NSUInteger parsedChatID = 0;
                if (!ParsePositiveInteger(chatID, NSIntegerMax, &parsedChatID)) {
                    response = Problem(400, @"invalid-chat", @"The chat identifier is invalid.");
                } else if (!messagesRoute) {
                    if (request.query.length > 0) {
                        response = Problem(400, @"invalid-query", @"This route does not accept query parameters.");
                    } else {
                        NSError *upstreamError = nil;
                        NSArray *items = [self runJSONLines:@[@"group", @"--chat-id", chatID]
                                               maximumItems:1
                                                      error:&upstreamError];
                        NSDictionary *chat = items.count == 1 ? ChatDTO(items.firstObject) : nil;
                        if (items == nil) {
                            response = upstreamError.code == IMPServerErrorNotFound
                                           ? Problem(404, @"chat-not-found", @"The chat was not found.")
                                           : [self upstreamProblem:upstreamError];
                        } else if (chat != nil) {
                            response = JSONResponse(200, chat);
                        } else {
                            response =
                                [self upstreamProblem:ServerError(IMPServerErrorUpstream, @"invalid chat response")];
                        }
                    }
                } else {
                    NSError *queryError = nil;
                    NSDictionary *query = ParseQueryAllowingRepeatedNames(
                        request.query, [NSSet setWithObject:@"participant"], &queryError);
                    NSSet *allowed = [NSSet setWithArray:@[@"limit", @"participant", @"start", @"end"]];
                    if (query == nil || ![[NSSet setWithArray:query.allKeys] isSubsetOfSet:allowed]) {
                        response = Problem(400, @"invalid-query", @"The query parameters are invalid.");
                    } else {
                        NSUInteger limit = 50;
                        if (query[@"limit"] != nil && !ParsePositiveInteger(query[@"limit"], 200, &limit)) {
                            response = Problem(400, @"invalid-limit", @"limit must be between 1 and 200.");
                        } else {
                            NSMutableArray *arguments = [NSMutableArray arrayWithArray:@[
                                @"history", @"--chat-id", chatID, @"--limit", [@(limit) stringValue], @"--attachments"
                            ]];
                            NSArray<NSString *> *participants = query[@"participant"] ?: @[];
                            if (participants.count > 32) {
                                response =
                                    Problem(400, @"invalid-participants", @"At most 32 participants are allowed.");
                            } else if (participants.count > 0) {
                                for (NSString *participant in participants) {
                                    if (UnicodeCodePointLength(participant) == 0 ||
                                        UnicodeCodePointLength(participant) > 256 || [participant hasPrefix:@"-"] ||
                                        [participant containsString:@","] ||
                                        [participant rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet]
                                                .location != NSNotFound) {
                                        response =
                                            Problem(400, @"invalid-participants", @"A participant filter is invalid.");
                                        break;
                                    }
                                }
                                if (response == nil) {
                                    [arguments addObjectsFromArray:@[
                                        @"--participants", [participants componentsJoinedByString:@","]
                                    ]];
                                }
                            }
                            NSDate *startDate = nil;
                            NSDate *endDate = nil;
                            NSString *startValue = query[@"start"];
                            NSString *endValue = query[@"end"];
                            if ((startValue != nil && !ParseStrictRFC3339(startValue, &startDate)) ||
                                (endValue != nil && !ParseStrictRFC3339(endValue, &endDate)) ||
                                (startDate != nil && endDate != nil &&
                                 [startDate compare:endDate] != NSOrderedAscending)) {
                                response = Problem(400, @"invalid-date", @"Date filters are invalid.");
                            } else {
                                if (startValue != nil)
                                    [arguments addObjectsFromArray:@[@"--start", startValue]];
                                if (endValue != nil)
                                    [arguments addObjectsFromArray:@[@"--end", endValue]];
                            }
                            if (response == nil) {
                                NSError *upstreamError = nil;
                                NSArray *items = [self runJSONLines:arguments maximumItems:limit error:&upstreamError];
                                NSArray *messages =
                                    items == nil ? nil : ProjectItems(items, ^NSDictionary *(NSDictionary *item) {
                                        return MessageDTO(item);
                                    });
                                if (messages != nil)
                                    messages = MessagesInChronologicalOrder(messages);
                                response = messages == nil
                                               ? [self upstreamProblem:upstreamError
                                                                           ?: ServerError(IMPServerErrorUpstream,
                                                                                          @"invalid message response")]
                                               : JSONResponse(200, @{@"messages": messages});
                            }
                        }
                    }
                }
            }
        }
    }

    if (response == nil && [request.method isEqualToString:@"GET"]) {
        NSRegularExpression *backgroundExpression =
            [NSRegularExpression regularExpressionWithPattern:@"^/api/chats/([1-9][0-9]*)/background$"
                                                      options:0
                                                        error:nil];
        NSTextCheckingResult *backgroundMatch =
            [backgroundExpression firstMatchInString:request.path options:0 range:NSMakeRange(0, request.path.length)];
        if (backgroundMatch != nil) {
            auditAction = @"background.read";
            if (![actor hasScope:IMPAPIKeyScopeMessagesRead]) {
                response = [self scopeProblem];
            } else if (request.query.length > 0 || request.body.length > 0) {
                response = Problem(400, @"invalid-request", @"This route accepts no body or query.");
            } else {
                NSString *chatID = [request.path substringWithRange:[backgroundMatch rangeAtIndex:1]];
                NSUInteger parsedChatID = 0;
                if (!ParsePositiveInteger(chatID, NSIntegerMax, &parsedChatID)) {
                    response = Problem(400, @"invalid-chat", @"The chat identifier is invalid.");
                } else {
                    NSError *upstreamError = nil;
                    NSArray *items = [self runJSONLines:@[@"chat-background", @"status", @"--chat-id", chatID]
                                           maximumItems:1
                                                  error:&upstreamError];
                    NSDictionary *background =
                        items.count == 1 ? ChatBackgroundDTO(items.firstObject, (long long)parsedChatID) : nil;
                    if (items == nil) {
                        response = upstreamError.code == IMPServerErrorNotFound
                                       ? Problem(404, @"chat-not-found", @"The chat was not found.")
                                       : [self upstreamProblem:upstreamError];
                    } else if (background != nil) {
                        response = JSONResponse(200, background);
                    } else {
                        response = [self
                            upstreamProblem:ServerError(IMPServerErrorUpstream, @"invalid chat background response")];
                    }
                }
            }
        }
    }

    if (response == nil && [request.method isEqualToString:@"GET"] &&
        [request.path isEqualToString:@"/api/scheduled-messages"]) {
        auditAction = @"scheduled.list";
        if (![actor hasScope:IMPAPIKeyScopeMessagesRead]) {
            response = [self scopeProblem];
        } else if (request.body.length > 0) {
            response = Problem(400, @"invalid-request", @"This route accepts no body.");
        } else {
            NSError *queryError = nil;
            NSDictionary *query = ParseQuery(request.query, &queryError);
            if (query == nil || (query.count > 0 && !(query.count == 1 && query[@"limit"] != nil))) {
                response = Problem(400, @"invalid-query", @"The query parameters are invalid.");
            } else {
                NSUInteger limit = 50;
                if (query[@"limit"] != nil && !ParsePositiveInteger(query[@"limit"], 100, &limit)) {
                    response = Problem(400, @"invalid-limit", @"limit must be between 1 and 100.");
                } else {
                    NSError *upstreamError = nil;
                    NSArray *items = [self runJSONLines:@[@"scheduled", @"list", @"--limit", [@(limit) stringValue]]
                                           maximumItems:limit
                                                  error:&upstreamError];
                    NSArray *messages = items == nil ? nil : ProjectItems(items, ^NSDictionary *(NSDictionary *item) {
                        return ScheduledMessageDTO(item);
                    });
                    response = messages == nil
                                   ? [self upstreamProblem:upstreamError
                                                               ?: ServerError(IMPServerErrorUpstream,
                                                                              @"invalid scheduled response")]
                                   : JSONResponse(200, @{@"messages": messages});
                }
            }
        }
    }

    if (response == nil && [request.method isEqualToString:@"GET"] &&
        [request.path isEqualToString:@"/api/statistics/messages"]) {
        auditAction = @"statistics.read";
        if (![actor hasScope:IMPAPIKeyScopeMessagesRead]) {
            response = [self scopeProblem];
        } else if (request.body.length > 0) {
            response = Problem(400, @"invalid-request", @"This route accepts no body.");
        } else {
            NSError *queryError = nil;
            NSDictionary *query = ParseQuery(request.query, &queryError);
            NSSet *allowed = [NSSet setWithArray:@[@"chat_id", @"time_zone", @"include_media"]];
            if (query == nil || ![[NSSet setWithArray:query.allKeys] isSubsetOfSet:allowed]) {
                response = Problem(400, @"invalid-query", @"The query parameters are invalid.");
            } else {
                NSMutableArray *arguments = [NSMutableArray arrayWithObject:@"stats"];
                NSUInteger chatID = 0;
                if (query[@"chat_id"] != nil && !ParsePositiveInteger(query[@"chat_id"], NSIntegerMax, &chatID)) {
                    response = Problem(400, @"invalid-chat", @"chat_id is invalid.");
                } else if (query[@"include_media"] != nil &&
                           ![@[@"true", @"false"] containsObject:query[@"include_media"]]) {
                    response = Problem(400, @"invalid-media-filter", @"include_media must be true or false.");
                } else {
                    if (query[@"chat_id"] != nil)
                        [arguments addObjectsFromArray:@[@"--chat-id", query[@"chat_id"]]];
                    if (query[@"time_zone"] != nil) {
                        if (!IsKnownTimeZoneName(query[@"time_zone"])) {
                            response = Problem(400, @"invalid-time-zone", @"time_zone is invalid.");
                        } else {
                            [arguments addObjectsFromArray:@[@"--time-zone", query[@"time_zone"]]];
                        }
                    }
                    if ([query[@"include_media"] isEqualToString:@"true"])
                        [arguments addObject:@"--media"];
                    if (response == nil) {
                        NSError *upstreamError = nil;
                        NSArray *items = [self runJSONLines:arguments maximumItems:1 error:&upstreamError];
                        NSDictionary *statistics = items.count == 1 ? StatisticsDTO(items.firstObject) : nil;
                        if (items == nil) {
                            response = upstreamError.code == IMPServerErrorNotFound
                                           ? Problem(404, @"chat-not-found", @"The chat was not found.")
                                           : [self upstreamProblem:upstreamError];
                        } else {
                            response = statistics != nil
                                           ? JSONResponse(200, statistics)
                                           : [self upstreamProblem:ServerError(IMPServerErrorUpstream,
                                                                               @"invalid statistics response")];
                        }
                    }
                }
            }
        }
    }

    if (response == nil && [request.method isEqualToString:@"POST"] &&
        [request.path isEqualToString:@"/api/messages"]) {
        auditAction = @"messages.send";
        NSTimeInterval sendDeadline = MonotonicSeconds() + self.configuration.sendTimeout;
        if (![actor hasScope:IMPAPIKeyScopeMessagesSend]) {
            response = [self scopeProblem];
        } else if (request.query.length > 0) {
            response = Problem(400, @"invalid-query", @"This route does not accept query parameters.");
        } else if (![self allowRateForPrincipal:actor.uuid category:@"send" limit:20]) {
            response = RateLimitedResponse(requestID, @"send-rate-limited", @"Too many send requests.");
        } else if (!IsJSONContentType(request.headers[@"content-type"] ?: @"")) {
            response = Problem(415, @"unsupported-media-type", @"Content-Type must be application/json.");
        } else {
            NSString *idempotencyKey = request.headers[@"idempotency-key"];
            NSCharacterSet *invalidKeyCharacters = [[NSCharacterSet
                characterSetWithCharactersInString:
                    @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~-"] invertedSet];
            if (idempotencyKey.length < 8 || idempotencyKey.length > 128 ||
                [idempotencyKey rangeOfCharacterFromSet:invalidKeyCharacters].location != NSNotFound) {
                response = Problem(400, @"invalid-idempotency-key", @"A valid Idempotency-Key header is required.");
            } else {
                id object = request.body.length == 0
                                ? nil
                                : [NSJSONSerialization JSONObjectWithData:request.body options:0 error:nil];
                if (![object isKindOfClass:NSDictionary.class]) {
                    response = Problem(400, @"invalid-body", @"The request body must be a JSON object.");
                } else {
                    NSDictionary *body = object;
                    NSSet *allowed = [NSSet setWithArray:@[@"recipient", @"chat_id", @"text"]];
                    BOOL recipientPresent = [body.allKeys containsObject:@"recipient"];
                    BOOL chatIDPresent = [body.allKeys containsObject:@"chat_id"];
                    NSString *recipient = [body[@"recipient"] isKindOfClass:NSString.class] ? body[@"recipient"] : nil;
                    NSNumber *chatID = [body[@"chat_id"] isKindOfClass:NSNumber.class] ? body[@"chat_id"] : nil;
                    NSString *text = [body[@"text"] isKindOfClass:NSString.class] ? body[@"text"] : nil;
                    BOOL validRecipient = recipientPresent && IsDirectMessageRecipient(recipient);
                    BOOL validChat = chatID != nil && CFGetTypeID((__bridge CFTypeRef)chatID) != CFBooleanGetTypeID() &&
                                     chatID.doubleValue == chatID.longLongValue && chatID.longLongValue > 0;
                    if (![[NSSet setWithArray:body.allKeys] isSubsetOfSet:allowed] ||
                        recipientPresent == chatIDPresent || (recipientPresent && !validRecipient) ||
                        (chatIDPresent && !validChat) || UnicodeCodePointLength(text) == 0 ||
                        UnicodeCodePointLength(text) > 4000 || [text hasPrefix:@"-"] || !IsSafeMessageText(text)) {
                        response = Problem(400, @"invalid-message",
                                           @"Exactly one valid target and message text are required.");
                    } else {
                        BOOL targetAllowed = validChat
                                                 ? [self.configuration.allowedChatIDs containsObject:chatID.stringValue]
                                                 : [self.configuration.allowedRecipients containsObject:recipient];
                        if (!targetAllowed) {
                            response = Problem(403, @"target-forbidden", @"The message target is not allowed.");
                        } else {
                            NSDictionary *normalized = validChat ? @{@"chat_id": chatID, @"text": text}
                                                                 : @{@"recipient": recipient, @"text": text};
                            NSData *requestHash = [IMPAPIKeyStore SHA256ForData:JSONData(normalized, nil)];
                            if (![self recordAttemptForRequestID:requestID
                                                           actor:actor
                                                          action:auditAction
                                                   targetKeyUUID:nil]) {
                                response = Problem(503, @"audit-unavailable", @"The send could not be audited.");
                            } else {
                                NSError *claimError = nil;
                                IMPIdempotencyRecord *claim = [self.keyStore claimForPrincipalUUID:actor.uuid
                                                                                               key:idempotencyKey
                                                                                       requestHash:requestHash
                                                                                             error:&claimError];
                                if (claim == nil) {
                                    NSInteger status =
                                        claimError.code == IMPAPIKeyStoreErrorAuthenticationFailed ? 401 : 503;
                                    response = status == 401 ? UnauthorizedResponse(requestID)
                                                             : Problem(503, @"idempotency-unavailable",
                                                                       @"The request state could not be recorded.");
                                } else if (claim.disposition == IMPIdempotencyDispositionConflict) {
                                    response = Problem(409, @"idempotency-conflict",
                                                       @"The Idempotency-Key was used for a different request.");
                                } else if (claim.disposition == IMPIdempotencyDispositionInProgress) {
                                    response = Problem(409, @"request-in-progress",
                                                       @"The matching request is already in progress.");
                                } else if (claim.disposition == IMPIdempotencyDispositionReplay ||
                                           claim.disposition == IMPIdempotencyDispositionAmbiguous) {
                                    if (claim.responseBody.length == 0) {
                                        response = Problem(409, @"send-ambiguous",
                                                           @"A previous process ended during this send; it will not be "
                                                           @"retried automatically.");
                                    } else {
                                        response = [IMPHTTPResponse new];
                                        response.status = claim.responseStatus.integerValue;
                                        response.body = claim.responseBody;
                                        response.contentType =
                                            response.status >= 400 ? @"application/problem+json" : @"application/json";
                                    }
                                    SetResponseHeader(response, @"Idempotent-Replayed", @"true");
                                } else {
                                    NSMutableArray *arguments = [NSMutableArray arrayWithObject:@"send"];
                                    if (validChat) {
                                        NSError *chatError = nil;
                                        NSTimeInterval remaining = sendDeadline - MonotonicSeconds();
                                        if (remaining <= 0) {
                                            response = Problem(504, @"dependency-timeout",
                                                               @"The send deadline elapsed before chat validation.");
                                        } else {
                                            NSArray *chatItems =
                                                [self runJSONLines:@[@"group", @"--chat-id", chatID.stringValue]
                                                      maximumItems:1
                                                           timeout:MIN(self.configuration.readTimeout, remaining)
                                                             error:&chatError];
                                            if (chatItems == nil) {
                                                response =
                                                    chatError.code == IMPServerErrorNotFound
                                                        ? Problem(404, @"chat-not-found", @"The chat was not found.")
                                                        : [self upstreamProblem:chatError];
                                            } else {
                                                NSDictionary *chat =
                                                    chatItems.count == 1 ? ChatDTO(chatItems.firstObject) : nil;
                                                NSString *service = [chat[@"service"] isKindOfClass:NSString.class]
                                                                        ? [chat[@"service"] lowercaseString]
                                                                        : @"";
                                                if (chat == nil) {
                                                    response =
                                                        [self upstreamProblem:ServerError(IMPServerErrorUpstream,
                                                                                          @"invalid chat response")];
                                                } else if (![service isEqualToString:@"imessage"]) {
                                                    response = Problem(409, @"not-imessage-chat",
                                                                       @"The selected chat is not an iMessage chat.");
                                                } else {
                                                    [arguments addObjectsFromArray:@[@"--chat-id", chatID.stringValue]];
                                                }
                                            }
                                        }
                                    } else {
                                        [arguments addObjectsFromArray:@[@"--to", recipient]];
                                    }
                                    IMPIdempotencyState terminalState = IMPIdempotencyStateFailed;
                                    if (response == nil) {
                                        [arguments addObjectsFromArray:@[
                                            @"--text", text, @"--service", @"imessage", @"--no-sms-fallback"
                                        ]];
                                        NSTimeInterval remaining = sendDeadline - MonotonicSeconds();
                                        if (remaining <= 0) {
                                            response = Problem(504, @"dependency-timeout",
                                                               @"The send deadline elapsed before execution.");
                                        } else {
                                            NSError *sendError = nil;
                                            NSArray *items = [self runJSONLines:arguments
                                                                   maximumItems:1
                                                                        timeout:remaining
                                                                          error:&sendError];
                                            NSDictionary *sendResult =
                                                items.count == 1
                                                    ? AcceptedSendDTO(items.firstObject, claim.operationUUID)
                                                    : nil;
                                            if (sendResult == nil) {
                                                NSInteger status = sendError.code == IMPServerErrorTimeout ? 504 : 502;
                                                response = Problem(status, @"send-ambiguous",
                                                                   @"The send result is ambiguous and will not be "
                                                                   @"retried automatically.");
                                                terminalState = IMPIdempotencyStateAmbiguous;
                                            } else {
                                                response = JSONResponse(202, sendResult);
                                                terminalState = IMPIdempotencyStateSucceeded;
                                            }
                                        }
                                    }
                                    NSError *completionError = nil;
                                    if (![self.keyStore completeForPrincipalUUID:actor.uuid
                                                                             key:idempotencyKey
                                                                     requestHash:requestHash
                                                                   operationUUID:claim.operationUUID
                                                                           state:terminalState
                                                                  responseStatus:response.status
                                                                    responseBody:response.body
                                                                           error:&completionError]) {
                                        response = Problem(
                                            503, @"idempotency-completion-failed",
                                            @"The result could not be durably finalized; do not retry with a new key.");
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (response == nil && [request.path isEqualToString:@"/api/keys"] && [request.method isEqualToString:@"GET"]) {
        auditAction = @"keys.list";
        if (![actor hasScope:IMPAPIKeyScopeAdmin]) {
            response = [self scopeProblem];
        } else if (request.query.length > 0 || request.body.length > 0) {
            response = Problem(400, @"invalid-request", @"This route accepts no body or query.");
        } else {
            NSError *storeError = nil;
            NSArray<IMPAPIKeyRecord *> *records = [self.keyStore listKeysWithLimit:1000 error:&storeError];
            if (records == nil) {
                response = Problem(503, @"key-store-unavailable", @"API key metadata is unavailable.");
            } else {
                NSMutableArray *keys = [NSMutableArray array];
                for (IMPAPIKeyRecord *record in records)
                    [keys addObject:KeyDTO(record)];
                response = JSONResponse(200, @{@"keys": keys});
            }
        }
    }

    if (response == nil && [request.path isEqualToString:@"/api/audit-events"] &&
        [request.method isEqualToString:@"GET"]) {
        auditAction = @"audit.list";
        if (![actor hasScope:IMPAPIKeyScopeAdmin]) {
            response = [self scopeProblem];
        } else if (request.body.length > 0) {
            response = Problem(400, @"invalid-request", @"This route accepts no body.");
        } else {
            NSError *queryError = nil;
            NSDictionary *query = ParseQuery(request.query, &queryError);
            if (query == nil || (query.count > 0 && !(query.count == 1 && query[@"limit"] != nil))) {
                response = Problem(400, @"invalid-query", @"The query parameters are invalid.");
            } else {
                NSUInteger limit = 100;
                if (query[@"limit"] != nil && !ParsePositiveInteger(query[@"limit"], 1000, &limit)) {
                    response = Problem(400, @"invalid-limit", @"limit must be between 1 and 1000.");
                } else {
                    NSError *storeError = nil;
                    NSArray<IMPAuditRecord *> *records = [self.keyStore auditRecordsWithLimit:limit error:&storeError];
                    if (records == nil) {
                        response = Problem(503, @"audit-unavailable", @"Audit metadata is unavailable.");
                    } else {
                        NSMutableArray *events = [NSMutableArray arrayWithCapacity:records.count];
                        for (IMPAuditRecord *record in records) {
                            [events addObject:AuditEventDTO(record)];
                        }
                        response = JSONResponse(200, @{@"events": events});
                    }
                }
            }
        }
    }

    if (response == nil && [request.method isEqualToString:@"GET"] && [request.path hasPrefix:@"/api/keys/"]) {
        auditAction = @"keys.read";
        if (![actor hasScope:IMPAPIKeyScopeAdmin]) {
            response = [self scopeProblem];
        } else if (request.query.length > 0 || request.body.length > 0) {
            response = Problem(400, @"invalid-request", @"This route accepts no body or query.");
        } else {
            NSString *uuid = [request.path substringFromIndex:@"/api/keys/".length];
            NSUUID *parsedUUID = [[NSUUID alloc] initWithUUIDString:uuid];
            if (parsedUUID == nil) {
                response = Problem(404, @"key-not-found", @"The API key was not found.");
            } else {
                NSString *normalizedUUID = parsedUUID.UUIDString.lowercaseString;
                NSError *storeError = nil;
                IMPAPIKeyRecord *record = [self.keyStore keyWithUUID:normalizedUUID error:&storeError];
                if (record != nil) {
                    response = JSONResponse(200, KeyDTO(record));
                    response.auditTargetKeyUUID = normalizedUUID;
                } else if (storeError.code == IMPAPIKeyStoreErrorNotFound) {
                    response = Problem(404, @"key-not-found", @"The API key was not found.");
                } else {
                    response = Problem(503, @"key-store-unavailable", @"API key metadata is unavailable.");
                }
            }
        }
    }

    if (response == nil && [request.path isEqualToString:@"/api/keys"] && [request.method isEqualToString:@"POST"]) {
        auditAction = @"keys.create";
        if (![actor hasScope:IMPAPIKeyScopeAdmin]) {
            response = [self scopeProblem];
        } else if (request.query.length > 0) {
            response = Problem(400, @"invalid-query", @"This route does not accept query parameters.");
        } else if (!IsJSONContentType(request.headers[@"content-type"] ?: @"")) {
            response = Problem(415, @"unsupported-media-type", @"Content-Type must be application/json.");
        } else {
            id object = request.body.length == 0
                            ? nil
                            : [NSJSONSerialization JSONObjectWithData:request.body options:0 error:nil];
            NSDictionary *body = [object isKindOfClass:NSDictionary.class] ? object : nil;
            NSSet *allowed = [NSSet setWithArray:@[@"name", @"scopes", @"expires_in_days"]];
            NSString *name = nil;
            BOOL validName = IsValidAPIKeyName(body[@"name"], &name);
            NSArray *scopes = [body[@"scopes"] isKindOfClass:NSArray.class] ? body[@"scopes"] : nil;
            BOOL daysPresent = [body.allKeys containsObject:@"expires_in_days"];
            NSNumber *daysValue = [body[@"expires_in_days"] isKindOfClass:NSNumber.class] ? body[@"expires_in_days"]
                                                                                          : (daysPresent ? nil : @90);
            BOOL validDays = daysValue != nil && CFGetTypeID((__bridge CFTypeRef)daysValue) != CFBooleanGetTypeID() &&
                             daysValue.doubleValue == daysValue.unsignedIntegerValue &&
                             daysValue.unsignedIntegerValue >= 1 && daysValue.unsignedIntegerValue <= 365;
            NSSet *validScopes =
                [NSSet setWithArray:@[IMPAPIKeyScopeMessagesRead, IMPAPIKeyScopeMessagesSend, IMPAPIKeyScopeAdmin]];
            NSSet *scopeSet = scopes == nil ? nil : [NSSet setWithArray:scopes];
            if (body == nil || ![[NSSet setWithArray:body.allKeys] isSubsetOfSet:allowed] || !validName ||
                scopes.count == 0 || scopes.count != scopeSet.count || ![scopeSet isSubsetOfSet:validScopes] ||
                !validDays) {
                response = Problem(400, @"invalid-key", @"The API key request is invalid.");
            } else {
                NSDate *expiresAt = [NSDate dateWithTimeIntervalSinceNow:daysValue.unsignedIntegerValue * 86400.0];
                if (![self recordAttemptForRequestID:requestID actor:actor action:auditAction targetKeyUUID:nil]) {
                    response = Problem(503, @"audit-unavailable", @"The mutation could not be audited.");
                } else {
                    NSError *storeError = nil;
                    NSDictionary *created = [self.keyStore createKeyNamed:name
                                                                   scopes:scopes
                                                                expiresAt:expiresAt
                                                                actorUUID:actor.uuid
                                                                    error:&storeError];
                    if (created == nil) {
                        NSInteger status = storeError.code == IMPAPIKeyStoreErrorAuthorizationFailed
                                               ? 403
                                               : (storeError.code == IMPAPIKeyStoreErrorConflict ? 409 : 503);
                        response = Problem(status,
                                           status == 403 ? @"administrator-inactive"
                                                         : (status == 409 ? @"key-limit" : @"key-store-unavailable"),
                                           status == 403 ? @"An active administrator is required."
                                                         : @"The API key could not be created.");
                    } else {
                        IMPAPIKeyRecord *record = created[IMPAPIKeyCreationRecordKey];
                        NSMutableDictionary *dto = [KeyDTO(record) mutableCopy];
                        dto[@"key"] = created[IMPAPIKeyCreationTokenKey];
                        response = JSONResponse(201, dto);
                        response.auditTargetKeyUUID = record.uuid;
                        SetResponseHeader(response, @"Location", [@"/api/keys/" stringByAppendingString:record.uuid]);
                    }
                }
            }
        }
    }

    if (response == nil && [request.method isEqualToString:@"DELETE"] && [request.path hasPrefix:@"/api/keys/"]) {
        auditAction = @"keys.revoke";
        if (![actor hasScope:IMPAPIKeyScopeAdmin]) {
            response = [self scopeProblem];
        } else if (request.query.length > 0 || request.body.length > 0) {
            response = Problem(400, @"invalid-request", @"This route accepts no body or query.");
        } else {
            NSString *uuid = [request.path substringFromIndex:@"/api/keys/".length];
            if ([[NSUUID alloc] initWithUUIDString:uuid] == nil) {
                response = Problem(404, @"key-not-found", @"The API key was not found.");
            } else {
                NSString *normalizedUUID = [[[[NSUUID alloc] initWithUUIDString:uuid] UUIDString] lowercaseString];
                if (![self recordAttemptForRequestID:requestID
                                               actor:actor
                                              action:auditAction
                                       targetKeyUUID:normalizedUUID]) {
                    response = Problem(503, @"audit-unavailable", @"The mutation could not be audited.");
                } else {
                    NSError *storeError = nil;
                    if ([self.keyStore revokeKeyUUID:normalizedUUID actorUUID:actor.uuid error:&storeError]) {
                        response = JSONResponse(204, @{});
                    } else if (storeError.code == IMPAPIKeyStoreErrorLastActiveAdmin) {
                        response = Problem(409, @"last-admin", @"The final active administrator cannot be revoked.");
                    } else if (storeError.code == IMPAPIKeyStoreErrorNotFound) {
                        response = Problem(404, @"key-not-found", @"The API key was not found.");
                    } else if (storeError.code == IMPAPIKeyStoreErrorAuthorizationFailed) {
                        response = Problem(403, @"administrator-inactive", @"An active administrator is required.");
                    } else {
                        response = Problem(503, @"key-store-unavailable", @"The API key could not be revoked.");
                    }
                    response.auditTargetKeyUUID = normalizedUUID;
                }
            }
        }
    }

    if (response == nil) {
        response = Problem(404, @"not-found", @"The requested API route does not exist.");
    }
    return [self finishResponse:response requestID:requestID actor:actor action:auditAction started:started];
}

@end

static BOOL WriteAll(int fileDescriptor, const void *bytes, NSUInteger length) {
    const uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t count = send(fileDescriptor, cursor, length, MSG_NOSIGNAL);
        if (count < 0 && errno == EINTR)
            continue;
        if (count <= 0)
            return NO;
        cursor += count;
        length -= (NSUInteger)count;
    }
    return YES;
}

static BOOL WriteBootstrapToken(NSString *token) {
    NSData *output = [[token stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (output == nil) {
        errno = EINVAL;
        return NO;
    }
    struct sigaction ignore = {0};
    ignore.sa_handler = SIG_IGN;
    sigemptyset(&ignore.sa_mask);
    if (sigaction(SIGPIPE, &ignore, NULL) != 0 || sigaction(SIGXFSZ, &ignore, NULL) != 0) {
        return NO;
    }

    const uint8_t *cursor = output.bytes;
    NSUInteger remaining = output.length;
    while (remaining > 0) {
        ssize_t count = write(STDOUT_FILENO, cursor, remaining);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            return NO;
        }
        cursor += count;
        remaining -= (NSUInteger)count;
    }
    return YES;
}

static void SendResponse(int fileDescriptor, IMPHTTPResponse *response) {
    NSMutableString *headers = [NSMutableString
        stringWithFormat:@"HTTP/1.1 %ld %@\r\nContent-Length: %lu\r\nContent-Type: %@\r\nConnection: close\r\n"
                          "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n",
                         (long)response.status, ReasonPhrase(response.status), (unsigned long)response.body.length,
                         response.contentType ?: @"application/json"];
    [response.headers enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, __unused BOOL *stop) {
        [headers appendFormat:@"%@: %@\r\n", name, value];
    }];
    [headers appendString:@"\r\n"];
    NSData *headerData = [headers dataUsingEncoding:NSUTF8StringEncoding];
    if (WriteAll(fileDescriptor, headerData.bytes, headerData.length) && response.body.length > 0) {
        (void)WriteAll(fileDescriptor, response.body.bytes, response.body.length);
    }
}

static void HandleSignal(__unused int signalNumber) { stopRequested = 1; }

static BOOL ServerStartupFailure(NSError **error, NSString *message, const char *reason) {
    NSError *failure = ServerError(IMPServerErrorInvalidConfiguration, message);
    if (error != NULL)
        *error = failure;
    LogOperationalFailure("server.start", reason, failure);
    return NO;
}

static BOOL RunServer(IMPConfiguration *configuration, NSError **error) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGINT, HandleSignal);
    signal(SIGTERM, HandleSignal);
    NSError *messagesError = nil;
    if (!CheckMessagesReadPath(configuration, &messagesError)) {
        if (error != NULL) {
            *error = messagesError ?: ServerError(IMPServerErrorUpstream, @"Messages read-path preflight failed");
        }
        LogOperationalFailure("server.start", "messages_read_preflight_failed", messagesError);
        return NO;
    }
    struct stat existing;
    if (lstat(configuration.socketPath.fileSystemRepresentation, &existing) == 0) {
        return ServerStartupFailure(error, @"socket path already exists", "socket_path_exists");
    }
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0) {
        return ServerStartupFailure(error, @"could not create socket", "socket_create_failed");
    }
    int flags = fcntl(server, F_GETFD);
    if (flags < 0 || fcntl(server, F_SETFD, flags | FD_CLOEXEC) != 0) {
        close(server);
        return ServerStartupFailure(error, @"could not secure socket", "socket_secure_failed");
    }
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, configuration.socketPath.fileSystemRepresentation, sizeof(address.sun_path));
    mode_t previousMask = umask(0177);
    int bindResult = bind(server, (struct sockaddr *)&address, sizeof(address));
    umask(previousMask);
    if (bindResult != 0 || chmod(configuration.socketPath.fileSystemRepresentation, 0600) != 0 ||
        listen(server, 32) != 0) {
        close(server);
        unlink(configuration.socketPath.fileSystemRepresentation);
        return ServerStartupFailure(error, @"could not bind socket", "socket_bind_failed");
    }
    struct stat ownedSocket;
    if (lstat(configuration.socketPath.fileSystemRepresentation, &ownedSocket) != 0 || !S_ISSOCK(ownedSocket.st_mode) ||
        ownedSocket.st_uid != getuid() || (ownedSocket.st_mode & 0777) != 0600) {
        close(server);
        unlink(configuration.socketPath.fileSystemRepresentation);
        return ServerStartupFailure(error, @"socket ownership is invalid", "socket_ownership_invalid");
    }
    IMPServer *handler = [[IMPServer alloc] initWithConfiguration:configuration error:error];
    if (handler == nil) {
        close(server);
        unlink(configuration.socketPath.fileSystemRepresentation);
        LogOperationalFailure("server.start", "handler_initialization_failed", error == NULL ? nil : *error);
        return NO;
    }
    os_log_with_type(ServerOperationalLog(), OS_LOG_TYPE_INFO, "action=server.start version=%{public}s transport=unix",
                     ServerVersion.UTF8String);
    dispatch_queue_t clients =
        dispatch_queue_create("io.github.mglaeser.imessage-proxy.server.clients", DISPATCH_QUEUE_CONCURRENT);
    dispatch_group_t clientGroup = dispatch_group_create();
    dispatch_semaphore_t slots = dispatch_semaphore_create(configuration.maximumConcurrency);
    BOOL acceptFailed = NO;
    // Darwin restarts accept(2), and shutdown(2) does not wake an unconnected listener.
    // A bounded poll keeps the signal handler async-safe and caps shutdown latency.
    while (!stopRequested) {
        struct pollfd listener = {.fd = server, .events = POLLIN, .revents = 0};
        int pollResult = poll(&listener, 1, 250);
        if (pollResult < 0 && errno == EINTR)
            continue;
        if (pollResult == 0)
            continue;
        if (stopRequested)
            break;
        if (pollResult < 0 || (listener.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0 ||
            (listener.revents & POLLIN) == 0) {
            if (stopRequested)
                break;
            NSError *pollError = ServerError(IMPServerErrorUpstream, @"the Unix socket listener failed");
            if (error != NULL)
                *error = pollError;
            LogOperationalFailure("server.run", "socket_poll_failed", pollError);
            acceptFailed = YES;
            break;
        }
        int client = accept(server, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR)
                continue;
            if (stopRequested || errno == EBADF)
                break;
            NSError *acceptError = ServerError(IMPServerErrorUpstream, @"the Unix socket accept loop failed");
            if (error != NULL)
                *error = acceptError;
            LogOperationalFailure("server.run", "socket_accept_failed", acceptError);
            acceptFailed = YES;
            break;
        }
        if (stopRequested) {
            close(client);
            break;
        }
        if (!ConfigureClient(client, configuration.socketTimeout)) {
            close(client);
            continue;
        }
        if (dispatch_semaphore_wait(slots, DISPATCH_TIME_NOW) != 0) {
            NSString *requestID = NewRequestUUID();
            IMPHTTPResponse *response =
                [handler finishResponse:ProblemWithRequestID(503, @"overloaded",
                                                             @"The server is at its concurrency limit.", requestID)
                              requestID:requestID
                                  actor:nil
                                 action:@"server.overloaded"
                                started:NSDate.date];
            SendResponse(client, response);
            close(client);
            continue;
        }
        dispatch_group_async(clientGroup, clients, ^{
            @autoreleasepool {
                NSString *requestID = NewRequestUUID();
                NSDate *requestStarted = NSDate.date;
                NSError *requestError = nil;
                NSInteger requestErrorStatus = 400;
                IMPHTTPRequest *request =
                    ReadRequest(client, configuration.socketTimeout, &requestErrorStatus, &requestError);
                IMPHTTPResponse *response =
                    request == nil
                        ? [handler finishResponse:ProblemWithRequestID(requestErrorStatus, @"invalid-request",
                                                                       @"The HTTP request is invalid.", requestID)
                                        requestID:requestID
                                            actor:nil
                                           action:@"request.invalid"
                                          started:requestStarted]
                        : [handler responseForRequest:request requestID:requestID];
                SendResponse(client, response);
                close(client);
                dispatch_semaphore_signal(slots);
            }
        });
    }
    NSTimeInterval drainSeconds =
        MAX(configuration.sendTimeout, configuration.readTimeout) + configuration.socketTimeout + 5;
    BOOL drainFailed = NO;
    long drainResult =
        dispatch_group_wait(clientGroup, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(drainSeconds * NSEC_PER_SEC)));
    if (drainResult != 0) {
        os_log_with_type(ServerOperationalLog(), OS_LOG_TYPE_ERROR, "action=shutdown.drain_timeout");
        SignalAllChildProcessGroups(SIGTERM);
        drainResult = dispatch_group_wait(clientGroup, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        if (drainResult != 0) {
            SignalAllChildProcessGroups(SIGKILL);
            drainResult = dispatch_group_wait(clientGroup, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        }
        if (drainResult != 0) {
            os_log_with_type(ServerOperationalLog(), OS_LOG_TYPE_FAULT, "action=shutdown.forced_exit");
            drainFailed = YES;
            if (error != NULL) {
                *error = ServerError(IMPServerErrorTimeout, @"shutdown drain did not complete");
            }
        }
    }
    close(server);
    struct stat current;
    if (lstat(configuration.socketPath.fileSystemRepresentation, &current) == 0 &&
        current.st_dev == ownedSocket.st_dev && current.st_ino == ownedSocket.st_ino) {
        unlink(configuration.socketPath.fileSystemRepresentation);
    }
    if (!acceptFailed && !drainFailed) {
        os_log_with_type(ServerOperationalLog(), OS_LOG_TYPE_INFO, "action=server.stop status=ok");
    }
    return !acceptFailed && !drainFailed;
}

static void PrintUsage(void) {
    fprintf(stderr,
            "Usage: imessage-proxy-server "
            "<serve|check-config|check-messages|config-fingerprint|check-bootstrap-admin|bootstrap-admin|version>\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL bootstrapArguments =
            argc == 4 && (strcmp(argv[1], "check-bootstrap-admin") == 0 || strcmp(argv[1], "bootstrap-admin") == 0);
        if (argc != 2 && !bootstrapArguments) {
            PrintUsage();
            return 64;
        }
        NSString *command = [NSString stringWithUTF8String:argv[1]];
        if ([command isEqualToString:@"version"]) {
            if (argc != 2)
                return 64;
            printf("%s\n", ServerVersion.UTF8String);
            return 0;
        }
        NSError *error = nil;
        IMPConfiguration *configuration = LoadConfiguration(&error);
        if (configuration == nil) {
            if ([command isEqualToString:@"serve"]) {
                LogOperationalFailure("configuration.load", "validation_failed", error);
            }
            fprintf(stderr, "ERROR: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        if ([command isEqualToString:@"check-config"]) {
            printf("ok\n");
            return 0;
        }
        if ([command isEqualToString:@"check-messages"]) {
            if (!CheckMessagesReadPath(configuration, &error)) {
                fprintf(stderr, "ERROR: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            printf("ok\n");
            return 0;
        }
        if ([command isEqualToString:@"config-fingerprint"]) {
            printf("%s\n", configuration.fingerprint.UTF8String);
            return 0;
        }
        BOOL checkBootstrap = [command isEqualToString:@"check-bootstrap-admin"];
        if (checkBootstrap || [command isEqualToString:@"bootstrap-admin"]) {
            if (argc != 4) {
                PrintUsage();
                return 64;
            }
            NSString *rawName = [NSString stringWithUTF8String:argv[2]];
            NSString *daysText = [NSString stringWithUTF8String:argv[3]];
            NSUInteger days = 0;
            if (!ParsePositiveInteger(daysText, NSUIntegerMax, &days)) {
                fprintf(stderr, "ERROR: bootstrap arguments are invalid\n");
                return 1;
            }
            IMPAPIKeyStore *store = [[IMPAPIKeyStore alloc] initWithPath:configuration.databasePath error:&error];
            if (store == nil) {
                fprintf(stderr, "ERROR: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            if (checkBootstrap) {
                if (![store checkBootstrapAdminNamed:rawName expiresDays:days error:&error]) {
                    fprintf(stderr, "ERROR: %s\n", error.localizedDescription.UTF8String);
                    return 1;
                }
                printf("ok\n");
                return 0;
            }

            IMPAPIKeyRecord *record = [store bootstrapAdminNamed:rawName
                                                     expiresDays:days
                                                    deliverToken:^BOOL(NSString *token) {
                                                        return WriteBootstrapToken(token);
                                                    }
                                                           error:&error];
            if (record == nil) {
                fprintf(stderr, "ERROR: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            os_log_with_type(ServerOperationalLog(), OS_LOG_TYPE_INFO,
                             "caller=bootstrap action=keys.bootstrap status=201 key_id=%{public}s",
                             record.uuid.UTF8String);
            return 0;
        }
        if ([command isEqualToString:@"serve"]) {
            if (RunServer(configuration, &error))
                return 0;
            os_log_with_type(ServerOperationalLog(), OS_LOG_TYPE_FAULT, "action=server.exit status=failed");
            fprintf(stderr, "ERROR: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        PrintUsage();
        return 64;
    }
}
