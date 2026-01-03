//
//  AddServerViewController.m
//  SnapClientIOS
//
//  Created by Lee Jun Kit on 7/3/21.
//

#import "AddServerViewController.h"
#import "AppDelegate.h"

@interface AddServerViewController () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>

@property (strong, nonatomic) PersistentContainer *pc;
@property (weak, nonatomic) IBOutlet UITextField *nameField;
@property (weak, nonatomic) IBOutlet UITextField *hostField;
@property (weak, nonatomic) IBOutlet UITextField *portField;

@property (strong, nonatomic) NSNetServiceBrowser *browser;
@property (strong, nonatomic) NSMutableArray<NSNetService *> *services;
@property (strong, nonatomic) NSNetService *resolvingService;

@end

@implementation AddServerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // get a reference to the persistent container
    AppDelegate *appDelegate = (AppDelegate *)[UIApplication sharedApplication].delegate;
    self.pc = appDelegate.persistentContainer;
    
    self.services = [NSMutableArray array];
    
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    
    UIBarButtonItem *saveBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(save)];
    UIBarButtonItem *scanBtn = [[UIBarButtonItem alloc] initWithTitle:@"Scan" style:UIBarButtonItemStylePlain target:self action:@selector(scan)];
    
    self.navigationItem.rightBarButtonItems = @[saveBtn, scanBtn];
    
    if (self.existingServer) {
        self.navigationItem.title = @"Edit Server";
        self.nameField.text = [self.existingServer valueForKey:@"name"];
        self.hostField.text = [self.existingServer valueForKey:@"host"];
        self.portField.text = [NSString stringWithFormat:@"%ld", (long)[[self.existingServer valueForKey:@"port"] integerValue]];
    } else {
        self.navigationItem.title = @"Add Server";
    }
    
    // listen for textFieldDidChange events
    NSArray *textFields = @[self.nameField, self.hostField, self.portField];
    for (UITextField *textField in textFields) {
        [textField addTarget:self action:@selector(textFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
    }
}

- (void)scan {
    self.browser = [[NSNetServiceBrowser alloc] init];
    self.browser.delegate = self;
    [self.browser searchForServicesOfType:@"_snapcast._tcp." inDomain:@"local."];
    
    // Show spinner or alert "Scanning..."
    [self.services removeAllObjects];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Scanning..." message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        [self.browser stop];
    }]];
    
    // Store alert ref to dismiss later or append actions
    // Actually, dynamic updating of alert actions is tricky.
    // Better: Wait 2 seconds then show list.
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self showFoundServices];
    });
}

- (void)showFoundServices {
    [self.browser stop];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Found Servers" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (NSNetService *service in self.services) {
        [alert addAction:[UIAlertAction actionWithTitle:service.name style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self resolveService:service];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    // For iPad
    alert.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems[1];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resolveService:(NSNetService *)service {
    self.resolvingService = service;
    service.delegate = self;
    [service resolveWithTimeout:5.0];
}

#pragma mark - NSNetServiceDelegate
- (void)netServiceDidResolveAddress:(NSNetService *)sender {
    // Get IP and Port
    NSString *host = nil;
    NSInteger port = sender.port;
    
    // Extract IP from addresses
    for (NSData *address in sender.addresses) {
        struct sockaddr_in *socketAddress = (struct sockaddr_in *)[address bytes];
        if (socketAddress->sin_family == AF_INET) { // IPv4
            char str[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &(socketAddress->sin_addr), str, INET_ADDRSTRLEN);
            host = [NSString stringWithUTF8String:str];
            break;
        }
    }
    
    if (host) {
        self.hostField.text = host;
        self.portField.text = [NSString stringWithFormat:@"%ld", (long)port];
        self.nameField.text = sender.name; // Auto-fill name
        [self textFieldDidChange:nil]; // Update save button state
    }
}

#pragma mark - NSNetServiceBrowserDelegate
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
    [self.services addObject:service];
}

- (void)textFieldDidChange:(UITextField *)sender {
    self.navigationItem.rightBarButtonItems[0].enabled = [self canSave];
}

- (void)save {
"Edit Server";
        self.nameField.text = [self.existingServer valueForKey:@"name"];
        self.hostField.text = [self.existingServer valueForKey:@"host"];
        self.portField.text = [NSString stringWithFormat:@"%ld", (long)[[self.existingServer valueForKey:@"port"] integerValue]];
    } else {
        self.navigationItem.title = @"Add Server";
    }
    
    // listen for textFieldDidChange events
    NSArray *textFields = @[self.nameField, self.hostField, self.portField];
    for (UITextField *textField in textFields) {
        [textField addTarget:self action:@selector(textFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
    }
}

- (void)textFieldDidChange:(UITextField *)sender {
    self.navigationItem.rightBarButtonItem.enabled = [self canSave];
}

- (void)save {
    if (self.existingServer) {
        [self.existingServer setValue:self.nameField.text forKey:@"name"];
        [self.existingServer setValue:self.hostField.text forKey:@"host"];
        [self.existingServer setValue:@(self.portField.text.integerValue) forKey:@"port"];
        
        NSError *error = nil;
        if (![self.pc.viewContext save:&error]) {
            NSLog(@"Error saving context: %@", error);
        }
    } else {
        [self.pc addServerWithName:self.nameField.text
                              host:self.hostField.text
                              port:self.portField.text.integerValue];
    }
    [self dismissViewControllerAnimated:YES completion:NULL];
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:NULL];
}

- (BOOL)canSave {
    NSArray *textFields = @[self.nameField, self.hostField, self.portField];
    for (UITextField *textField in textFields) {
        if (textField.text.length == 0) {
            return NO;
        }
    }
    
    return YES;
}

@end
