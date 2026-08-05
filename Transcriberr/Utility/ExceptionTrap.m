#import "ExceptionTrap.h"

@implementation ExceptionTrap

+ (BOOL)runBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError * _Nullable * _Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = e.reason ?: @"unknown NSException";
            info[@"name"] = e.name ?: @"";
            if (e.userInfo) {
                info[@"originalUserInfo"] = e.userInfo;
            }
            *error = [NSError errorWithDomain:@"nl.ihnatov.Transcriberr.NSException"
                                         code:0
                                     userInfo:info];
        }
        return NO;
    }
}

@end
