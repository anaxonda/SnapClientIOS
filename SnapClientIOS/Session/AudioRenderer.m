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

@interface PCMChunk : NSObject

@property (nonatomic, strong) NSData *data;
@property (nonatomic, assign) double timestampMs;
@property (nonatomic, assign) NSUInteger frameCount;
@property (nonatomic, assign) NSUInteger idx;
@property (nonatomic, assign) NSUInteger channels;
@property (nonatomic, assign) double sampleRate;

- (instancetype)initWithData:(NSData *)data
                  timestampMs:(double)timestampMs
                    channels:(NSUInteger)channels
                   sampleRate:(double)sampleRate;
- (double)startMs;
- (double)durationMs;
- (NSUInteger)remainingFrames;

@end

@implementation PCMChunk

- (instancetype)initWithData:(NSData *)data
                  timestampMs:(double)timestampMs
                    channels:(NSUInteger)channels
                   sampleRate:(double)sampleRate {
    if (self = [super init]) {
        _data = data;
        _timestampMs = timestampMs;
        _channels = channels;
        _sampleRate = sampleRate;
        _frameCount = (NSUInteger)(data.length / (channels * sizeof(int16_t)));
        _idx = 0;
    }
    return self;
}

- (double)startMs {
    return self.timestampMs + ((double)self.idx / self.sampleRate) * 1000.0;
}

- (double)durationMs {
    if (self.idx >= self.frameCount) {
        return 0.0;
    }
    return ((double)(self.frameCount - self.idx) / self.sampleRate) * 1000.0;
}

- (NSUInteger)remainingFrames {
    if (self.idx >= self.frameCount) {
        return 0;
    }
    return self.frameCount - self.idx;
}

@end

@interface AudioRenderer ()

@property (nonatomic, strong) StreamInfo *streamInfo;
@property (nonatomic, strong) TimeProvider *timeProvider;
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) AVAudioPlayerNode *playerNode;
@property (nonatomic, strong) AVAudioFormat *audioFormat;
@property (nonatomic, assign) NSInteger serverBufferMs;
@property (nonatomic, assign) NSInteger clientLatencyMs;
@property (nonatomic, assign) NSInteger playbackBufferMs;
@property (nonatomic, assign) double bufferDurationMs;
@property (nonatomic, assign) AVAudioFrameCount bufferFrameCount;
@property (nonatomic, assign) NSInteger audioBufferCount;
@property (nonatomic, assign) float currentVolume;
@property (nonatomic, assign) BOOL isMuted;
@property (nonatomic, assign) double nextPlayTimeMs;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, strong) NSMutableArray<PCMChunk *> *chunks;
@property (nonatomic, strong) PCMChunk *currentChunk;

@end

@implementation AudioRenderer

- (instancetype)initWithStreamInfo:(StreamInfo *)info timeProvider:(TimeProvider *)timeProvider {
    if (self = [super init]) {
        self.streamInfo = info;
        self.timeProvider = timeProvider;
        self.serverBufferMs = 1000;
        self.clientLatencyMs = 0;
        [self updatePlaybackBuffer];
        self.bufferDurationMs = 80.0;
        [self updateBufferFrameCount];
        self.audioBufferCount = 3;
        self.currentVolume = 1.0;
        self.isMuted = NO;
        self.chunks = [NSMutableArray array];
        self.currentChunk = nil;
        self.isPlaying = NO;
        self.nextPlayTimeMs = 0.0;
        [self initAudioEngine];
    }
    return self;
}

- (void)setServerBufferMs:(NSInteger)bufferMs clientLatencyMs:(NSInteger)latencyMs {
    self.serverBufferMs = bufferMs;
    self.clientLatencyMs = latencyMs;
    [self updatePlaybackBuffer];
    NSLog(@"AudioRenderer: Server buffer=%ldms, client latency=%ldms, playback buffer=%ldms",
          (long)self.serverBufferMs, (long)self.clientLatencyMs, (long)self.playbackBufferMs);
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

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAudioSessionInterruption:) name:AVAudioSessionInterruptionNotification object:session];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAudioSessionRouteChange:) name:AVAudioSessionRouteChangeNotification object:session];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleEngineConfigurationChange:) name:AVAudioEngineConfigurationChangeNotification object:self.engine];
}

- (void)handleAudioSessionInterruption:(NSNotification *)note {
    NSNumber *typeValue = note.userInfo[AVAudioSessionInterruptionTypeKey];
    AVAudioSessionInterruptionType type = (AVAudioSessionInterruptionType)[typeValue unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        NSLog(@"AudioSession interruption: began");
    } else if (type == AVAudioSessionInterruptionTypeEnded) {
        NSNumber *optionValue = note.userInfo[AVAudioSessionInterruptionOptionKey];
        AVAudioSessionInterruptionOptions options = (AVAudioSessionInterruptionOptions)[optionValue unsignedIntegerValue];
        NSLog(@"AudioSession interruption: ended (options=%lu)", (unsigned long)options);
    } else {
        NSLog(@"AudioSession interruption: unknown (%lu)", (unsigned long)type);
    }
}

