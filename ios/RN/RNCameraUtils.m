//
//  RNCameraUtils.m
//  RCTCamera
//
//  Created by Joao Guilherme Daros Fidelis on 19/01/18.
//

#import "RNCameraUtils.h"
#import <VideoToolbox/VideoToolbox.h>

@implementation RNCameraUtils

# pragma mark - Camera utilities

+ (AVCaptureDevice *)deviceWithMediaType:(AVMediaType)mediaType preferringPosition:(AVCaptureDevicePosition)position
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:mediaType];
    AVCaptureDevice *captureDevice = [devices firstObject];
    
    for (AVCaptureDevice *device in devices) {
        if ([device position] == position) {
            captureDevice = device;
            break;
        }
    }
    
    return captureDevice;
}

# pragma mark - Enum conversion

+ (AVCaptureVideoOrientation)videoOrientationForInterfaceOrientation:(UIInterfaceOrientation)orientation
{
    switch (orientation) {
        case UIInterfaceOrientationPortrait:
            return AVCaptureVideoOrientationPortrait;
        case UIInterfaceOrientationPortraitUpsideDown:
            return AVCaptureVideoOrientationPortraitUpsideDown;
        case UIInterfaceOrientationLandscapeRight:
            return AVCaptureVideoOrientationLandscapeRight;
        case UIInterfaceOrientationLandscapeLeft:
            return AVCaptureVideoOrientationLandscapeLeft;
        default:
            return 0;
    }
}

+ (AVCaptureVideoOrientation)videoOrientationForDeviceOrientation:(UIDeviceOrientation)orientation
{
    switch (orientation) {
        case UIDeviceOrientationPortrait:
            return AVCaptureVideoOrientationPortrait;
        case UIDeviceOrientationPortraitUpsideDown:
            return AVCaptureVideoOrientationPortraitUpsideDown;
        case UIDeviceOrientationLandscapeLeft:
            return AVCaptureVideoOrientationLandscapeRight;
        case UIDeviceOrientationLandscapeRight:
            return AVCaptureVideoOrientationLandscapeLeft;
        default:
            return AVCaptureVideoOrientationPortrait;
    }
}

+ (float)temperatureForWhiteBalance:(RNCameraWhiteBalance)whiteBalance
{
    switch (whiteBalance) {
        case RNCameraWhiteBalanceSunny: default:
            return 5200;
        case RNCameraWhiteBalanceCloudy:
            return 6000;
        case RNCameraWhiteBalanceShadow:
            return 7000;
        case RNCameraWhiteBalanceIncandescent:
            return 3000;
        case RNCameraWhiteBalanceFluorescent:
            return 4200;
    }
}

+ (NSString *)captureSessionPresetForVideoResolution:(RNCameraVideoResolution)resolution
{
    switch (resolution) {
        case RNCameraVideo2160p:
            return AVCaptureSessionPreset3840x2160;
        case RNCameraVideo1080p:
            return AVCaptureSessionPreset1920x1080;
        case RNCameraVideo720p:
            return AVCaptureSessionPreset1280x720;
        case RNCameraVideo4x3:
            return AVCaptureSessionPreset640x480;
        case RNCameraVideo288p:
            return AVCaptureSessionPreset352x288;
        default:
            return AVCaptureSessionPresetHigh;
    }
}

//+ (UIImage * _Nullable)imageWithSampleBuffer:(CMSampleBufferRef _Nonnull)sampleBuffer {
//    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
//    CIImage *image = [CIImage imageWithCVPixelBuffer:imageBuffer];
//    // OSStatus createdImage = VTCreateCGImageFromCVPixelBuffer(imageBuffer, NULL, &image);
//
//    UIDeviceOrientation curOrientation = UIDevice.currentDevice.orientation;
//    UIImageOrientation imageOrientation;
//
//    if (curOrientation == UIDeviceOrientationLandscapeLeft) {
//        imageOrientation = UIImageOrientationUp;
//    } else if (curOrientation == UIDeviceOrientationLandscapeRight) {
//        imageOrientation = UIImageOrientationDown;
//    } else if (curOrientation == UIDeviceOrientationPortrait) {
//        imageOrientation = UIImageOrientationRight;
//    } else if (curOrientation == UIDeviceOrientationPortraitUpsideDown) {
//        imageOrientation = UIImageOrientationLeft;
//    } else {
//        imageOrientation = UIImageOrientationUp;
//    }
//
//    return [UIImage imageWithCIImage:image scale:1.0 orientation:imageOrientation];
//    // return [UIImage imageWithCGImage:image];
//}

