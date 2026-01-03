//
//  AddServerViewController.h
//  SnapClientIOS
//
//  Created by Lee Jun Kit on 7/3/21.
//

#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>

NS_ASSUME_NONNULL_BEGIN

@interface AddServerViewController : UIViewController

@property (nonatomic, strong, nullable) NSManagedObject *existingServer;

@end

NS_ASSUME_NONNULL_END
