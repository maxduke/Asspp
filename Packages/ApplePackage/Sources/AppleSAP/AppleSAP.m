#import "AppleSAP.h"
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#if TARGET_OS_IOS
#import "AssppSAPRuntime.h"
#endif

@interface APSAPDesktopSession : NSObject
- (instancetype)initWithStoreClient:(id)client;
- (void)openSessionWithCompletionHandler:(void (^)(void))completion;
- (BOOL)isSessionOpen;
- (NSData *)signData:(NSData *)data error:(NSError **)error;
- (void)closeSession;
@end

static NSError *APSAPError(NSString *message) {
    return [NSError errorWithDomain:@"ApplePackage.SAP" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSError *APSAPOperationError(NSString *stage, NSError *cause) {
    NSMutableDictionary *info = [@{
        NSLocalizedDescriptionKey: @"Apple SAP could not sign the login request.",
        @"ApplePackageSAPStage": stage,
    } mutableCopy];
    if (cause) info[NSUnderlyingErrorKey] = cause;
    return [NSError errorWithDomain:@"ApplePackage.SAP" code:2 userInfo:info];
}

@interface APSAPOperation ()
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, copy) void (^callback)(NSData *, NSError *);
@property(nonatomic, copy) void (^progress)(NSInteger);
@property(nonatomic) unsigned long long identifier;
@property(nonatomic) BOOL cancelled;
- (void)finish:(NSData *)signature error:(NSError *)error;
- (void)attach:(unsigned long long)identifier;
- (void)report:(NSInteger)stage;
@end

@implementation APSAPOperation
- (void)finish:(NSData *)signature error:(NSError *)error {
    [self.lock lock];
    void (^callback)(NSData *, NSError *) = self.callback;
    self.callback = nil;
    self.progress = nil;
    [self.lock unlock];
    if (callback) callback(signature, error);
}
- (void)cancel {
    [self.lock lock];
    self.cancelled = YES;
#if TARGET_OS_IOS
    unsigned long long identifier = self.identifier;
#endif
    [self.lock unlock];
#if TARGET_OS_IOS
    if (identifier) AssppSAPCancel(identifier);
#endif
    [self finish:nil error:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
}
- (void)attach:(unsigned long long)identifier {
    [self.lock lock];
    self.identifier = identifier;
#if TARGET_OS_IOS
    BOOL cancelled = self.cancelled;
#endif
    [self.lock unlock];
#if TARGET_OS_IOS
    if (cancelled && identifier) AssppSAPCancel(identifier);
#endif
}
- (void)report:(NSInteger)stage {
    [self.lock lock];
    void (^progress)(NSInteger) = self.progress;
    [self.lock unlock];
    if (progress) progress(stage);
}
@end

#if TARGET_OS_OSX
static NSData *APSAPDesktopSign(NSData *data, NSError **error, NSString **stage) {
    *stage = @"macOS.load";
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/CommerceKit.framework/CommerceKit", RTLD_LAZY | RTLD_LOCAL);
    });
    Class cls = handle ? NSClassFromString(@"CKSigningSession") : Nil;
    if (!cls || ![cls instancesRespondToSelector:@selector(initWithStoreClient:)] ||
        ![cls instancesRespondToSelector:@selector(openSessionWithCompletionHandler:)] ||
        ![cls instancesRespondToSelector:@selector(isSessionOpen)] ||
        ![cls instancesRespondToSelector:@selector(signData:error:)] ||
        ![cls instancesRespondToSelector:@selector(closeSession)]) {
        *error = APSAPError(@"Apple SAP signing is unavailable on this macOS version.");
        return nil;
    }
    *stage = @"macOS.create-session";
    APSAPDesktopSession *session = [(APSAPDesktopSession *)[cls alloc] initWithStoreClient:nil];
    if (!session) {
        *error = APSAPError(@"Could not create the Apple SAP signing session.");
        return nil;
    }
    @try {
        *stage = @"macOS.open-session";
        dispatch_semaphore_t opened = dispatch_semaphore_create(0);
        [session openSessionWithCompletionHandler:^{ dispatch_semaphore_signal(opened); }];
        if (dispatch_semaphore_wait(opened, dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC)) != 0 ||
            ![session isSessionOpen]) {
            *error = APSAPError(@"The Apple SAP signing service did not open a session. Try again later.");
            return nil;
        }
        *stage = @"macOS.sign";
        return [session signData:data error:error];
    } @finally {
        [session closeSession];
    }
}
#endif

