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
#include <math.h>

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

@interface MedianBuffer : NSObject

@property (nonatomic, assign) NSUInteger capacity;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *values;

- (instancetype)initWithCapacity:(NSUInteger)capacity;
- (void)addValue:(double)value;
- (BOOL)isFull;
- (double)median;
- (void)clear;

@end

@implementation MedianBuffer

- (instancetype)initWithCapacity:(NSUInteger)capacity {
    if (self = [super init]) {
        _capacity = capacity;
        _values = [NSMutableArray arrayWithCapacity:capacity];
    }
    return self;
}

- (void)addValue:(double)value {
    [self.values addObject:@(value)];
    if (self.values.count > self.capacity) {
        [self.values removeObjectAtIndex:0];
    }
}

- (BOOL)isFull {
    return self.values.count == self.capacity;
}

- (double)median {
    if (self.values.count == 0) {
        return 0.0;
    }
    NSArray<NSNumber *> *sorted = [self.values sortedArrayUsingSelector:@selector(compare:)];
    return sorted[sorted.count / 2].doubleValue;
}

- (void)clear {
    [self.values removeAllObjects];
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
@property (nonatomic, assign) NSInteger localPlayerLatencyMs;
@property (nonatomic, assign) NSInteger playbackBufferMs;
@property (nonatomic, assign) double bufferDurationMs;
@property (nonatomic, assign) AVAudioFrameCount bufferFrameCount;
@property (nonatomic, assign) NSInteger audioBufferCount;
@property (nonatomic, assign) float currentVolume;
@property (nonatomic, assign) BOOL isMuted;
@property (nonatomic, assign) double nextPlayTimeMs;
@property (nonatomic, assign) double nextPlaySampleTime;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) BOOL hardSync;
@property (nonatomic, assign) double medianAgeMs;
@property (nonatomic, assign) double shortMedianAgeMs;
@property (nonatomic, assign) int32_t correctAfterXFrames;
@property (nonatomic, assign) uint32_t playedFrames;
@property (nonatomic, assign) CFAbsoluteTime lastRestartTime;
@property (nonatomic, assign) CFAbsoluteTime lastSyncLogTime;
@property (nonatomic, assign) CFAbsoluteTime lastDacLogTime;
@property (nonatomic, assign) CFAbsoluteTime lastAnchorTime;
@property (nonatomic, strong) MedianBuffer *bufferMedian;
@property (nonatomic, strong) MedianBuffer *shortBuffer;
@property (nonatomic, strong) MedianBuffer *miniBuffer;
@property (nonatomic, strong) NSMutableData *readBuffer;
@property (nonatomic, strong) NSMutableData *correctedBuffer;
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
        self.localPlayerLatencyMs = 0;
        [self updatePlaybackBuffer];
        self.bufferDurationMs = 40.0;
        [self updateBufferFrameCount];
        self.audioBufferCount = 3;
        self.currentVolume = 1.0;
        self.isMuted = NO;
        self.chunks = [NSMutableArray array];
        self.currentChunk = nil;
        self.isPlaying = NO;
        self.nextPlayTimeMs = 0.0;
        self.nextPlaySampleTime = 0.0;
        self.hardSync = YES;
        self.medianAgeMs = 0.0;
        self.shortMedianAgeMs = 0.0;
        self.correctAfterXFrames = 0;
        self.playedFrames = 0;
        self.lastRestartTime = 0.0;
        self.lastSyncLogTime = 0.0;
        self.lastDacLogTime = 0.0;
        self.lastAnchorTime = 0.0;
        self.bufferMedian = [[MedianBuffer alloc] initWithCapacity:500];
        self.shortBuffer = [[MedianBuffer alloc] initWithCapacity:100];
        self.miniBuffer = [[MedianBuffer alloc] initWithCapacity:20];
        self.readBuffer = [NSMutableData data];
        self.correctedBuffer = [NSMutableData data];
        [self initAudioEngine];
    }
    return self;
}

