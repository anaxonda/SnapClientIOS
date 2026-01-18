//
//  AudioRenderer.m
//  SnapClientIOS
//
//  Created by Lee Jun Kit on 31/12/20.
//

#import "AudioRenderer.h"
@import AVFoundation;
#include <mach/mach.h>
#include <mach/mach_time.h>

@interface AudioRenderer ()

@property (nonatomic, strong) StreamInfo *streamInfo;
@property (nonatomic, strong) TimeProvider *timeProvider;
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) AVAudioPlayerNode *playerNode;
@property (nonatomic, strong) AVAudioFormat *audioFormat;
@property (nonatomic, assign) NSInteger latencyMs;
@property (nonatomic, assign) float currentVolume;
@property (nonatomic, assign) BOOL isMuted;

@end

@implementation AudioRenderer

- (instancetype)initWithStreamInfo:(StreamInfo *)info timeProvider:(TimeProvider *)timeProvider {
    if (self = [super init]) {
        self.streamInfo = info;
        self.timeProvider = timeProvider;
        self.latencyMs = 1000; // Default
        self.currentVolume = 1.0;
        self.isMuted = NO;
        [self initAudioEngine];
    }
    return self;
}

- (void)setLatency:(NSInteger)latencyMs {
    self.latencyMs = latencyMs;
    NSLog(@"AudioRenderer: Latency updated to %ld ms", (long)latencyMs);
}

- (void)setVolume:(float)volume {
    self.currentVolume = volume;
    [self updateVolume];
}

- (void)setMuted:(BOOL)muted {
    self.isMuted = muted;
    [self updateVolume];
}

- (void)updateVolume {
    float effectiveVolume = self.isMuted ? 0.0 : self.currentVolume;
    self.playerNode.volume = effectiveVolume;
}

- (void)initAudioEngine {
    // Configure Audio Session
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    [session setCategory:AVAudioSessionCategoryPlayback error:&error];
    if (error) NSLog(@"Error setting category: %@", error);
    [session setActive:YES error:&error];
    if (error) NSLog(@"Error activating session: %@", error);

    self.engine = [[AVAudioEngine alloc] init];
    self.playerNode = [[AVAudioPlayerNode alloc] init];
    
    [self.engine attachNode:self.playerNode];
    
    // Create Audio Format (Float32 Non-Interleaved)
    self.audioFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                        sampleRate:self.streamInfo.sampleRate
                                                          channels:self.streamInfo.channels
                                                       interleaved:NO];
    
    [self.engine connect:self.playerNode to:self.engine.mainMixerNode format:self.audioFormat];
    
    if (![self.engine startAndReturnError:&error]) {
        NSLog(@"Error starting AVAudioEngine: %@", error);
    }
    
    [self.playerNode play];
}

- (void)feedPCMData:(NSData *)pcmData serverSec:(int32_t)sec serverUsec:(int32_t)usec {
    // 1. Create Buffer
    AVAudioFrameCount frameCount = (AVAudioFrameCount)(pcmData.length / (self.streamInfo.channels * sizeof(int16_t)));
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.audioFormat frameCapacity:frameCount];
    buffer.frameLength = frameCount;
    
    // 2. Convert Int16 (Interleaved) -> Float32 (Non-Interleaved)
    int16_t *src = (int16_t *)pcmData.bytes;
    float *const *dst = buffer.floatChannelData;
    
    for (int frame = 0; frame < frameCount; frame++) {
        for (int ch = 0; ch < self.streamInfo.channels; ch++) {
            dst[ch][frame] = src[frame * self.streamInfo.channels + ch] / 32768.0f;
        }
    }
    
    // 3. Calculate Target Mach Time
    double serverTimeMs = (sec * 1000.0) + (usec / 1000.0);
    
    // Dynamic Hardware Latency
    double hwLatencyMs = [AVAudioSession sharedInstance].outputLatency * 1000.0;
    
    // Total Target = ServerCaptureTime + Buffer + Latency - HardwareDelay
    double targetPlayTimeMs = serverTimeMs + (double)self.latencyMs - hwLatencyMs;
    
    uint64_t machTime = [self.timeProvider machTimeForServerTimeMs:targetPlayTimeMs];
    uint64_t now = mach_absolute_time();
    
    // 4. Schedule
    // If target is too far in past (e.g. 500ms) or uninitialized, play immediately
    uint64_t lateThreshold = [self.timeProvider msToMach:500.0];
    if (machTime == 0 || machTime < (now - lateThreshold)) {
        [self.playerNode scheduleBuffer:buffer atTime:nil options:0 completionHandler:nil];
    } else {
        AVAudioTime *audioTime = [[AVAudioTime alloc] initWithHostTime:machTime];
        [self.playerNode scheduleBuffer:buffer atTime:audioTime options:0 completionHandler:nil];
    }
}

@end
