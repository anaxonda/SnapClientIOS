//
//  SocketHandler.m
//  SnapClientIOS
//

#import "SocketHandler.h"
#import <GCDAsyncSocket.h>
#import <UIKit/UIKit.h>
#include <mach/mach.h>
#include <mach/mach_time.h>

typedef enum : uint16_t {
    MESSAGE_TYPE_BASE = 0,
    MESSAGE_TYPE_CODEC_HEADER = 1,
    MESSAGE_TYPE_WIRE_CHUNK = 2,
    MESSAGE_TYPE_SERVER_SETTINGS = 3,
    MESSAGE_TYPE_TIME = 4,
    MESSAGE_TYPE_HELLO = 5,
    MESSAGE_TYPE_STREAM_TAGS = 6,
} SnapCastMessageType;

@interface SocketHandler () <GCDAsyncSocketDelegate> {
    dispatch_queue_t queue;
    
    // Header parsing temp storage
    int32_t _headerSentSec;
    int32_t _headerSentUsec;
    int32_t _headerRecvSec;
    int32_t _headerRecvUsec;
    
    uint64_t _lastPingMach;
}

@property (nonatomic, copy) NSString *serverHost;
@property (nonatomic) NSUInteger serverPort;
@property (nonatomic, strong) GCDAsyncSocket *socket;

@end

@implementation SocketHandler

- (instancetype)initWithSnapServerHost:(NSString *)host port:(NSUInteger)port delegate:(id<SocketHandlerDelegate>)delegate {
    if (self = [super init]) {
        self.serverHost = host;
        self.serverPort = port;
        _delegate = delegate;
        
        queue = dispatch_queue_create("ljk.snapclientios.socketqueue", NULL);
        self.socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:queue];
        [self.socket performBlock:^{
            [self.socket enableBackgroundingOnSocket];
        }];
        [self start];
    }
    
    return self;
}

- (void)start {
    NSError *err = nil;
    if (![self.socket connectToHost:self.serverHost onPort:self.serverPort error:&err]) {
        NSLog(@"Socket Connect Error: %@", err);
    }
    
    NSMutableData *base = [self baseMessageWithType:MESSAGE_TYPE_HELLO];
    
    NSString *clientName = [[NSUserDefaults standardUserDefaults] stringForKey:@"ClientName"] ?: @"SnapClientIOS";
    NSString *hostName = [[NSUserDefaults standardUserDefaults] stringForKey:@"HostName"] ?: [[UIDevice currentDevice] name];
    
    NSDictionary *helloMessage = @{
        @"Arch": @"arm64",
        @"ClientName": clientName,
        @"HostName": hostName,
        @"ID": @"00:11:22:33:44:55",
        @"Instance": @1,
        @"MAC": @"00:11:22:33:44:55",
        @"OS": @"iOS",
        @"SnapStreamProtocolVersion": @2,
        @"Version": @"0.17.1"
    };
    
    NSData *helloJSONData = [NSJSONSerialization dataWithJSONObject:helloMessage options:0 error:nil];
    uint32_t helloJSONLength = (uint32_t)[helloJSONData length];
    uint32_t leHelloJSONLength = CFSwapInt32HostToLittle(helloJSONLength);
    
    NSMutableData *helloData = [[NSMutableData alloc] init];
    [helloData appendBytes:&leHelloJSONLength length:sizeof(uint32_t)];
    [helloData appendData:helloJSONData];
    
    uint32_t sizeOfHelloTypedMessage = (uint32_t)[helloData length];
    uint32_t leSizeOfHelloTypedMessage = CFSwapInt32HostToLittle(sizeOfHelloTypedMessage);
    
    [base appendBytes:&leSizeOfHelloTypedMessage length:sizeof(uint32_t)];
    [base appendData:helloData];
    
    [self.socket writeData:base withTimeout:-1 tag:MESSAGE_TYPE_HELLO];
    [self readNextMessage:self.socket];
}

- (void)disconnect {
    [self.socket disconnect];
}

- (void)sendTime {
    NSMutableData *data = [self baseMessageWithType:MESSAGE_TYPE_TIME];
    uint32_t payloadLen = 0;
    [data appendBytes:&payloadLen length:sizeof(uint32_t)];
    
    _lastPingMach = mach_absolute_time();
    [self.socket writeData:data withTimeout:-1 tag:MESSAGE_TYPE_TIME];
}

- (NSMutableData *)baseMessageWithType:(uint16_t)type {
    NSMutableData *base = [[NSMutableData alloc] init];
    uint16_t leType = CFSwapInt16HostToLittle(type);
    uint16_t idField = 0;
    uint16_t refersToField = 0;
    int32_t zero = 0;
    
    [base appendBytes:&leType length:sizeof(uint16_t)];
    [base appendBytes:&idField length:sizeof(uint16_t)];
    [base appendBytes:&refersToField length:sizeof(uint16_t)];
    
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    int32_t sec = CFSwapInt32HostToLittle((int32_t)now);
    int32_t usec = CFSwapInt32HostToLittle((int32_t)((now - (int32_t)now) * 1000000));
    
    [base appendBytes:&sec length:sizeof(int32_t)];
    [base appendBytes:&usec length:sizeof(int32_t)];
    [base appendBytes:&zero length:sizeof(int32_t)];
    [base appendBytes:&zero length:sizeof(int32_t)];

    return base;
}