- (void)setServerBufferMs:(NSInteger)bufferMs clientLatencyMs:(NSInteger)latencyMs {
    self.serverBufferMs = bufferMs;
    self.clientLatencyMs = latencyMs;
    [self updatePlaybackBuffer];
    NSLog(@"AudioRenderer: Server buffer=%ldms, client latency=%ldms, local latency=%ldms, playback buffer=%ldms",
          (long)self.serverBufferMs, (long)self.clientLatencyMs, (long)self.localPlayerLatencyMs,
          (long)self.playbackBufferMs);
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
    self.localPlayerLatencyMs = (NSInteger)lround(session.IOBufferDuration * 1000.0);
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
        self.isPlaying = NO;
    } else if (type == AVAudioSessionInterruptionTypeEnded) {
        NSNumber *optionValue = note.userInfo[AVAudioSessionInterruptionOptionKey];
        AVAudioSessionInterruptionOptions options = (AVAudioSessionInterruptionOptions)[optionValue unsignedIntegerValue];
        NSLog(@"AudioSession interruption: ended (options=%lu)", (unsigned long)options);
        if (options & AVAudioSessionInterruptionOptionShouldResume) {
            [self restartPlaybackWithReason:@"interruption ended"];
        }
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
    [self restartPlaybackWithReason:@"engine configuration change"];
}

- (void)restartPlaybackWithReason:(NSString *)reason {
    dispatch_async(dispatch_get_main_queue(), ^{
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - self.lastRestartTime < 1.0) {
            return;
        }
        self.lastRestartTime = now;

        NSLog(@"AudioRenderer: restart playback (%@)", reason);

        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *error = nil;
        [session setActive:YES error:&error];
        if (error) {
            NSLog(@"Error reactivating session: %@", error);
        }

        if (self.engine) {
            [self.playerNode stop];
            [self.engine stop];
            if (![self.engine startAndReturnError:&error]) {
                NSLog(@"Error restarting AVAudioEngine: %@", error);
                return;
            }
        }

        self.isPlaying = NO;
        self.nextPlayTimeMs = 0.0;
        self.nextPlaySampleTime = 0.0;
        self.hardSync = YES;
        self.playedFrames = 0;
        [self resetSyncBuffers];
        [self startPlaybackIfNeeded];
    });
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

- (void)resetSyncBuffers {
    [self.bufferMedian clear];
    [self.shortBuffer clear];
    [self.miniBuffer clear];
    self.medianAgeMs = 0.0;
    self.shortMedianAgeMs = 0.0;
}

- (void)setRealSampleRate:(double)sampleRate {
    double nominalRate = self.streamInfo.sampleRate;
    if (nominalRate <= 0.0 || fabs(sampleRate - nominalRate) < 0.000001) {
        self.correctAfterXFrames = 0;
        return;
    }
    double ratio = nominalRate / sampleRate;
    double denom = ratio - 1.0;
    if (fabs(denom) < 0.000000001) {
        self.correctAfterXFrames = 0;
        return;
    }
    self.correctAfterXFrames = (int32_t)llround(ratio / denom);
}

- (void)startPlaybackIfNeeded {
    if (self.isPlaying || self.bufferFrameCount == 0) {
        return;
    }
    if (![self.timeProvider hasSync]) {
        return;
    }
    self.isPlaying = YES;
    self.nextPlayTimeMs = [self.timeProvider nowMs] + 100.0;
    self.nextPlaySampleTime = 0.0;
    self.hardSync = YES;
    self.playedFrames = 0;
    [self resetSyncBuffers];
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

    double nowMs = [self.timeProvider nowMs];
    double outputBufferDacTimeMs = [self estimateOutputBufferDacTimeMs:nowMs];
    [self fillBuffer:buffer outputBufferDacTimeMs:outputBufferDacTimeMs];

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
    if (self.nextPlaySampleTime > 0.0) {
        self.nextPlaySampleTime += (double)self.bufferFrameCount;
    }
}