// also does not work. MLKit completely ignores orientation of the bytes
+ (UIImage * _Nullable)imageWithSampleBuffer:(CMSampleBufferRef _Nonnull)sampleBuffer {
    UIImage *returnValue = nil;
    UIDeviceOrientation curOrientation = UIDevice.currentDevice.orientation;
    UIImageOrientation imageOrientation;

    if (curOrientation == UIDeviceOrientationLandscapeLeft) {
        imageOrientation = UIImageOrientationUp;
    } else if (curOrientation == UIDeviceOrientationLandscapeRight) {
        imageOrientation = UIImageOrientationDown;
    } else if (curOrientation == UIDeviceOrientationPortrait) {
        imageOrientation = UIImageOrientationRight;
    } else if (curOrientation == UIDeviceOrientationPortraitUpsideDown) {
        imageOrientation = UIImageOrientationLeft;
    } else {
        imageOrientation = UIImageOrientationRight;
    }
    
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferLockBaseAddress(imageBuffer, 0); {
        void *baseAddress = CVPixelBufferGetBaseAddress(imageBuffer);
        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
        size_t width = CVPixelBufferGetWidth(imageBuffer);
        size_t height = CVPixelBufferGetHeight(imageBuffer);
        
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(baseAddress, width, height, 8, bytesPerRow, colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        CGImageRef quartzImage = CGBitmapContextCreateImage(context);
        
        returnValue = [UIImage imageWithCGImage:quartzImage scale:1.0 orientation:imageOrientation];
        
        CGImageRelease(quartzImage);
        CGContextRelease(context);
        CGColorSpaceRelease(colorSpace);
    } CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
    
    return returnValue;
}

+ (UIImage *)convertBufferToUIImage:(CMSampleBufferRef)sampleBuffer previewSize:(CGSize)previewSize {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
    UIDeviceOrientation curOrientation = UIDevice.currentDevice.orientation;
    
    // if these are on the back, do we change the orientation?
//    typedef CF_ENUM(uint32_t, CGImagePropertyOrientation) {
//        kCGImagePropertyOrientationUp = 1,        // 0th row at top,    0th column on left   - default orientation
//        kCGImagePropertyOrientationUpMirrored,    // 0th row at top,    0th column on right  - horizontal flip
//        kCGImagePropertyOrientationDown,          // 0th row at bottom, 0th column on right  - 180 deg rotation
//        kCGImagePropertyOrientationDownMirrored,  // 0th row at bottom, 0th column on left   - vertical flip
//        kCGImagePropertyOrientationLeftMirrored,  // 0th row on left,   0th column at top
//        kCGImagePropertyOrientationRight,         // 0th row on right,  0th column at top    - 90 deg CW
//        kCGImagePropertyOrientationRightMirrored, // 0th row on right,  0th column on bottom
//        kCGImagePropertyOrientationLeft           // 0th row on left,   0th column at bottom - 90 deg CCW
//    };
    
//    typedef NS_ENUM(NSInteger, UIDeviceOrientation) {
//        UIDeviceOrientationUnknown,
//        UIDeviceOrientationPortrait,            // Device oriented vertically, home button on the bottom
//        UIDeviceOrientationPortraitUpsideDown,  // Device oriented vertically, home button on the top
//        UIDeviceOrientationLandscapeLeft,       // Device oriented horizontally, home button on the right
//        UIDeviceOrientationLandscapeRight,      // Device oriented horizontally, home button on the left
//        UIDeviceOrientationFaceUp,              // Device oriented flat, face up
//        UIDeviceOrientationFaceDown             // Device oriented flat, face down
//    } __TVOS_PROHIBITED;
    
    if (curOrientation == UIDeviceOrientationLandscapeLeft) {
        ciImage = [ciImage imageByApplyingOrientation:1];
    } else if (curOrientation == UIDeviceOrientationLandscapeRight) {
        ciImage = [ciImage imageByApplyingOrientation:3];
    } else if (curOrientation == UIDeviceOrientationPortrait) {
        ciImage = [ciImage imageByApplyingOrientation:6];
    } else if (curOrientation == UIDeviceOrientationPortraitUpsideDown) {
        ciImage = [ciImage imageByApplyingOrientation:8];
    }
    
    float bufferWidth = CVPixelBufferGetWidth(imageBuffer);
    float bufferHeight = CVPixelBufferGetHeight(imageBuffer);
    
    // scale down CIImage
    float scale = bufferHeight > bufferWidth ? 1024 / bufferWidth : 1024 / bufferHeight;
    CIFilter* scaleFilter = [CIFilter filterWithName:@"CILanczosScaleTransform"];
    [scaleFilter setValue:ciImage forKey:kCIInputImageKey];
    [scaleFilter setValue:@(scale) forKey:kCIInputScaleKey];
    [scaleFilter setValue:@(1) forKey:kCIInputAspectRatioKey];
    ciImage = scaleFilter.outputImage;
    
    // convert to UIImage and crop to preview aspect ratio
    NSDictionary *contextOptions = @{kCIContextUseSoftwareRenderer : @(false)};
    CIContext *temporaryContext = [CIContext contextWithOptions:contextOptions];
    CGImageRef videoImage;
    CGRect boundingRect;
    
    if (curOrientation == UIDeviceOrientationLandscapeLeft || curOrientation == UIDeviceOrientationLandscapeRight) {
        boundingRect = CGRectMake(0, 0, bufferWidth*scale, bufferHeight*scale);
    } else {
        boundingRect = CGRectMake(0, 0, bufferHeight*scale, bufferWidth*scale);
    }
    
    videoImage = [temporaryContext createCGImage:ciImage fromRect:boundingRect];
    CGRect croppedSize = AVMakeRectWithAspectRatioInsideRect(previewSize, boundingRect);
    CGImageRef croppedCGImage = CGImageCreateWithImageInRect(videoImage, croppedSize);
    UIImage *image = [[UIImage alloc] initWithCGImage:croppedCGImage];
    CGImageRelease(videoImage);
    CGImageRelease(croppedCGImage);
    return image;
}

@end

