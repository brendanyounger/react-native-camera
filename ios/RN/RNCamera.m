#import "RNCamera.h"
#import "RNCameraUtils.h"
#import "RNImageUtils.h"
#import "RNFileSystem.h"
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>
#import <React/UIView+React.h>
#import "RNSensorOrientationChecker.h"
#import <FirebaseMLVision/FirebaseMLVision.h>

@interface RNCamera ()

@property (nonatomic, weak) RCTBridge* bridge;
@property (nonatomic, strong) RNSensorOrientationChecker* sensorOrientationChecker;
@property (nonatomic, assign, getter=isSessionPaused) BOOL paused;

@property (nonatomic, strong) RCTPromiseResolveBlock videoRecordedResolve;
@property (nonatomic, strong) RCTPromiseRejectBlock videoRecordedReject;
@property (nonatomic, strong) id faceDetectorManager;
@property (nonatomic, strong) FIRVisionTextRecognizer* textDetector;
@property (nonatomic, strong) FIRVisionBarcodeDetector* barcodeDetector;

@property (nonatomic, copy) RCTDirectEventBlock onCameraReady;
@property (nonatomic, copy) RCTDirectEventBlock onMountError;
@property (nonatomic, copy) RCTDirectEventBlock onBarCodeRead;
@property (nonatomic, copy) RCTDirectEventBlock onTextRecognized;
@property (nonatomic, copy) RCTDirectEventBlock onFacesDetected;
@property (nonatomic, copy) RCTDirectEventBlock onPictureSaved;
@property (atomic, strong) dispatch_semaphore_t textSemaphore;
@property (atomic, strong) dispatch_semaphore_t barcodeSemaphore;

@end

@implementation RNCamera

static NSDictionary *defaultFaceDetectorOptions = nil;

- (id)initWithBridge:(RCTBridge *)bridge
{
    if ((self = [super init])) {
        self.bridge = bridge;
        self.session = [AVCaptureSession new];
        self.sessionQueue = dispatch_queue_create("cameraQueue", DISPATCH_QUEUE_SERIAL);
        self.sensorOrientationChecker = [RNSensorOrientationChecker new];
        
        self.textDetector = [[FIRVision vision] onDeviceTextRecognizer];
        self.textSemaphore = dispatch_semaphore_create(1);
        
        self.barcodeDetector = [[FIRVision vision] barcodeDetector];
        self.barcodeSemaphore = dispatch_semaphore_create(1);
        
#if !(TARGET_IPHONE_SIMULATOR)
        self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
        self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        self.previewLayer.needsDisplayOnBoundsChange = YES;
#endif
        
        self.paused = NO;
        [self changePreviewOrientation:[UIApplication sharedApplication].statusBarOrientation];
        [self initializeCaptureSessionInput];
        [self startSession];
        self.autoFocus = -1;
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(orientationChanged:)
                                                     name:UIDeviceOrientationDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)onReady:(NSDictionary *)event
{
    if (_onCameraReady) {
        _onCameraReady(nil);
    }
}

- (void)onMountingError:(NSDictionary *)event
{
    if (_onMountError) {
        _onMountError(event);
    }
}

- (void)onCodeRead:(NSDictionary *)event
{
    if (_onBarCodeRead) {
        _onBarCodeRead(event);
    }
}

- (void)onPictureSaved:(NSDictionary *)event
{
    if (_onPictureSaved) {
        _onPictureSaved(event);
    }
}

- (void)onText:(NSDictionary *)event
{
    if (_onTextRecognized) {
        _onTextRecognized(event);
    }
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    self.previewLayer.frame = self.bounds;
    [self setBackgroundColor:[UIColor blackColor]];
    [self.layer insertSublayer:self.previewLayer atIndex:0];
}

- (void)insertReactSubview:(UIView *)view atIndex:(NSInteger)atIndex
{
    [self insertSubview:view atIndex:atIndex + 1];
    [super insertReactSubview:view atIndex:atIndex];
    return;
}

- (void)removeReactSubview:(UIView *)subview
{
    [subview removeFromSuperview];
    [super removeReactSubview:subview];
    return;
}

- (void)removeFromSuperview
{
    [super removeFromSuperview];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIDeviceOrientationDidChangeNotification object:nil];
    [self stopSession];
}

-(void)updateType
{
    dispatch_async(self.sessionQueue, ^{
        [self initializeCaptureSessionInput];
        if (!self.session.isRunning) {
            [self startSession];
        }
    });
}

- (void)updateFlashMode
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (self.flashMode == RNCameraFlashModeTorch) {
        if (![device hasTorch])
            return;
        if (![device lockForConfiguration:&error]) {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
            return;
        }
        if (device.hasTorch && [device isTorchModeSupported:AVCaptureTorchModeOn])
        {
            NSError *error = nil;
            if ([device lockForConfiguration:&error]) {
                [device setFlashMode:AVCaptureFlashModeOff];
                [device setTorchMode:AVCaptureTorchModeOn];
                [device unlockForConfiguration];
            } else {
                if (error) {
                    RCTLogError(@"%s: %@", __func__, error);
                }
            }
        }
    } else {
        if (![device hasFlash])
            return;
        if (![device lockForConfiguration:&error]) {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
            return;
        }
        if (device.hasFlash && [device isFlashModeSupported:self.flashMode])
        {
            NSError *error = nil;
            if ([device lockForConfiguration:&error]) {
                if ([device isTorchActive]) {
                    [device setTorchMode:AVCaptureTorchModeOff];
                }
                [device setFlashMode:self.flashMode];
                [device unlockForConfiguration];
            } else {
                if (error) {
                    RCTLogError(@"%s: %@", __func__, error);
                }
            }
        }
    }

    [device unlockForConfiguration];
}

