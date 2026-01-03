//
//  AudioRenderer.h
//  SnapClientIOS
//
//  Created by Lee Jun Kit on 31/12/20.
//

#import <Foundation/Foundation.h>
#import "StreamInfo.h"
#import "TimeProvider.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioRenderer : NSObject

- (instancetype)initWithStreamInfo:(StreamInfo *)info timeProvider:(TimeProvider *)timeProvider;
- (void)feedPCMData:(NSData *)pcmData serverSec:(int32_t)sec serverUsec:(int32_t)usec;

@end

NS_ASSUME_NONNULL_END
