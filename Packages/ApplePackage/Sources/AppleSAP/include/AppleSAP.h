#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Exchanges a SAP setup buffer with Apple's validated setup endpoint.
typedef void (^APSAPSetupExchange)(
    NSData *request,
    void (^reply)(NSData * _Nullable data, NSError * _Nullable error)
);

/// Signs the exact request bytes locally using the operating system's SAP implementation.
/// The completion runs once, including when the system service times out.
FOUNDATION_EXPORT void APSAPSignData(
    NSData *data,
    NSData * _Nullable certificate,
    APSAPSetupExchange _Nullable exchange,
    void (^completion)(NSData * _Nullable signature, NSError * _Nullable error)
);

NS_ASSUME_NONNULL_END