- (double)estimateOutputBufferDacTimeMs:(double)nowMs {
    static const CFAbsoluteTime kReanchorCooldownSec = 1.0;
    static const CFAbsoluteTime kPeriodicReanchorSec = 30.0;

    double hwLatencyMs = [AVAudioSession sharedInstance].outputLatency * 1000.0;
    double sampleRate = self.streamInfo.sampleRate;
    if (sampleRate <= 0.0) {
        double fallbackMs = (self.nextPlayTimeMs - nowMs) + hwLatencyMs + 15.0;
        [self logDacEstimateWithMode:@"no-samplerate"
                         sampleRate:sampleRate
                   currentSampleTime:0.0
                     nextSampleTime:self.nextPlaySampleTime
                      queueFrames:0.0
                      rawQueueFrames:0.0
                         queueMs:0.0
                       hwLatencyMs:hwLatencyMs
                         dacTimeMs:fallbackMs];
        return fallbackMs;
    }

    double currentSampleTime = 0.0;
    if ([self getCurrentSampleTime:&currentSampleTime]) {
        if (self.nextPlaySampleTime <= 0.0) {
            double deltaMs = self.nextPlayTimeMs - nowMs;
            double deltaFrames = (deltaMs / 1000.0) * sampleRate;
            self.nextPlaySampleTime = currentSampleTime + deltaFrames;
            self.lastAnchorTime = CFAbsoluteTimeGetCurrent();
        }

        double rawQueueFrames = self.nextPlaySampleTime - currentSampleTime;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        double timeToNextMs = self.nextPlayTimeMs - nowMs;
        if (rawQueueFrames < 0.0 && (now - self.lastAnchorTime) >= kReanchorCooldownSec) {
            double leadMs = self.bufferDurationMs * MAX(self.audioBufferCount, 2);
            timeToNextMs = MAX(timeToNextMs, leadMs);
            self.nextPlayTimeMs = nowMs + timeToNextMs;
            double deltaFrames = (timeToNextMs / 1000.0) * sampleRate;
            self.nextPlaySampleTime = currentSampleTime + deltaFrames;
            self.lastAnchorTime = now;
            rawQueueFrames = self.nextPlaySampleTime - currentSampleTime;
            NSLog(@"AudioRenderer: reanchor reason=behind rawQueueFrames=%.0f current=%.0f next=%.0f nextPlay=%.2f",
                  rawQueueFrames, currentSampleTime, self.nextPlaySampleTime, self.nextPlayTimeMs);
        } else if ((now - self.lastAnchorTime) >= kPeriodicReanchorSec) {
            double deltaFrames = (timeToNextMs / 1000.0) * sampleRate;
            double targetNextSample = currentSampleTime + deltaFrames;
            double deltaFramesToTarget = targetNextSample - self.nextPlaySampleTime;
            double thresholdFrames = MAX((double)self.bufferFrameCount, sampleRate * 0.01);
            if (fabs(deltaFramesToTarget) > thresholdFrames) {
                self.nextPlaySampleTime = targetNextSample;
                self.lastAnchorTime = now;
                rawQueueFrames = self.nextPlaySampleTime - currentSampleTime;
                NSLog(@"AudioRenderer: reanchor reason=periodic deltaFrames=%.0f current=%.0f next=%.0f nextPlay=%.2f",
                      deltaFramesToTarget, currentSampleTime, self.nextPlaySampleTime, self.nextPlayTimeMs);
            }
        }
        double queueFrames = rawQueueFrames;
        if (queueFrames < 0.0) {
            queueFrames = 0.0;
        }
        double queueMs = (queueFrames / sampleRate) * 1000.0;
        double dacMs = queueMs + hwLatencyMs + 15.0;
        [self logDacEstimateWithMode:@"sampletime"
                         sampleRate:sampleRate
                   currentSampleTime:currentSampleTime
                     nextSampleTime:self.nextPlaySampleTime
                      queueFrames:queueFrames
                      rawQueueFrames:rawQueueFrames
                         queueMs:queueMs
                       hwLatencyMs:hwLatencyMs
                         dacTimeMs:dacMs];
        return dacMs;
    }

    double fallbackMs = (self.nextPlayTimeMs - nowMs) + hwLatencyMs + 15.0;
    [self logDacEstimateWithMode:@"fallback"
                     sampleRate:sampleRate
               currentSampleTime:0.0
                 nextSampleTime:self.nextPlaySampleTime
                  queueFrames:0.0
                  rawQueueFrames:0.0
                     queueMs:0.0
                   hwLatencyMs:hwLatencyMs
                     dacTimeMs:fallbackMs];
    return fallbackMs;
}

- (BOOL)getCurrentSampleTime:(double *)sampleTime {
    AVAudioTime *nodeTime = self.playerNode.lastRenderTime;
    if (!nodeTime || nodeTime.hostTime == 0) {
        return NO;
    }
    AVAudioTime *playerTime = [self.playerNode playerTimeForNodeTime:nodeTime];
    if (!playerTime || playerTime.sampleRate <= 0 || playerTime.sampleTime < 0) {
        return NO;
    }
    if (sampleTime) {
        *sampleTime = (double)playerTime.sampleTime;
    }
    return YES;
}

