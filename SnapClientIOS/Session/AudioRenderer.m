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
    if (self.streamInfo.sampleRate > 0) {
        [session setPreferredSampleRate:self.streamInfo.sampleRate error:&error];
        if (error) NSLog(@"Error setting preferred sample rate: %@", error);
    }
    [session setPreferredIOBufferDuration:0.04 error:&error];
    if (error) NSLog(@"Error setting preferred IO buffer duration: %@", error);
    [session setActive:YES error:&error];
    if (error) NSLog(@"Error activating session: %@", error);
    NSLog(@"AudioSession: sampleRate=%.0f, ioBuffer=%.3fms, outputLatency=%.3fms",
          session.sampleRate, session.IOBufferDuration * 1000.0, session.outputLatency * 1000.0);

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
    int64_t diffTicks = (int64_t)machTime - (int64_t)now;
    uint64_t absDiffTicks = (uint64_t)llabs(diffTicks);
    double diffMs = [self.timeProvider machToMs:absDiffTicks] * (diffTicks < 0 ? -1.0 : 1.0);
    
    // Debug Logging (every 500 chunks to avoid lag)
    static int logCount = 0;
    if (logCount++ % 500 == 0) {
        NSLog(@"AudioRenderer Sync: Latency=%ldms, TargetDiff=%.2fms, HWDelay=%.2fms", (long)self.latencyMs, diffMs, hwLatencyMs);
    }
    
    // 4. Schedule
    // If target is in the past (machTime <= now) or uninitialized, play immediately.
    // If target is more than 5 seconds in the future, it's a math error, play immediately.
    uint64_t fiveSecsInMach = [self.timeProvider msToMach:5000.0];
    static uint64_t immediateCount = 0;
    static uint64_t lateCount = 0;
    static uint64_t farFutureCount = 0;
    static uint64_t zeroTimeCount = 0;
    static CFAbsoluteTime lastImmediateLog = 0;
    BOOL isLate = (machTime != 0 && machTime <= now);
    BOOL isFarFuture = (machTime > (now + fiveSecsInMach));
    if (machTime == 0 || isLate || isFarFuture) {
        immediateCount += 1;
        if (machTime == 0) {
            zeroTimeCount += 1;
        } else if (isLate) {
            lateCount += 1;
        } else {
            farFutureCount += 1;
        }
        CFAbsoluteTime nowTime = CFAbsoluteTimeGetCurrent();
        if (nowTime - lastImmediateLog >= 5.0) {
            NSLog(@"AudioRenderer: immediate schedule=%llu (late=%llu, future=%llu, zero=%llu), lastDiff=%.2fms",
                  immediateCount, lateCount, farFutureCount, zeroTimeCount, diffMs);
            lastImmediateLog = nowTime;
        }
        [self.playerNode scheduleBuffer:buffer atTime:nil options:0 completionHandler:nil];
    } else {
        AVAudioTime *audioTime = [[AVAudioTime alloc] initWithHostTime:machTime];
        [self.playerNode scheduleBuffer:buffer atTime:audioTime options:0 completionHandler:nil];
    }
}

@end
