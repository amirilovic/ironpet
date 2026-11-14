#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns YES. If it raises an NSException, returns NO and fills `error`.
/// Swift cannot catch NSExceptions, and AVAudioEngine raises them for a stale or mismatched format.
BOOL IronPetCatchException(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
