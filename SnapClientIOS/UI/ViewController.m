//
//  ViewController.m
//  SnapClientIOS
//
//  Created by Lee Jun Kit on 29/12/20.
//

#import "ViewController.h"
#import "ClientSession.h"
#import "AppDelegate.h"
#import "AddServerViewController.h"

@interface ViewController () <UITableViewDelegate, UITableViewDataSource>

@property (strong, nonatomic) PersistentContainer *pc;
@property (strong, nonatomic) NSArray *servers;

@property (weak, nonatomic) UITableView *tableView;
@property (strong, nonatomic) ClientSession *session;
@property (strong, nonatomic) NSDictionary *serverStatus;

@end

@implementation ViewController

- (void)awakeFromNib {
    [super awakeFromNib];
    
    // get a reference to the persistent container
    AppDelegate *appDelegate = (AppDelegate *)[UIApplication sharedApplication].delegate;
    self.pc = appDelegate.persistentContainer;
    
    // get a list of saved servers
    self.servers = [self.pc servers];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onServerStatus:) name:@"SnapClientServerStatusUpdated" object:nil];
}

- (void)onServerStatus:(NSNotification *)note {
    self.serverStatus = note.userInfo;
    NSLog(@"UI received status update");
}

- (void)loadView {
    self.navigationItem.title = @"Snapcast Servers";
    
    // Add standard Edit button
    self.navigationItem.leftBarButtonItem = self.editButtonItem;
    
    UIBarButtonItem *addBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addServer)];
    UIBarButtonItem *streamBtn = [[UIBarButtonItem alloc] initWithTitle:@"Streams" style:UIBarButtonItemStylePlain target:self action:@selector(showStreams)];
    
    self.navigationItem.rightBarButtonItems = @[addBtn, streamBtn];
    
    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tableView.dataSource = self;
    tableView.delegate = self;
    
    self.tableView = tableView;
    self.view = tableView;
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [self.tableView setEditing:editing animated:animated];
}

// Standard Deletion Handler (for Edit Mode)
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        NSManagedObject *obj = [self.servers objectAtIndex:indexPath.row];
        [self.pc.viewContext deleteObject:obj];
        NSError *error = nil;
        [self.pc.viewContext save:&error];
    }
}

- (void)showStreams {
    if (!self.serverStatus) {
        // alert
        return;
    }
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Stream" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *streams = self.serverStatus[@"server"][@"streams"];
    NSString *myClientId = @"00:11:22:33:44:55"; // Hardcoded in SocketHandler
    NSString *myGroupId = nil;
    
    // Find my group
    NSArray *groups = self.serverStatus[@"server"][@"groups"];
    for (NSDictionary *group in groups) {
        for (NSDictionary *client in group[@"clients"]) {
            if ([client[@"id"] isEqualToString:myClientId] || [client[@"host"][@"mac"] isEqualToString:myClientId]) {
                myGroupId = group[@"id"];
                break;
            }
        }
        if (myGroupId) break;
    }
    
    if (!myGroupId && groups.count > 0) {
        // Fallback: Use first group
        myGroupId = groups[0][@"id"];
    }
    
    for (NSDictionary *stream in streams) {
        NSString *name = stream[@"id"]; // or stream[@"uri"]? Usually id is human readable alias if set
        if (stream[@"meta"] && stream[@"meta"][@"STREAM"]) {
             // Try to find a better name
        }
        
        [alert addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self.session setStreamId:stream[@"id"] forGroupId:myGroupId];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    // For iPad
    alert.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems[1];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self registerViewContextNotifications];
    
    //self.session = [[ClientSession alloc] initWithSnapServerHost:@"192.168.1.5" port:1704];
}

- (void)registerViewContextNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(contextUpdatedNotification:) name:NSManagedObjectContextObjectsDidChangeNotification object:self.pc.viewContext];
}

- (void)contextUpdatedNotification:(NSNotification *)notification {
    self.servers = [self.pc servers];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.servers count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSManagedObject *obj = [self.servers objectAtIndex:indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell"];
    }
    
    cell.textLabel.text = [obj valueForKey:@"name"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@:%ld", [obj valueForKey:@"host"], (long)[[obj valueForKey:@"port"] integerValue]];
    
    if (self.session && [[obj valueForKey:@"host"] isEqualToString:self.session.host] && [[obj valueForKey:@"port"] integerValue] == self.session.port) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    } else {
        // In edit mode, we might want DisclosureIndicator, but keeping simple for now
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSManagedObject *obj = [self.servers objectAtIndex:indexPath.row];
    
    if (self.tableView.editing) {
        // Edit Mode: Open Editor
        AddServerViewController *controller = [AddServerViewController new];
        controller.existingServer = obj;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
        [self presentViewController:nav animated:YES completion:NULL];
    } else {
        // Normal Mode: Connect
        NSString *host = [obj valueForKey:@"host"];
        NSInteger port = [[obj valueForKey:@"port"] integerValue];
        
        NSLog(@"Connecting to %@:%ld", host, (long)port);
        
        self.session = nil;
        
        self.session = [[ClientSession alloc] initWithSnapServerHost:host port:port];
        [self.session start];
        
        [tableView reloadData];
    }
}

- (nullable NSArray<UITableViewRowAction *> *)tableView:(UITableView *)tableView editActionsForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewRowAction *editAction = [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleNormal title:@"Edit" handler:^(UITableViewRowAction * _Nonnull action, NSIndexPath * _Nonnull indexPath) {
        NSManagedObject *obj = [self.servers objectAtIndex:indexPath.row];
        AddServerViewController *controller = [AddServerViewController new];
        controller.existingServer = obj;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
        [self presentViewController:nav animated:YES completion:NULL];
    }];
    editAction.backgroundColor = [UIColor blueColor];
    
    UITableViewRowAction *deleteAction = [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleDestructive title:@"Delete" handler:^(UITableViewRowAction * _Nonnull action, NSIndexPath * _Nonnull indexPath) {
        NSManagedObject *obj = [self.servers objectAtIndex:indexPath.row];
        [self.pc.viewContext deleteObject:obj];
        NSError *error = nil;
        [self.pc.viewContext save:&error];
    }];
    
    return @[deleteAction, editAction];
}

- (void)addServer {
    AddServerViewController *controller = [AddServerViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    [self presentViewController:nav animated:YES completion:NULL];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
