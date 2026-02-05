#import "RV64AppDelegate.h"
#import "RV64RootViewController.h"

@implementation RV64AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	RV64RootViewController *root = [[RV64RootViewController alloc] init];
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
	self.window.rootViewController = nav;
	[self.window makeKeyAndVisible];
	return YES;
}

@end