- (void)updateAutoFocusPointOfInterest
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    if ([self.autoFocusPointOfInterest objectForKey:@"x"] && [self.autoFocusPointOfInterest objectForKey:@"y"]) {
        float xValue = [self.autoFocusPointOfInterest[@"x"] floatValue];
        float yValue = [self.autoFocusPointOfInterest[@"y"] floatValue];
        if ([device isFocusPointOfInterestSupported] && [device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {

            CGPoint autofocusPoint = CGPointMake(xValue, yValue);
            [device setFocusPointOfInterest:autofocusPoint];
            [device setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
          }
        else {
            RCTLogWarn(@"AutoFocusPointOfInterest not supported");
        }
    }

    [device unlockForConfiguration];
}

- (void)updateFocusMode
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    if ([device isFocusModeSupported:self.autoFocus]) {
        if ([device lockForConfiguration:&error]) {
            [device setFocusMode:self.autoFocus];
        } else {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
        }
    }

    [device unlockForConfiguration];
}

- (void)updateFocusDepth
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (device == nil || self.autoFocus < 0 || device.focusMode != RNCameraAutoFocusOff || device.position == RNCameraTypeFront) {
        return;
    }

    if (@available(iOS 10.0, *)) {
        if (![device respondsToSelector:@selector(isLockingFocusWithCustomLensPositionSupported)] || ![device isLockingFocusWithCustomLensPositionSupported]) {
            RCTLogWarn(@"%s: Setting focusDepth isn't supported for this camera device", __func__);
            return;
        }
    } else {
        // Fallback on earlier versions
    }

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    __weak __typeof__(device) weakDevice = device;
    [device setFocusModeLockedWithLensPosition:self.focusDepth completionHandler:^(CMTime syncTime) {
        [weakDevice unlockForConfiguration];
    }];
}

- (void)updateZoom {
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    device.videoZoomFactor = (device.activeFormat.videoMaxZoomFactor - 1.0) * self.zoom + 1.0;

    [device unlockForConfiguration];
}

- (void)updateWhiteBalance {
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    if (self.whiteBalance == RNCameraWhiteBalanceAuto) {
        [device setWhiteBalanceMode:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance];
        [device unlockForConfiguration];
    } else {
        AVCaptureWhiteBalanceTemperatureAndTintValues temperatureAndTint = {
            .temperature = [RNCameraUtils temperatureForWhiteBalance:self.whiteBalance],
            .tint = 0,
        };
        AVCaptureWhiteBalanceGains rgbGains = [device deviceWhiteBalanceGainsForTemperatureAndTintValues:temperatureAndTint];
        __weak __typeof__(device) weakDevice = device;
        if ([device lockForConfiguration:&error]) {
            [device setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:rgbGains completionHandler:^(CMTime syncTime) {
                [weakDevice unlockForConfiguration];
            }];
        } else {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
        }
    }

    [device unlockForConfiguration];
}

- (void)updatePictureSize
{
    [self updateSessionPreset:self.pictureSize];
}

- (void)updateFaceDetecting:(id)faceDetecting
{
}

- (void)updateFaceDetectionMode:(id)requestedMode
{
}

- (void)updateFaceDetectionLandmarks:(id)requestedLandmarks
{
}

- (void)updateFaceDetectionClassifications:(id)requestedClassifications
{
}


- (void)takePictureWithOrientation:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject{
    [self.sensorOrientationChecker getDeviceOrientationWithBlock:^(UIInterfaceOrientation orientation) {
        NSMutableDictionary *tmpOptions = [options mutableCopy];
        if ([tmpOptions valueForKey:@"orientation"] == nil) {
            tmpOptions[@"orientation"] = [NSNumber numberWithInteger:[self.sensorOrientationChecker convertToAVCaptureVideoOrientation:orientation]];
        }
        self.deviceOrientation = [NSNumber numberWithInteger:orientation];
        self.orientation = [NSNumber numberWithInteger:[tmpOptions[@"orientation"] integerValue]];
        [self takePicture:tmpOptions resolve:resolve reject:reject];
    }];
}

