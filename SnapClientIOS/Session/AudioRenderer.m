//
//  AudioRenderer.m
//  SnapClientIOS
//
//  Created by Lee Jun Kit on 31/12/20.
//

#import "AudioRenderer.h"
@import AVFoundation;

@interface AudioRenderer ()

@property (nonatomic, strong) StreamInfo *streamInfo;
@property (nonatomic, strong) TimeProvider *timeProvider;
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) AVAudioPlayerNode *playerNode;
@property (nonatomic, strong) AVAudioFormat *audioFormat;

@end

@implementation AudioRenderer

- (instancetype)initWithStreamInfo:(StreamInfo *)info timeProvider:(TimeProvider *)timeProvider {
    if (self = [super init]) {
        self.streamInfo = info;
        self.timeProvider = timeProvider;
        [self initAudioEngine];
    }
    return self;
}

- (void)initAudioEngine {
    self.engine = [[AVAudioEngine alloc] init];
    self.playerNode = [[AVAudioPlayerNode alloc] init];
    
    [self.engine attachNode:self.playerNode];
    
    // Create Audio Format
    // We use Float32 because AVAudioEngine's mixer node expects it.
    // We will convert Int16 -> Float32 manually.
    self.audioFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                        sampleRate:self.streamInfo.sampleRate
                                                          channels:self.streamInfo.channels
                                                       interleaved:NO]; // Float32 is usually non-interleaved in AVAudioEngine
    
    [self.engine connect:self.playerNode to:self.engine.mainMixerNode format:self.audioFormat];
    
    NSError *error = nil;
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
            // Convert and de-interleave
            dst[ch][frame] = src[frame * self.streamInfo.channels + ch] / 32768.0f;
        }
    }
    
    // 3. Calculate Timestamp
    double serverTimeMs = (sec * 1000.0) + (usec / 1000.0);
    double latencyMs = 1000.0; // Hardcoded 1s latency
    double targetPlayTimeMs = serverTimeMs + latencyMs;
    
    uint64_t machTime = [self.timeProvider machTimeForServerTimeMs:targetPlayTimeMs];
    
    AVAudioTime *audioTime = [[AVAudioTime alloc] initWithHostTime:machTime];
    
    // 4. Schedule
    [self.playerNode scheduleBuffer:buffer atTime:audioTime options:0 completionHandler:nil];
}

@end