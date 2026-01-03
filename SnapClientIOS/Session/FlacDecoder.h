//
//  FlacDecoder.h
//  SnapClientIOS
//
//  Created by Lee Jun Kit on 31/12/20.
//

#import <Foundation/Foundation.h>
#import "TPCircularBuffer.h"
#import "StreamInfo.h"

NS_ASSUME_NONNULL_BEGIN

@class FlacDecoder;

@protocol FlacDecoderDelegate <NSObject>

- (void)decoder:(FlacDecoder *)decoder didDecodePCMData:(NSData *)pcmData serverSec:(int32_t)sec serverUsec:(int32_t)usec;

@end

@interface FlacDecoder : NSObject

@property (weak, nonatomic) id<FlacDecoderDelegate> delegate;
@property (strong, nonatomic) NSData *codecHeader;

- (instancetype)init;
- (StreamInfo *)getStreamInfo;
- (BOOL)feedAudioData:(NSData *)audioData serverSec:(int32_t)sec serverUsec:(int32_t)usec;

@end

NS_ASSUME_NONNULL_END