- (void)logDacEstimateWithMode:(NSString *)mode
                    sampleRate:(double)sampleRate
              currentSampleTime:(double)currentSampleTime
                nextSampleTime:(double)nextSampleTime
                     queueFrames:(double)queueFrames
                     rawQueueFrames:(double)rawQueueFrames
                        queueMs:(double)queueMs
                      hwLatencyMs:(double)hwLatencyMs
                        dacTimeMs:(double)dacTimeMs {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - self.lastDacLogTime < 5.0) {
        return;
    }
    self.lastDacLogTime = now;
    NSLog(@"AudioRenderer: dac estimate mode=%@ sr=%.1f current=%.0f next=%.0f rawQueueFrames=%.0f queueFrames=%.0f queueMs=%.2f hw=%.2f dac=%.2f nextPlay=%.2f",
          mode, sampleRate, currentSampleTime, nextSampleTime, rawQueueFrames, queueFrames, queueMs, hwLatencyMs, dacTimeMs, self.nextPlayTimeMs);
}

- (void)logSyncStatsIfNeededWithServerNowMs:(double)serverNowMs
                                    startMs:(double)startMs
                                      ageMs:(double)ageMs
                       outputBufferDacTimeMs:(double)outputBufferDacTimeMs
                                   hardSync:(BOOL)hardSync {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - self.lastSyncLogTime < 5.0) {
        return;
    }
    self.lastSyncLogTime = now;
    double rawAgeMs = serverNowMs - startMs;
    double miniMedian = [self.miniBuffer median];
    NSLog(@"AudioRenderer: sync stats hard=%d rawAge=%.2f age=%.2f dac=%.2f playback=%.0f serverNow=%.2f start=%.2f nextPlay=%.2f med=%.2f short=%.2f mini=%.2f",
          hardSync ? 1 : 0, rawAgeMs, ageMs, outputBufferDacTimeMs, (double)self.playbackBufferMs,
          serverNowMs, startMs, self.nextPlayTimeMs, self.medianAgeMs, self.shortMedianAgeMs, miniMedian);
}