- (void)takePicture:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
    if (!self.deviceOrientation) {
        [self takePictureWithOrientation:options resolve:resolve reject:reject];
        return;
    }

    NSInteger orientation = [options[@"orientation"] integerValue];

    AVCaptureConnection *connection = [self.stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
    [connection setVideoOrientation:orientation];
    [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:connection completionHandler:^(CMSampleBufferRef imageSampleBuffer, NSError *error) {
        if (imageSampleBuffer && !error) {
            if ([options[@"pauseAfterCapture"] boolValue]) {
                [[self.previewLayer connection] setEnabled:NO];
            }

            BOOL useFastMode = [options valueForKey:@"fastMode"] != nil && [options[@"fastMode"] boolValue];
            if (useFastMode) {
                resolve(nil);
            }
            NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageSampleBuffer];

            UIImage *takenImage = [UIImage imageWithData:imageData];

            CGImageRef takenCGImage = takenImage.CGImage;
            CGSize previewSize;
            if (UIInterfaceOrientationIsPortrait([[UIApplication sharedApplication] statusBarOrientation])) {
                previewSize = CGSizeMake(self.previewLayer.frame.size.height, self.previewLayer.frame.size.width);
            } else {
                previewSize = CGSizeMake(self.previewLayer.frame.size.width, self.previewLayer.frame.size.height);
            }
            CGRect cropRect = CGRectMake(0, 0, CGImageGetWidth(takenCGImage), CGImageGetHeight(takenCGImage));
            CGRect croppedSize = AVMakeRectWithAspectRatioInsideRect(previewSize, cropRect);
            takenImage = [RNImageUtils cropImage:takenImage toRect:croppedSize];

            if ([options[@"mirrorImage"] boolValue]) {
                takenImage = [RNImageUtils mirrorImage:takenImage];
            }
            if ([options[@"forceUpOrientation"] boolValue]) {
                takenImage = [RNImageUtils forceUpOrientation:takenImage];
            }

            if ([options[@"width"] integerValue]) {
                takenImage = [RNImageUtils scaleImage:takenImage toWidth:[options[@"width"] integerValue]];
            }

            NSMutableDictionary *response = [[NSMutableDictionary alloc] init];
            float quality = [options[@"quality"] floatValue];
            NSData *takenImageData = UIImageJPEGRepresentation(takenImage, quality);
            NSString *path = [RNFileSystem generatePathInDirectory:[[RNFileSystem cacheDirectoryPath] stringByAppendingPathComponent:@"Camera"] withExtension:@".jpg"];
            if (![options[@"doNotSave"] boolValue]) {
                response[@"uri"] = [RNImageUtils writeImage:takenImageData toPath:path];
            }
            response[@"width"] = @(takenImage.size.width);
            response[@"height"] = @(takenImage.size.height);

            if ([options[@"base64"] boolValue]) {
                response[@"base64"] = [takenImageData base64EncodedStringWithOptions:0];
            }

            if ([options[@"exif"] boolValue]) {
                int imageRotation;
                switch (takenImage.imageOrientation) {
                    case UIImageOrientationLeft:
                    case UIImageOrientationRightMirrored:
                        imageRotation = 90;
                        break;
                    case UIImageOrientationRight:
                    case UIImageOrientationLeftMirrored:
                        imageRotation = -90;
                        break;
                    case UIImageOrientationDown:
                    case UIImageOrientationDownMirrored:
                        imageRotation = 180;
                        break;
                    case UIImageOrientationUpMirrored:
                    default:
                        imageRotation = 0;
                        break;
                }
                [RNImageUtils updatePhotoMetadata:imageSampleBuffer withAdditionalData:@{ @"Orientation": @(imageRotation) } inResponse:response]; // TODO
            }

            response[@"pictureOrientation"] = @([self.orientation integerValue]);
            response[@"deviceOrientation"] = @([self.deviceOrientation integerValue]);
            self.orientation = nil;
            self.deviceOrientation = nil;

            if (useFastMode) {
                [self onPictureSaved:@{@"data": response, @"id": options[@"id"]}];
            } else {
                resolve(response);
            }
        } else {
            reject(@"E_IMAGE_CAPTURE_FAILED", @"Image could not be captured", error);
        }
    }];
}

- (void)recordWithOrientation:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject{
    [self.sensorOrientationChecker getDeviceOrientationWithBlock:^(UIInterfaceOrientation orientation) {
        NSMutableDictionary *tmpOptions = [options mutableCopy];
        if ([tmpOptions valueForKey:@"orientation"] == nil) {
            tmpOptions[@"orientation"] = [NSNumber numberWithInteger:[self.sensorOrientationChecker convertToAVCaptureVideoOrientation: orientation]];
        }
        self.deviceOrientation = [NSNumber numberWithInteger:orientation];
        self.orientation = [NSNumber numberWithInteger:[tmpOptions[@"orientation"] integerValue]];
        [self record:tmpOptions resolve:resolve reject:reject];
    }];
}

