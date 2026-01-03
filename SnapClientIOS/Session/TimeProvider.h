//
//  TimeProvider.h
//  SnapClientIOS
//
//  Created by Anaxonda on 02/01/26.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TimeProvider : NSObject

/// Returns the current local time in milliseconds (Unix epoch based)
- (double)now;

/// Returns the calculated server time in milliseconds
- (double)serverNow;

/// Updates the time offset based on the round-trip timestamps
/// @param c2s Client-to-Server delta (ServerReceived - ClientSent)
/// @param s2c Server-to-Client delta (ClientReceived - ServerSent)
- (void)setDiffWithC2S:(double)c2s s2c:(double)s2c;

/// Resets the synchronization state
- (void)reset;

@end

NS_ASSUME_NONNULL_END
