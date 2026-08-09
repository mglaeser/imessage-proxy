#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <poll.h>
#import <signal.h>
#import <stdlib.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <time.h>
#import <unistd.h>

#ifndef STELLA_VERSION
#define STELLA_VERSION "0.1.0"
#endif
#define STELLA_NSSTRING_IMPL(value) @value
#define STELLA_NSSTRING(value) STELLA_NSSTRING_IMPL(value)

static NSString *const BridgeVersion = STELLA_NSSTRING(STELLA_VERSION);
static const NSUInteger MaxHeaderBytes = 16 * 1024;
static const NSUInteger MaxRequestBytes = 64 * 1024;
static const NSUInteger MaxRPCResponseBytes = 4 * 1024 * 1024;
static const NSUInteger MaxRPCDiagnosticBytes = 64 * 1024;

static uint16_t bridgePort = 8765;
static NSString *bridgeToken;
static NSString *imsgPath;
static NSSet<NSString *> *allowedTargets;
static BOOL allowEveryTarget = NO;
static NSTimeInterval rpcTimeout = 30;
static NSTimeInterval socketTimeout = 10;
static NSUInteger maxConcurrentRequests = 8;

static NSError *BridgeError(NSInteger status, NSString *message) {
    return [NSError errorWithDomain:@"io.github.mglaeser.stella.bridge"
                               code:status
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *Trim(NSString *value) {
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *StringOrFallback(NSString *value, NSString *fallback) { return value != nil ? value : fallback; }

static BOOL ParseUnsignedInteger(NSString *text, NSUInteger minimum, NSUInteger maximum, NSUInteger *result) {
    if (text.length == 0) {
        return NO;
    }
    NSCharacterSet *nonDigits = [NSCharacterSet.decimalDigitCharacterSet invertedSet];
    if ([text rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        return NO;
    }
    errno = 0;
    char *end = NULL;
    unsigned long long parsed = strtoull(text.UTF8String, &end, 10);
    if (errno == ERANGE || end == NULL || *end != '\0' || parsed < minimum || parsed > maximum) {
        return NO;
    }
    if (result != NULL) {
        *result = (NSUInteger)parsed;
    }
    return YES;
}

static NSData *ReadPrivateFile(NSString *path, NSString *label, NSUInteger maximumSize, NSError **error) {
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        *error = BridgeError(500, [NSString stringWithFormat:@"cannot open %@ securely", label]);
        return nil;
    }
    struct stat info;
    if (fstat(descriptor, &info) != 0 || !S_ISREG(info.st_mode)) {
        close(descriptor);
        *error = BridgeError(500, [NSString stringWithFormat:@"%@ must be a regular file", label]);
        return nil;
    }
    if (info.st_uid != geteuid() || (info.st_mode & 077) != 0 || (info.st_mode & 0600) != 0600) {
        close(descriptor);
        *error =
            BridgeError(500, [NSString stringWithFormat:@"%@ must be owned by the current user with mode 0600", label]);
        return nil;
    }
    if (info.st_size <= 0 || (NSUInteger)info.st_size > maximumSize) {
        close(descriptor);
        *error = BridgeError(500, [NSString stringWithFormat:@"%@ has an invalid size", label]);
        return nil;
    }

    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[4096];
    while (YES) {
        ssize_t count = read(descriptor, buffer, sizeof(buffer));
        if (count == 0) {
            break;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            close(descriptor);
            *error = BridgeError(500, [NSString stringWithFormat:@"cannot read %@", label]);
            return nil;
        }
        if (data.length + (NSUInteger)count > maximumSize) {
            close(descriptor);
            *error = BridgeError(500, [NSString stringWithFormat:@"%@ exceeds the size limit", label]);
            return nil;
        }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    close(descriptor);
    return data;
}

static BOOL LoadConfiguration(NSError **error) {
    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    NSString *portText = StringOrFallback(environment[@"IMESSAGE_BRIDGE_PORT"], @"8765");
    NSUInteger portValue = 0;
    if (!ParseUnsignedInteger(portText, 1, 65535, &portValue)) {
        *error = BridgeError(500, @"IMESSAGE_BRIDGE_PORT must be 1-65535");
        return NO;
    }
    bridgePort = (uint16_t)portValue;

    NSString *tokenPath = environment[@"IMESSAGE_BRIDGE_TOKEN_FILE"];
    if (tokenPath.length == 0) {
        *error = BridgeError(500, @"IMESSAGE_BRIDGE_TOKEN_FILE is required");
        return NO;
    }
    NSData *tokenData = ReadPrivateFile(tokenPath, @"bridge token file", 1024, error);
    if (tokenData == nil) {
        return NO;
    }
    NSString *tokenText =
        StringOrFallback([[NSString alloc] initWithData:tokenData encoding:NSUTF8StringEncoding], @"");
    bridgeToken = tokenText.length == 65 && [tokenText hasSuffix:@"\n"] ? [tokenText substringToIndex:64] : tokenText;
    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    if (bridgeToken.length != 64 || [bridgeToken rangeOfCharacterFromSet:nonHex].location != NSNotFound) {
        *error = BridgeError(500, @"bridge token must contain exactly 64 lowercase hexadecimal characters");
        return NO;
    }

    NSString *targetsPath = environment[@"IMESSAGE_ALLOWED_TARGETS_FILE"];
    if (targetsPath.length == 0) {
        *error = BridgeError(500, @"IMESSAGE_ALLOWED_TARGETS_FILE is required");
        return NO;
    }
    NSData *targetsData = ReadPrivateFile(targetsPath, @"allowed targets file", 64 * 1024, error);
    if (targetsData == nil) {
        return NO;
    }
    NSString *targetsText = [[NSString alloc] initWithData:targetsData encoding:NSUTF8StringEncoding];
    if (targetsText == nil) {
        *error = BridgeError(500, @"allowed targets file must be valid UTF-8");
        return NO;
    }
    allowEveryTarget = NO;
    NSMutableSet<NSString *> *targets = [NSMutableSet set];
    __block NSString *invalidTarget = nil;
    [targetsText enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *value = Trim(line);
        if (value.length == 0 || [value hasPrefix:@"#"]) {
            return;
        }
        if (value.length > 512 || targets.count >= 256) {
            invalidTarget = @"allowed targets file exceeds its entry or line limit";
            *stop = YES;
            return;
        }
        if ([value isEqualToString:@"*"]) {
            allowEveryTarget = YES;
        } else {
            [targets addObject:value];
        }
    }];
    if (invalidTarget != nil) {
        *error = BridgeError(500, invalidTarget);
        return NO;
    }
    allowedTargets = [targets copy];

    imsgPath = StringOrFallback(environment[@"IMSG_BIN"], @"/opt/homebrew/bin/imsg");
    if (![NSFileManager.defaultManager isExecutableFileAtPath:imsgPath]) {
        *error = BridgeError(500, @"imsg is not executable at configured path");
        return NO;
    }

    NSString *timeoutText = StringOrFallback(environment[@"IMESSAGE_RPC_TIMEOUT_SECONDS"], @"30");
    NSUInteger timeoutValue = 0;
    if (!ParseUnsignedInteger(timeoutText, 1, 120, &timeoutValue)) {
        *error = BridgeError(500, @"IMESSAGE_RPC_TIMEOUT_SECONDS must be 1-120");
        return NO;
    }
    rpcTimeout = (NSTimeInterval)timeoutValue;

    NSString *socketTimeoutText = StringOrFallback(environment[@"STELLA_BRIDGE_SOCKET_TIMEOUT_SECONDS"], @"10");
    NSUInteger socketTimeoutValue = 0;
    if (!ParseUnsignedInteger(socketTimeoutText, 1, 60, &socketTimeoutValue)) {
        *error = BridgeError(500, @"STELLA_BRIDGE_SOCKET_TIMEOUT_SECONDS must be 1-60");
        return NO;
    }
    socketTimeout = (NSTimeInterval)socketTimeoutValue;

    NSString *concurrencyText = StringOrFallback(environment[@"STELLA_BRIDGE_MAX_CONCURRENCY"], @"8");
    if (!ParseUnsignedInteger(concurrencyText, 1, 64, &maxConcurrentRequests)) {
        *error = BridgeError(500, @"STELLA_BRIDGE_MAX_CONCURRENCY must be 1-64");
        return NO;
    }
    return YES;
}

static BOOL ConstantTimeEqual(NSString *left, NSString *right) {
    NSData *a = [left dataUsingEncoding:NSUTF8StringEncoding];
    NSData *b = [right dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *aBytes = a.bytes;
    const uint8_t *bBytes = b.bytes;
    NSUInteger count = a.length > b.length ? a.length : b.length;
    NSUInteger difference = a.length ^ b.length;
    for (NSUInteger index = 0; index < count; index++) {
        uint8_t x = index < a.length ? aBytes[index] : 0;
        uint8_t y = index < b.length ? bBytes[index] : 0;
        difference |= x ^ y;
    }
    return difference == 0;
}

static BOOL IsInteger(id value, BOOL positive, NSInteger *result) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    NSNumber *number = value;
    double numeric = number.doubleValue;
    NSInteger integer = number.integerValue;
    if (numeric != (double)integer || (positive ? integer <= 0 : integer < 0)) {
        return NO;
    }
    if (result != NULL) {
        *result = integer;
    }
    return YES;
}

static BOOL RequireOnly(NSDictionary *params, NSArray<NSString *> *keys, NSError **error) {
    NSSet *permitted = [NSSet setWithArray:keys];
    for (NSString *key in params) {
        if (![permitted containsObject:key]) {
            *error = BridgeError(400, @"unsupported parameter");
            return NO;
        }
    }
    return YES;
}

static BOOL ValidateLimit(id value, NSInteger maximum, NSError **error) {
    if (value == nil) {
        return YES;
    }
    NSInteger limit = 0;
    if (!IsInteger(value, YES, &limit) || limit > maximum) {
        *error = BridgeError(400, @"limit exceeds the API policy");
        return NO;
    }
    return YES;
}

static BOOL RejectTrue(id value, NSString *name, NSError **error) {
    if (value == nil) {
        return YES;
    }
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
        *error = BridgeError(400, [NSString stringWithFormat:@"%@ must be a boolean", name]);
        return NO;
    }
    if ([value boolValue]) {
        *error = BridgeError(403, [NSString stringWithFormat:@"%@ is disabled", name]);
        return NO;
    }
    return YES;
}

static BOOL ValidateOptionalBoolean(id value, NSString *name, NSError **error) {
    if (value == nil) {
        return YES;
    }
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
        *error = BridgeError(400, [NSString stringWithFormat:@"%@ must be a boolean", name]);
        return NO;
    }
    return YES;
}

static BOOL ValidateOptionalString(id value, NSString *name, NSUInteger maximum, NSError **error) {
    if (value == nil) {
        return YES;
    }
    if (![value isKindOfClass:NSString.class] || [value length] == 0 || [value length] > maximum) {
        *error = BridgeError(400, [NSString stringWithFormat:@"%@ must be a non-empty string of at most %lu characters",
                                                             name, (unsigned long)maximum]);
        return NO;
    }
    return YES;
}

static BOOL ValidJSONRPCID(id value) {
    if ([value isKindOfClass:NSString.class]) {
        return [value length] > 0 && [value length] <= 256;
    }
    if ([value isKindOfClass:NSNumber.class]) {
        return CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
    }
    return NO;
}

static NSString *SendTarget(NSDictionary *params, NSError **error) {
    NSMutableArray<NSString *> *targets = [NSMutableArray array];
    id directValue = params[@"to"];
    if (!ValidateOptionalString(directValue, @"to", 256, error)) {
        return nil;
    }
    NSString *direct = directValue;
    if (direct.length > 0) {
        [targets addObject:direct];
    }
    NSInteger chatID = 0;
    id chatIDValue = params[@"chat_id"];
    if (chatIDValue != nil && !IsInteger(chatIDValue, YES, &chatID)) {
        *error = BridgeError(400, @"chat_id must be a positive integer");
        return nil;
    }
    if (chatIDValue != nil) {
        [targets addObject:[NSString stringWithFormat:@"chat_id:%ld", (long)chatID]];
    }
    id identifierValue = params[@"chat_identifier"];
    if (!ValidateOptionalString(identifierValue, @"chat_identifier", 256, error)) {
        return nil;
    }
    NSString *identifier = identifierValue;
    if (identifier.length > 0) {
        [targets addObject:[@"chat_identifier:" stringByAppendingString:identifier]];
    }
    id guidValue = params[@"chat_guid"];
    if (!ValidateOptionalString(guidValue, @"chat_guid", 256, error)) {
        return nil;
    }
    NSString *guid = guidValue;
    if (guid.length > 0) {
        [targets addObject:[@"chat_guid:" stringByAppendingString:guid]];
    }
    if (targets.count != 1) {
        *error = BridgeError(400, @"send needs exactly one target");
        return nil;
    }
    return targets.firstObject;
}

static NSData *ValidateAndSanitizeRPC(NSData *data, NSString **methodOut, NSError **error) {
    if (data.length == 0 || data.length > MaxRequestBytes) {
        *error = BridgeError(400, @"invalid JSON-RPC request");
        return nil;
    }
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:error];
    if (![parsed isKindOfClass:NSDictionary.class]) {
        *error = BridgeError(400, @"invalid JSON-RPC request");
        return nil;
    }
    NSMutableDictionary *object = parsed;
    NSString *method = [object[@"method"] isKindOfClass:NSString.class] ? object[@"method"] : nil;
    if (!RequireOnly(object, @[@"jsonrpc", @"id", @"method", @"params"], error) ||
        ![object[@"jsonrpc"] isEqual:@"2.0"] || !ValidJSONRPCID(object[@"id"]) || method.length == 0) {
        *error = BridgeError(400, @"invalid JSON-RPC request");
        return nil;
    }
    id rawParams = object[@"params"];
    if (rawParams != nil && ![rawParams isKindOfClass:NSDictionary.class]) {
        *error = BridgeError(400, @"params must be an object");
        return nil;
    }
    NSMutableDictionary *params = rawParams == nil ? [NSMutableDictionary dictionary] : [rawParams mutableCopy];

    if ([method isEqualToString:@"chats.list"]) {
        if (!RequireOnly(params, @[@"limit", @"unread_only"], error) || !ValidateLimit(params[@"limit"], 100, error) ||
            !ValidateOptionalBoolean(params[@"unread_only"], @"unread_only", error)) {
            return nil;
        }
    } else if ([method isEqualToString:@"messages.history"]) {
        NSInteger chatID = 0;
        if (!RequireOnly(params, @[@"chat_id", @"limit", @"participants", @"start", @"end", @"attachments"], error) ||
            !IsInteger(params[@"chat_id"], YES, &chatID) || !ValidateLimit(params[@"limit"], 200, error) ||
            !ValidateOptionalString(params[@"start"], @"start", 64, error) ||
            !ValidateOptionalString(params[@"end"], @"end", 64, error) ||
            !RejectTrue(params[@"attachments"], @"attachments", error)) {
            if (*error == nil) {
                *error = BridgeError(400, @"messages.history needs a positive chat_id");
            }
            return nil;
        }
        id participants = params[@"participants"];
        if (participants != nil) {
            if (![participants isKindOfClass:NSArray.class] || [participants count] > 32) {
                *error = BridgeError(400, @"participants must be an array with at most 32 entries");
                return nil;
            }
            for (id participant in participants) {
                if (![participant isKindOfClass:NSString.class] || [participant length] == 0 ||
                    [participant length] > 256) {
                    *error = BridgeError(400, @"participants must contain non-empty strings of at most 256 characters");
                    return nil;
                }
            }
        }
        params[@"attachments"] = @NO;
    } else if ([method isEqualToString:@"messages.after"]) {
        NSInteger cursor = 0;
        if (!RequireOnly(
                params,
                @[@"since_rowid", @"chat_id", @"limit", @"attachments", @"convert_attachments", @"include_reactions"],
                error) ||
            !IsInteger(params[@"since_rowid"], NO, &cursor) || !ValidateLimit(params[@"limit"], 200, error) ||
            !RejectTrue(params[@"attachments"], @"attachments", error) ||
            !RejectTrue(params[@"convert_attachments"], @"convert_attachments", error) ||
            !RejectTrue(params[@"include_reactions"], @"include_reactions", error)) {
            if (*error == nil) {
                *error = BridgeError(400, @"messages.after needs a non-negative since_rowid");
            }
            return nil;
        }
        if (params[@"chat_id"] != nil) {
            NSInteger chatID = 0;
            if (!IsInteger(params[@"chat_id"], YES, &chatID)) {
                *error = BridgeError(400, @"chat_id must be positive");
                return nil;
            }
        }
        params[@"attachments"] = @NO;
        params[@"convert_attachments"] = @NO;
        params[@"include_reactions"] = @NO;
    } else if ([method isEqualToString:@"send"]) {
        if (!RequireOnly(params, @[@"to", @"text", @"service", @"region", @"chat_id", @"chat_identifier", @"chat_guid"],
                         error)) {
            return nil;
        }
        NSString *text = [params[@"text"] isKindOfClass:NSString.class] ? params[@"text"] : nil;
        if (text.length == 0 || text.length > 4000) {
            *error = BridgeError(400, @"send needs text containing 1-4000 characters");
            return nil;
        }
        NSString *target = SendTarget(params, error);
        if (target == nil) {
            return nil;
        }
        if (!allowEveryTarget && ![allowedTargets containsObject:target]) {
            *error = BridgeError(403, @"send target is not allowed");
            return nil;
        }
        if (params[@"service"] != nil && ![params[@"service"] isKindOfClass:NSString.class]) {
            *error = BridgeError(400, @"service must be a string");
            return nil;
        }
        NSString *service = [params[@"service"] lowercaseString];
        if (service != nil && ![@[@"auto", @"imessage", @"sms"] containsObject:service]) {
            *error = BridgeError(400, @"service must be auto, imessage, or sms");
            return nil;
        }
        if (service != nil) {
            params[@"service"] = service;
        }
        if (params[@"region"] != nil &&
            (![params[@"region"] isKindOfClass:NSString.class] || [params[@"region"] length] > 16)) {
            *error = BridgeError(400, @"region must be a string no longer than 16 characters");
            return nil;
        }
        params[@"transport"] = @"applescript";
    } else if ([method isEqualToString:@"message.send_status"]) {
        if (!RequireOnly(params, @[@"guid"], error)) {
            return nil;
        }
        NSString *guid = [params[@"guid"] isKindOfClass:NSString.class] ? params[@"guid"] : nil;
        if (guid.length == 0 || guid.length > 256) {
            *error = BridgeError(400, @"message.send_status needs a valid guid");
            return nil;
        }
    } else {
        *error = BridgeError(403, @"JSON-RPC method is not allowed");
        return nil;
    }

    object[@"params"] = params;
    if (methodOut != NULL) {
        *methodOut = method;
    }
    return [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:error];
}