- (void)record:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
    if (!self.deviceOrientation) {
        [self recordWithOrientation:options resolve:resolve reject:reject];
        return;
    }

    NSInteger orientation = [options[@"orientation"] integerValue];

    if (_movieFileOutput == nil) {
        // At the time of writing AVCaptureMovieFileOutput and AVCaptureVideoDataOutput (> GMVDataOutput)
        // cannot coexist on the same AVSession (see: https://stackoverflow.com/a/4986032/1123156).
        // We stop face detection here and restart it in when AVCaptureMovieFileOutput finishes recording.
        [self stopTextRecognition];
        [self setupMovieFileCapture];
    }

    if (self.movieFileOutput == nil || self.movieFileOutput.isRecording || _videoRecordedResolve != nil || _videoRecordedReject != nil) {
      return;
    }

    if (options[@"maxDuration"]) {
        Float64 maxDuration = [options[@"maxDuration"] floatValue];
        self.movieFileOutput.maxRecordedDuration = CMTimeMakeWithSeconds(maxDuration, 30);
    }

    if (options[@"maxFileSize"]) {
        self.movieFileOutput.maxRecordedFileSize = [options[@"maxFileSize"] integerValue];
    }

    if (options[@"quality"]) {
        AVCaptureSessionPreset newQuality = [RNCameraUtils captureSessionPresetForVideoResolution:(RNCameraVideoResolution)[options[@"quality"] integerValue]];
        if (self.session.sessionPreset != newQuality) {
            [self updateSessionPreset:newQuality];
        }
    }

    if ([options valueForKey:@"mute"] != nil) {
        [self updateSessionAudioIsMuted:[options[@"mute"] boolValue]];
    }

    AVCaptureConnection *connection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
    if (self.videoStabilizationMode != 0) {
        if (connection.isVideoStabilizationSupported == NO) {
            RCTLogWarn(@"%s: Video Stabilization is not supported on this device.", __func__);
        } else {
            [connection setPreferredVideoStabilizationMode:self.videoStabilizationMode];
        }
    }
    [connection setVideoOrientation:orientation];

    if (options[@"codec"]) {
      if (@available(iOS 10, *)) {
        AVVideoCodecType videoCodecType = options[@"codec"];
        if ([self.movieFileOutput.availableVideoCodecTypes containsObject:videoCodecType]) {
          [self.movieFileOutput setOutputSettings:@{AVVideoCodecKey:videoCodecType} forConnection:connection];
          self.videoCodecType = videoCodecType;
        } else {
            RCTLogWarn(@"%s: Setting videoCodec is only supported above iOS version 10.", __func__);
        }
      }
    }

    dispatch_async(self.sessionQueue, ^{
        [self updateFlashMode];
        NSString *path = nil;
        if (options[@"path"]) {
            path = options[@"path"];
        }
        else {
            path = [RNFileSystem generatePathInDirectory:[[RNFileSystem cacheDirectoryPath] stringByAppendingPathComponent:@"Camera"] withExtension:@".mov"];
        }

        if ([options[@"mirrorVideo"] boolValue]) {
            if ([connection isVideoMirroringSupported]) {
                [connection setAutomaticallyAdjustsVideoMirroring:NO];
                [connection setVideoMirrored:YES];
            }
        }

        NSURL *outputURL = [[NSURL alloc] initFileURLWithPath:path];
        [self.movieFileOutput startRecordingToOutputFileURL:outputURL recordingDelegate:self];
        self.videoRecordedResolve = resolve;
        self.videoRecordedReject = reject;
    });
}

- (void)stopRecording {
    if ([self.movieFileOutput isRecording]) {
        [self.movieFileOutput stopRecording];
    }
}

- (void)resumePreview {
    [[self.previewLayer connection] setEnabled:YES];
}

- (void)pausePreview {
    [[self.previewLayer connection] setEnabled:NO];
}

- (void)startSession {
#if TARGET_IPHONE_SIMULATOR
    [self onReady:nil];
    return;
#endif
    //    NSDictionary *cameraPermissions = [EXCameraPermissionRequester permissions];
    //    if (![cameraPermissions[@"status"] isEqualToString:@"granted"]) {
    //        [self onMountingError:@{@"message": @"Camera permissions not granted - component could not be rendered."}];
    //        return;
    //    }
    
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    
    dispatch_async(self.sessionQueue, ^{
        if (self.presetCamera == AVCaptureDevicePositionUnspecified) {
            return;
        }

        // Default video quality AVCaptureSessionPresetHigh if non is provided
        AVCaptureSessionPreset preset = [self defaultVideoQuality] ?
            [RNCameraUtils captureSessionPresetForVideoResolution:[[self defaultVideoQuality] integerValue]] : AVCaptureSessionPresetHigh;

        self.session.sessionPreset = (preset == AVCaptureSessionPresetHigh ? AVCaptureSessionPresetPhoto : preset);

        AVCaptureStillImageOutput *stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
        if ([self.session canAddOutput:stillImageOutput]) {
            stillImageOutput.outputSettings = @{AVVideoCodecKey : AVVideoCodecJPEG};
            [self.session addOutput:stillImageOutput];
            [stillImageOutput setHighResolutionStillImageOutputEnabled:YES];
            self.stillImageOutput = stillImageOutput;
        }

        // If AVCaptureVideoDataOutput is not required because of Google Vision
        // (see comment in -record), we go ahead and add the AVCaptureMovieFileOutput
        // to avoid an exposure rack on some devices that can cause the first few
        // frames of the recorded output to be underexposed.
        // [self setupMovieFileCapture];
        [self setupOrDisableTextDetector];

        __weak RNCamera *weakSelf = self;
        [self setRuntimeErrorHandlingObserver:
         [NSNotificationCenter.defaultCenter addObserverForName:AVCaptureSessionRuntimeErrorNotification object:self.session queue:nil usingBlock:^(NSNotification *note) {
            RNCamera *strongSelf = weakSelf;
            dispatch_async(strongSelf.sessionQueue, ^{
                // Manually restarting the session since it must
                // have been stopped due to an error.
                [strongSelf.session startRunning];
                [strongSelf onReady:nil];
            });
        }]];

        [self.session startRunning];
        [self onReady:nil];
    });
}

