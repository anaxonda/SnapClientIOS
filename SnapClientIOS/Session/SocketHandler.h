//
//  SocketHandler.h
//  SnapClientIOS
//
//  Created by Lee Jun Kit on 31/12/20.
//

#import <Foundation/Foundation.h>
#import "TimeProvider.h"

NS_ASSUME_NONNULL_BEGIN

@class SocketHandler;

@protocol SocketHandlerDelegate <NSObject>

- (void)socketHandler:(SocketHandler *)socketHandler didReceiveCodec:(NSString *)codec header:(NSData *)codecHeader;
- (void)socketHandler:(SocketHandler *)socketHandler didReceiveAudioData:(NSData *)audioData serverSec:(int32_t)sec serverUsec:(int32_t)usec;
- (void)socketHandler:(SocketHandler *)socketHandler didReceiveServerSettings:(NSDictionary *)settings;
- (void)socketHandler:(SocketHandler *)socketHandler didReceiveStreamTags:(NSDictionary *)tags;
- (void)socketHandler:(SocketHandler *)socketHandler didReceiveTimeSyncServerMs:(double)serverTimeMs atLocalTimeMs:(double)localTimeMs;

@end

@interface SocketHandler : NSObject

@property (nonatomic, weak) id<SocketHandlerDelegate> delegate;
@property (nonatomic, weak) TimeProvider *timeProvider;

- (instancetype)initWithSnapServerHost:(NSString *)host port:(NSUInteger)port delegate:(id<SocketHandlerDelegate>)delegate;
- (void)start;
- (void)disconnect;
- (void)sendTime;

@end

NS_ASSUME_NONNULL_END
