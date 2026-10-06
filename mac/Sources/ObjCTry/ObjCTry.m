#import "ObjCTry.h"

BOOL FridayObjCTry(NS_NOESCAPE void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (error) {
            *error = [NSError errorWithDomain:@"FridayObjC" code:6
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""]}];
        }
        return NO;
    }
}
