#import "RV64AppDelegate.h"
#import "RV64RootViewController.h"

@implementation RV64AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

	RV64RootViewController *terminalRoot = [[RV64RootViewController alloc] init];
	UINavigationController *terminalNav = [[UINavigationController alloc] initWithRootViewController:terminalRoot];
	terminalNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Terminal" image:nil tag:0];

	RV64FramebufferViewController *fbRoot = [[RV64FramebufferViewController alloc] init];
	UINavigationController *fbNav = [[UINavigationController alloc] initWithRootViewController:fbRoot];
	fbNav.navigationBarHidden = YES;
	fbNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Framebuffer" image:nil tag:1];

	UITabBarController *tabs = [[UITabBarController alloc] init];
	tabs.viewControllers = @[terminalNav, fbNav];
	tabs.tabBar.hidden = YES;
	self.window.rootViewController = tabs;
	[self.window makeKeyAndVisible];
	return YES;
}

@end
