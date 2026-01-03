//
//  ClientSession.m
//  SnapClientIOS
//
//  Created by Lee Jun Kit on 31/12/20.
//

#import "ClientSession.h"
#import "SocketHandler.h"
#import "FlacDecoder.h"
#import "AudioRenderer.h"
#import "TimeProvider.h"

@interface ClientSession () <SocketHandlerDelegate, FlacDecoderDelegate>

@property (strong, nonatomic) SocketHandler *socketHandler;
@property (strong, nonatomic) FlacDecoder *flacDecoder;
@property (strong, nonatomic) AudioRenderer *audioRenderer;
@property (strong, nonatomic) TimeProvider *timeProvider;
@property (strong, nonatomic) NSTimer *syncTimer;

@end

@implementation ClientSession

- (instancetype)initWithSnapServerHost:(NSString *)host port:(NSUInteger)port {
    if (self = [super init]) {
        _host = host;
        _port = port;
        self.timeProvider = [[TimeProvider alloc] init];
        self.socketHandler = [[SocketHandler alloc] initWithSnapServerHost:host port:port delegate:self];
    }
    return self;
}

- (void)start {
    // Start Sync Timer (every 1 second)
    self.syncTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(sendSync) userInfo:nil repeats:YES];
}

- (void)sendSync {
    [self.socketHandler sendTime];
}

- (void)dealloc {
    [self.syncTimer invalidate];
}

#pragma mark - SocketHandlerDelegate
- (void)socketHandler:(SocketHandler *)socketHandler didReceiveCodec:(NSString *)codec header:(NSData *)codecHeader {
    if ([codec isEqualToString:@"flac"]) {
        self.flacDecoder = [[FlacDecoder alloc] init];
        self.flacDecoder.delegate = self;
        self.flacDecoder.codecHeader = codecHeader;
        self.audioRenderer = [[AudioRenderer alloc] initWithStreamInfo:[self.flacDecoder getStreamInfo] timeProvider:self.timeProvider];
    }
}

- (void)socketHandler:(SocketHandler *)socketHandler didReceiveAudioData:(NSData *)audioData serverSec:(int32_t)sec serverUsec:(int32_t)usec {
    if (![self.flacDecoder feedAudioData:audioData serverSec:sec serverUsec:usec]) {
        NSLog(@"Error feeding audio data to the decoder");
    }
}

- (void)socketHandler:(SocketHandler *)socketHandler didReceiveTimeAtClient:(NSDate *)clientReceivedTime serverReceivedSec:(int32_t)serverRecvSec serverReceivedUsec:(int32_t)serverRecvUsec serverSentSec:(int32_t)serverSentSec serverSentUsec:(int32_t)serverSentUsec {
    
    double clientReceivedMs = [clientReceivedTime timeIntervalSince1970] * 1000.0;
    double serverReceivedMs = (serverRecvSec * 1000.0) + (serverRecvUsec / 1000.0);
    double serverSentMs = (serverSentSec * 1000.0) + (serverSentUsec / 1000.0);
    
    // Approximation until we fix ClientSent echo
    [self.timeProvider setDiffWithC2S:(serverReceivedMs - (clientReceivedMs - 5)) s2c:(clientReceivedMs - serverSentMs)];
}

#pragma mark - FlacDecoderDelegate
- (void)decoder:(FlacDecoder *)decoder didDecodePCMData:(NSData *)pcmData serverSec:(int32_t)sec serverUsec:(int32_t)usec {
    [self.audioRenderer feedPCMData:pcmData serverSec:sec serverUsec:usec];
}

@end