- (void)stopSession
{
#if TARGET_IPHONE_SIMULATOR
    return;
#endif
    
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
    
    dispatch_async(self.sessionQueue, ^{
        [self.previewLayer removeFromSuperlayer];
        [self.session commitConfiguration];
        [self.session stopRunning];
        for (AVCaptureInput *input in self.session.inputs) {
            [self.session removeInput:input];
        }
        for (AVCaptureOutput *output in self.session.outputs) {
            [self.session removeOutput:output];
        }
    });
}

- (void)initializeCaptureSessionInput
{
    if (self.videoCaptureDeviceInput.device.position == self.presetCamera) {
        return;
    }
    __block UIInterfaceOrientation interfaceOrientation;

    void (^statusBlock)() = ^() {
        interfaceOrientation = [[UIApplication sharedApplication] statusBarOrientation];
    };
    
    if ([NSThread isMainThread]) {
        statusBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), statusBlock);
    }

    AVCaptureVideoOrientation orientation = [RNCameraUtils videoOrientationForInterfaceOrientation:interfaceOrientation];
    dispatch_async(self.sessionQueue, ^{
        [self.session beginConfiguration];

        NSError *error = nil;
        AVCaptureDevice *captureDevice = [RNCameraUtils deviceWithMediaType:AVMediaTypeVideo preferringPosition:self.presetCamera];
        AVCaptureDeviceInput *captureDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:captureDevice error:&error];

        if (error || captureDeviceInput == nil) {
            RCTLog(@"%s: %@", __func__, error);
            return;
        }

        [self.session removeInput:self.videoCaptureDeviceInput];
        if ([self.session canAddInput:captureDeviceInput]) {
            [self.session addInput:captureDeviceInput];

            self.videoCaptureDeviceInput = captureDeviceInput;
            [self updateFlashMode];
            [self updateZoom];
            [self updateFocusMode];
            [self updateFocusDepth];
            [self updateAutoFocusPointOfInterest];
            [self updateWhiteBalance];
            [self.previewLayer.connection setVideoOrientation:orientation];
            [self _updateMetadataObjectsToRecognize];
        }

        [self.session commitConfiguration];
    });
}

#pragma mark - internal

- (void)updateSessionPreset:(AVCaptureSessionPreset)preset
{
#if !(TARGET_IPHONE_SIMULATOR)
    if ([preset integerValue] < 0) {
        return;
    }
    if (preset) {
        if (self.isDetectingFaces && [preset isEqual:AVCaptureSessionPresetPhoto]) {
            RCTLog(@"AVCaptureSessionPresetPhoto not supported during face detection. Falling back to AVCaptureSessionPresetHigh");
            preset = AVCaptureSessionPresetHigh;
        }
        dispatch_async(self.sessionQueue, ^{
            [self.session beginConfiguration];
            if ([self.session canSetSessionPreset:preset]) {
                self.session.sessionPreset = preset;
            }
            [self.session commitConfiguration];
        });
    }
#endif
}

- (void)updateSessionAudioIsMuted:(BOOL)isMuted
{
    dispatch_async(self.sessionQueue, ^{
        [self.session beginConfiguration];

        for (AVCaptureDeviceInput* input in [self.session inputs]) {
            if ([input.device hasMediaType:AVMediaTypeAudio]) {
                if (isMuted) {
                    [self.session removeInput:input];
                }
                [self.session commitConfiguration];
                return;
            }
        }

        if (!isMuted) {
            NSError *error = nil;

            AVCaptureDevice *audioCaptureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
            AVCaptureDeviceInput *audioDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:audioCaptureDevice error:&error];

            if (error || audioDeviceInput == nil) {
                RCTLogWarn(@"%s: %@", __func__, error);
                return;
            }

            if ([self.session canAddInput:audioDeviceInput]) {
                [self.session addInput:audioDeviceInput];
            }
        }

        [self.session commitConfiguration];
    });
}

- (void)orientationChanged:(NSNotification *)notification {
    [self changePreviewOrientation:[[UIApplication sharedApplication] statusBarOrientation]];
}

- (void)changePreviewOrientation:(UIInterfaceOrientation)orientation {
    __weak typeof(self) weakSelf = self;
    // AVCaptureVideoOrientation videoOrientation = [RNCameraUtils videoOrientationForInterfaceOrientation:orientation];
    AVCaptureVideoOrientation videoOrientation = [RNCameraUtils videoOrientationForDeviceOrientation:UIDevice.currentDevice.orientation];
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf.previewLayer.connection.isVideoOrientationSupported) {
            [strongSelf.previewLayer.connection setVideoOrientation:videoOrientation];
        }
    });
}

# pragma mark - AVCaptureMetadataOutput

- (void)setupOrDisableBarcodeScanner
{
//    [self _setupOrDisableMetadataOutput];
//    [self _updateMetadataObjectsToRecognize];
}

