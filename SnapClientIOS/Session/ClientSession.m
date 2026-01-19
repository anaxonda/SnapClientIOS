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
@property (strong, nonatomic) dispatch_source_t quickSyncTimer;

@property (assign, nonatomic) NSInteger cachedBufferMs;
@property (assign, nonatomic) NSInteger cachedLatency;
@property (assign, nonatomic) NSInteger quickSyncRemaining;

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
        self.socketHandler.timeProvider = self.timeProvider;
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
    self.quickSyncRemaining = 50;
    [self startQuickSyncTimer];
    [self.rpcHandler connect];
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = @{MPMediaItemPropertyTitle: @"Snapcast"};
}

- (void)sendSync {
    [self.socketHandler sendTime];
    if (self.quickSyncRemaining > 0) {
        self.quickSyncRemaining--;
        if (self.quickSyncRemaining == 0) {
            [self stopQuickSyncTimer];
            [self startSyncTimerWithInterval:1.0];
        }
    }
}

- (void)startQuickSyncTimer {
    [self stopQuickSyncTimer];
    dispatch_queue_t queue = dispatch_get_main_queue();
    self.quickSyncTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    uint64_t intervalNs = (uint64_t)(0.02 * NSEC_PER_SEC);
    dispatch_source_set_timer(self.quickSyncTimer, dispatch_time(DISPATCH_TIME_NOW, 0), intervalNs, intervalNs / 2);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.quickSyncTimer, ^{
        [weakSelf sendSync];
    });
    dispatch_resume(self.quickSyncTimer);
}

- (void)stopQuickSyncTimer {
    if (self.quickSyncTimer) {
        dispatch_source_cancel(self.quickSyncTimer);
        self.quickSyncTimer = nil;
    }
}

- (void)startSyncTimerWithInterval:(NSTimeInterval)interval {
    [self.syncTimer invalidate];
    self.syncTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                      target:self
                                                    selector:@selector(sendSync)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)setStreamId:(NSString *)streamId forGroupId:(NSString *)groupId {
    [self.rpcHandler setStreamId:streamId forGroupId:groupId];
}

- (void)dealloc {
    [self.syncTimer invalidate];
    [self stopQuickSyncTimer];
}

#pragma mark - SocketHandlerDelegate

- (void)socketHandler:(SocketHandler *)socketHandler didReceiveCodec:(NSString *)codec header:(NSData *)codecHeader {
    if ([codec isEqualToString:@"flac"]) {
        self.flacDecoder = [[FlacDecoder alloc] init];
        self.flacDecoder.delegate = self;
        self.flacDecoder.codecHeader = codecHeader;
        self.audioRenderer = [[AudioRenderer alloc] initWithStreamInfo:[self.flacDecoder getStreamInfo] timeProvider:self.timeProvider];
        [self.audioRenderer setServerBufferMs:self.cachedBufferMs clientLatencyMs:self.cachedLatency];
    }
}

- (void)socketHandler:(SocketHandler *)socketHandler didReceiveAudioData:(NSData *)audioData serverSec:(int32_t)sec serverUsec:(int32_t)usec {
    [self.flacDecoder feedAudioData:audioData serverSec:sec serverUsec:usec];
}

- (void)socketHandler:(SocketHandler *)socketHandler didReceiveTimeSyncServerMs:(double)serverTimeMs atLocalTimeMs:(double)localTimeMs {
    [self.timeProvider updateOffsetWithServerTime:serverTimeMs localTime:localTimeMs];
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
        [self.audioRenderer setServerBufferMs:self.cachedBufferMs clientLatencyMs:self.cachedLatency];
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