- (void)fillBuffer:(AVAudioPCMBuffer *)buffer outputBufferDacTimeMs:(double)outputBufferDacTimeMs {
    AVAudioFrameCount frames = buffer.frameLength;
    if (frames == 0 || self.streamInfo.sampleRate <= 0) {
        return;
    }

    float *const *dst = buffer.floatChannelData;
    NSUInteger channels = self.streamInfo.channels;
    for (NSUInteger ch = 0; ch < channels; ch++) {
        memset(dst[ch], 0, frames * sizeof(float));
    }

    double serverNowMs = [self.timeProvider serverNowMs];

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

    double reqChunkDurationMs = ((double)frames / self.streamInfo.sampleRate) * 1000.0;

    if (self.hardSync) {
        double ageMs = serverNowMs - [chunk startMs] - self.playbackBufferMs + outputBufferDacTimeMs;
        [self logSyncStatsIfNeededWithServerNowMs:serverNowMs
                                          startMs:[chunk startMs]
                                            ageMs:ageMs
                             outputBufferDacTimeMs:outputBufferDacTimeMs
                                         hardSync:YES];
        if (ageMs < -reqChunkDurationMs) {
            return;
        }

        if (ageMs > 0.0) {
            @synchronized (self) {
                while (self.currentChunk && ageMs > [self.currentChunk durationMs]) {
                    self.currentChunk = [self popChunkLocked];
                    if (!self.currentChunk) {
                        break;
                    }
                    ageMs = serverNowMs - [self.currentChunk startMs] - self.playbackBufferMs + outputBufferDacTimeMs;
                }
                chunk = self.currentChunk;
            }
        }

        if (!chunk) {
            return;
        }

        if (ageMs > 0.0) {
            NSUInteger skipFrames = (NSUInteger)floor(ageMs * chunk.sampleRate / 1000.0);
            if (skipFrames > 0) {
                chunk.idx = MIN(chunk.idx + skipFrames, chunk.frameCount);
            }
            ageMs = 0.0;
        }

        NSUInteger silentFrames = 0;
        if (ageMs < 0.0) {
            silentFrames = (NSUInteger)floor(-ageMs * self.streamInfo.sampleRate / 1000.0);
            if (silentFrames > frames) {
                silentFrames = frames;
            }
        }

        if (silentFrames < frames) {
            double startMs = [self fillPCMDataIntoBuffer:buffer frames:(frames - silentFrames) framesCorrection:0 startOffset:silentFrames];
            if (!isnan(startMs)) {
                self.hardSync = NO;
                [self resetSyncBuffers];
            }
        }
        return;
    }

    int32_t framesCorrection = 0;
    if (self.correctAfterXFrames != 0) {
        self.playedFrames += frames;
        uint32_t absCorrect = (uint32_t)abs(self.correctAfterXFrames);
        if (self.playedFrames >= absCorrect) {
            int32_t sign = (self.correctAfterXFrames < 0) ? -1 : 1;
            framesCorrection = sign * (int32_t)(self.playedFrames / absCorrect);
            self.playedFrames = self.playedFrames % absCorrect;
        }
    }

    double startMs = [self fillPCMDataIntoBuffer:buffer frames:frames framesCorrection:framesCorrection startOffset:0];
    if (isnan(startMs)) {
        return;
    }

    double ageMs = serverNowMs - startMs - self.playbackBufferMs + outputBufferDacTimeMs;
    [self logSyncStatsIfNeededWithServerNowMs:serverNowMs
                                      startMs:startMs
                                        ageMs:ageMs
                         outputBufferDacTimeMs:outputBufferDacTimeMs
                                     hardSync:NO];
    [self.bufferMedian addValue:ageMs];
    [self.shortBuffer addValue:ageMs];
    [self.miniBuffer addValue:ageMs];
    self.medianAgeMs = [self.bufferMedian median];
    self.shortMedianAgeMs = [self.shortBuffer median];
    double miniMedian = [self.miniBuffer median];

    if ([self.bufferMedian isFull] && fabs(self.medianAgeMs) > 2.0 && fabs(ageMs) > 0.5) {
        self.hardSync = YES;
    } else if ([self.shortBuffer isFull] && fabs(self.shortMedianAgeMs) > 5.0 && fabs(ageMs) > 0.5) {
        self.hardSync = YES;
    } else if ([self.miniBuffer isFull] && fabs(miniMedian) > 50.0 && fabs(ageMs) > 0.5) {
        self.hardSync = YES;
    } else if (fabs(ageMs) > 500.0) {
        self.hardSync = YES;
    } else if ([self.shortBuffer isFull]) {
        if (self.shortMedianAgeMs > 0.1 && miniMedian > 0.05 && ageMs > 0.05) {
            double rate = (self.shortMedianAgeMs / 100.0) * 0.00005;
            rate = 1.0 - MIN(rate, 0.0005);
            [self setRealSampleRate:self.streamInfo.sampleRate * rate];
        } else if (self.shortMedianAgeMs < -0.1 && miniMedian < -0.05 && ageMs < -0.05) {
            double rate = (self.shortMedianAgeMs / 100.0) * 0.00005;
            rate = 1.0 - MAX(rate, -0.0005);
            [self setRealSampleRate:self.streamInfo.sampleRate * rate];
        } else {
            [self setRealSampleRate:self.streamInfo.sampleRate];
        }
    }
}

