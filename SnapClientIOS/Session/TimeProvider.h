//
//  TimeProvider.h
//  SnapClientIOS
//
//  Created by Anaxonda on 02/01/26.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^TimeProviderAudioClockBlock)(double *audioNowMs, uint64_t *hostTime);

@interface TimeProvider : NSObject

// Returns the current local mach_absolute_time converted to milliseconds
- (double)nowMs;

- (double)machToMs:(uint64_t)machTime;
- (uint64_t)msToMach:(double)ms;

// Returns the calculated server time in milliseconds based on mach time
- (double)serverNowMs;
// Returns the calculated server time for a given local mach time in milliseconds
- (double)serverTimeForLocalTimeMs:(double)localTimeMs;

// Provide an audio clock source (audio time + host time).
- (void)setAudioClockBlock:(TimeProviderAudioClockBlock)block;

// Converts an audio-clock timestamp to host time for scheduling.
- (uint64_t)hostTimeForAudioTimeMs:(double)audioTimeMs;

// Returns whether the audio clock source is currently available.
- (BOOL)isAudioClockAvailable;

/// Updates the time offset.
/// @param serverTimeMs The server time in milliseconds.
/// @param localTimeMs The local mach time in milliseconds when the server time was valid.
- (void)updateOffsetWithServerTime:(double)serverTimeMs localTime:(double)localTimeMs;

/// Converts a server timestamp (milliseconds) to local mach_absolute_time units
- (uint64_t)machTimeForServerTimeMs:(double)serverTimeMs;

- (void)reset;

@end

NS_ASSUME_NONNULL_END
