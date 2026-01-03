//
//  RpcHandler.m
//  SnapClientIOS
//
//  Created by Anaxonda on 03/01/26.
//

#import "RpcHandler.h"
#import <GCDAsyncSocket.h>

@interface RpcHandler () <GCDAsyncSocketDelegate>

@property (nonatomic, strong) GCDAsyncSocket *socket;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) NSUInteger port;
@property (nonatomic, assign) long currentRequestId;

@end

@implementation RpcHandler

- (instancetype)initWithHost:(NSString *)host port:(NSUInteger)port {
    self = [super init];
    if (self) {
        _host = host;
        _port = port;
        _currentRequestId = 1;
        
        dispatch_queue_t queue = dispatch_queue_create("ljk.snapclientios.rpcqueue", NULL);
        _socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:queue];
    }
    return self;
}

- (void)connect {
    NSError *err = nil;
    if (![self.socket connectToHost:self.host onPort:self.port error:&err]) {
        NSLog(@"RpcHandler Connect Error: %@", err);
    }
}

- (void)disconnect {
    [self.socket disconnect];
}

- (void)setStreamId:(NSString *)streamId forGroupId:(NSString *)groupId {
    NSDictionary *params = @{ @"id": groupId, @"stream_id": streamId };
    NSDictionary *request = @{
        @"id": @(++self.currentRequestId),
        @"jsonrpc": @"2.0",
        @"method": @"Group.SetStream",
        @"params": params
    };
    [self sendRequest:request];
}

- (void)sendRequest:(NSDictionary *)request {
    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:request options:0 error:&err];
    if (json) {
        NSMutableData *data = [json mutableCopy];
        [data appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [self.socket writeData:data withTimeout:-1 tag:1];
    }
}

#pragma mark - GCDAsyncSocketDelegate

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port {
    NSLog(@"RpcHandler Connected to %@:%d", host, port);
    
    // Fetch Status immediately
    NSDictionary *request = @{
        @"id": @(1),
        @"jsonrpc": @"2.0",
        @"method": @"Server.GetStatus"
    };
    [self sendRequest:request];
    
    // Read continuously
    [sock readDataToData:[GCDAsyncSocket CRLFData] withTimeout:-1 tag:0];
}

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
    // Strip CRLF
    NSData *payload = [data subdataWithRange:NSMakeRange(0, data.length - 2)];
    
    NSError *err = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:payload options:0 error:&err];
    
    if (json) {
        if (json[@"result"] && [json[@"result"] isKindOfClass:[NSDictionary class]]) {
            NSDictionary *result = json[@"result"];
            if (result[@"server"]) { // It's likely GetStatus response
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate rpcHandler:self didReceiveServerStatus:result];
                });
            }
        }
    }
    
    // Keep reading
    [sock readDataToData:[GCDAsyncSocket CRLFData] withTimeout:-1 tag:0];
}

@end
