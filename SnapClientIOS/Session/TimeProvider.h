//
//  TimeProvider.h
//  SnapClientIOS
//
//  Created by Anaxonda on 02/01/26.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TimeProvider : NSObject

// Returns the current local mach_absolute_time converted to milliseconds
- (double)nowMs;

// Returns the calculated server time in milliseconds based on mach time
- (double)serverNowMs;

/// Updates the time offset.
/// @param serverTimeMs The server time in milliseconds.
/// @param localTimeMs The local mach time in milliseconds when the server time was valid.
- (void)updateOffsetWithServerTime:(double)serverTimeMs localTime:(double)localTimeMs;

/// Converts a server timestamp (milliseconds) to local mach_absolute_time units
- (uint64_t)machTimeForServerTimeMs:(double)serverTimeMs;

- (void)reset;

@end

NS_ASSUME_NONNULL_END