- (void)handleAudioSessionRouteChange:(NSNotification *)note {
    NSNumber *reasonValue = note.userInfo[AVAudioSessionRouteChangeReasonKey];
    AVAudioSessionRouteChangeReason reason = (AVAudioSessionRouteChangeReason)[reasonValue unsignedIntegerValue];
    NSLog(@"AudioSession route change: reason=%lu", (unsigned long)reason);
}

- (void)handleEngineConfigurationChange:(NSNotification *)note {
    NSLog(@"AudioEngine configuration change");
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)feedPCMData:(NSData *)pcmData serverSec:(int32_t)sec serverUsec:(int32_t)usec {
    double serverTimeMs = (sec * 1000.0) + (usec / 1000.0);
    PCMChunk *chunk = [[PCMChunk alloc] initWithData:pcmData
                                          timestampMs:serverTimeMs
                                            channels:self.streamInfo.channels
                                           sampleRate:self.streamInfo.sampleRate];
    @synchronized (self) {
        [self.chunks addObject:chunk];
        [self dropOldChunksLocked];
    }
    [self startPlaybackIfNeeded];
}

- (void)updatePlaybackBuffer {
    NSInteger playback = self.serverBufferMs - self.clientLatencyMs;
    if (playback < 0) {
        playback = 0;
    }
    self.playbackBufferMs = playback;
}

- (void)updateBufferFrameCount {
    if (self.streamInfo.sampleRate <= 0) {
        self.bufferFrameCount = 0;
        return;
    }
    double frames = floor((self.bufferDurationMs * self.streamInfo.sampleRate) / 1000.0);
    if (frames < 1) {
        frames = 1;
    }
    self.bufferFrameCount = (AVAudioFrameCount)frames;
}

- (void)startPlaybackIfNeeded {
    if (self.isPlaying || self.bufferFrameCount == 0) {
        return;
    }
    self.isPlaying = YES;
    self.nextPlayTimeMs = [self.timeProvider nowMs] + 100.0;
    for (NSInteger i = 0; i < self.audioBufferCount; i++) {
        [self scheduleNextBuffer];
    }
    [self.playerNode play];
}

- (void)scheduleNextBuffer {
    if (!self.isPlaying || self.bufferFrameCount == 0) {
        return;
    }

    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.audioFormat
                                                             frameCapacity:self.bufferFrameCount];
    buffer.frameLength = self.bufferFrameCount;

    double hwLatencyMs = [AVAudioSession sharedInstance].outputLatency * 1000.0;
    double playTimeMs = self.nextPlayTimeMs + hwLatencyMs - self.playbackBufferMs;
    [self fillBuffer:buffer playTimeMs:playTimeMs];

    uint64_t hostTime = [self.timeProvider msToMach:self.nextPlayTimeMs];
    uint64_t now = mach_absolute_time();
    AVAudioTime *audioTime = nil;
    if (hostTime > now) {
        audioTime = [[AVAudioTime alloc] initWithHostTime:hostTime];
    }

    __weak typeof(self) weakSelf = self;
    [self.playerNode scheduleBuffer:buffer atTime:audioTime options:0 completionHandler:^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf scheduleNextBuffer];
    }];

    self.nextPlayTimeMs += self.bufferDurationMs;
}