static NSData *BuildSipgateSendRPC(NSData *data, NSString **methodOut, NSError **error) {
    if (data.length == 0 || data.length > MaxRequestBytes) {
        *error = BridgeError(400, @"invalid Sipgate SMS request");
        return nil;
    }
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![parsed isKindOfClass:NSDictionary.class]) {
        *error = BridgeError(400, @"Sipgate SMS body must be a JSON object");
        return nil;
    }
    NSDictionary *object = parsed;
    if (!RequireOnly(object, @[@"smsId", @"recipient", @"message", @"sendAt"], error)) {
        return nil;
    }

    NSString *smsID = [object[@"smsId"] isKindOfClass:NSString.class] ? object[@"smsId"] : nil;
    NSString *recipient = [object[@"recipient"] isKindOfClass:NSString.class] ? object[@"recipient"] : nil;
    NSString *message = [object[@"message"] isKindOfClass:NSString.class] ? object[@"message"] : nil;
    if (smsID.length == 0 || smsID.length > 64) {
        *error = BridgeError(400, @"smsId must be a non-empty string no longer than 64 characters");
        return nil;
    }
    if (recipient.length == 0 || recipient.length > 256) {
        *error = BridgeError(400, @"recipient must be a non-empty string no longer than 256 characters");
        return nil;
    }
    if (message.length == 0 || message.length > 460) {
        *error = BridgeError(400, @"message must contain 1-460 characters");
        return nil;
    }
    if (!allowEveryTarget && ![allowedTargets containsObject:recipient]) {
        *error = BridgeError(403, @"recipient is not allowed");
        return nil;
    }

    id sendAt = object[@"sendAt"];
    if (sendAt != nil) {
        BOOL isBoolean =
            [sendAt isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)sendAt) == CFBooleanGetTypeID();
        if (![sendAt isKindOfClass:NSNumber.class] || isBoolean || [sendAt doubleValue] != -1.0) {
            *error = BridgeError(400, @"scheduled sendAt is unsupported; omit it or use -1 for immediate delivery");
            return nil;
        }
    }

    NSDictionary *rpc = @{
        @"jsonrpc": @"2.0",
        @"id": @"sipgate-sms",
        @"method": @"send",
        @"params": @{@"to": recipient, @"text": message, @"service": @"imessage", @"transport": @"applescript"}
    };
    if (methodOut != NULL) {
        *methodOut = @"sipgate.sms.send";
    }
    return [NSJSONSerialization dataWithJSONObject:rpc options:NSJSONWritingSortedKeys error:error];
}