- (void)_setupOrDisableMetadataOutput
{
    /*if ([self isReadingBarCodes] && (_metadataOutput == nil || ![self.session.outputs containsObject:_metadataOutput])) {
        AVCaptureMetadataOutput *metadataOutput = [[AVCaptureMetadataOutput alloc] init];
        if ([self.session canAddOutput:metadataOutput]) {
            [metadataOutput setMetadataObjectsDelegate:self queue:self.sessionQueue];
            [self.session addOutput:metadataOutput];
            self.metadataOutput = metadataOutput;
        }
    } else if (_metadataOutput != nil && ![self isReadingBarCodes]) {
        [self.session removeOutput:_metadataOutput];
        _metadataOutput = nil;
    }*/
}

- (void)_updateMetadataObjectsToRecognize
{
    /*if (_metadataOutput == nil) {
        return;
    }

    NSArray<AVMetadataObjectType> *availableRequestedObjectTypes = [[NSArray alloc] init];
    NSArray<AVMetadataObjectType> *requestedObjectTypes = [NSArray arrayWithArray:self.barCodeTypes];
    NSArray<AVMetadataObjectType> *availableObjectTypes = _metadataOutput.availableMetadataObjectTypes;

    for(AVMetadataObjectType objectType in requestedObjectTypes) {
        if ([availableObjectTypes containsObject:objectType]) {
            availableRequestedObjectTypes = [availableRequestedObjectTypes arrayByAddingObject:objectType];
        }
    }

    [_metadataOutput setMetadataObjectTypes:availableRequestedObjectTypes];*/
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputMetadataObjects:(NSArray *)metadataObjects
       fromConnection:(AVCaptureConnection *)connection
{
    /*for(AVMetadataObject *metadata in metadataObjects) {
        if([metadata isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) {
            AVMetadataMachineReadableCodeObject *codeMetadata = (AVMetadataMachineReadableCodeObject *) metadata;
            for (id barcodeType in self.barCodeTypes) {
                if ([metadata.type isEqualToString:barcodeType]) {
                    AVMetadataMachineReadableCodeObject *transformed = (AVMetadataMachineReadableCodeObject *)[_previewLayer transformedMetadataObjectForMetadataObject:metadata];
                    NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:@{
                        @"type" : codeMetadata.type,
                        @"data" : [NSNull null],
                        @"rawData" : [NSNull null],
                        @"bounds": @{
                            @"origin": @{
                                    @"x": [NSString stringWithFormat:@"%f", transformed.bounds.origin.x],
                                    @"y": [NSString stringWithFormat:@"%f", transformed.bounds.origin.y]
                                    },
                            @"size": @{
                                    @"height": [NSString stringWithFormat:@"%f", transformed.bounds.size.height],
                                    @"width": [NSString stringWithFormat:@"%f", transformed.bounds.size.width]
                                    }
                            }
                        }
                    ];

                    NSData *rawData;
                    // If we're on ios11 then we can use `descriptor` to access the raw data of the barcode.
                    // If we're on an older version of iOS we're stuck using valueForKeyPath to peek at the
                    // data.
                    if (@available(iOS 11, *)) {
                        // descriptor is a CIBarcodeDescriptor which is an abstract base class with no useful fields.
                        // in practice it's a subclass, many of which contain errorCorrectedPayload which is the data we
                        // want. Instead of individually checking the class types, just duck type errorCorrectedPayload
                        if ([codeMetadata.descriptor respondsToSelector:@selector(errorCorrectedPayload)]) {
                            rawData = [codeMetadata.descriptor performSelector:@selector(errorCorrectedPayload)];
                        }
                    } else {
                        rawData = [codeMetadata valueForKeyPath:@"_internal.basicDescriptor.BarcodeRawData"];
                    }

                    // Now that we have the raw data of the barcode translate it into a hex string to pass to the JS
                    const unsigned char *dataBuffer = (const unsigned char *)[rawData bytes];
                    if (dataBuffer) {
                        NSMutableString     *rawDataHexString  = [NSMutableString stringWithCapacity:([rawData length] * 2)];
                        for (int i = 0; i < [rawData length]; ++i) {
                            [rawDataHexString appendString:[NSString stringWithFormat:@"%02lx", (unsigned long)dataBuffer[i]]];
                        }
                        [event setObject:[NSString stringWithString:rawDataHexString] forKey:@"rawData"];
                    }

                    // If we were able to extract a string representation of the barcode, attach it to the event as well
                    // else just send null along.
                    if (codeMetadata.stringValue) {
                        [event setObject:codeMetadata.stringValue forKey:@"data"];
                    }

                    // Only send the event if we were able to pull out a binary or string representation
                    if ([event objectForKey:@"data"] != [NSNull null] || [event objectForKey:@"rawData"] != [NSNull null]) {
                        [self onCodeRead:event];
                    }
                }
            }
        }
    }*/
}

# pragma mark - AVCaptureMovieFileOutput

- (void)setupMovieFileCapture
{
    AVCaptureMovieFileOutput *movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];

    if ([self.session canAddOutput:movieFileOutput]) {
        [self.session addOutput:movieFileOutput];
        self.movieFileOutput = movieFileOutput;
    }
}

