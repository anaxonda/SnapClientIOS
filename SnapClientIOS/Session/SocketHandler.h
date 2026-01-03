//
//  SocketHandler.h
//  SnapClientIOS
//
//  Created by Lee Jun Kit on 31/12/20.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class SocketHandler;

@protocol SocketHandlerDelegate <NSObject>

- (void)socketHandler:(SocketHandler *)socketHandler didReceiveCodec:(NSString *)codec header:(NSData *)codecHeader;
- (void)socketHandler:(SocketHandler *)socketHandler didReceiveAudioData:(NSData *)audioData serverSec:(int32_t)sec serverUsec:(int32_t)usec;
- (void)socketHandler:(SocketHandler *)socketHandler didReceiveServerSettings:(NSDictionary *)settings;
- (void)socketHandler:(SocketHandler *)socketHandler didReceiveTimeAtClient:(NSDate *)clientReceivedTime
     serverReceivedSec:(int32_t)serverRecvSec serverReceivedUsec:(int32_t)serverRecvUsec
         serverSentSec:(int32_t)serverSentSec serverSentUsec:(int32_t)serverSentUsec;

@end

@interface SocketHandler : NSObject

@property (nonatomic, weak) id<SocketHandlerDelegate> delegate;

- (instancetype)initWithSnapServerHost:(NSString *)host port:(NSUInteger)port delegate:(id<SocketHandlerDelegate>)delegate;
- (void)start;
- (void)disconnect;
- (void)sendTime;

@end

NS_ASSUME_NONNULL_END
