#import "RV64AppDelegate.h"
#import "RV64RootViewController.h"
#import "RV64Runner.h"

#import <dispatch/dispatch.h>

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

- (void)applicationDidBecomeActive:(UIApplication *)application
{
	(void)application;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		[RV64Runner reinitNetwork];
	});
}

@end