- (void)fillBuffer:(AVAudioPCMBuffer *)buffer playTimeMs:(double)playTimeMs {
    AVAudioFrameCount frames = buffer.frameLength;
    if (frames == 0 || self.streamInfo.sampleRate <= 0) {
        return;
    }

    float *const *dst = buffer.floatChannelData;
    NSUInteger channels = self.streamInfo.channels;
    for (NSUInteger ch = 0; ch < channels; ch++) {
        memset(dst[ch], 0, frames * sizeof(float));
    }

    double serverPlayTimeMs = [self.timeProvider serverTimeForLocalTimeMs:playTimeMs];

    PCMChunk *chunk = nil;
    @synchronized (self) {
        if (!self.currentChunk) {
            self.currentChunk = [self popChunkLocked];
        }
        chunk = self.currentChunk;
    }

    if (!chunk) {
        return;
    }

    double reqChunkDuration = ((double)frames / self.streamInfo.sampleRate) * 1000.0;
    double age = serverPlayTimeMs - [chunk startMs];

    if (age < -reqChunkDuration) {
        static CFAbsoluteTime lastYoungLog = 0;
        CFAbsoluteTime nowTime = CFAbsoluteTimeGetCurrent();
        if (nowTime - lastYoungLog >= 5.0) {
            NSLog(@"AudioRenderer: chunk too young (age=%.2fms, req=%.2fms)", age, reqChunkDuration);
            lastYoungLog = nowTime;
        }
        return;
    }

    NSInteger read = 0;
    NSInteger pos = 0;

    if (fabs(age) > 5.0) {
        if (age > 0) {
            @synchronized (self) {
                while (self.currentChunk && age > [self.currentChunk durationMs]) {
                    NSLog(@"AudioRenderer: drop chunk (age=%.2fms > %.2fms)",
                          age, [self.currentChunk durationMs]);
                    self.currentChunk = [self popChunkLocked];
                    if (!self.currentChunk) {
                        break;
                    }
                    age = serverPlayTimeMs - [self.currentChunk startMs];
                }
                chunk = self.currentChunk;
            }
        }

        if (!chunk) {
            return;
        }

        if (age > 0) {
            NSUInteger skipFrames = (NSUInteger)floor(age * chunk.sampleRate / 1000.0);
            if (skipFrames > 0) {
                chunk.idx = MIN(chunk.idx + skipFrames, chunk.frameCount);
                NSLog(@"AudioRenderer: fast forward %.2fms (%lu frames)", age, (unsigned long)skipFrames);
            }
        } else if (age < 0) {
            NSUInteger silentFrames = (NSUInteger)floor(-age * chunk.sampleRate / 1000.0);
            if (silentFrames > frames) {
                silentFrames = frames;
            }
            read = (NSInteger)silentFrames;
            pos = (NSInteger)silentFrames;
            NSLog(@"AudioRenderer: insert silence %.2fms (%lu frames)", -age, (unsigned long)silentFrames);
        }
        age = 0.0;
    }

    NSInteger addFrames = 0;
    if (age > 0.1) {
        addFrames = (NSInteger)ceil(age);
    } else if (age < -0.1) {
        addFrames = (NSInteger)floor(age);
    }

    NSInteger readFrames = (NSInteger)frames + addFrames - read;
    if (readFrames < 0) {
        readFrames = 0;
    }

    NSInteger everyN = 0;
    if (addFrames != 0) {
        NSInteger absAddFrames = (addFrames < 0) ? -addFrames : addFrames;
        everyN = (NSInteger)ceil((double)(frames + addFrames - read) / ((double)absAddFrames + 1.0));
    }

    while (read < readFrames && chunk && pos < (NSInteger)frames) {
        NSUInteger available = [chunk remainingFrames];
        NSUInteger remaining = (NSUInteger)(readFrames - read);
        NSUInteger framesToRead = MIN(available, remaining);

        int16_t *src = (int16_t *)chunk.data.bytes;
        NSUInteger framesRead = 0;
        for (NSUInteger i = 0; i < framesToRead && pos < (NSInteger)frames; i++) {
            NSUInteger srcIndex = (chunk.idx + i) * channels;
            for (NSUInteger ch = 0; ch < channels; ch++) {
                dst[ch][pos] = src[srcIndex + ch] / 32768.0f;
            }

            read++;
            if (everyN != 0 && (read % everyN == 0)) {
                if (addFrames > 0) {
                    if (pos > 0) {
                        pos--;
                    }
                } else if (pos + 1 < (NSInteger)frames) {
                    for (NSUInteger ch = 0; ch < channels; ch++) {
                        dst[ch][pos + 1] = dst[ch][pos];
                    }
                    pos++;
                }
            }
            pos++;
            framesRead++;
        }

        chunk.idx += framesRead;
        if (chunk.idx >= chunk.frameCount) {
            @synchronized (self) {
                self.currentChunk = [self popChunkLocked];
            }
            chunk = self.currentChunk;
        }
    }

    if (read < (NSInteger)frames) {
        static CFAbsoluteTime lastEmptyLog = 0;
        CFAbsoluteTime nowTime = CFAbsoluteTimeGetCurrent();
        if (nowTime - lastEmptyLog >= 5.0) {
            NSUInteger chunkCount = 0;
            @synchronized (self) {
                chunkCount = self.chunks.count;
            }
            NSLog(@"AudioRenderer: underrun (read=%ld/%u, chunks=%lu)",
                  (long)read, (unsigned int)frames, (unsigned long)chunkCount);
            lastEmptyLog = nowTime;
        }
    }
}

- (PCMChunk *)popChunkLocked {
    if (self.chunks.count == 0) {
        return nil;
    }
    PCMChunk *chunk = self.chunks.firstObject;
    [self.chunks removeObjectAtIndex:0];
    return chunk;
}

- (void)dropOldChunksLocked {
    double serverNow = [self.timeProvider serverNowMs];
    double maxAge = 5000.0 + self.playbackBufferMs;
    while (self.chunks.count > 0) {
        PCMChunk *first = self.chunks.firstObject;
        double age = serverNow - first.timestampMs;
        if (age <= maxAge) {
            break;
        }
        NSLog(@"AudioRenderer: drop old chunk %.2fms (max=%.2fms)", age, maxAge);
        [self.chunks removeObjectAtIndex:0];
    }
}

@end
