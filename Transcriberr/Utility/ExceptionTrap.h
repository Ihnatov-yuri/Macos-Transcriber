#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Obj-C @try/@catch shim so Swift code can survive NSException-based
/// failures from AVFoundation (`AVAudioEngine.prepare()`,
/// `inputNode.outputFormat`, etc.). Swift's native `do/catch` does NOT
/// catch NSException; without this wrapper, a thrown NSException calls
/// `abort()` and the app dies with SIGABRT — which is exactly what
/// Transcriberr was doing when the record button was pressed.
@interface ExceptionTrap : NSObject
/// Bridges an NSException raised inside `block` to a Swift `throws`.
/// Calling pattern from Swift:
///     try ExceptionTrap.runBlock { engine.prepare() }
+ (BOOL)runBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
