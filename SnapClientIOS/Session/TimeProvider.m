//
//  TimeProvider.m
//  SnapClientIOS
//
//  Created by Anaxonda on 02/01/26.
//

#import "TimeProvider.h"
#include <mach/mach.h>
#include <mach/mach_time.h>

@interface TimeProvider ()

@property (nonatomic, assign) double diff;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *diffBuffer;
@property (nonatomic, assign) mach_timebase_info_data_t timebaseInfo;

@end

@implementation TimeProvider

- (instancetype)init {
    self = [super init];
    if (self) {
        _diff = 0;
        _diffBuffer = [NSMutableArray array];
        mach_timebase_info(&_timebaseInfo);
    }
    return self;
}

- (double)now {
    // Current time in milliseconds
    return [[NSDate date] timeIntervalSince1970] * 1000.0;
}

- (double)serverNow {
    return [self now] + self.diff;
}

- (uint64_t)machTimeForServerTimeMs:(double)serverTimeMs {
    // 1. Convert Server Time -> Local Wall Time (Ms)
    double localTimeMs = serverTimeMs - self.diff;
    
    // 2. Calculate delta from NOW (Wall Time)
    double nowMs = [self now];
    double deltaMs = localTimeMs - nowMs;
    
    // 3. Convert Delta Ms -> Mach Time Units
    // Nanoseconds = Ms * 1,000,000
    // MachUnits = Nanoseconds * denom / numer
    double deltaNanos = deltaMs * 1000000.0;
    uint64_t deltaMach = (uint64_t)(deltaNanos * self.timebaseInfo.denom / self.timebaseInfo.numer);
    
    // 4. Apply to current Mach Time
    return mach_absolute_time() + deltaMach;
}

- (void)setDiffWithC2S:(double)c2s s2c:(double)s2c {
    if ([self now] == 0) {
        [self reset];
        return;
    }
    
    // Calculate the offset for this specific round trip
    // Logic port from Snap.Net: double add = ((c2s - s2c)) / 2.0f;
    double add = (c2s - s2c) / 2.0;
    
    [self.diffBuffer addObject:@(add)];
    
    // Keep buffer size at 100
    if (self.diffBuffer.count > 100) {
        [self.diffBuffer removeObjectAtIndex:0];
    }
    
    // Calculate Median
    NSArray *sorted = [self.diffBuffer sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger idx = sorted.count / 2;
    
    if (idx < sorted.count) {
        double median = [[sorted objectAtIndex:idx] doubleValue];
        self.diff = median;
//        NSLog(@"Time Sync: Offset updated to %.2f ms (samples: %lu)", self.diff, (unsigned long)self.diffBuffer.count);
    }
}

- (void)reset {
    [self.diffBuffer removeAllObjects];
    self.diff = 0;
}

@end
