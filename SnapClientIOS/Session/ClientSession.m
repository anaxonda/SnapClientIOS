//
//  ClientSession.m
//  SnapClientIOS
//

#import "ClientSession.h"
#import "SocketHandler.h"
#import "FlacDecoder.h"
#import "AudioRenderer.h"
#import "TimeProvider.h"
#import "RpcHandler.h"
#include <mach/mach.h>
#include <mach/mach_time.h>
@import MediaPlayer;

@interface ClientSession () <SocketHandlerDelegate, FlacDecoderDelegate, RpcHandlerDelegate>

@property (strong, nonatomic) SocketHandler *socketHandler;
@property (strong, nonatomic) RpcHandler *rpcHandler;
@property (strong, nonatomic) FlacDecoder *flacDecoder;
@property (strong, nonatomic) AudioRenderer *audioRenderer;
@property (strong, nonatomic) TimeProvider *timeProvider;
@property (strong, nonatomic) NSTimer *syncTimer;

@property (assign, nonatomic) NSInteger cachedBufferMs;
@property (assign, nonatomic) NSInteger cachedLatency;

@end

@implementation ClientSession

- (instancetype)initWithSnapServerHost:(NSString *)host port:(NSUInteger)port {
    if (self = [super init]) {
        _host = host;
        _port = port;
        self.cachedBufferMs = 1000;
        self.cachedLatency = 0;
        self.timeProvider = [[TimeProvider alloc] init];
        self.socketHandler = [[SocketHandler alloc] initWithSnapServerHost:host port:port delegate:self];
        self.rpcHandler = [[RpcHandler alloc] initWithHost:host port:1705];
        self.rpcHandler.delegate = self;
        [self setupRemoteCommandCenter];
    }
    return self;
}

- (void)setupRemoteCommandCenter {
    MPRemoteCommandCenter *cc = [MPRemoteCommandCenter sharedCommandCenter];
    [cc.playCommand setEnabled:YES];
    [cc.pauseCommand setEnabled:YES];
}

- (void)start {
    self.syncTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(sendSync) userInfo:nil repeats:YES];
    [self.rpcHandler connect];
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = @{MPMediaItemPropertyTitle: @"Snapcast"};
}

- (void)sendSync {
    [self.socketHandler sendTime];
}

- (void)setStreamId:(NSString *)streamId forGroupId:(NSString *)groupId {
    [self.rpcHandler setStreamId:streamId forGroupId:groupId];
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
        [self.audioRenderer setLatency:(self.cachedBufferMs + self.cachedLatency)];
    }
}

- (void)socketHandler:(SocketHandler *)socketHandler didReceiveAudioData:(NSData *)audioData serverSec:(int32_t)sec serverUsec:(int32_t)usec {
    [self.flacDecoder feedAudioData:audioData serverSec:sec serverUsec:usec];
}

- (void)socketHandler:(SocketHandler *)socketHandler didReceiveTimeSyncServerRecv:(double)t2 serverSent:(double)t3 clientSent:(uint64_t)t1 clientRecv:(uint64_t)t4 {
    double t1ms = [self.timeProvider machToMs:t1];
    double t4ms = [self.timeProvider machToMs:t4];
    
    // NTP offset = ((T2 - T1) + (T3 - T4)) / 2
    double offset = ((t2 - t1ms) + (t3 - t4ms)) / 2.0;
    
    // Update with mid-point reference
    // We anchor to T4 (client received)
    [self.timeProvider updateOffsetWithServerTime:t3 localTime:t4ms - (t4ms - t1ms)/2.0];
    
    // Actually, just passing the offset directly to TimeProvider is better if we change its API.
    // For now, updateOffsetWithServerTime:localTime works if we pass:
    // [timeProvider updateOffsetWithServerTime:t3 localTime:t3-offset];
    [self.timeProvider updateOffsetWithServerTime:t3 localTime:(t3 - offset)];
}

- (void)socketHandler:(SocketHandler *)socketHandler didReceiveServerSettings:(NSDictionary *)settings {
    NSLog(@"ClientSession Settings: %@", settings);
    
    // Robust key search for buffer duration
    NSArray *keys = @[@"bufferMs", @"buffer_ms", @"buffer", @"bufferDuration"];
    for (NSString *key in keys) {
        if (settings[key]) {
            self.cachedBufferMs = [settings[key] integerValue];
            break;
        }
    }
    
    if (settings[@"latency"]) {
        self.cachedLatency = [settings[@"latency"] integerValue];
    }
    
    if (self.audioRenderer) {
        [self.audioRenderer setLatency:(self.cachedBufferMs + self.cachedLatency)];
    }
    
    if (settings[@"volume"]) {
        [self.audioRenderer setVolume:([settings[@"volume"] floatValue] / 100.0)];
    }
    
    if (settings[@"muted"]) {
        [self.audioRenderer setMuted:[settings[@"muted"] boolValue]];
    }
}

- (void)socketHandler:(SocketHandler *)socketHandler didReceiveStreamTags:(NSDictionary *)tags {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableDictionary *info = [[NSMutableDictionary alloc] initWithDictionary:[MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo];
        if (tags[@"TITLE"]) info[MPMediaItemPropertyTitle] = tags[@"TITLE"];
        if (tags[@"ARTIST"]) info[MPMediaItemPropertyArtist] = tags[@"ARTIST"];
        if (tags[@"ALBUM"]) info[MPMediaItemPropertyAlbumTitle] = tags[@"ALBUM"];
        if (tags[@"COVERART"]) {
            NSData *data = [[NSData alloc] initWithBase64EncodedString:tags[@"COVERART"] options:NSDataBase64DecodingIgnoreUnknownCharacters];
            UIImage *img = [UIImage imageWithData:data];
            if (img) {
                info[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc] initWithBoundsSize:img.size requestHandler:^UIImage * _Nonnull(CGSize size) { return img; }];
            }
        }
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
    });
}

#pragma mark - RpcHandlerDelegate
- (void)rpcHandler:(RpcHandler *)handler didReceiveServerStatus:(NSDictionary *)status {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SnapClientServerStatusUpdated" object:nil userInfo:status];
}

#pragma mark - FlacDecoderDelegate
- (void)decoder:(FlacDecoder *)decoder didDecodePCMData:(NSData *)pcmData serverSec:(int32_t)sec serverUsec:(int32_t)usec {
    [self.audioRenderer feedPCMData:pcmData serverSec:sec serverUsec:usec];
}

@end