- (void)readNextMessage:(GCDAsyncSocket *)socket {
    [socket readDataToLength:26 withTimeout:-1 tag:MESSAGE_TYPE_BASE];
}

#pragma mark - GCDAsyncSocketDelegate
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
    if (tag == MESSAGE_TYPE_BASE) {
        uint16_t messageType;
        [data getBytes:&messageType length:sizeof(uint16_t)];
        messageType = CFSwapInt16LittleToHost(messageType);
        
        [data getBytes:&_headerRecvSec range:NSMakeRange(6, 4)];
        _headerRecvSec = CFSwapInt32LittleToHost(_headerRecvSec);
        [data getBytes:&_headerRecvUsec range:NSMakeRange(10, 4)];
        _headerRecvUsec = CFSwapInt32LittleToHost(_headerRecvUsec);
        [data getBytes:&_headerSentSec range:NSMakeRange(14, 4)];
        _headerSentSec = CFSwapInt32LittleToHost(_headerSentSec);
        [data getBytes:&_headerSentUsec range:NSMakeRange(18, 4)];
        _headerSentUsec = CFSwapInt32LittleToHost(_headerSentUsec);
        
        uint32_t typedMessageLength;
        [data getBytes:&typedMessageLength range:NSMakeRange(22, sizeof(uint32_t))];
        typedMessageLength = CFSwapInt32LittleToHost(typedMessageLength);
        
        if (typedMessageLength > 0) {
            [sock readDataToLength:typedMessageLength withTimeout:-1 tag:messageType];
        } else {
            if (messageType == MESSAGE_TYPE_TIME) [self handleTimePayload:nil];
            [self readNextMessage:sock];
        }
        return;
    }
    
    if (tag == MESSAGE_TYPE_WIRE_CHUNK) {
        int32_t sec, usec;
        uint32_t payloadSize;
        [data getBytes:&sec range:NSMakeRange(0, 4)];
        sec = CFSwapInt32LittleToHost(sec);
        [data getBytes:&usec range:NSMakeRange(4, 4)];
        usec = CFSwapInt32LittleToHost(usec);
        [data getBytes:&payloadSize range:NSMakeRange(8, 4)];
        payloadSize = CFSwapInt32LittleToHost(payloadSize);
        
        NSData *payload = [data subdataWithRange:NSMakeRange(12, payloadSize)];
        [self.delegate socketHandler:self didReceiveAudioData:payload serverSec:sec serverUsec:usec];
    } else if (tag == MESSAGE_TYPE_SERVER_SETTINGS) {
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (json) [self.delegate socketHandler:self didReceiveServerSettings:json];
    } else if (tag == MESSAGE_TYPE_STREAM_TAGS) {
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (json && json[@"STREAM"]) [self.delegate socketHandler:self didReceiveStreamTags:json[@"STREAM"]];
    } else if (tag == MESSAGE_TYPE_CODEC_HEADER) {
        uint32_t codecSize;
        [data getBytes:&codecSize range:NSMakeRange(0, 4)];
        codecSize = CFSwapInt32LittleToHost(codecSize);
        
        NSString *codec = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(4, codecSize)] encoding:NSASCIIStringEncoding];
        
        uint32_t payloadSize;
        [data getBytes:&payloadSize range:NSMakeRange(4 + codecSize, 4)];
        payloadSize = CFSwapInt32LittleToHost(payloadSize);
        
        NSData *header = [data subdataWithRange:NSMakeRange(8 + codecSize, payloadSize)];
        if ([codec isEqualToString:@"flac"]) [self.delegate socketHandler:self didReceiveCodec:codec header:header];
    } else if (tag == MESSAGE_TYPE_TIME) {
        [self handleTimePayload:data];
    }
    
    [self readNextMessage:sock];
}

- (void)handleTimePayload:(NSData *)data {
    uint64_t pongRecvMach = mach_absolute_time();
    
    // Server System Clock (Unix) from Header (Sent field)
    // This is the reference used by audio chunks.
    double serverSystemMs = (_headerSentSec * 1000.0) + (_headerSentUsec / 1000.0);
    
    uint64_t rttMach = pongRecvMach - _lastPingMach;
    
    // Local Mach time when server sent that pong = PongRecv - RTT/2
    uint64_t localMachAtServerSent = pongRecvMach - (rttMach / 2);
    
    [self.delegate socketHandler:self didReceiveTimeSyncServerMs:serverSystemMs atLocalMach:localMachAtServerSent];
}

@end