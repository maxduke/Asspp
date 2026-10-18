#import "AppleSAP.h"
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

// Runtime interfaces, not hard-coded function addresses. Sources and limitations:
// ../../SAP-AUTHENTICATION.md. Check every selector before calling private APIs.
@interface APSAPBagInterpreter : NSObject
- (NSURL *)mescalSetupURL;
- (NSURL *)mescalCertificateURL;
@end

@interface APSAPMobileSession : NSObject
- (instancetype)initWithURLBagDictionary:(NSDictionary *)bag SAPVersion:(long long)version;
- (NSData *)signatureWithData:(NSData *)data error:(NSError **)error;
- (long long)SAPVersion;
- (APSAPBagInterpreter *)urlBagInterpreter;
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

static NSData *APSAPNativeSign(NSData *data, NSDictionary *bag, NSError **error, NSString **stage) {
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
    Class cls = handle ? NSClassFromString(@"SSVFairPlaySAPSession") : Nil;
    if (!cls || ![cls instancesRespondToSelector:@selector(initWithURLBagDictionary:SAPVersion:)] ||
        ![cls instancesRespondToSelector:@selector(signatureWithData:error:)] ||
        ![cls instancesRespondToSelector:@selector(SAPVersion)] ||
        ![cls instancesRespondToSelector:@selector(urlBagInterpreter)]) {
        *error = APSAPError(@"Apple SAP signing is unavailable on this iOS version. Login requires a supported physical device.");
        return nil;
    }
    *stage = @"iOS.create-session";
    APSAPMobileSession *session = [(APSAPMobileSession *)[cls alloc] initWithURLBagDictionary:bag SAPVersion:200];
    if (!session) {
        *error = APSAPError(@"Could not create the Apple SAP signing session.");
        return nil;
    }
    *stage = @"iOS.validate-bag";
    APSAPBagInterpreter *interpreter = [session urlBagInterpreter];
    if ([session SAPVersion] != 200 ||
        ![interpreter respondsToSelector:@selector(mescalSetupURL)] ||
        ![interpreter respondsToSelector:@selector(mescalCertificateURL)] ||
        ![[interpreter mescalSetupURL].absoluteString isEqualToString:bag[@"sign-sap-setup"]] ||
        ![[interpreter mescalCertificateURL].absoluteString isEqualToString:bag[@"sign-sap-setup-cert"]]) {
        *error = APSAPError(@"The system SAP signer could not use the Apple Store signing configuration.");
        return nil;
    }
    *stage = @"iOS.sign";
    return [session signatureWithData:data error:error];
#else
    *error = APSAPError(@"Apple SAP signing requires a physical iOS device or macOS.");
    return nil;
#endif
}

void APSAPSignData(NSData *data, NSDictionary<NSString *, id> *URLBag,
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
                NSData *signature = APSAPNativeSign(data, URLBag, &error, &stage);
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
