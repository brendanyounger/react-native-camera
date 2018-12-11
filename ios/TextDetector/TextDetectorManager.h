#import <React/RCTComponent.h>

#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
#import <GoogleMobileVision/GoogleMobileVision.h>

@interface TextDetectorManager : NSObject

- (instancetype)init;

-(BOOL)isRealDetector;
-(void)findTextBlocksInFrame:(UIImage*)image  semaphore:(dispatch_semaphore_t)sema callback:(RCTDirectEventBlock)cb;

@end
#endif