- (void)cleanupMovieFileCapture
{
    if ([_session.outputs containsObject:_movieFileOutput]) {
        [_session removeOutput:_movieFileOutput];
        _movieFileOutput = nil;
    }
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error
{
    BOOL success = YES;
    if ([error code] != noErr) {
        NSNumber *value = [[error userInfo] objectForKey:AVErrorRecordingSuccessfullyFinishedKey];
        if (value) {
            success = [value boolValue];
        }
    }
    if (success && self.videoRecordedResolve != nil) {
        NSMutableDictionary *result = [[NSMutableDictionary alloc] init];

        void (^resolveBlock)(void) = ^() {
            self.videoRecordedResolve(result);
        };
        
        result[@"uri"] = outputFileURL.absoluteString;
        result[@"videoOrientation"] = @([self.orientation integerValue]);
        result[@"deviceOrientation"] = @([self.deviceOrientation integerValue]);


        if (@available(iOS 10, *)) {
            AVVideoCodecType videoCodec = self.videoCodecType;
            if (videoCodec == nil) {
                videoCodec = [self.movieFileOutput.availableVideoCodecTypes firstObject];
            }
            result[@"codec"] = videoCodec;

            if ([connections[0] isVideoMirrored]) {
                [self mirrorVideo:outputFileURL completion:^(NSURL *mirroredURL) {
                    result[@"uri"] = mirroredURL.absoluteString;
                    resolveBlock();
                }];
                return;
            }
        }

        resolveBlock();
    } else if (self.videoRecordedReject != nil) {
        self.videoRecordedReject(@"E_RECORDING_FAILED", @"An error occurred while recording a video.", error);
    }

    [self cleanupCamera];

}

- (void)cleanupCamera {
    self.videoRecordedResolve = nil;
    self.videoRecordedReject = nil;
    self.videoCodecType = nil;
    self.deviceOrientation = nil;
    self.orientation = nil;

    [self cleanupMovieFileCapture];
    [self setupOrDisableTextDetector];

    AVCaptureSessionPreset preset = [RNCameraUtils captureSessionPresetForVideoResolution:[[self defaultVideoQuality] intValue]];
    if (self.session.sessionPreset != preset) {
        [self updateSessionPreset:(preset == AVCaptureSessionPresetHigh ? AVCaptureSessionPresetPhoto : preset)];
    }
}

- (void)mirrorVideo:(NSURL *)inputURL completion:(void (^)(NSURL* outputUR))completion {
    AVAsset* videoAsset = [AVAsset assetWithURL:inputURL];
    AVAssetTrack* clipVideoTrack = [[videoAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];

    AVMutableComposition* composition = [[AVMutableComposition alloc] init];
    [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];

    AVMutableVideoComposition* videoComposition = [[AVMutableVideoComposition alloc] init];
    videoComposition.renderSize = CGSizeMake(clipVideoTrack.naturalSize.height, clipVideoTrack.naturalSize.width);
    videoComposition.frameDuration = CMTimeMake(1, 30);

    AVMutableVideoCompositionLayerInstruction* transformer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:clipVideoTrack];

    AVMutableVideoCompositionInstruction* instruction = [[AVMutableVideoCompositionInstruction alloc] init];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(60, 30));

    CGAffineTransform transform = CGAffineTransformMakeScale(-1.0, 1.0);
    transform = CGAffineTransformTranslate(transform, -clipVideoTrack.naturalSize.width, 0);
    transform = CGAffineTransformRotate(transform, M_PI/2.0);
    transform = CGAffineTransformTranslate(transform, 0.0, -clipVideoTrack.naturalSize.width);

    [transformer setTransform:transform atTime:kCMTimeZero];

    [instruction setLayerInstructions:@[transformer]];
    [videoComposition setInstructions:@[instruction]];

    // Export
    AVAssetExportSession* exportSession = [AVAssetExportSession exportSessionWithAsset:videoAsset presetName:AVAssetExportPreset640x480];
    NSString* filePath = [RNFileSystem generatePathInDirectory:[[RNFileSystem cacheDirectoryPath] stringByAppendingString:@"CameraFlip"] withExtension:@".mp4"];
    NSURL* outputURL = [NSURL fileURLWithPath:filePath];
    [exportSession setOutputURL:outputURL];
    [exportSession setOutputFileType:AVFileTypeMPEG4];
    [exportSession setVideoComposition:videoComposition];
    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        if (exportSession.status == AVAssetExportSessionStatusCompleted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(outputURL);
            });
        } else {
            NSLog(@"Export failed %@", exportSession.error);
        }
    }];
}

# pragma mark - Face detector

- (void)onFacesDetected:(NSArray<NSDictionary *> *)faces
{
    if (_onFacesDetected) {
        _onFacesDetected(@{@"type": @"face",
                           @"faces": faces});
    }
}

# pragma mark - TextDetector

- (void)setupOrDisableTextDetector {
    if ([self canReadText] || [self isReadingBarCodes]) {
        [self setupTextDetector];
    } else {
        [self stopTextRecognition];
    }
}

