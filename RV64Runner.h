#import <Foundation/Foundation.h>
#import <stdint.h>

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
extern NSString * const RV64RunnerVirtioFSDebugNotification;
extern NSString * const RV64RunnerFramebufferNotification;
extern NSString * const RV64RunnerFramebufferDataKey;
extern NSString * const RV64RunnerFramebufferWidthKey;
extern NSString * const RV64RunnerFramebufferHeightKey;
extern NSString * const RV64RunnerFramebufferStrideKey;
extern NSString * const RV64RunnerFramebufferFormatKey;

@interface RV64Runner : NSObject
+ (void)startLinux;
+ (void)requestRestart;
+ (BOOL)saveSnapshot:(NSString * _Nullable * _Nullable)errorOut;
+ (BOOL)loadSnapshot:(NSString * _Nullable * _Nullable)errorOut;
+ (BOOL)reinitNetwork:(NSString * _Nullable * _Nullable)errorOut;
+ (void)sendConsoleBytes:(NSData * _Nullable)data;
+ (void)sendConsoleText:(NSString * _Nullable)text;
+ (uint32_t)framebufferSeq;
+ (void)framebufferMetaWidth:(uint32_t * _Nullable)widthOut
                      height:(uint32_t * _Nullable)heightOut
                      stride:(uint32_t * _Nullable)strideOut
                      format:(uint32_t * _Nullable)formatOut
                      offset:(uint32_t * _Nullable)offsetOut;
+ (BOOL)copyFramebufferBGRA:(NSMutableData *)outData
                    width:(NSUInteger * _Nullable)widthOut
                   height:(NSUInteger * _Nullable)heightOut
              bytesPerRow:(NSUInteger * _Nullable)bytesPerRowOut;
+ (void)sendVirtioText:(NSString * _Nullable)text;
+ (void)sendVirtioText:(NSString * _Nullable)text
                 ctrl:(BOOL)ctrl
                  alt:(BOOL)alt;
+ (void)sendVirtioKey:(uint8_t)hidKey
               shift:(BOOL)shift
                ctrl:(BOOL)ctrl
                 alt:(BOOL)alt;
+ (void)sendVirtioMouseDeltaX:(int32_t)dx deltaY:(int32_t)dy;
+ (void)setVirtioMouseResolutionWidth:(uint32_t)width height:(uint32_t)height;
+ (void)sendVirtioMouseAbsX:(int32_t)x absY:(int32_t)y;
+ (void)sendVirtioMouseButtons:(uint8_t)btnMask down:(BOOL)down;
+ (void)sendVirtioMouseScroll:(int32_t)offset;
+ (void)setVirtioFSDebugToUARTEnabled:(BOOL)enabled;
+ (NSArray<NSString *> *)virtioFSDebugLines;
+ (void)clearVirtioFSDebug;
@end

NS_ASSUME_NONNULL_END