- (double)fillPCMDataIntoBuffer:(AVAudioPCMBuffer *)buffer
                         frames:(AVAudioFrameCount)frames
               framesCorrection:(int32_t)framesCorrection
                    startOffset:(NSUInteger)startOffset {
    if (frames == 0 || self.streamInfo.sampleRate <= 0) {
        return NAN;
    }

    if (framesCorrection < 0 && ((int32_t)frames + framesCorrection <= 0)) {
        framesCorrection = -((int32_t)frames) + 1;
    }

    int32_t toReadFrames = (int32_t)frames + framesCorrection;
    if (toReadFrames < 1) {
        toReadFrames = 1;
    }

    NSUInteger channels = self.streamInfo.channels;
    NSUInteger readSamples = (NSUInteger)toReadFrames * channels;
    [self.readBuffer setLength:readSamples * sizeof(int16_t)];
    memset(self.readBuffer.mutableBytes, 0, self.readBuffer.length);

    NSUInteger framesRead = 0;
    double startMs = [self readFramesIntoBuffer:(int16_t *)self.readBuffer.mutableBytes
                                         frames:(NSUInteger)toReadFrames
                                     framesRead:&framesRead];
    if (isnan(startMs)) {
        return NAN;
    }

    NSUInteger outSamples = (NSUInteger)frames * channels;
    [self.correctedBuffer setLength:outSamples * sizeof(int16_t)];
    int16_t *readData = (int16_t *)self.readBuffer.mutableBytes;
    int16_t *outData = (int16_t *)self.correctedBuffer.mutableBytes;

    if (framesCorrection == 0) {
        memcpy(outData, readData, outSamples * sizeof(int16_t));
    } else {
        NSUInteger max = (framesCorrection < 0) ? (NSUInteger)frames : (NSUInteger)toReadFrames;
        NSUInteger slices = (NSUInteger)abs(framesCorrection) + 1;
        if (slices > max) {
            slices = max;
        }
        NSUInteger size = max / slices;
        NSUInteger pos = 0;
        for (NSUInteger n = 0; n < slices; n++) {
            if (n + 1 == slices) {
                size = max - pos;
            }
            NSUInteger srcIndex = 0;
            NSUInteger dstIndex = 0;
            if (framesCorrection < 0) {
                srcIndex = pos - n;
                dstIndex = pos;
            } else {
                srcIndex = pos;
                dstIndex = pos - n;
            }
            memcpy(outData + (dstIndex * channels),
                   readData + (srcIndex * channels),
                   size * channels * sizeof(int16_t));
            pos += size;
        }
    }

    float *const *dst = buffer.floatChannelData;
    NSUInteger maxFrames = MIN((NSUInteger)frames, buffer.frameLength - startOffset);
    for (NSUInteger i = 0; i < maxFrames; i++) {
        NSUInteger srcIndex = i * channels;
        NSUInteger dstIndex = startOffset + i;
        for (NSUInteger ch = 0; ch < channels; ch++) {
            dst[ch][dstIndex] = outData[srcIndex + ch] / 32768.0f;
        }
    }

    NSUInteger expectedFrames = (NSUInteger)toReadFrames;
    if (framesRead < expectedFrames) {
        static CFAbsoluteTime lastEmptyLog = 0;
        CFAbsoluteTime nowTime = CFAbsoluteTimeGetCurrent();
        if (nowTime - lastEmptyLog >= 5.0) {
            NSUInteger chunkCount = 0;
            @synchronized (self) {
                chunkCount = self.chunks.count;
            }
            NSLog(@"AudioRenderer: underrun (read=%lu/%u, chunks=%lu)",
                  (unsigned long)framesRead, (unsigned int)expectedFrames, (unsigned long)chunkCount);
            lastEmptyLog = nowTime;
        }
    }

    return startMs;
}

- (double)readFramesIntoBuffer:(int16_t *)dest
                        frames:(NSUInteger)frames
                    framesRead:(NSUInteger *)framesRead {
    if (framesRead) {
        *framesRead = 0;
    }
    PCMChunk *chunk = nil;
    @synchronized (self) {
        if (!self.currentChunk) {
            self.currentChunk = [self popChunkLocked];
        }
        chunk = self.currentChunk;
    }
    if (!chunk) {
        return NAN;
    }

    double startMs = [chunk startMs];
    NSUInteger channels = self.streamInfo.channels;
    NSUInteger read = 0;
    while (read < frames && chunk) {
        NSUInteger available = [chunk remainingFrames];
        NSUInteger framesToRead = MIN(available, frames - read);
        int16_t *src = (int16_t *)chunk.data.bytes;
        memcpy(dest + (read * channels),
               src + (chunk.idx * channels),
               framesToRead * channels * sizeof(int16_t));
        read += framesToRead;
        chunk.idx += framesToRead;
        if (chunk.idx >= chunk.frameCount) {
            @synchronized (self) {
                self.currentChunk = [self popChunkLocked];
            }
            chunk = self.currentChunk;
        }
    }

    if (framesRead) {
        *framesRead = read;
    }
    if (read < frames) {
        memset(dest + (read * channels), 0, (frames - read) * channels * sizeof(int16_t));
    }
    return startMs;
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
