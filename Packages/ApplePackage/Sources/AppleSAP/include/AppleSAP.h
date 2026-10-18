#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface APSAPOperation : NSObject
- (void)cancel;
@end

/// Signs the exact bytes locally. iOS uses the source-built TCI interpreter;
/// macOS uses CommerceKit. Cancellation and completion are exactly once.
FOUNDATION_EXPORT APSAPOperation *APSAPSignData(
    NSData *data,
    NSData * _Nullable hardwareID,
    NSString * _Nullable cacheDirectory,
    void (^ _Nullable progress)(NSInteger stage),
    void (^completion)(NSData * _Nullable signature, NSError * _Nullable error)
);

NS_ASSUME_NONNULL_END
