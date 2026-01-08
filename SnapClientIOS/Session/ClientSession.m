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
#import "RpcHandler.h"
@import MediaPlayer;

@interface ClientSession () <SocketHandlerDelegate, FlacDecoderDelegate, RpcHandlerDelegate>

@property (strong, nonatomic) TimeProvider *timeProvider;
@property (strong, nonatomic) NSTimer *syncTimer;
@property (assign, nonatomic) uint64_t lastPingTime;

@end

@implementation ClientSession

- (instancetype)initWithSnapServerHost:(NSString *)host port:(NSUInteger)port {
    if (self = [super init]) {
        _host = host;
        _port = port;
        self.timeProvider = [[TimeProvider alloc] init];
        self.socketHandler = [[SocketHandler alloc] initWithSnapServerHost:host port:port delegate:self];
        
        // Initialize RPC Handler
        self.rpcHandler = [[RpcHandler alloc] initWithHost:host port:1705];
        self.rpcHandler.delegate = self;
        
        [self setupRemoteCommandCenter];
    }
    return self;
}

// ... (omitted)

- (void)sendSync {
    self.lastPingTime = mach_absolute_time();
    [self.socketHandler sendTime];
}

// ...

- (void)socketHandler:(SocketHandler *)socketHandler didReceiveTimeAtClient:(uint64_t)clientRecvMachTime serverReceivedSec:(int32_t)serverRecvSec serverReceivedUsec:(int32_t)serverRecvUsec serverSentSec:(int32_t)serverSentSec serverSentUsec:(int32_t)serverSentUsec {
    
    // Calculate RTT
    uint64_t rttMach = clientRecvMachTime - self.lastPingTime;
    double rttMs = [self.timeProvider machToMs:rttMach];
    
    // Server Time = ServerSent
    double serverSentMs = (serverSentSec * 1000.0) + (serverSentUsec / 1000.0);
    
    // Local Time (when ServerSent happened) = ClientRecv - RTT/2
    // We use Mach Time for local reference
    uint64_t localMachAtServerSent = clientRecvMachTime - (rttMach / 2);
    double localMs = [self.timeProvider machToMs:localMachAtServerSent];
    
    [self.timeProvider updateOffsetWithServerTime:serverSentMs localTime:localMs];
}
"Snapcast" forKey:MPMediaItemPropertyTitle];
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nowPlayingInfo;
}

#pragma mark - RpcHandlerDelegate
- (void)rpcHandler:(RpcHandler *)handler didReceiveServerStatus:(NSDictionary *)status {
    NSLog(@"RPC Status Received: %@", status);
    // TODO: Notify UI about streams
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SnapClientServerStatusUpdated" object:nil userInfo:status];
}

- (void)socketHandler:(SocketHandler *)socketHandler didReceiveStreamTags:(NSDictionary *)tags {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableDictionary *nowPlayingInfo = [[NSMutableDictionary alloc] initWithDictionary:[MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo];
        
        if (tags[@"TITLE"]) {
            [nowPlayingInfo setObject:tags[@"TITLE"] forKey:MPMediaItemPropertyTitle];
        }
        if (tags[@"ARTIST"]) {
            [nowPlayingInfo setObject:tags[@"ARTIST"] forKey:MPMediaItemPropertyArtist];
        }
        if (tags[@"ALBUM"]) {
            [nowPlayingInfo setObject:tags[@"ALBUM"] forKey:MPMediaItemPropertyAlbumTitle];
        }
        
        // Cover Art (Base64)
        if (tags[@"COVERART"]) {
            NSData *imageData = [[NSData alloc] initWithBase64EncodedString:tags[@"COVERART"] options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (imageData) {
                UIImage *image = [UIImage imageWithData:imageData];
                if (image) {
                    MPMediaItemArtwork *artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size requestHandler:^UIImage * _Nonnull(CGSize size) {
                        return image;
                    }];
                    [nowPlayingInfo setObject:artwork forKey:MPMediaItemPropertyArtwork];
                }
            }
        }
        
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nowPlayingInfo;
    });
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

- (void)socketHandler:(SocketHandler *)socketHandler didReceiveServerSettings:(NSDictionary *)settings {
    if (settings[@"latency"]) {
        NSInteger latency = [settings[@"latency"] integerValue];
        [self.audioRenderer setLatency:latency];
    }
    
    if (settings[@"volume"]) {
        NSInteger vol = [settings[@"volume"] integerValue];
        [self.audioRenderer setVolume:(float)vol / 100.0];
    }
    
    if (settings[@"muted"]) {
        BOOL muted = [settings[@"muted"] boolValue];
        [self.audioRenderer setMuted:muted];
    }
}

#pragma mark - FlacDecoderDelegate
- (void)decoder:(FlacDecoder *)decoder didDecodePCMData:(NSData *)pcmData serverSec:(int32_t)sec serverUsec:(int32_t)usec {
    [self.audioRenderer feedPCMData:pcmData serverSec:sec serverUsec:usec];
}

@end
