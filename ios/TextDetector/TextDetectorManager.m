#import <FirebaseMLVision/FirebaseMLVision.h>
#import <React/RCTLog.h>
#import "TextDetectorManager.h"

@interface TextDetectorManager ()
@property(nonatomic, strong) FIRVisionTextRecognizer* textDetector;
@property(nonatomic, assign) float scaleX;
@property(nonatomic, assign) float scaleY;
@end

@implementation TextDetectorManager

- (instancetype)init {
  if (self = [super init]) {
      self.textDetector = [[FIRVision vision] onDeviceTextRecognizer];
  }
  return self;
}

-(BOOL)isRealDetector {
  return true;
}

- (void)findTextBlocksInFrame:(UIImage*)uiImage semaphore:(dispatch_semaphore_t)sema callback:(RCTDirectEventBlock)cb {
    self.scaleX = 1;
    self.scaleY = 1;
    
    FIRVisionImage *firImage = [[FIRVisionImage alloc] initWithImage:uiImage];
    
    [self.textDetector processImage:firImage completion:^(FIRVisionText *_Nullable result, NSError *_Nullable error) {
        dispatch_semaphore_signal(sema);
        
        if (error != nil || result == nil) {
            if(error != nil) {
                RCTLogWarn(@"Error! %@, %@", error, result);
            }
        } else {
            NSMutableArray *textBlocks = [[NSMutableArray alloc] init];
            // NSString *resultText = result.text;
           
            RCTLogInfo(@"Blocks %@, %@", result.text, result.blocks);
            for (FIRVisionTextBlock *block in result.blocks) {
               NSString *blockText = block.text;
//               NSNumber *blockConfidence = block.confidence;
//               NSArray<FIRVisionTextRecognizedLanguage *> *blockLanguages = block.recognizedLanguages;
//               NSArray<NSValue *> *blockCornerPoints = block.cornerPoints;
               CGRect blockFrame = block.frame;
               NSMutableArray *lineBlocks = [[NSMutableArray alloc] init];
               
               for (FIRVisionTextLine *line in block.lines) {
                   NSString *lineText = line.text;
//                   NSNumber *lineConfidence = line.confidence;
//                   NSArray<FIRVisionTextRecognizedLanguage *> *lineLanguages = line.recognizedLanguages;
//                   NSArray<NSValue *> *lineCornerPoints = line.cornerPoints;
                   CGRect lineFrame = line.frame;
                   NSMutableArray *elementBlocks = [[NSMutableArray alloc] init];
                   
                   for (FIRVisionTextElement *element in line.elements) {
                       NSString *elementText = element.text;
//                       NSNumber *elementConfidence = element.confidence;
//                       NSArray<FIRVisionTextRecognizedLanguage *> *elementLanguages = element.recognizedLanguages;
//                       NSArray<NSValue *> *elementCornerPoints = element.cornerPoints;
                       CGRect elementFrame = element.frame;
                       
                       NSDictionary *textElementDict = @{@"type": @"element", @"value" : elementText, @"bounds" : [self processBounds:elementFrame]};
                       [elementBlocks addObject:textElementDict];
                   }
                   
                   NSDictionary *textLineDict = @{@"type": @"line", @"value" : lineText, @"bounds" : [self processBounds:lineFrame], @"components" : elementBlocks};
                   [lineBlocks addObject:textLineDict];
               }
               
               NSDictionary *textBlockDict = @{@"type": @"block", @"value" : blockText, @"bounds" : [self processBounds:blockFrame], @"components" : lineBlocks};
               [textBlocks addObject:textBlockDict];
           }
           cb(@{@"type" : @"TextBlock", @"textBlocks" : textBlocks});
       }
   }];
}

-(NSDictionary *)processBounds:(CGRect)bounds 
{
  float width = bounds.size.width * _scaleX;
  float height = bounds.size.height * _scaleY;
  float originX = bounds.origin.x * _scaleX;
  float originY = bounds.origin.y * _scaleY;
  NSDictionary *boundsDict =
  @{
    @"size" : 
              @{
                @"width" : @(width), 
                @"height" : @(height)
                }, 
    @"origin" : 
              @{
                @"x" : @(originX),
                @"y" : @(originY)
                }
    };
  return boundsDict;
}

@end