#if TARGET_OS_IOS
static void APSAPRuntimeProgress(void *context, int stage) {
    APSAPOperation *operation = (__bridge APSAPOperation *)context;
    [operation report:stage];
}

static NSString *APSAPRuntimeStage(int stage) {
    switch (stage) {
        case 1: return @"iOS.runtime.assets";
        case 2: return @"iOS.runtime.load";
        case 3: return @"iOS.runtime.initialize";
        case 4: return @"iOS.runtime.certificate";
        case 5: return @"iOS.runtime.exchange-request";
        case 6: return @"iOS.runtime.setup";
        case 7: return @"iOS.runtime.exchange-response";
        case 8: return @"iOS.runtime.ready";
        case 9: return @"iOS.runtime.sign";
        case 11: return @"iOS.runtime.timeout";
        case 12: return @"iOS.runtime.input";
        case 13: return @"iOS.runtime.failure";
        case 14: return @"iOS.runtime.wait";
        default: return @"native.sign";
    }
}
#endif

APSAPOperation *APSAPSignData(NSData *data, NSData *hardwareID, NSString *cacheDirectory,
                             void (^progress)(NSInteger), void (^completion)(NSData *, NSError *)) {
    APSAPOperation *result = [APSAPOperation new];
    result.lock = [NSLock new];
    result.callback = completion;
    result.progress = progress;
    // Bound outstanding C workers, including cancelled native macOS calls.
    static dispatch_semaphore_t capacity;
    static dispatch_once_t capacityOnce;
    dispatch_once(&capacityOnce, ^{ capacity = dispatch_semaphore_create(2); });
    if (dispatch_semaphore_wait(capacity, DISPATCH_TIME_NOW) != 0) {
        [result finish:nil error:APSAPOperationError(@"native.capacity", nil)];
        return result;
    }
#if TARGET_OS_OSX
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [result finish:nil error:APSAPOperationError(@"native.timeout", nil)];
    });
#endif
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *stage = @"native.sign";
#if TARGET_OS_IOS
            unsigned char *output = NULL;
#endif
            @try {
#if TARGET_OS_IOS
                if (data.length == 0 || data.length > (1u << 20) || hardwareID.length == 0 ||
                    hardwareID.length > 20 || !cacheDirectory.isAbsolutePath) {
                    [result finish:nil error:APSAPOperationError(@"iOS.runtime.input", nil)];
                    return;
                }
                unsigned long long identifier = AssppSAPNewOperation();
                [result attach:identifier];
                int phase = 12, detail = 0, length = 0;
                int status = AssppSAPSign(identifier, (char *)cacheDirectory.fileSystemRepresentation,
                    (unsigned char *)hardwareID.bytes, (int)hardwareID.length,
                    (unsigned char *)data.bytes, (int)data.length, &output, &length, &phase, &detail,
                    APSAPRuntimeProgress, (__bridge void *)result);
                [result attach:0];
                stage = APSAPRuntimeStage(phase);
                if (phase == 10) {
                    [result cancel];
                } else if (status != 0 || !output || length <= 0 || length > (1 << 20)) {
                    NSError *cause = [NSError errorWithDomain:@"ApplePackage.SAP.Runtime" code:detail userInfo:nil];
                    [result finish:nil error:APSAPOperationError(stage, cause)];
                } else {
                    [result finish:[NSData dataWithBytes:output length:(NSUInteger)length] error:nil];
                }
#elif TARGET_OS_OSX
                NSError *error = nil;
                NSData *signature = APSAPDesktopSign(data, &error, &stage);
                if (error || ![signature isKindOfClass:[NSData class]] || signature.length == 0) {
                    [result finish:nil error:APSAPOperationError(stage, error)];
                } else {
                    [result finish:signature error:nil];
                }
#else
                [result finish:nil error:APSAPError(@"Apple SAP signing is unavailable on this platform.")];
#endif
            } @catch (NSException *exception) {
                [result finish:nil error:APSAPOperationError(stage,
                    APSAPError(@"Apple SAP signing could not complete."))];
            } @finally {
#if TARGET_OS_IOS
                AssppSAPFree(output);
#endif
                dispatch_semaphore_signal(capacity);
            }
        }
    });
    return result;
}
