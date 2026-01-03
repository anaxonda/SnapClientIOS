//
//  RpcHandler.h
//  SnapClientIOS
//
//  Created by Anaxonda on 03/01/26.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class RpcHandler;

@protocol RpcHandlerDelegate <NSObject>
- (void)rpcHandler:(RpcHandler *)handler didReceiveServerStatus:(NSDictionary *)status;
@end

@interface RpcHandler : NSObject

@property (nonatomic, weak) id<RpcHandlerDelegate> delegate;

- (instancetype)initWithHost:(NSString *)host port:(NSUInteger)port;
- (void)connect;
- (void)disconnect;
- (void)setStreamId:(NSString *)streamId forGroupId:(NSString *)groupId;

@end

NS_ASSUME_NONNULL_END
