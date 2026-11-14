#import "IronPetObjC.h"

BOOL IronPetCatchException(NS_NOESCAPE void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:@"IronPetObjCException"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason,
                                                @"name": exception.name}];
        }
        return NO;
    }
}