- (void)setupTextDetector {
    if(nil == self.videoDataOutput) {
        self.videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
        if (![self.session canAddOutput:_videoDataOutput]) {
            RCTLogWarn(@"Failed to setup video data output");
            self.videoDataOutput = nil;
        } else {
            NSString *format = (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey;
            NSDictionary *rgbOutputSettings = @{ format: @(kCMPixelFormat_32BGRA) };
            [self.videoDataOutput setVideoSettings:rgbOutputSettings];
            [self.videoDataOutput setAlwaysDiscardsLateVideoFrames:YES];
            [self.videoDataOutput setSampleBufferDelegate:self queue:self.sessionQueue];
            [self.session addOutput:_videoDataOutput];
        }
    } else {
        RCTLogInfo(@"Already created text detector");
    }
}

- (void)stopTextRecognition {
    if ((nil != self.session) && (nil != self.videoDataOutput)) {
        [self.session removeOutput:self.videoDataOutput];
    }
    self.videoDataOutput = nil;
}

-(NSDictionary *)getImageBounds:(CGRect)bounds scaleX:(float)scaleX scaleY:(float)scaleY {
    float width = bounds.size.width * scaleX;
    float height = bounds.size.height * scaleY;
    float originX = bounds.origin.x * scaleX;
    float originY = bounds.origin.y * scaleY;
    NSDictionary *boundsDict = @{@"size": @{ @"width": @(width), @"height": @(height) }, @"origin": @{ @"x": @(originX), @"y": @(originY) }};
    return boundsDict;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    CGSize previewSize = _previewLayer.frame.size;
    UIImage *uiImage = [RNCameraUtils convertBufferToUIImage:sampleBuffer previewSize:previewSize];
    
    if(_onBarCodeRead && (uiImage != nil) && (0 == dispatch_semaphore_wait(self.barcodeSemaphore, dispatch_time(DISPATCH_TIME_NOW, 31250000)))) {
        FIRVisionImage *firImage = [[FIRVisionImage alloc] initWithImage:uiImage];
        
        [self.barcodeDetector detectInImage:firImage completion:^(NSArray<FIRVisionBarcode *> *barcodes, NSError *error) {
            dispatch_semaphore_signal(self.barcodeSemaphore);
            
            if (error != nil) {
                RCTLogWarn(@"Error! %@", error);
            } else if (barcodes != nil && barcodes.count > 0) {
                NSMutableArray* barcodeList = [[NSMutableArray alloc] init];
                
                for (FIRVisionBarcode *barcode in barcodes) {
                    NSString *displayValue = barcode.displayValue;
                    // NSString *rawValue = barcode.rawValue;
                    
                    [barcodeList addObject:displayValue];
                    
                    FIRVisionBarcodeValueType valueType = barcode.valueType;
                    switch (valueType) {
                        case FIRVisionBarcodeValueTypeWiFi:
                            // ssid = barcode.wifi.ssid;
                            // password = barcode.wifi.password;
                            // encryptionType = barcode.wifi.type;
                            break;
                        case FIRVisionBarcodeValueTypeURL:
                            // url = barcode.URL.url;
                            // title = barcode.URL.title;
                            break;
                        default:
                            break;
                    }
                }
                
                self.onBarCodeRead(@{@"type": @"BarcodeList",
                                     @"barcodes": barcodeList});
            }
        }];
    }
    
    if(_onTextRecognized && (uiImage != nil) && (0 == dispatch_semaphore_wait(self.textSemaphore, dispatch_time(DISPATCH_TIME_NOW, 31250000)))) {
        FIRVisionImage *firImage = [[FIRVisionImage alloc] initWithImage:uiImage];
        float scaleX = previewSize.width / uiImage.size.width;
        float scaleY = previewSize.height / uiImage.size.height;
        
        [self.textDetector processImage:firImage completion:^(FIRVisionText *_Nullable result, NSError *_Nullable error) {
            dispatch_semaphore_signal(self.textSemaphore);
            
            if (error != nil) {
                RCTLogWarn(@"Error! %@", error);
            } else if(result != nil) {
                NSMutableArray *textBlocks = [[NSMutableArray alloc] init];
                
                for (FIRVisionTextBlock *block in result.blocks) {
                    NSMutableArray *lineBlocks = [[NSMutableArray alloc] init];
                    
                    // RCTLogInfo(@"Block %@, %ld", block.text, UIDevice.currentDevice.orientation);
                    
                    for (FIRVisionTextLine *line in block.lines) {
                        NSMutableArray *elementBlocks = [[NSMutableArray alloc] init];
                        
                        for (FIRVisionTextElement *element in line.elements) {
                            [elementBlocks addObject:@{@"type": @"element",
                                                       @"value": element.text,
                                                       @"bounds": [self getImageBounds:element.frame scaleX:scaleX scaleY:scaleY]}];
                        }
                        
                        [lineBlocks addObject:@{@"type": @"line",
                                                @"value": line.text,
                                                @"bounds": [self getImageBounds:line.frame scaleX:scaleX scaleY:scaleY],
                                                @"components": elementBlocks}];
                    }
                    
                    [textBlocks addObject:@{@"type": @"block",
                                            @"value": block.text,
                                            @"bounds": [self getImageBounds:block.frame scaleX:scaleX scaleY:scaleY],
                                            @"components": lineBlocks}];
                }
                
                self.onTextRecognized(@{@"type": @"TextBlock",
                                        @"text": result.text,
                                        @"textBlocks": textBlocks});
            }
        }];
    }
}

- (bool)isRecording {
    return self.movieFileOutput.isRecording;
}

@end
