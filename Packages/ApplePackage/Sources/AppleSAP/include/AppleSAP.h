#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Signs the exact request bytes locally using the operating system's SAP implementation.
/// The completion runs once, including when the system service times out.
FOUNDATION_EXPORT void APSAPSignData(
    NSData *data,
    NSDictionary<NSString *, id> *URLBag,
    void (^completion)(NSData * _Nullable signature, NSError * _Nullable error)
);

NS_ASSUME_NONNULL_END
