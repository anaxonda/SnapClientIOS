//
//  TimeProvider.m
//  SnapClientIOS
//
//  Created by Anaxonda on 02/01/26.
//

#import "TimeProvider.h"

@interface TimeProvider ()

@property (nonatomic, assign) double diff;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *diffBuffer;

@end

@implementation TimeProvider

- (instancetype)init {
    self = [super init];
    if (self) {
        _diff = 0;
        _diffBuffer = [NSMutableArray array];
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
