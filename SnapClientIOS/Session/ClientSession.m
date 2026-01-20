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
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
@import MediaPlayer;

static void *kSyncQueueKey = &kSyncQueueKey;

@interface ClientSession () <SocketHandlerDelegate, FlacDecoderDelegate, RpcHandlerDelegate>

@property (strong, nonatomic) SocketHandler *socketHandler;
@property (strong, nonatomic) RpcHandler *rpcHandler;
@property (strong, nonatomic) FlacDecoder *flacDecoder;
@property (strong, nonatomic) AudioRenderer *audioRenderer;
@property (strong, nonatomic) TimeProvider *timeProvider;
@property (strong, nonatomic) dispatch_queue_t syncQueue;
@property (strong, nonatomic) dispatch_source_t quickSyncTimer;
@property (strong, nonatomic) dispatch_source_t steadySyncTimer;

@property (assign, nonatomic) NSInteger cachedBufferMs;
@property (assign, nonatomic) NSInteger cachedLatency;
@property (assign, nonatomic) NSInteger quickSyncRemaining;
@property (assign, nonatomic) CFAbsoluteTime lastTimeSyncRestart;
@property (assign, nonatomic) CFAbsoluteTime lastSteadySyncLog;

@end

@implementation ClientSession

- (instancetype)initWithSnapServerHost:(NSString *)host port:(NSUInteger)port {
    if (self = [super init]) {
        _host = host;
        _port = port;
        self.cachedBufferMs = 1000;
        self.cachedLatency = 0;
        self.lastSteadySyncLog = 0;
        self.timeProvider = [[TimeProvider alloc] init];
        self.syncQueue = dispatch_queue_create("ljk.snapclientios.syncqueue", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(self.syncQueue, kSyncQueueKey, kSyncQueueKey, NULL);
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
    [self registerForResumeNotifications];
    [self withSyncQueue:^{
        self.quickSyncRemaining = 50;
        [self startQuickSyncTimerLocked];
    }];
    [self.rpcHandler connect];
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = @{MPMediaItemPropertyTitle: @"Snapcast"};
}

- (void)sendSync {
    [self withSyncQueue:^{
        [self.socketHandler sendTime];
        if (self.quickSyncRemaining > 0) {
            self.quickSyncRemaining--;
            if (self.quickSyncRemaining == 0) {
                NSLog(@"ClientSession: quick sync complete, switching to steady sync");
                [self stopQuickSyncTimerLocked];
                [self startSyncTimerWithIntervalLocked:1.0];
            }
        } else {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - self.lastSteadySyncLog >= 5.0) {
                self.lastSteadySyncLog = now;
                NSLog(@"ClientSession: steady sync ping");
            }
        }
    }];
}

- (void)startQuickSyncTimer {
    [self withSyncQueue:^{
        [self startQuickSyncTimerLocked];
    }];
}

- (void)stopQuickSyncTimer {
    [self withSyncQueue:^{
        [self stopQuickSyncTimerLocked];
    }];
}

- (void)startSyncTimerWithInterval:(NSTimeInterval)interval {
    [self withSyncQueue:^{
        [self startSyncTimerWithIntervalLocked:interval];
    }];
}

- (void)registerForResumeNotifications {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(handleAppDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(handleAppWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    [center addObserver:self selector:@selector(handleAudioSessionInterruption:) name:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance]];
}

- (void)handleAppWillEnterForeground:(NSNotification *)note {
    [self restartTimeSyncWithReason:@"foreground"];
}

- (void)handleAppDidBecomeActive:(NSNotification *)note {
    [self restartTimeSyncWithReason:@"app active"];
}

- (void)handleAudioSessionInterruption:(NSNotification *)note {
    NSNumber *typeValue = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (!typeValue) {
        return;
    }
    AVAudioSessionInterruptionType type = (AVAudioSessionInterruptionType)[typeValue unsignedIntegerValue];
    if (type != AVAudioSessionInterruptionTypeEnded) {
        return;
    }
    NSNumber *optionValue = note.userInfo[AVAudioSessionInterruptionOptionKey];
    AVAudioSessionInterruptionOptions options = (AVAudioSessionInterruptionOptions)[optionValue unsignedIntegerValue];
    if (options & AVAudioSessionInterruptionOptionShouldResume) {
        [self restartTimeSyncWithReason:@"interruption ended"];
    }
}

- (void)restartTimeSyncWithReason:(NSString *)reason {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - self.lastTimeSyncRestart < 1.0) {
        return;
    }
    self.lastTimeSyncRestart = now;
    NSLog(@"ClientSession: restart time sync (%@)", reason);
    [self withSyncQueue:^{
        [self.timeProvider reset];
        [self stopSyncTimerLocked];
        [self stopQuickSyncTimerLocked];
        self.quickSyncRemaining = 50;
        [self startQuickSyncTimerLocked];
        [self sendSync];
    }];
}

- (void)setStreamId:(NSString *)streamId forGroupId:(NSString *)groupId {
    [self.rpcHandler setStreamId:streamId forGroupId:groupId];
}

- (void)dealloc {
    [self stopAllSyncTimers];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Sync Timers

- (void)withSyncQueue:(dispatch_block_t)block {
    if (dispatch_get_specific(kSyncQueueKey)) {
        block();
    } else {
        dispatch_async(self.syncQueue, block);
    }
}

- (void)stopAllSyncTimers {
    if (dispatch_get_specific(kSyncQueueKey)) {
        [self stopQuickSyncTimerLocked];
        [self stopSyncTimerLocked];
    } else {
        dispatch_sync(self.syncQueue, ^{
            [self stopQuickSyncTimerLocked];
            [self stopSyncTimerLocked];
        });
    }
}

- (void)startQuickSyncTimerLocked {
    [self stopQuickSyncTimerLocked];
    self.quickSyncTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.syncQueue);
    uint64_t intervalNs = (uint64_t)(0.02 * NSEC_PER_SEC);
    dispatch_source_set_timer(self.quickSyncTimer, dispatch_time(DISPATCH_TIME_NOW, 0), intervalNs, intervalNs / 2);
    NSLog(@"ClientSession: quick sync start (50 pings @ 20ms)");
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.quickSyncTimer, ^{
        [weakSelf sendSync];
    });
    dispatch_resume(self.quickSyncTimer);
}

- (void)stopQuickSyncTimerLocked {
    if (self.quickSyncTimer) {
        dispatch_source_cancel(self.quickSyncTimer);
        self.quickSyncTimer = nil;
        NSLog(@"ClientSession: quick sync stop");
    }
}

- (void)startSyncTimerWithIntervalLocked:(NSTimeInterval)interval {
    [self stopSyncTimerLocked];
    self.steadySyncTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.syncQueue);
    uint64_t intervalNs = (uint64_t)(interval * NSEC_PER_SEC);
    dispatch_source_set_timer(self.steadySyncTimer, dispatch_time(DISPATCH_TIME_NOW, intervalNs), intervalNs, intervalNs / 10);
    self.lastSteadySyncLog = 0;
    NSLog(@"ClientSession: steady sync start (interval=%.2fs)", interval);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.steadySyncTimer, ^{
        [weakSelf sendSync];
    });
    dispatch_resume(self.steadySyncTimer);
}

- (void)stopSyncTimerLocked {
    if (self.steadySyncTimer) {
        dispatch_source_cancel(self.steadySyncTimer);
        self.steadySyncTimer = nil;
        NSLog(@"ClientSession: steady sync stop");
    }
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
