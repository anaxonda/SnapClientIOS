//
//  FlacDecoder.m
//  SnapClientIOS
//
//  Created by Lee Jun Kit on 31/12/20.
//

#import "FlacDecoder.h"
#include "FLACiOS/stream_decoder.h"

@interface FlacDecoder () {
    dispatch_queue_t decoderQueue;
    FLAC__StreamDecoder *decoder;
    StreamInfo *streamInfo;
}

@property (atomic, assign) int32_t currentSec;
@property (atomic, assign) int32_t currentUsec;
@property (nonatomic, strong) NSData *decodeBuffer;
@property (nonatomic, assign) NSUInteger decodeOffset;
@property (nonatomic, strong) NSMutableData *pcmOutput;
@property (nonatomic, assign) BOOL decoderInitialized;

@end

@implementation FlacDecoder

- (instancetype)init {
    if (self = [super init]) {
        decoderQueue = dispatch_queue_create("ljk.SnapClientIOS.decoderqueue", NULL);
        if ((decoder = FLAC__stream_decoder_new()) == NULL) {
            NSLog(@"Error allocating FLAC decoder!");
            @throw NSInternalInconsistencyException;
        }
        self.decoderInitialized = NO;
    }
    return self;
}

- (StreamInfo *)getStreamInfo {
    return streamInfo;
}

- (void)setCodecHeader:(NSData *)codecHeader {
    _codecHeader = codecHeader;

    if (!self.decoderInitialized) {
        FLAC__StreamDecoderInitStatus init_status;
        init_status = FLAC__stream_decoder_init_stream(decoder, read_cb, NULL, NULL, NULL, NULL, write_cb, metadata_cb, error_cb, (__bridge void *)(self));
        if (init_status != FLAC__STREAM_DECODER_INIT_STATUS_OK) {
            const char *errorMessage = FLAC__StreamDecoderInitStatusString[init_status];
            NSString *errorString = [NSString stringWithUTF8String:errorMessage];
            NSLog(@"Error initializing decoder: %@", errorString ?: @"unknown");
            @throw NSInternalInconsistencyException;
        }
        self.decoderInitialized = YES;
    }

    self.decodeBuffer = codecHeader;
    self.decodeOffset = 0;
    if (!FLAC__stream_decoder_process_until_end_of_metadata(decoder)) {
        NSLog(@"Error processing FLAC metadata");
    }
    if (!FLAC__stream_decoder_reset(decoder)) {
        NSLog(@"Error resetting FLAC decoder after header");
    }
    self.decodeBuffer = nil;
}

- (BOOL)feedAudioData:(NSData *)audioData serverSec:(int32_t)sec serverUsec:(int32_t)usec {
    if (streamInfo == nil) {
        NSLog(@"streamInfo is still NULL, ignoring the audio data for now");
        return NO;
    }
    if (!self.decoderInitialized || self.codecHeader.length == 0) {
        NSLog(@"Decoder not initialized or missing codec header");
        return NO;
    }

    NSMutableData *buffer = [NSMutableData dataWithCapacity:self.codecHeader.length + audioData.length];
    [buffer appendData:self.codecHeader];
    [buffer appendData:audioData];

    dispatch_async(decoderQueue, ^{
        self.currentSec = sec;
        self.currentUsec = usec;
        self.decodeBuffer = buffer;
        self.decodeOffset = 0;
        self.pcmOutput = [NSMutableData data];

        if (!FLAC__stream_decoder_reset(self->decoder)) {
            NSLog(@"Error resetting FLAC decoder before chunk");
        }
        if (!FLAC__stream_decoder_process_until_end_of_stream(self->decoder)) {
            NSLog(@"Error occurred during decoding!");
        }

        NSData *pcmData = [self.pcmOutput copy];
        self.decodeBuffer = nil;
        self.pcmOutput = nil;

        if (pcmData.length > 0) {
            [self.delegate decoder:self didDecodePCMData:pcmData serverSec:sec serverUsec:usec];
        }
    });

    return YES;
}

FLAC__StreamDecoderReadStatus read_cb(const FLAC__StreamDecoder *decoder, FLAC__byte buffer[], size_t *bytes, void *client_data) {
    FlacDecoder *THIS = (__bridge FlacDecoder *)client_data;
    NSData *decodeBuffer = THIS.decodeBuffer;
    if (!decodeBuffer || THIS.decodeOffset >= decodeBuffer.length) {
        *bytes = 0;
        return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM;
    }

    size_t remaining = decodeBuffer.length - THIS.decodeOffset;
    size_t toCopy = MIN(remaining, *bytes);
    memcpy(buffer, ((const uint8_t *)decodeBuffer.bytes) + THIS.decodeOffset, toCopy);
    THIS.decodeOffset += toCopy;
    *bytes = toCopy;

    return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE;
}

FLAC__StreamDecoderWriteStatus write_cb(const FLAC__StreamDecoder *decoder, const FLAC__Frame *frame, const FLAC__int32 * const buffer[], void *client_data) {
    FlacDecoder *THIS = (__bridge FlacDecoder *)client_data;
    StreamInfo *info = THIS->streamInfo;
    if (!info || info.sampleSize != 2) {
        return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
    }

    size_t bytes = frame->header.blocksize * info.frameSize;
    if (!THIS.pcmOutput) {
        THIS.pcmOutput = [NSMutableData data];
    }
    NSUInteger offset = THIS.pcmOutput.length;
    [THIS.pcmOutput setLength:(offset + bytes)];
    int16_t *pcmBuffer = (int16_t *)((uint8_t *)THIS.pcmOutput.mutableBytes + offset);

    for (size_t channel = 0; channel < info.channels; ++channel) {
        for (size_t i = 0; i < frame->header.blocksize; i++) {
            pcmBuffer[info.channels * i + channel] = (int16_t)buffer[channel][i];
        }
    }

    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

void metadata_cb(const FLAC__StreamDecoder *decoder, const FLAC__StreamMetadata *metadata, void *client_data) {
    if (metadata->type == FLAC__METADATA_TYPE_STREAMINFO) {
        FLAC__StreamMetadata_StreamInfo si = metadata->data.stream_info;

        StreamInfo *info = [[StreamInfo alloc] initWithSampleRate:si.sample_rate bitsPerSample:si.bits_per_sample channels:si.channels];
        NSLog(@"%@", [info debugDescription]);

        FlacDecoder *THIS = (__bridge FlacDecoder *)client_data;
        THIS->streamInfo = info;
    }
}

void error_cb(const FLAC__StreamDecoder *decoder, FLAC__StreamDecoderErrorStatus status, void *client_data) {
    NSLog(@"Got error callback, %@", status);
}

@end
