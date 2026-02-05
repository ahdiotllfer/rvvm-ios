#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void RV64SmokeTest(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_BEGIN

extern NSString * const RV64RunnerUARTTextNotification;
extern NSString * const RV64RunnerUARTTextKey;

@interface RV64Runner : NSObject
+ (void)startLinux;
+ (void)requestRestart;
+ (BOOL)saveSnapshot:(NSString * _Nullable * _Nullable)errorOut;
+ (BOOL)loadSnapshot:(NSString * _Nullable * _Nullable)errorOut;
+ (void)sendConsoleBytes:(NSData * _Nullable)data;
+ (void)sendConsoleText:(NSString * _Nullable)text;
@end

NS_ASSUME_NONNULL_END
