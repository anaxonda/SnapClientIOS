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
    dispatch_queue_t processingQueue;
    
    // Header parsing temp storage
    int32_t _headerSentSec;
    int32_t _headerSentUsec;
    int32_t _headerRecvSec;
    int32_t _headerRecvUsec;
    
    uint64_t _lastPingMach;
    uint16_t _nextMessageId;
}

@property (nonatomic, copy) NSString *serverHost;
@property (nonatomic) NSUInteger serverPort;
@property (nonatomic, strong) GCDAsyncSocket *socket;
@property (nonatomic, assign) double lastAudioArrivalMs;
@property (nonatomic, assign) double lastServerTimestampMs;

@end

@implementation SocketHandler

- (instancetype)initWithSnapServerHost:(NSString *)host port:(NSUInteger)port delegate:(id<SocketHandlerDelegate>)delegate {
    if (self = [super init]) {
        self.serverHost = host;
        self.serverPort = port;
        _delegate = delegate;
    _nextMessageId = 0;
    
    queue = dispatch_queue_create("ljk.snapclientios.socketqueue", NULL);
    processingQueue = dispatch_queue_create("ljk.snapclientios.socketprocessing", NULL);
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
    
    NSMutableData *base = [self baseMessageWithType:MESSAGE_TYPE_HELLO sentMs:-1];
    
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
    [self readNextMessage];
}

- (void)disconnect {
    [self.socket disconnect];
}

- (void)sendTime {
    double nowMs = [self currentTimeMsForMessage];
    NSMutableData *data = [self baseMessageWithType:MESSAGE_TYPE_TIME sentMs:nowMs];
    uint32_t payloadLen = CFSwapInt32HostToLittle(sizeof(int32_t) * 2);
    [data appendBytes:&payloadLen length:sizeof(uint32_t)];

    int32_t sec = (int32_t)(nowMs / 1000.0);
    int32_t usec = (int32_t)((nowMs - (sec * 1000.0)) * 1000.0);
    int32_t leSec = CFSwapInt32HostToLittle(sec);
    int32_t leUsec = CFSwapInt32HostToLittle(usec);
    [data appendBytes:&leSec length:sizeof(int32_t)];
    [data appendBytes:&leUsec length:sizeof(int32_t)];

    _lastPingMach = mach_absolute_time();
    [self.socket writeData:data withTimeout:-1 tag:MESSAGE_TYPE_TIME];
}

- (double)currentTimeMsForMessage {
    if (self.timeProvider) {
        double nowMs = [self.timeProvider nowMs];
        if (nowMs > 0.0) {
            return nowMs;
        }
    }
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    return now * 1000.0;
}

- (uint16_t)lastSentMessageId {
    return _nextMessageId;
}

- (NSMutableData *)baseMessageWithType:(uint16_t)type sentMs:(double)sentMs {
    NSMutableData *base = [[NSMutableData alloc] init];
    uint16_t leType = CFSwapInt16HostToLittle(type);
    uint16_t idField = ++_nextMessageId;
    uint16_t refersToField = 0;
    int32_t zero = 0;
    
    [base appendBytes:&leType length:sizeof(uint16_t)];
    uint16_t leIdField = CFSwapInt16HostToLittle(idField);
    uint16_t leRefersToField = CFSwapInt16HostToLittle(refersToField);
    [base appendBytes:&leIdField length:sizeof(uint16_t)];
    [base appendBytes:&leRefersToField length:sizeof(uint16_t)];
    
    if (sentMs < 0.0) {
        sentMs = [self currentTimeMsForMessage];
    }
    int32_t sec = (int32_t)(sentMs / 1000.0);
    int32_t usec = (int32_t)((sentMs - (sec * 1000.0)) * 1000.0);
    int32_t leSec = CFSwapInt32HostToLittle(sec);
    int32_t leUsec = CFSwapInt32HostToLittle(usec);
    
    [base appendBytes:&leSec length:sizeof(int32_t)];
    [base appendBytes:&leUsec length:sizeof(int32_t)];
    [base appendBytes:&zero length:sizeof(int32_t)];
    [base appendBytes:&zero length:sizeof(int32_t)];

    return base;
}

- (void)readNextMessage {
    [self scheduleReadLength:26 tag:MESSAGE_TYPE_BASE];
}

- (void)scheduleReadLength:(NSUInteger)length tag:(long)tag {
    dispatch_async(queue, ^{
        [self.socket readDataToLength:length withTimeout:-1 tag:tag];
    });
}

#pragma mark - GCDAsyncSocketDelegate
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
    dispatch_async(processingQueue, ^{
        [self handleReadData:data tag:tag];
    });
}

