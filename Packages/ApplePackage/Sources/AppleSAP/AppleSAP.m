#import "AppleSAP.h"
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

// Runtime interfaces, not hard-coded function addresses. Sources and limitations:
// ../../SAP-AUTHENTICATION.md. Check every selector before calling private APIs.
@interface APSAPMobileContext : NSObject
- (instancetype)initWithSAPVersion:(long long)version;
- (NSData *)exchangeData:(NSData *)data error:(NSError **)error;
- (BOOL)isComplete;
- (NSData *)signData:(NSData *)data error:(NSError **)error;
@end

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

// A timeout can race with the native callback. Keeping completion ownership in a
// locked object guarantees exactly one Swift continuation resume. A late native
// result is discarded; its session still follows the normal cleanup path.
@interface APSAPCompletion : NSObject
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, copy) void (^callback)(NSData *, NSError *);
- (void)finish:(NSData *)signature error:(NSError *)error;
@end

@implementation APSAPCompletion
- (void)finish:(NSData *)signature error:(NSError *)error {
    [self.lock lock];
    void (^callback)(NSData *, NSError *) = self.callback;
    self.callback = nil;
    [self.lock unlock];
    if (callback) callback(signature, error);
}
@end

static NSData *APSAPNativeSign(NSData *data, NSData *certificate, APSAPSetupExchange exchange,
                              NSError **error, NSString **stage) {
#if TARGET_OS_OSX
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
#elif TARGET_OS_IOS && !TARGET_OS_SIMULATOR
    *stage = @"iOS.load";
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices", RTLD_LAZY | RTLD_LOCAL);
    });
    Class cls = handle ? NSClassFromString(@"SSVFairPlaySAPContext") : Nil;
    if (!cls || ![cls instancesRespondToSelector:@selector(initWithSAPVersion:)] ||
        ![cls instancesRespondToSelector:@selector(exchangeData:error:)] ||
        ![cls instancesRespondToSelector:@selector(isComplete)] ||
        ![cls instancesRespondToSelector:@selector(signData:error:)]) {
        *error = APSAPError(@"Apple SAP signing is unavailable on this iOS version. Login requires a supported physical device.");
        return nil;
    }
    *stage = @"iOS.certificate";
    if (![certificate isKindOfClass:[NSData class]] || certificate.length == 0 || !exchange) {
        *error = APSAPError(@"Apple SAP setup is missing its certificate or exchange handler.");
        return nil;
    }
    *stage = @"iOS.context-init";
    // StoreServices uses enum 0 for wire version 200 (enum 1 selects 210).
    // ARC owns teardown through SSVFairPlaySAPContext's dealloc implementation.
    APSAPMobileContext *context = [(APSAPMobileContext *)[cls alloc] initWithSAPVersion:0];
    if (!context) {
        *error = APSAPError(@"Could not create the Apple SAP signing context.");
        return nil;
    }
    *stage = @"iOS.exchange-request";
    NSData *request = [context exchangeData:certificate error:error];
    if (*error || ![request isKindOfClass:[NSData class]] || request.length == 0 || [context isComplete]) {
        if (!*error) *error = APSAPError(@"Apple SAP did not enter its setup-request state.");
        return nil;
    }
    *stage = @"iOS.setup-request";
    dispatch_semaphore_t received = dispatch_semaphore_create(0);
    __block NSData *reply = nil;
    __block NSError *exchangeError = nil;
    APSAPCompletion *setupResult = [APSAPCompletion new];
    setupResult.lock = [NSLock new];
    setupResult.callback = ^(NSData *value, NSError *failure) {
        reply = value;
        exchangeError = failure;
        dispatch_semaphore_signal(received);
    };
    exchange(request, ^(NSData *value, NSError *failure) {
        [setupResult finish:value error:failure];
    });
    if (dispatch_semaphore_wait(received, dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC)) != 0) {
        *error = APSAPError(@"Apple SAP setup did not reply before its deadline.");
        return nil;
    }
    if (exchangeError || ![reply isKindOfClass:[NSData class]] || reply.length == 0) {
        *error = exchangeError ?: APSAPError(@"Apple SAP setup returned an empty reply.");
        return nil;
    }
    *stage = @"iOS.exchange-response";
    // A successful final exchange may have no output bytes. Completion, rather
    // than the returned buffer, decides whether the signing context is ready.
    [context exchangeData:reply error:error];
    if (*error || ![context isComplete]) {
        if (!*error) *error = APSAPError(@"Apple SAP did not complete its setup exchange.");
        return nil;
    }
    *stage = @"iOS.sign";
    return [context signData:data error:error];
#else
    *error = APSAPError(@"Apple SAP signing requires a physical iOS device or macOS.");
    return nil;
#endif
}

void APSAPSignData(NSData *data, NSData *certificate, APSAPSetupExchange exchange,
                  void (^completion)(NSData *, NSError *)) {
    // A system call cannot safely be killed after timeout. Bound outstanding
    // native work so repeated retries cannot accumulate stuck worker threads.
    static dispatch_semaphore_t capacity;
    static dispatch_once_t capacityOnce;
    dispatch_once(&capacityOnce, ^{ capacity = dispatch_semaphore_create(2); });
    if (dispatch_semaphore_wait(capacity, DISPATCH_TIME_NOW) != 0) {
        completion(nil, APSAPOperationError(@"native.capacity", nil));
        return;
    }
    APSAPCompletion *result = [APSAPCompletion new];
    result.lock = [NSLock new];
    result.callback = completion;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [result finish:nil error:APSAPOperationError(@"native.timeout", nil)];
    });
    // Never block the main actor. Each operation owns its session, so simultaneous
    // accounts cannot share signing state or strand one another behind a timeout.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *stage = @"native.sign";
            @try {
                NSError *error = nil;
                NSData *signature = APSAPNativeSign(data, certificate, exchange, &error, &stage);
                if (error || ![signature isKindOfClass:[NSData class]] || signature.length == 0) {
                    // Swift extracts only stage/domain/code. Keep the original
                    // error internally, never its description or request data.
                    [result finish:nil error:APSAPOperationError(stage, error)];
                } else {
                    [result finish:signature error:nil];
                }
            } @catch (NSException *exception) {
                [result finish:nil error:APSAPOperationError(stage,
                    APSAPError(@"The system Apple SAP signing interface is incompatible with this OS version."))];
            } @finally {
                dispatch_semaphore_signal(capacity);
            }
        }
    });
}
