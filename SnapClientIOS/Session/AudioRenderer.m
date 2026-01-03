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
    
    // Create Audio Format (16-bit Int is standard for Snapcast FLAC)
    // AVAudioFormat usually prefers Float32. We might need to convert or tell it to handle Int16.
    // Snapserver sends Interleaved Int16 usually.
    // AVAudioCommonFormat: AVAudioPCMFormatInt16
    self.audioFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                        sampleRate:self.streamInfo.sampleRate
                                                          channels:self.streamInfo.channels
                                                       interleaved:YES];
    
    [self.engine connect:self.playerNode to:self.engine.mainMixerNode format:self.audioFormat];
    
    NSError *error = nil;
    if (![self.engine startAndReturnError:&error]) {
        NSLog(@"Error starting AVAudioEngine: %@", error);
    }
    
    [self.playerNode play];
}

- (void)feedPCMData:(NSData *)pcmData serverSec:(int32_t)sec serverUsec:(int32_t)usec {
    // 1. Create Buffer
    // We need to copy bytes into AVAudioPCMBuffer
    // AVAudioPCMBuffer for Int16 Interleaved provides int16ChannelData (if deinterleaved) or...
    // Wait, AVAudioPCMBuffer doesn't easily support Interleaved access via int16ChannelData if it's Int16?
    // Actually, initWithCommonFormat:AVAudioPCMFormatInt16 interleaved:YES
    // buffer.int16ChannelData[0] points to the interleaved buffer.
    
    AVAudioFrameCount frameCount = (AVAudioFrameCount)(pcmData.length / self.audioFormat.streamDescription->mBytesPerFrame);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.audioFormat frameCapacity:frameCount];
    buffer.frameLength = frameCount;
    
    // Copy data
    memcpy(buffer.int16ChannelData[0], pcmData.bytes, pcmData.length);
    
    // 2. Calculate Timestamp
    double serverTimeMs = (sec * 1000.0) + (usec / 1000.0);
    double latencyMs = 1000.0; // Hardcoded 1s latency for now (matches Snapcast default)
    double targetPlayTimeMs = serverTimeMs + latencyMs;
    
    uint64_t machTime = [self.timeProvider machTimeForServerTimeMs:targetPlayTimeMs];
    
    AVAudioTime *audioTime = [[AVAudioTime alloc] initWithHostTime:machTime];
    
    // 3. Schedule
    [self.playerNode scheduleBuffer:buffer atTime:audioTime completionHandler:nil];
    
    // Safety check: If machTime is in the past, AVAudioEngine usually plays immediately.
    // If it's too far in future, it waits.
}

@end