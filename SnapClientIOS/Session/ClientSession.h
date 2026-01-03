//
//  ClientSession.h
//  SnapClientIOS
//
//  Created by Lee Jun Kit on 31/12/20.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ClientSession : NSObject

@property (nonatomic, strong, readonly) NSString *host;
@property (nonatomic, assign, readonly) NSUInteger port;

- (instancetype)initWithSnapServerHost:(NSString *)host port:(NSUInteger)port;
- (void)start;

@end

NS_ASSUME_NONNULL_END
