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

@property (nonatomic, assign) double diff; // Offset: ServerMs - LocalMachMs
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

- (double)machToMs:(uint64_t)machTime {
    uint64_t nanos = machTime * self.timebaseInfo.numer / self.timebaseInfo.denom;
    return nanos / 1000000.0;
}

- (uint64_t)msToMach:(double)ms {
    double nanos = ms * 1000000.0;
    return (uint64_t)(nanos * self.timebaseInfo.denom / self.timebaseInfo.numer);
}

- (double)nowMs {
    return [self machToMs:mach_absolute_time()];
}

- (double)serverNowMs {
    return [self nowMs] + self.diff;
}

- (uint64_t)machTimeForServerTimeMs:(double)serverTimeMs {
    // LocalMachMs = ServerTimeMs - Diff
    double targetLocalMs = serverTimeMs - self.diff;
    return [self msToMach:targetLocalMs];
}

- (void)updateOffsetWithServerTime:(double)serverTimeMs localTime:(double)localTimeMs {
    // Diff = Server - Local
    double offset = serverTimeMs - localTimeMs;
    
    [self.diffBuffer addObject:@(offset)];
    
    // Median Filter (Size 100)
    if (self.diffBuffer.count > 100) {
        [self.diffBuffer removeObjectAtIndex:0];
    }
    
    NSArray *sorted = [self.diffBuffer sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger idx = sorted.count / 2;
    
    if (idx < sorted.count) {
        self.diff = [[sorted objectAtIndex:idx] doubleValue];
        // NSLog(@"Time Sync: Offset %.2f ms", self.diff);
    }
}

- (void)reset {
    [self.diffBuffer removeAllObjects];
    self.diff = 0;
}

@end