- (void)handleReadData:(NSData *)data tag:(long)tag {
    if (tag == MESSAGE_TYPE_BASE) {
        uint16_t messageType;
        [data getBytes:&messageType length:sizeof(uint16_t)];
        messageType = CFSwapInt16LittleToHost(messageType);
        
        [data getBytes:&_headerSentSec range:NSMakeRange(6, 4)];
        _headerSentSec = CFSwapInt32LittleToHost(_headerSentSec);
        [data getBytes:&_headerSentUsec range:NSMakeRange(10, 4)];
        _headerSentUsec = CFSwapInt32LittleToHost(_headerSentUsec);
        [data getBytes:&_headerRecvSec range:NSMakeRange(14, 4)];
        _headerRecvSec = CFSwapInt32LittleToHost(_headerRecvSec);
        [data getBytes:&_headerRecvUsec range:NSMakeRange(18, 4)];
        _headerRecvUsec = CFSwapInt32LittleToHost(_headerRecvUsec);
        
        uint32_t typedMessageLength;
        [data getBytes:&typedMessageLength range:NSMakeRange(22, sizeof(uint32_t))];
        typedMessageLength = CFSwapInt32LittleToHost(typedMessageLength);
        
        if (typedMessageLength > 0) {
            [self scheduleReadLength:typedMessageLength tag:messageType];
        } else {
            if (messageType == MESSAGE_TYPE_TIME) [self handleTimePayload:nil];
            [self readNextMessage];
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
        double serverTimeMs = (sec * 1000.0) + (usec / 1000.0);
        double arrivalMs = CFAbsoluteTimeGetCurrent() * 1000.0;
        if (self.lastAudioArrivalMs > 0.0) {
            double gapMs = arrivalMs - self.lastAudioArrivalMs;
            double serverGapMs = serverTimeMs - self.lastServerTimestampMs;
            if (gapMs > 150.0 || serverGapMs > 150.0) {
                static CFAbsoluteTime lastGapLogTime = 0;
                CFAbsoluteTime nowTime = CFAbsoluteTimeGetCurrent();
                if (nowTime - lastGapLogTime >= 2.0) {
                    NSLog(@"Audio gap: arrival=%.1fms server=%.1fms", gapMs, serverGapMs);
                    lastGapLogTime = nowTime;
                }
            }
        }
        self.lastAudioArrivalMs = arrivalMs;
        self.lastServerTimestampMs = serverTimeMs;
        [self.delegate socketHandler:self didReceiveAudioData:payload serverSec:sec serverUsec:usec];
    } else if (tag == MESSAGE_TYPE_SERVER_SETTINGS) {
        NSDictionary *json = [self jsonDictionaryFromTypedMessage:data];
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
    
    [self readNextMessage];
}

- (NSDictionary *)jsonDictionaryFromTypedMessage:(NSData *)data {
    if (data.length == 0) {
        return nil;
    }

    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        return obj;
    }

    if (data.length <= sizeof(uint32_t)) {
        return nil;
    }

    uint32_t jsonSize = 0;
    [data getBytes:&jsonSize length:sizeof(uint32_t)];
    jsonSize = CFSwapInt32LittleToHost(jsonSize);
    if (jsonSize == 0 || jsonSize > data.length - sizeof(uint32_t)) {
        return nil;
    }

    NSData *jsonData = [data subdataWithRange:NSMakeRange(sizeof(uint32_t), jsonSize)];
    obj = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        return obj;
    }

    return nil;
}

- (void)handleTimePayload:(NSData *)data {
    uint64_t pongRecvMach = mach_absolute_time();
    
    // Server System Clock (Unix) from Header (Sent field)
    // This is the reference used by audio chunks.
    double serverSystemMs = (_headerSentSec * 1000.0) + (_headerSentUsec / 1000.0);
    
    if (!self.timeProvider) {
        return;
    }

    double localNowMs = [self.timeProvider nowMs];
    if (localNowMs <= 0.0) {
        return;
    }

    if (data.length >= sizeof(int32_t) * 2) {
        int32_t latencySec = 0;
        int32_t latencyUsec = 0;
        [data getBytes:&latencySec range:NSMakeRange(0, 4)];
        [data getBytes:&latencyUsec range:NSMakeRange(4, 4)];
        latencySec = CFSwapInt32LittleToHost(latencySec);
        latencyUsec = CFSwapInt32LittleToHost(latencyUsec);
        double latencyMs = (latencySec * 1000.0) + (latencyUsec / 1000.0);
        double s2cMs = localNowMs - serverSystemMs;
        double offset = (latencyMs - s2cMs) / 2.0;
        [self.timeProvider updateOffsetWithDiff:offset];
    } else {
        uint64_t rttMach = pongRecvMach - _lastPingMach;
        double rttMs = [self.timeProvider machToMs:rttMach];
        double localTimeAtServerSent = localNowMs - (rttMs / 2.0);
        [self.delegate socketHandler:self didReceiveTimeSyncServerMs:serverSystemMs atLocalTimeMs:localTimeAtServerSent];
    }
}

@end