static NSData *ReadPipeLimited(NSFileHandle *handle, NSUInteger limit, BOOL *exceeded, BOOL *failed) {
    NSMutableData *collected = [NSMutableData data];
    @try {
        while (YES) {
            @autoreleasepool {
                NSData *chunk = [handle readDataOfLength:64 * 1024];
                if (chunk.length == 0) {
                    break;
                }
                NSUInteger capacity = limit + 1;
                if (collected.length < capacity) {
                    NSUInteger remaining = capacity - collected.length;
                    NSUInteger accepted = remaining < chunk.length ? remaining : chunk.length;
                    [collected appendBytes:chunk.bytes length:accepted];
                }
                if (collected.length > limit || chunk.length > limit) {
                    *exceeded = YES;
                }
            }
        }
    } @catch (NSException *exception) {
        (void)exception;
        *failed = YES;
    }
    return collected;
}

static BOOL ValidRPCResponse(NSData *candidate, id expectedID) {
    id parsed = [NSJSONSerialization JSONObjectWithData:candidate options:0 error:nil];
    if (![parsed isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    NSDictionary *object = parsed;
    BOOL hasResult = object[@"result"] != nil;
    BOOL hasError = object[@"error"] != nil;
    return [object[@"jsonrpc"] isEqual:@"2.0"] && [object[@"id"] isEqual:expectedID] && hasResult != hasError;
}

static void CloseFileHandle(NSFileHandle *handle) {
    @try {
        [handle closeFile];
    } @catch (NSException *exception) {
        (void)exception;
    }
}

static NSData *RunRPC(NSData *request, NSError **error) {
    NSDictionary *requestObject = [NSJSONSerialization JSONObjectWithData:request options:0 error:nil];
    id expectedID = [requestObject isKindOfClass:NSDictionary.class] ? requestObject[@"id"] : nil;
    if (!ValidJSONRPCID(expectedID)) {
        *error = BridgeError(500, @"internal JSON-RPC request has an invalid id");
        return nil;
    }

    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:imsgPath];
    task.arguments = @[@"rpc"];

    NSPipe *input = [NSPipe pipe];
    NSPipe *output = [NSPipe pipe];
    NSPipe *diagnostics = [NSPipe pipe];
    task.standardInput = input;
    task.standardOutput = output;
    task.standardError = diagnostics;

    dispatch_semaphore_t terminated = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *finished) {
        (void)finished;
        dispatch_semaphore_signal(terminated);
    };

    if (![task launchAndReturnError:error]) {
        return nil;
    }
    pid_t taskPID = task.processIdentifier;
    BOOL isolatedProcessGroup = setpgid(taskPID, taskPID) == 0 || getpgid(taskPID) == taskPID;

    __block NSData *stdoutData;
    __block BOOL stdoutExceeded = NO;
    __block BOOL stdoutFailed = NO;
    __block BOOL stderrExceeded = NO;
    __block BOOL stderrFailed = NO;
    __block BOOL writeFailed = NO;
    dispatch_group_t io = dispatch_group_create();
    dispatch_queue_t utility = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_group_async(io, utility, ^{
        stdoutData = ReadPipeLimited(output.fileHandleForReading, MaxRPCResponseBytes, &stdoutExceeded, &stdoutFailed);
    });
    dispatch_group_async(io, utility, ^{
        (void)ReadPipeLimited(diagnostics.fileHandleForReading, MaxRPCDiagnosticBytes, &stderrExceeded, &stderrFailed);
    });
    dispatch_group_async(io, utility, ^{
        @try {
            [input.fileHandleForWriting writeData:request];
            [input.fileHandleForWriting writeData:[NSData dataWithBytes:"\n" length:1]];
        } @catch (NSException *exception) {
            (void)exception;
            writeFailed = YES;
        } @finally {
            CloseFileHandle(input.fileHandleForWriting);
        }
    });

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(rpcTimeout * NSEC_PER_SEC));
    BOOL timedOut = NO;
    if (dispatch_semaphore_wait(terminated, deadline) != 0) {
        timedOut = YES;
        kill(isolatedProcessGroup ? -taskPID : taskPID, SIGTERM);
        if (dispatch_semaphore_wait(terminated, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0) {
            kill(isolatedProcessGroup ? -taskPID : taskPID, SIGKILL);
            (void)dispatch_semaphore_wait(terminated, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        }
    }

    if (dispatch_group_wait(io, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0) {
        if (isolatedProcessGroup) {
            kill(-taskPID, SIGKILL);
        }
        CloseFileHandle(input.fileHandleForWriting);
        CloseFileHandle(output.fileHandleForReading);
        CloseFileHandle(diagnostics.fileHandleForReading);
        if (dispatch_group_wait(io, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0) {
            *error = BridgeError(502, @"imsg RPC pipes did not close cleanly");
            return nil;
        }
    }

    if (timedOut) {
        *error = BridgeError(504, @"imsg RPC timed out");
        return nil;
    }

    if (writeFailed || stdoutFailed || stderrFailed) {
        *error = BridgeError(502, @"imsg RPC pipe failed");
        return nil;
    }
    if (stdoutExceeded || stdoutData.length > MaxRPCResponseBytes) {
        *error = BridgeError(502, @"imsg RPC response exceeded the size limit");
        return nil;
    }
    if (stderrExceeded) {
        fprintf(stderr, "stella-bridge: imsg diagnostics exceeded the size limit\n");
    }
    if (task.terminationStatus != 0) {
        fprintf(stderr, "stella-bridge: imsg exited status=%d\n", task.terminationStatus);
        *error = BridgeError(502, @"imsg RPC failed");
        return nil;
    }

    NSString *outputText =
        StringOrFallback([[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding], @"");
    for (NSString *line in [outputText componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSData *candidate = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (candidate.length > 0 && ValidRPCResponse(candidate, expectedID)) {
            return candidate;
        }
    }
    *error = BridgeError(502, @"imsg RPC returned no JSON response");
    return nil;
}

static NSString *SanitizeCaller(NSString *caller) {
    if (caller.length == 0) {
        return @"unknown";
    }
    NSCharacterSet *allowed = [NSCharacterSet
        characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    NSMutableString *value = [NSMutableString string];
    for (NSUInteger index = 0; index < caller.length && value.length < 64; index++) {
        unichar character = [caller characterAtIndex:index];
        if ([allowed characterIsMember:character]) {
            [value appendFormat:@"%C", character];
        }
    }
    return value.length == 0 ? @"unknown" : value;
}

static BOOL IsJSONContentType(NSString *value) {
    if (value.length == 0) {
        return NO;
    }
    NSString *mediaType = Trim([[value componentsSeparatedByString:@";"] firstObject]).lowercaseString;
    return [mediaType isEqualToString:@"application/json"];
}

static void Audit(NSString *caller, NSString *method, NSInteger status, NSDate *started) {
    NSInteger milliseconds = (NSInteger)(-[started timeIntervalSinceNow] * 1000);
    fprintf(stderr, "stella-bridge: caller=%s method=%s status=%ld duration_ms=%ld\n", caller.UTF8String,
            method.UTF8String, (long)status, (long)milliseconds);
}

static NSDictionary *ReadRequest(int clientFD, NSError **error) {
    NSMutableData *received = [NSMutableData data];
    NSData *marker = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange headerEnd = NSMakeRange(NSNotFound, 0);
    while (headerEnd.location == NSNotFound) {
        if (received.length >= MaxHeaderBytes) {
            *error = BridgeError(431, @"request headers are too large");
            return nil;
        }
        uint8_t buffer[4096];
        ssize_t count = recv(clientFD, buffer, sizeof(buffer), 0);
        if (count <= 0) {
            *error =
                BridgeError(errno == EAGAIN || errno == EWOULDBLOCK ? 408 : 400,
                            errno == EAGAIN || errno == EWOULDBLOCK ? @"request timed out" : @"incomplete request");
            return nil;
        }
        [received appendBytes:buffer length:(NSUInteger)count];
        headerEnd = [received rangeOfData:marker options:0 range:NSMakeRange(0, received.length)];
    }
    if (headerEnd.location > MaxHeaderBytes) {
        *error = BridgeError(431, @"request headers are too large");
        return nil;
    }

    NSString *headerText = [[NSString alloc] initWithData:[received subdataWithRange:NSMakeRange(0, headerEnd.location)]
                                                 encoding:NSUTF8StringEncoding];
    if (headerText == nil) {
        *error = BridgeError(400, @"invalid request headers");
        return nil;
    }
    NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *requestParts =
        [lines.firstObject componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in requestParts) {
        if (part.length > 0) {
            [parts addObject:part];
        }
    }
    if (parts.count != 3) {
        *error = BridgeError(400, @"invalid request line");
        return nil;
    }
    if (![@[@"HTTP/1.0", @"HTTP/1.1"] containsObject:parts[2]]) {
        *error = BridgeError(400, @"unsupported HTTP version");
        return nil;
    }

    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    for (NSUInteger index = 1; index < lines.count; index++) {
        NSString *line = lines[index];
        NSRange separator = [line rangeOfString:@":"];
        if (separator.location == NSNotFound) {
            *error = BridgeError(400, @"invalid request header");
            return nil;
        }
        NSString *name = [Trim([line substringToIndex:separator.location]) lowercaseString];
        NSString *value = Trim([line substringFromIndex:NSMaxRange(separator)]);
        if (name.length == 0 || headers[name] != nil) {
            *error = BridgeError(400, @"invalid or duplicate request header");
            return nil;
        }
        headers[name] = value;
    }
    if (headers[@"transfer-encoding"] != nil) {
        *error = BridgeError(400, @"chunked requests are not supported");
        return nil;
    }
    NSString *authorization = headers[@"authorization"];
    if (![authorization hasPrefix:@"Bearer "] ||
        !ConstantTimeEqual([authorization substringFromIndex:7], bridgeToken)) {
        *error = BridgeError(401, @"unauthorized");
        return nil;
    }
    NSString *lengthText = StringOrFallback(headers[@"content-length"], @"0");
    NSCharacterSet *nonDigits = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
    if (lengthText.length == 0 || [lengthText rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        *error = BridgeError(400, @"invalid Content-Length");
        return nil;
    }
    unsigned long long parsedLength = lengthText.longLongValue;
    if (parsedLength > MaxRequestBytes) {
        *error = BridgeError(413, @"request body is too large");
        return nil;
    }
    NSUInteger contentLength = (NSUInteger)parsedLength;

    NSUInteger bodyStart = NSMaxRange(headerEnd);
    NSUInteger required = bodyStart + contentLength;
    while (received.length < required) {
        uint8_t buffer[4096];
        NSUInteger remaining = required - received.length;
        size_t readLength = sizeof(buffer) < remaining ? sizeof(buffer) : (size_t)remaining;
        ssize_t count = recv(clientFD, buffer, readLength, 0);
        if (count <= 0) {
            *error = BridgeError(errno == EAGAIN || errno == EWOULDBLOCK ? 408 : 400,
                                 errno == EAGAIN || errno == EWOULDBLOCK ? @"request timed out"
                                                                         : @"incomplete request body");
            return nil;
        }
        [received appendBytes:buffer length:(NSUInteger)count];
    }

    NSString *path = parts[1];
    if ([path containsString:@"?"]) {
        *error = BridgeError(400, @"query strings are not accepted");
        return nil;
    }
    return @{
        @"method": [parts[0] uppercaseString],
        @"path": path,
        @"headers": headers,
        @"body": [received subdataWithRange:NSMakeRange(bodyStart, contentLength)]
    };
}

static NSData *JSONData(NSDictionary *object) {
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    return encoded != nil ? encoded : [NSData data];
}

static NSDictionary *RouteRequest(NSDictionary *request, NSError **error) {
    NSDictionary *headers = request[@"headers"];
    NSString *authorization = headers[@"authorization"];
    if (![authorization hasPrefix:@"Bearer "] ||
        !ConstantTimeEqual([authorization substringFromIndex:7], bridgeToken)) {
        *error = BridgeError(401, @"unauthorized");
        return nil;
    }

    NSString *method = request[@"method"];
    NSString *path = request[@"path"];
    NSString *caller = SanitizeCaller(headers[@"x-api-client"]);
    NSDate *started = [NSDate date];

    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/healthz"]) {
        NSDictionary *health =
            @{@"jsonrpc": @"2.0",
              @"id": @"health",
              @"method": @"chats.list",
              @"params": @{@"limit": @1}};
        NSData *response = RunRPC(JSONData(health), error);
        NSDictionary *rpcResponse =
            response == nil ? nil : [NSJSONSerialization JSONObjectWithData:response options:0 error:nil];
        NSDictionary *result = [rpcResponse[@"result"] isKindOfClass:NSDictionary.class] ? rpcResponse[@"result"] : nil;
        if (response == nil || ![rpcResponse isKindOfClass:NSDictionary.class] || result == nil ||
            ![result[@"chats"] isKindOfClass:NSArray.class]) {
            if (*error == nil) {
                *error = BridgeError(503, @"imsg is unavailable");
            }
            return nil;
        }
        Audit(caller, @"health", 200, started);
        return @{@"status": @200, @"body": JSONData(@{@"status": @"ok", @"version": BridgeVersion})};
    }

    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/v1/rpc"]) {
        if (!IsJSONContentType(headers[@"content-type"])) {
            *error = BridgeError(415, @"Content-Type must be application/json");
            Audit(caller, @"rpc.rejected", 415, started);
            return nil;
        }
        NSString *rpcMethod = nil;
        NSData *sanitized = ValidateAndSanitizeRPC(request[@"body"], &rpcMethod, error);
        if (sanitized == nil) {
            Audit(caller, StringOrFallback(rpcMethod, @"rejected"), (*error).code, started);
            return nil;
        }
        NSData *response = RunRPC(sanitized, error);
        if (response == nil) {
            Audit(caller, rpcMethod, (*error).code, started);
            return nil;
        }
        Audit(caller, rpcMethod, 200, started);
        return @{@"status": @200, @"body": response};
    }

    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/v2/sessions/sms"]) {
        if (!IsJSONContentType(headers[@"content-type"])) {
            *error = BridgeError(415, @"Content-Type must be application/json");
            Audit(caller, @"sipgate.sms.rejected", 415, started);
            return nil;
        }
        NSString *auditMethod = nil;
        NSData *sanitized = BuildSipgateSendRPC(request[@"body"], &auditMethod, error);
        if (sanitized == nil) {
            Audit(caller, StringOrFallback(auditMethod, @"sipgate.sms.rejected"), (*error).code, started);
            return nil;
        }
        NSData *response = RunRPC(sanitized, error);
        NSDictionary *rpcResponse =
            response == nil ? nil : [NSJSONSerialization JSONObjectWithData:response options:0 error:nil];
        NSDictionary *result = [rpcResponse[@"result"] isKindOfClass:NSDictionary.class] ? rpcResponse[@"result"] : nil;
        BOOL ok = [result[@"ok"] isKindOfClass:NSNumber.class] &&
                  CFGetTypeID((__bridge CFTypeRef)result[@"ok"]) == CFBooleanGetTypeID() && [result[@"ok"] boolValue];
        if (response == nil || ![rpcResponse isKindOfClass:NSDictionary.class] || !ok) {
            if (*error == nil) {
                *error = BridgeError(502, @"iMessage send failed");
            }
            Audit(caller, auditMethod, (*error).code, started);
            return nil;
        }
        Audit(caller, auditMethod, 204, started);
        return @{@"status": @204, @"body": [NSData data]};
    }

    *error = BridgeError(404, @"not found");
    return nil;
}

static NSString *ReasonPhrase(NSInteger status) {
    switch (status) {
    case 200:
        return @"OK";
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
    case 408:
        return @"Request Timeout";
    case 413:
        return @"Payload Too Large";
    case 415:
        return @"Unsupported Media Type";
    case 431:
        return @"Request Header Fields Too Large";
    case 502:
        return @"Bad Gateway";
    case 503:
        return @"Service Unavailable";
    case 504:
        return @"Gateway Timeout";
    default:
        return @"Internal Server Error";
    }
}

static void WriteAll(int fileDescriptor, NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSUInteger written = 0;
    while (written < data.length) {
        ssize_t count = write(fileDescriptor, bytes + written, data.length - written);
        if (count <= 0) {
            return;
        }
        written += (NSUInteger)count;
    }
}

static void WriteResponse(int clientFD, NSInteger status, NSData *body) {
    NSString *contentType = body.length > 0 ? @"Content-Type: application/json\r\n" : @"";
    NSString *headers =
        [NSString stringWithFormat:@"HTTP/1.1 %ld %@\r\n"
                                    "%@"
                                    "Content-Length: %lu\r\n"
                                    "Cache-Control: no-store\r\n"
                                    "Connection: close\r\n\r\n",
                                   (long)status, ReasonPhrase(status), contentType, (unsigned long)body.length];
    WriteAll(clientFD, [headers dataUsingEncoding:NSUTF8StringEncoding]);
    WriteAll(clientFD, body);
}

static int64_t MonotonicMilliseconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return -1;
    }
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static void RejectOverloadedClient(int clientFD) {
    WriteResponse(clientFD, 503, JSONData(@{@"error": @"too many concurrent requests"}));
    (void)shutdown(clientFD, SHUT_WR);

    int flags = fcntl(clientFD, F_GETFL);
    if (flags < 0 || fcntl(clientFD, F_SETFL, flags | O_NONBLOCK) != 0) {
        close(clientFD);
        return;
    }
    int64_t started = MonotonicMilliseconds();
    if (started < 0) {
        close(clientFD);
        return;
    }
    int64_t deadline = started + 250;
    NSUInteger drained = 0;
    uint8_t discarded[4096];
    while (drained < MaxHeaderBytes + MaxRequestBytes) {
        NSUInteger remaining = MaxHeaderBytes + MaxRequestBytes - drained;
        size_t readLength = sizeof(discarded) < remaining ? sizeof(discarded) : (size_t)remaining;
        ssize_t count = recv(clientFD, discarded, readLength, 0);
        if (count > 0) {
            drained += (NSUInteger)count;
            continue;
        }
        if (count == 0) {
            break;
        }
        int receiveError = errno;
        if (receiveError == EINTR) {
            continue;
        }
        if (receiveError != EAGAIN && receiveError != EWOULDBLOCK) {
            break;
        }
        struct pollfd readable = {
            .fd = clientFD,
            .events = POLLIN,
            .revents = 0,
        };
        int ready = -1;
        while (ready < 0) {
            int64_t now = MonotonicMilliseconds();
            if (now < 0 || now >= deadline) {
                break;
            }
            ready = poll(&readable, 1, (int)(deadline - now));
            if (ready < 0 && errno != EINTR) {
                break;
            }
        }
        if (ready <= 0) {
            break;
        }
    }
    close(clientFD);
}

static void HandleClient(int clientFD) {
    @autoreleasepool {
        NSError *error = nil;
        NSDictionary *request = ReadRequest(clientFD, &error);
        NSDictionary *response = request == nil ? nil : RouteRequest(request, &error);
        if (response == nil) {
            NSInteger status = error.code >= 400 && error.code <= 599 ? error.code : 500;
            WriteResponse(
                clientFD, status,
                JSONData(@{@"error": StringOrFallback(error.localizedDescription, @"internal bridge error")}));
        } else {
            WriteResponse(clientFD, [response[@"status"] integerValue], response[@"body"]);
        }
        close(clientFD);
    }
}

static BOOL ConfigureClientSocket(int clientFD) {
    struct timeval timeout = {
        .tv_sec = (time_t)socketTimeout,
        .tv_usec = 0,
    };
    if (setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0 ||
        setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) != 0) {
        return NO;
    }
    int flags = fcntl(clientFD, F_GETFD);
    return flags >= 0 && fcntl(clientFD, F_SETFD, flags | FD_CLOEXEC) == 0;
}

static BOOL RunServer(NSError **error) {
    signal(SIGPIPE, SIG_IGN);
    int serverFD = socket(AF_INET, SOCK_STREAM, 0);
    if (serverFD < 0) {
        *error = BridgeError(500, @"cannot create listening socket");
        return NO;
    }
    int reuse = 1;
    setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    int serverFlags = fcntl(serverFD, F_GETFD);
    if (serverFlags < 0 || fcntl(serverFD, F_SETFD, serverFlags | FD_CLOEXEC) != 0) {
        close(serverFD);
        *error = BridgeError(500, @"cannot secure listening socket");
        return NO;
    }

    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(bridgePort);
    address.sin_addr.s_addr = inet_addr("127.0.0.1");
    if (bind(serverFD, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(serverFD);
        *error = BridgeError(500, [NSString stringWithFormat:@"cannot bind 127.0.0.1:%u", bridgePort]);
        return NO;
    }
    if (listen(serverFD, 32) != 0) {
        close(serverFD);
        *error = BridgeError(500, @"cannot listen on configured port");
        return NO;
    }

    fprintf(stderr, "stella-bridge %s listening on 127.0.0.1:%u\n", BridgeVersion.UTF8String, bridgePort);
    dispatch_queue_t clients =
        dispatch_queue_create("io.github.mglaeser.stella.bridge.clients", DISPATCH_QUEUE_CONCURRENT);
    dispatch_queue_t rejections =
        dispatch_queue_create("io.github.mglaeser.stella.bridge.rejections", DISPATCH_QUEUE_CONCURRENT);
    dispatch_semaphore_t clientSlots = dispatch_semaphore_create((long)maxConcurrentRequests);
    dispatch_semaphore_t rejectionSlots = dispatch_semaphore_create(1);
    while (YES) {
        int clientFD = accept(serverFD, NULL, NULL);
        if (clientFD < 0) {
            if (errno == EINTR) {
                continue;
            }
            close(serverFD);
            *error = BridgeError(500, @"accept failed");
            return NO;
        }
        if (!ConfigureClientSocket(clientFD)) {
            close(clientFD);
            continue;
        }
        if (dispatch_semaphore_wait(clientSlots, DISPATCH_TIME_NOW) != 0) {
            if (dispatch_semaphore_wait(rejectionSlots, DISPATCH_TIME_NOW) != 0) {
                close(clientFD);
                continue;
            }
            dispatch_async(rejections, ^{
                @autoreleasepool {
                    @try {
                        RejectOverloadedClient(clientFD);
                    } @finally {
                        dispatch_semaphore_signal(rejectionSlots);
                    }
                }
            });
            continue;
        }
        dispatch_async(clients, ^{
            @try {
                HandleClient(clientFD);
            } @finally {
                dispatch_semaphore_signal(clientSlots);
            }
        });
    }
}

static void Usage(void) {
    puts("Usage: stella-bridge serve | check-config | version\n\n"
         "Environment:\n"
         "  IMESSAGE_BRIDGE_PORT\n"
         "  IMESSAGE_BRIDGE_TOKEN_FILE\n"
         "  IMESSAGE_ALLOWED_TARGETS_FILE\n"
         "  IMSG_BIN\n"
         "  IMESSAGE_RPC_TIMEOUT_SECONDS\n"
         "  STELLA_BRIDGE_MAX_CONCURRENCY\n"
         "  STELLA_BRIDGE_SOCKET_TIMEOUT_SECONDS");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *command = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
        if ([command isEqualToString:@"version"] && argc == 2) {
            puts(BridgeVersion.UTF8String);
            return 0;
        }
        if (argc != 2 || (![command isEqualToString:@"serve"] && ![command isEqualToString:@"check-config"])) {
            Usage();
            return 64;
        }

        NSError *error = nil;
        if (!LoadConfiguration(&error)) {
            fprintf(stderr, "ERROR: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        if ([command isEqualToString:@"check-config"]) {
            puts("configuration ok");
            return 0;
        }
        if (!RunServer(&error)) {
            fprintf(stderr, "ERROR: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
    }
    return 0;
}
