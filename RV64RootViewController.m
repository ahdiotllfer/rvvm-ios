#import "RV64RootViewController.h"
#import "RV64Runner.h"

#import <dispatch/dispatch.h>
#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kRVVMDefaultsBootMode = @"rvvm.bootMode";
static NSString *const kRVVMDefaultsCores = @"rvvm.cores";
static NSString *const kRVVMDefaultsRamMB = @"rvvm.ramMB";
static NSString *const kRVVMDefaultsDisableIso = @"rvvm.disableIso";
static NSString *const kRVVMDefaultsIsoFilename = @"rvvm.isoFilename";
static NSString *const kRVVMDefaultsDiskFilename = @"rvvm.diskFilename";
static NSString *const kRVVMDefaultsPortForwards = @"rvvm.portForwards";
static NSString *const kRVVMDefaultsVirtioFSDebugToUART = @"rvvm.virtiofsDebugToUart";
static NSString *const kRVVMDefaultsAutoLoadSnapshot = @"rvvm.autoLoadSnapshot";

typedef NS_ENUM(NSInteger, RVVMBootMode) {
	RVVMBootModeAuto = 0,
	RVVMBootModeAlpine = 1,
	RVVMBootModeArch = 2,
	RVVMBootModeCustom = 3,
};

@interface RV64SettingsViewController : UITableViewController
@end

@protocol RV64TextInputSink <NSObject>
- (void)rvvmInsertText:(NSString *)text;
- (void)rvvmDeleteBackward;
@end

@interface RV64AccessoryTextView : UITextView
@property (nonatomic, weak) id<RV64TextInputSink> rvvmSink;
@property (nonatomic, strong) UIView *rvvmAccessoryView;
@end

@implementation RV64AccessoryTextView

- (UIView *)inputAccessoryView
{
	return self.rvvmAccessoryView;
}

- (BOOL)hasText
{
	return YES;
}

- (void)insertText:(NSString *)text
{
	[self.rvvmSink rvvmInsertText:text];
}

- (void)deleteBackward
{
	[self.rvvmSink rvvmDeleteBackward];
}

@end

@interface RV64FramebufferViewController () <RV64TextInputSink>
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) NSMutableData *fbData;
@property (nonatomic) NSUInteger fbWidth;
@property (nonatomic) NSUInteger fbHeight;
@property (nonatomic) NSUInteger fbBytesPerRow;
@property (nonatomic, strong) UILabel *debugLabel;
@property (nonatomic) uint32_t lastFbSeq;
@property (nonatomic) CFTimeInterval lastFbSeqChange;
@property (nonatomic, strong) RV64AccessoryTextView *inputViewHidden;
@property (nonatomic) uint8_t mouseButtons;
@property (nonatomic) CGPoint mouseRemainder;
@property (nonatomic) BOOL ctrlArmed;
@property (nonatomic) BOOL altArmed;
@property (nonatomic, strong) UIButton *ctrlButton;
@property (nonatomic, strong) UIButton *altButton;
@property (nonatomic, strong) UIButton *keyboardButton;
@end

@implementation RV64FramebufferViewController

- (UIButton *)keyButtonWithTitle:(NSString *)title action:(SEL)action
{
	UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
	[b setTitle:title forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
	b.contentEdgeInsets = UIEdgeInsetsMake(6, 10, 6, 10);
	b.layer.cornerRadius = 8;
	b.layer.masksToBounds = YES;
	[b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
	return b;
}

- (void)updateModifierButtons
{
	UIColor *activeBg = [UIColor.systemBlueColor colorWithAlphaComponent:0.20];
	UIColor *inactiveBg = [UIColor.systemGray5Color colorWithAlphaComponent:0.80];
	self.ctrlButton.selected = self.ctrlArmed;
	self.altButton.selected = self.altArmed;
	self.ctrlButton.backgroundColor = self.ctrlButton.selected ? activeBg : inactiveBg;
	self.altButton.backgroundColor = self.altButton.selected ? activeBg : inactiveBg;
}

- (UIView *)buildVirtioKeyboardAccessoryView
{
	UIView *root = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 44)];

	UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
	blur.translatesAutoresizingMaskIntoConstraints = NO;
	[root addSubview:blur];
	[NSLayoutConstraint activateConstraints:@[
		[blur.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
		[blur.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
		[blur.topAnchor constraintEqualToAnchor:root.topAnchor],
		[blur.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
	]];

	UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
	scroll.translatesAutoresizingMaskIntoConstraints = NO;
	scroll.showsHorizontalScrollIndicator = NO;
	scroll.alwaysBounceHorizontal = YES;
	[blur.contentView addSubview:scroll];
	[NSLayoutConstraint activateConstraints:@[
		[scroll.leadingAnchor constraintEqualToAnchor:blur.contentView.leadingAnchor],
		[scroll.trailingAnchor constraintEqualToAnchor:blur.contentView.trailingAnchor],
		[scroll.topAnchor constraintEqualToAnchor:blur.contentView.topAnchor],
		[scroll.bottomAnchor constraintEqualToAnchor:blur.contentView.bottomAnchor],
	]];

	UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	stack.axis = UILayoutConstraintAxisHorizontal;
	stack.spacing = 8;
	stack.alignment = UIStackViewAlignmentCenter;
	stack.layoutMarginsRelativeArrangement = YES;
	stack.layoutMargins = UIEdgeInsetsMake(6, 8, 6, 8);
	[scroll addSubview:stack];
	[NSLayoutConstraint activateConstraints:@[
		[stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
		[stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
		[stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
		[stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
		[stack.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
	]];

	UIButton *esc = [self keyButtonWithTitle:@"Esc" action:@selector(keyEscPressed:)];
	UIButton *uart = [self keyButtonWithTitle:@"UART" action:@selector(switchToUARTPressed:)];
	UIButton *fb = [self keyButtonWithTitle:@"FB" action:@selector(switchToFramebufferPressed:)];
	UIButton *settings = [self keyButtonWithTitle:@"Settings" action:@selector(keySettingsPressed:)];
	UIButton *tab = [self keyButtonWithTitle:@"Tab" action:@selector(keyTabPressed:)];
	UIButton *ctrl = [self keyButtonWithTitle:@"Ctrl" action:@selector(keyCtrlPressed:)];
	UIButton *alt = [self keyButtonWithTitle:@"Alt" action:@selector(keyAltPressed:)];
	self.ctrlButton = ctrl;
	self.altButton = alt;

	UIButton *up = [self keyButtonWithTitle:@"↑" action:@selector(keyUpPressed:)];
	UIButton *down = [self keyButtonWithTitle:@"↓" action:@selector(keyDownPressed:)];
	UIButton *left = [self keyButtonWithTitle:@"←" action:@selector(keyLeftPressed:)];
	UIButton *right = [self keyButtonWithTitle:@"→" action:@selector(keyRightPressed:)];

	UIButton *hide = [self keyButtonWithTitle:@"Hide" action:@selector(keyHidePressed:)];

	NSArray<UIButton *> *all = @[esc, uart, fb, settings, tab, ctrl, alt, left, up, down, right, hide];
	for (UIButton *b in all) {
		[stack addArrangedSubview:b];
	}

	[self updateModifierButtons];
	return root;
}

- (void)switchToUARTPressed:(id)sender
{
	(void)sender;
	if (self.tabBarController) {
		self.tabBarController.selectedIndex = 0;
	}
}

- (void)switchToFramebufferPressed:(id)sender
{
	(void)sender;
	if (self.tabBarController) {
		self.tabBarController.selectedIndex = 1;
	}
}

- (void)keyEscPressed:(id)sender
{
	(void)sender;
	[RV64Runner sendVirtioKey:0x29 shift:NO ctrl:self.ctrlArmed alt:self.altArmed];
	[self.inputViewHidden becomeFirstResponder];
}

- (void)keySettingsPressed:(id)sender
{
	(void)sender;
	[self.view endEditing:YES];
	[self.navigationController setNavigationBarHidden:NO animated:YES];
	RV64SettingsViewController *vc = [[RV64SettingsViewController alloc] init];
	[self.navigationController pushViewController:vc animated:YES];
}

- (void)keyTabPressed:(id)sender
{
	(void)sender;
	[RV64Runner sendVirtioKey:0x2b shift:NO ctrl:self.ctrlArmed alt:self.altArmed];
	[self.inputViewHidden becomeFirstResponder];
}

- (void)keyCtrlPressed:(id)sender
{
	(void)sender;
	self.ctrlArmed = !self.ctrlArmed;
	[self updateModifierButtons];
	[self.inputViewHidden becomeFirstResponder];
}

- (void)keyAltPressed:(id)sender
{
	(void)sender;
	self.altArmed = !self.altArmed;
	[self updateModifierButtons];
	[self.inputViewHidden becomeFirstResponder];
}

- (void)keyUpPressed:(id)sender
{
	(void)sender;
	[RV64Runner sendVirtioKey:0x52 shift:NO ctrl:self.ctrlArmed alt:self.altArmed];
	[self.inputViewHidden becomeFirstResponder];
}

- (void)keyDownPressed:(id)sender
{
	(void)sender;
	[RV64Runner sendVirtioKey:0x51 shift:NO ctrl:self.ctrlArmed alt:self.altArmed];
	[self.inputViewHidden becomeFirstResponder];
}

- (void)keyLeftPressed:(id)sender
{
	(void)sender;
	[RV64Runner sendVirtioKey:0x50 shift:NO ctrl:self.ctrlArmed alt:self.altArmed];
	[self.inputViewHidden becomeFirstResponder];
}

- (void)keyRightPressed:(id)sender
{
	(void)sender;
	[RV64Runner sendVirtioKey:0x4f shift:NO ctrl:self.ctrlArmed alt:self.altArmed];
	[self.inputViewHidden becomeFirstResponder];
}

- (void)keyHidePressed:(id)sender
{
	(void)sender;
	[self.view endEditing:YES];
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.blackColor;
	self.view.multipleTouchEnabled = YES;

	self.imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
	self.imageView.contentMode = UIViewContentModeScaleAspectFit;
	self.imageView.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.imageView];

	UIButton *kb = [self keyButtonWithTitle:@"KB" action:@selector(keyKeyboardPressed:)];
	kb.translatesAutoresizingMaskIntoConstraints = NO;
	kb.backgroundColor = [UIColor.systemGray5Color colorWithAlphaComponent:0.80];
	[self.view addSubview:kb];
	self.keyboardButton = kb;

	[NSLayoutConstraint activateConstraints:@[
		[self.imageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[self.imageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[self.imageView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[self.imageView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

		[kb.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-8.0],
		[kb.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8.0],
	]];

	self.fbData = [[NSMutableData alloc] init];
	self.lastFbSeq = 0;
	self.lastFbSeqChange = CACurrentMediaTime();

	self.inputViewHidden = [[RV64AccessoryTextView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
	self.inputViewHidden.autocorrectionType = UITextAutocorrectionTypeNo;
	self.inputViewHidden.autocapitalizationType = UITextAutocapitalizationTypeNone;
	self.inputViewHidden.spellCheckingType = UITextSpellCheckingTypeNo;
	self.inputViewHidden.keyboardType = UIKeyboardTypeDefault;
	self.inputViewHidden.returnKeyType = UIReturnKeyDefault;
	self.inputViewHidden.rvvmSink = self;
	self.inputViewHidden.rvvmAccessoryView = [self buildVirtioKeyboardAccessoryView];
	self.inputViewHidden.text = @"";
	self.inputViewHidden.textColor = UIColor.clearColor;
	self.inputViewHidden.backgroundColor = UIColor.clearColor;
	self.inputViewHidden.translatesAutoresizingMaskIntoConstraints = YES;
	self.inputViewHidden.alpha = 0.01;
	self.inputViewHidden.userInteractionEnabled = NO;
	self.inputViewHidden.frame = CGRectMake(-1000, -1000, 1, 1);
	[self.view addSubview:self.inputViewHidden];

	UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapPressed:)];
	[self.view addGestureRecognizer:tap];

	UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panMoved:)];
	pan.minimumNumberOfTouches = 1;
	pan.maximumNumberOfTouches = 1;
	[self.view addGestureRecognizer:pan];

	UIPanGestureRecognizer *scrollPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(scrollPanMoved:)];
	scrollPan.minimumNumberOfTouches = 2;
	scrollPan.maximumNumberOfTouches = 2;
	[self.view addGestureRecognizer:scrollPan];

	UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressChanged:)];
	longPress.minimumPressDuration = 0.25;
	[self.view addGestureRecognizer:longPress];

	[RV64Runner startLinux];
}

- (void)keyKeyboardPressed:(id)sender
{
	(void)sender;
	if ([self.inputViewHidden isFirstResponder]) {
		[self.inputViewHidden resignFirstResponder];
	} else {
		[self.inputViewHidden becomeFirstResponder];
	}
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	if (!self.displayLink) {
		self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayTick:)];
		[self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
	}
}

- (void)viewWillDisappear:(BOOL)animated
{
	[super viewWillDisappear:animated];
	[self.displayLink invalidate];
	self.displayLink = nil;

	if (self.mouseButtons != 0) {
		uint8_t btns = self.mouseButtons;
		self.mouseButtons = 0;
		[RV64Runner sendVirtioMouseButtons:btns down:NO];
	}
	[self.inputViewHidden resignFirstResponder];
}

- (void)tapPressed:(UITapGestureRecognizer *)gr
{
	(void)gr;
	[RV64Runner sendVirtioMouseButtons:1 down:YES];
	[RV64Runner sendVirtioMouseButtons:1 down:NO];
}

- (void)panMoved:(UIPanGestureRecognizer *)gr
{
	if (gr.state == UIGestureRecognizerStateBegan || gr.state == UIGestureRecognizerStateChanged) {
		UIView *v = gr.view ?: self.view;
		CGPoint t = [gr translationInView:v];
		CGPoint r = self.mouseRemainder;
		double dxf = (double)t.x + (double)r.x;
		double dyf = (double)t.y + (double)r.y;
		int32_t dx = (int32_t)llround(dxf);
		int32_t dy = (int32_t)llround(dyf);
		if (dx != 0 || dy != 0) {
			[RV64Runner sendVirtioMouseDeltaX:dx deltaY:dy];
			r.x = (CGFloat)(dxf - (double)dx);
			r.y = (CGFloat)(dyf - (double)dy);
			self.mouseRemainder = r;
			[gr setTranslation:CGPointZero inView:v];
		}
	}
}

- (void)scrollPanMoved:(UIPanGestureRecognizer *)gr
{
	if (gr.state != UIGestureRecognizerStateBegan && gr.state != UIGestureRecognizerStateChanged) {
		return;
	}
	UIView *v = gr.view ?: self.view;
	CGPoint t = [gr translationInView:v];
	const CGFloat stepPx = 24.0;
	int32_t steps = (int32_t)llround(t.y / stepPx);
	if (steps == 0) {
		return;
	}
	[RV64Runner sendVirtioMouseScroll:steps];
	[gr setTranslation:CGPointZero inView:v];
}

- (void)longPressChanged:(UILongPressGestureRecognizer *)gr
{
	if (gr.state == UIGestureRecognizerStateBegan) {
		self.mouseButtons |= 1;
		[RV64Runner sendVirtioMouseButtons:1 down:YES];
		return;
	}
	if (gr.state == UIGestureRecognizerStateEnded || gr.state == UIGestureRecognizerStateCancelled || gr.state == UIGestureRecognizerStateFailed) {
		if (self.mouseButtons & 1) {
			self.mouseButtons &= (uint8_t)~1;
			[RV64Runner sendVirtioMouseButtons:1 down:NO];
		}
		return;
	}
}

- (void)displayTick:(CADisplayLink *)dl
{
	(void)dl;
	@autoreleasepool {
		const CFTimeInterval now = CACurrentMediaTime();
		const uint32_t seq = [RV64Runner framebufferSeq];
		uint32_t metaW = 0;
		uint32_t metaH = 0;
		uint32_t metaStride = 0;
		uint32_t metaFmt = 0;
		uint32_t metaOff = 0;
		[RV64Runner framebufferMetaWidth:&metaW height:&metaH stride:&metaStride format:&metaFmt offset:&metaOff];
		if (seq != 0 && seq != self.lastFbSeq) {
			self.lastFbSeq = seq;
			self.lastFbSeqChange = now;
		}

		NSUInteger w = 0;
		NSUInteger h = 0;
		NSUInteger bpr = 0;
		if (![RV64Runner copyFramebufferBGRA:self.fbData width:&w height:&h bytesPerRow:&bpr]) {
			return;
		}
		if (w == 0 || h == 0 || bpr == 0) {
			return;
		}
		self.fbWidth = w;
		self.fbHeight = h;
		self.fbBytesPerRow = bpr;

		CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)self.fbData);
		if (!provider) {
			return;
		}
		CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
		CGBitmapInfo bi = kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst;
		CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)bpr, cs, bi, provider, NULL, false, kCGRenderingIntentDefault);
		CGDataProviderRelease(provider);
		CGColorSpaceRelease(cs);
		if (!img) {
			return;
		}
		UIImage *ui = [UIImage imageWithCGImage:img scale:UIScreen.mainScreen.scale orientation:UIImageOrientationUp];
		CGImageRelease(img);
		self.imageView.image = ui;
	}
}

- (void)rvvmInsertText:(NSString *)text
{
	if (text.length > 0) {
		[RV64Runner sendVirtioText:text ctrl:self.ctrlArmed alt:self.altArmed];
	}
}

- (void)rvvmDeleteBackward
{
	[RV64Runner sendVirtioKey:0x2a shift:NO ctrl:NO alt:NO];
}

@end

@interface RV64VirtioFSDebugViewController : UIViewController
@end

@interface RV64TerminalWebView : WKWebView
@property (nonatomic, strong) UIView *rvvmAccessoryView;
@end

@implementation RV64TerminalWebView

- (UIView *)inputAccessoryView
{
	return self.rvvmAccessoryView;
}

@end

@interface RV64RootViewController ()
<WKScriptMessageHandler, WKNavigationDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) RV64TerminalWebView *terminalView;
@property (nonatomic) BOOL terminalReady;
@property (nonatomic, strong) NSMutableArray<NSString *> *pendingWritesB64;
@property (nonatomic) BOOL ctrlArmed;
@property (nonatomic) BOOL altArmed;
@property (nonatomic, strong) UIButton *ctrlButton;
@property (nonatomic, strong) UIButton *altButton;
@property (nonatomic, strong) NSLayoutConstraint *terminalBottomConstraint;
@end

@interface RV64SettingsViewController () <UIDocumentPickerDelegate>
@property (nonatomic) RVVMBootMode bootMode;
@property (nonatomic) NSInteger cores;
@property (nonatomic) NSInteger ramMB;
@property (nonatomic) BOOL disableIso;
@property (nonatomic) BOOL virtioFSDebugToUart;
@property (nonatomic) BOOL autoLoadSnapshot;
@property (nonatomic, copy) NSString *isoFilename;
@property (nonatomic, copy) NSString *diskFilename;
@property (nonatomic, copy) NSArray<NSString *> *portForwards;
@property (nonatomic, copy) NSArray<NSString *> *docFiles;
@end

@interface RV64PortForwardsViewController : UITableViewController
@property (nonatomic, strong) NSMutableArray<NSString *> *items;
@property (nonatomic, copy) void (^onChange)(NSArray<NSString *> *items);
@end

@implementation RV64PortForwardsViewController

- (instancetype)init
{
	return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)backPressed:(id)sender
{
	(void)sender;
	[self.navigationController popViewControllerAnimated:YES];
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"Port forwarding";
	if (!self.items) {
		self.items = [NSMutableArray array];
	}
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addPressed:)];
	UIBarButtonItem *back = [[UIBarButtonItem alloc] initWithTitle:@"Back" style:UIBarButtonItemStylePlain target:self action:@selector(backPressed:)];
	self.navigationItem.leftBarButtonItems = @[back, self.editButtonItem];
}

- (void)addPressed:(id)sender
{
	(void)sender;
	UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Add rule" message:@"Examples:\ntcp/2222=22\n127.0.0.1:2222=22\n[::1]:2222=22" preferredStyle:UIAlertControllerStyleAlert];
	[a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
		tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
		tf.autocorrectionType = UITextAutocorrectionTypeNo;
		tf.spellCheckingType = UITextSpellCheckingTypeNo;
		tf.keyboardType = UIKeyboardTypeASCIICapable;
		tf.placeholder = @"tcp/2222=22";
	}];
	__weak typeof(self) weakSelf = self;
	[a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[a addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act) {
		__strong typeof(weakSelf) selfStrong = weakSelf;
		if (!selfStrong) {
			return;
		}
		NSString *s = a.textFields.firstObject.text;
		s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (s.length == 0) {
			return;
		}
		[selfStrong.items addObject:s];
		if (selfStrong.onChange) {
			selfStrong.onChange([selfStrong.items copy]);
		}
		[selfStrong.tableView reloadData];
	}]];
	[self presentViewController:a animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	(void)tableView;
	return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"cell"];
	}
	cell.textLabel.text = self.items[indexPath.row];
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	return cell;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
	(void)tableView;
	(void)indexPath;
	return UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
	(void)tableView;
	if (editingStyle != UITableViewCellEditingStyleDelete) {
		return;
	}
	[self.items removeObjectAtIndex:indexPath.row];
	if (self.onChange) {
		self.onChange([self.items copy]);
	}
	[self.tableView reloadData];
}

@end

@interface RV64VirtioFSDebugViewController ()
@property (nonatomic, strong) UITextView *textView;
@end

@implementation RV64VirtioFSDebugViewController

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"Virtio-FS Debug";
	self.view.backgroundColor = UIColor.systemBackgroundColor;

	UITextView *tv = [UITextView new];
	tv.editable = NO;
	tv.selectable = YES;
	tv.alwaysBounceVertical = YES;
	tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
	tv.textColor = UIColor.labelColor;
	tv.backgroundColor = UIColor.systemBackgroundColor;
	tv.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:tv];
	self.textView = tv;

	[NSLayoutConstraint activateConstraints:@[
		[tv.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
		[tv.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
		[tv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
		[tv.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
	]];

	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStylePlain target:self action:@selector(clearPressed:)];
	[self reloadAll];
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onDebugLine:) name:RV64RunnerVirtioFSDebugNotification object:nil];
}

- (void)viewWillDisappear:(BOOL)animated
{
	[super viewWillDisappear:animated];
	[[NSNotificationCenter defaultCenter] removeObserver:self name:RV64RunnerVirtioFSDebugNotification object:nil];
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reloadAll
{
	NSArray<NSString *> *lines = [RV64Runner virtioFSDebugLines];
	self.textView.text = [lines componentsJoinedByString:@""];
	[self scrollToBottom];
}

- (void)scrollToBottom
{
	UITextView *tv = self.textView;
	if (!tv || tv.text.length == 0) {
		return;
	}
	NSRange range = NSMakeRange(tv.text.length - 1, 1);
	[tv scrollRangeToVisible:range];
}

- (void)appendLine:(NSString *)s
{
	if (s.length == 0) {
		return;
	}
	UITextView *tv = self.textView;
	if (!tv) {
		return;
	}
	BOOL atBottom = (tv.contentOffset.y + tv.bounds.size.height + 40.0) >= tv.contentSize.height;
	NSString *cur = tv.text ?: @"";
	tv.text = [cur stringByAppendingString:s];
	if (atBottom) {
		[self scrollToBottom];
	}
}

- (void)onDebugLine:(NSNotification *)note
{
	NSString *text = note.object;
	if (![text isKindOfClass:[NSString class]] || text.length == 0) {
		return;
	}
	[self appendLine:text];
}

- (void)clearPressed:(id)sender
{
	(void)sender;
	[RV64Runner clearVirtioFSDebug];
	self.textView.text = @"";
}

@end

@implementation RV64SettingsViewController

- (instancetype)init
{
	return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"Settings";
	[self loadDefaults];
	[self reloadDocFiles];
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	[self reloadDocFiles];
	[self.tableView reloadData];
}

- (void)loadDefaults
{
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	[d removeObjectForKey:kRVVMDefaultsBootMode];
	self.bootMode = RVVMBootModeAuto;

	NSInteger c = [d integerForKey:kRVVMDefaultsCores];
	self.cores = (c > 0) ? c : 2;

	NSInteger mb = [d integerForKey:kRVVMDefaultsRamMB];
	self.ramMB = (mb > 0) ? mb : 1024;

	self.disableIso = [d boolForKey:kRVVMDefaultsDisableIso];
	id vfsDbgObj = [d objectForKey:kRVVMDefaultsVirtioFSDebugToUART];
	self.virtioFSDebugToUart = vfsDbgObj ? [d boolForKey:kRVVMDefaultsVirtioFSDebugToUART] : YES;
	id autoSnapObj = [d objectForKey:kRVVMDefaultsAutoLoadSnapshot];
	self.autoLoadSnapshot = autoSnapObj ? [d boolForKey:kRVVMDefaultsAutoLoadSnapshot] : YES;
	self.isoFilename = [d stringForKey:kRVVMDefaultsIsoFilename];
	self.diskFilename = [d stringForKey:kRVVMDefaultsDiskFilename];
	NSArray *pf = [d objectForKey:kRVVMDefaultsPortForwards];
	if ([pf isKindOfClass:[NSArray class]]) {
		NSMutableArray<NSString *> *arr = [NSMutableArray array];
		for (id x in pf) {
			if ([x isKindOfClass:[NSString class]] && ((NSString *)x).length > 0) {
				[arr addObject:(NSString *)x];
			}
		}
		self.portForwards = arr;
	} else {
		self.portForwards = @[];
	}
}

- (void)saveDefaults
{
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	[d removeObjectForKey:kRVVMDefaultsBootMode];
	[d setInteger:self.cores forKey:kRVVMDefaultsCores];
	[d setInteger:self.ramMB forKey:kRVVMDefaultsRamMB];
	[d setBool:self.disableIso forKey:kRVVMDefaultsDisableIso];
	[d setBool:self.virtioFSDebugToUart forKey:kRVVMDefaultsVirtioFSDebugToUART];
	[d setBool:self.autoLoadSnapshot forKey:kRVVMDefaultsAutoLoadSnapshot];
	if (self.isoFilename.length > 0) {
		[d setObject:self.isoFilename forKey:kRVVMDefaultsIsoFilename];
	} else {
		[d removeObjectForKey:kRVVMDefaultsIsoFilename];
	}
	if (self.diskFilename.length > 0) {
		[d setObject:self.diskFilename forKey:kRVVMDefaultsDiskFilename];
	} else {
		[d removeObjectForKey:kRVVMDefaultsDiskFilename];
	}
	if (self.portForwards.count > 0) {
		[d setObject:self.portForwards forKey:kRVVMDefaultsPortForwards];
	} else {
		[d removeObjectForKey:kRVVMDefaultsPortForwards];
	}
	[d synchronize];
}

- (NSString *)documentsDirPath
{
	NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	return (docs.count > 0) ? docs.firstObject : nil;
}

- (void)reloadDocFiles
{
	NSString *docs = [self documentsDirPath];
	if (docs.length == 0) {
		self.docFiles = @[];
		return;
	}
	NSError *err = nil;
	NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:&err];
	if (![files isKindOfClass:[NSArray class]]) {
		self.docFiles = @[];
		return;
	}
	NSMutableArray<NSString *> *filtered = [NSMutableArray array];
	for (NSString *f in files) {
		NSString *lower = f.lowercaseString;
		if ([lower hasSuffix:@".img"] || [lower hasSuffix:@".raw"] || [lower hasSuffix:@".qcow2"] || [lower hasSuffix:@".iso"]) {
			[filtered addObject:f];
		}
	}
	[filtered sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
	self.docFiles = filtered;
}

- (NSString *)bootModeTitle
{
	switch (self.bootMode) {
		case RVVMBootModeAuto: return @"Auto";
		case RVVMBootModeAlpine: return @"Alpine ISO";
		case RVVMBootModeArch: return @"Arch image";
		case RVVMBootModeCustom: return @"Auto";
	}
	return @"Auto";
}

- (NSString *)isoTitle
{
	if (self.disableIso) {
		return @"Disabled";
	}
	return (self.isoFilename.length > 0) ? self.isoFilename : @"Bundled";
}

- (NSString *)diskTitle
{
	return (self.diskFilename.length > 0) ? self.diskFilename : @"alpine-riscv64.img";
}

- (NSString *)snapshotPath
{
	NSString *docs = [self documentsDirPath];
	return (docs.length > 0) ? [docs stringByAppendingPathComponent:@"rvvm.snapshot.img"] : nil;
}

- (BOOL)snapshotExists
{
	NSString *path = [self snapshotPath];
	return (path.length > 0) && [[NSFileManager defaultManager] fileExistsAtPath:path];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	(void)tableView;
	return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	(void)tableView;
	switch (section) {
		case 0: return 9;
		case 1: return 2;
		case 2: return self.docFiles.count + 2;
		case 3: return 3;
	}
	return 0;
}

- (void)autoLoadSnapshotChanged:(UISwitch *)sw
{
	self.autoLoadSnapshot = sw.isOn;
	[self saveDefaults];
	[self.tableView reloadData];
}

- (void)disableIsoChanged:(UISwitch *)sw
{
	self.disableIso = sw.isOn;
	[self saveDefaults];
	[self.tableView reloadData];
}

- (void)virtioFSDebugToUartChanged:(UISwitch *)sw
{
	self.virtioFSDebugToUart = sw.isOn;
	[self saveDefaults];
	[RV64Runner setVirtioFSDebugToUARTEnabled:self.virtioFSDebugToUart];
	[self.tableView reloadData];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
	(void)tableView;
	switch (section) {
		case 0: return @"Boot";
		case 1: return @"Hardware";
		case 2: return @"Documents";
		case 3: return @"Debug";
	}
	return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"cell"];
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	}
	cell.textLabel.textColor = UIColor.labelColor;
	cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

	if (indexPath.section == 0) {
		if (indexPath.row == 0) {
			cell.textLabel.text = @"Disable ISO";
			cell.detailTextLabel.text = @"";
			UISwitch *sw = [UISwitch new];
			sw.on = self.disableIso;
			[sw addTarget:self action:@selector(disableIsoChanged:) forControlEvents:UIControlEventValueChanged];
			cell.accessoryType = UITableViewCellAccessoryNone;
			cell.accessoryView = sw;
			cell.selectionStyle = UITableViewCellSelectionStyleNone;
		} else if (indexPath.row == 1) {
			cell.textLabel.text = @"ISO";
			cell.detailTextLabel.text = [self isoTitle];
			cell.accessoryType = self.disableIso ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
			cell.accessoryView = nil;
			cell.selectionStyle = self.disableIso ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
		} else if (indexPath.row == 2) {
			cell.textLabel.text = @"Disk";
			cell.detailTextLabel.text = [self diskTitle];
			cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			cell.accessoryView = nil;
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		} else if (indexPath.row == 3) {
			cell.textLabel.text = @"Import disk";
			cell.detailTextLabel.text = @"";
			cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			cell.accessoryView = nil;
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		} else if (indexPath.row == 4) {
			cell.textLabel.text = @"Port forwarding";
			cell.detailTextLabel.text = (self.portForwards.count > 0) ? [NSString stringWithFormat:@"%lu", (unsigned long)self.portForwards.count] : @"Off";
			cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			cell.accessoryView = nil;
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		} else if (indexPath.row == 5) {
			cell.textLabel.text = @"Reinit network";
			cell.textLabel.textColor = UIColor.labelColor;
			cell.detailTextLabel.text = @"";
			cell.accessoryType = UITableViewCellAccessoryNone;
			cell.accessoryView = nil;
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		} else if (indexPath.row == 6) {
			cell.textLabel.text = @"Restart emulation";
			cell.textLabel.textColor = UIColor.systemRedColor;
			cell.detailTextLabel.text = @"";
			cell.accessoryType = UITableViewCellAccessoryNone;
			cell.accessoryView = nil;
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		} else if (indexPath.row == 7) {
			cell.textLabel.text = @"Save snapshot";
			cell.detailTextLabel.text = @"";
			cell.accessoryType = UITableViewCellAccessoryNone;
			cell.accessoryView = nil;
			cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		} else if (indexPath.row == 8) {
			BOOL exists = [self snapshotExists];
			cell.textLabel.text = @"Load snapshot";
			cell.detailTextLabel.text = exists ? @"Available" : @"Missing";
			cell.accessoryType = UITableViewCellAccessoryNone;
			cell.accessoryView = nil;
			cell.selectionStyle = exists ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
			cell.textLabel.textColor = exists ? UIColor.labelColor : UIColor.tertiaryLabelColor;
			cell.detailTextLabel.textColor = exists ? UIColor.secondaryLabelColor : UIColor.tertiaryLabelColor;
		}
		return cell;
	}

	if (indexPath.section == 1) {
		if (indexPath.row == 0) {
			cell.textLabel.text = @"Cores";
			cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)self.cores];
		} else {
			cell.textLabel.text = @"RAM";
			cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld MB", (long)self.ramMB];
		}
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		cell.accessoryView = nil;
		cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		return cell;
	}

	if (indexPath.section == 3) {
		if (indexPath.row == 0) {
			cell.textLabel.text = @"Virtio-FS debug in UART";
			cell.detailTextLabel.text = @"";
			UISwitch *sw = [UISwitch new];
			sw.on = self.virtioFSDebugToUart;
			[sw addTarget:self action:@selector(virtioFSDebugToUartChanged:) forControlEvents:UIControlEventValueChanged];
			cell.accessoryType = UITableViewCellAccessoryNone;
			cell.accessoryView = sw;
			cell.selectionStyle = UITableViewCellSelectionStyleNone;
			return cell;
		}
		if (indexPath.row == 1) {
			cell.textLabel.text = @"Auto-load snapshot on startup";
			cell.detailTextLabel.text = @"";
			UISwitch *sw = [UISwitch new];
			sw.on = self.autoLoadSnapshot;
			[sw addTarget:self action:@selector(autoLoadSnapshotChanged:) forControlEvents:UIControlEventValueChanged];
			cell.accessoryType = UITableViewCellAccessoryNone;
			cell.accessoryView = sw;
			cell.selectionStyle = UITableViewCellSelectionStyleNone;
			return cell;
		}
		cell.textLabel.text = @"Virtio-FS debug log";
		cell.detailTextLabel.text = @"View";
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		cell.accessoryView = nil;
		cell.selectionStyle = UITableViewCellSelectionStyleDefault;
		return cell;
	}

	cell.accessoryType = UITableViewCellAccessoryNone;
	cell.accessoryView = nil;
	cell.detailTextLabel.text = @"";
	if (indexPath.row == 0) {
		cell.textLabel.text = @"Export documents";
		cell.textLabel.textColor = UIColor.labelColor;
		cell.selectionStyle = UITableViewCellSelectionStyleDefault;
	} else if (indexPath.row == 1) {
		cell.textLabel.text = @"Delete all documents";
		cell.textLabel.textColor = UIColor.systemRedColor;
		cell.selectionStyle = UITableViewCellSelectionStyleDefault;
	} else {
		cell.textLabel.text = self.docFiles[indexPath.row - 2];
		cell.textLabel.textColor = UIColor.labelColor;
		cell.selectionStyle = UITableViewCellSelectionStyleDefault;
	}
	return cell;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
	(void)tableView;
	if (indexPath.section == 2 && indexPath.row >= 2) {
		return UITableViewCellEditingStyleDelete;
	}
	return UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
	if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.section != 2 || indexPath.row < 2) {
		return;
	}
	NSString *docs = [self documentsDirPath];
	if (docs.length == 0) {
		return;
	}
	NSString *name = self.docFiles[indexPath.row - 2];
	NSString *path = [docs stringByAppendingPathComponent:name];
	NSError *err = nil;
	[[NSFileManager defaultManager] removeItemAtPath:path error:&err];
	if ([self.isoFilename isEqualToString:name]) {
		self.isoFilename = nil;
	}
	if ([self.diskFilename isEqualToString:name]) {
		self.diskFilename = nil;
	}
	[self saveDefaults];
	[self reloadDocFiles];
	[tableView reloadData];
}

- (NSArray<NSURL *> *)documentsFileURLsForExport
{
	NSString *docs = [self documentsDirPath];
	if (docs.length == 0) {
		return @[];
	}
	NSError *err = nil;
	NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:&err];
	if (![names isKindOfClass:[NSArray class]] || names.count == 0) {
		return @[];
	}
	NSMutableArray<NSURL *> *urls = [NSMutableArray array];
	for (NSString *name in names) {
		if (name.length == 0 || [name hasPrefix:@"."]) {
			continue;
		}
		NSString *path = [docs stringByAppendingPathComponent:name];
		[urls addObject:[NSURL fileURLWithPath:path]];
	}
	return urls;
}

- (void)exportDocumentsFromSourceView:(UIView *)sourceView sourceRect:(CGRect)sourceRect
{
	NSArray<NSURL *> *urls = [self documentsFileURLsForExport];
	if (urls.count == 0) {
		[self presentSimpleAlertWithTitle:@"Export documents" message:@"No files in Documents"];
		return;
	}

	UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
	UIPopoverPresentationController *ppc = avc.popoverPresentationController;
	if (ppc) {
		ppc.sourceView = sourceView ?: self.view;
		ppc.sourceRect = sourceView ? sourceRect : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
		ppc.permittedArrowDirections = UIPopoverArrowDirectionAny;
	}
	[self presentViewController:avc animated:YES completion:nil];
}

- (void)deleteAllDocumentsFromSourceView:(UIView *)sourceView sourceRect:(CGRect)sourceRect
{
	NSString *docs = [self documentsDirPath];
	if (docs.length == 0) {
		[self presentSimpleAlertWithTitle:@"Delete documents" message:@"Documents directory not available"];
		return;
	}

	UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Delete documents"
	                                                            message:@"Delete all files in Documents? This includes disks and snapshots."
	                                                     preferredStyle:UIAlertControllerStyleActionSheet];
	__weak typeof(self) weakSelf = self;
	[ac addAction:[UIAlertAction actionWithTitle:@"Delete all" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
		__strong typeof(weakSelf) selfStrong = weakSelf;
		if (!selfStrong) {
			return;
		}
		NSError *err = nil;
		NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:&err];
		if ([names isKindOfClass:[NSArray class]]) {
			for (NSString *name in names) {
				if (name.length == 0 || [name hasPrefix:@"."]) {
					continue;
				}
				NSString *path = [docs stringByAppendingPathComponent:name];
				(void)[[NSFileManager defaultManager] removeItemAtPath:path error:nil];
			}
		}
		selfStrong.isoFilename = nil;
		selfStrong.diskFilename = nil;
		[selfStrong saveDefaults];
		[selfStrong reloadDocFiles];
		[selfStrong.tableView reloadData];
	}]];
	[ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	UIPopoverPresentationController *ppc = ac.popoverPresentationController;
	if (ppc) {
		ppc.sourceView = sourceView ?: self.view;
		ppc.sourceRect = sourceView ? sourceRect : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
		ppc.permittedArrowDirections = UIPopoverArrowDirectionAny;
	}
	[self presentViewController:ac animated:YES completion:nil];
}

- (void)presentChoiceWithTitle:(NSString *)title options:(NSArray<NSString *> *)options fromSourceView:(UIView *)sourceView sourceRect:(CGRect)sourceRect handler:(void (^)(NSInteger idx))handler
{
	UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
	for (NSInteger i = 0; i < (NSInteger)options.count; i++) {
		NSString *opt = options[i];
		[ac addAction:[UIAlertAction actionWithTitle:opt style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
			handler(i);
		}]];
	}
	[ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	UIPopoverPresentationController *ppc = ac.popoverPresentationController;
	if (ppc) {
		ppc.sourceView = sourceView ?: self.view;
		ppc.sourceRect = sourceView ? sourceRect : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
		ppc.permittedArrowDirections = UIPopoverArrowDirectionAny;
	}
	[self presentViewController:ac animated:YES completion:nil];
}

- (void)presentSimpleAlertWithTitle:(NSString *)title message:(NSString *)message
{
	UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
	[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:a animated:YES completion:nil];
}

- (NSString *)uniqueFilenameInDocuments:(NSString *)name
{
	NSString *docs = [self documentsDirPath];
	if (docs.length == 0 || name.length == 0) {
		return nil;
	}
	NSString *base = [name stringByDeletingPathExtension];
	NSString *ext = [name pathExtension];
	NSString *candidate = name;
	NSFileManager *fm = [NSFileManager defaultManager];
	for (NSInteger i = 0; i < 1000; i++) {
		NSString *path = [docs stringByAppendingPathComponent:candidate];
		if (![fm fileExistsAtPath:path]) {
			return candidate;
		}
		candidate = (ext.length > 0) ? [NSString stringWithFormat:@"%@-%ld.%@", base, (long)(i + 1), ext] : [NSString stringWithFormat:@"%@-%ld", base, (long)(i + 1)];
	}
	return nil;
}

- (void)importDiskFromSourceView:(UIView *)sourceView sourceRect:(CGRect)sourceRect
{
	UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
	picker.delegate = self;
	picker.allowsMultipleSelection = NO;
	UIPopoverPresentationController *ppc = picker.popoverPresentationController;
	if (ppc) {
		ppc.sourceView = sourceView ?: self.view;
		ppc.sourceRect = sourceView ? sourceRect : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
		ppc.permittedArrowDirections = UIPopoverArrowDirectionAny;
	}
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	(void)controller;
	NSURL *url = urls.firstObject;
	if (!url) {
		return;
	}
	NSString *ext = url.pathExtension.lowercaseString ?: @"";
	if (!([ext isEqualToString:@"img"] || [ext isEqualToString:@"raw"] || [ext isEqualToString:@"qcow2"])) {
		[self presentSimpleAlertWithTitle:@"Import disk" message:@"Unsupported file type. Use .img/.raw/.qcow2"];
		return;
	}
	NSString *docs = [self documentsDirPath];
	if (docs.length == 0) {
		[self presentSimpleAlertWithTitle:@"Import disk" message:@"Documents directory not available"];
		return;
	}

	BOOL access = [url startAccessingSecurityScopedResource];
	NSString *name = url.lastPathComponent;
	NSString *dstName = [self uniqueFilenameInDocuments:name];
	if (dstName.length == 0) {
		if (access) {
			[url stopAccessingSecurityScopedResource];
		}
		[self presentSimpleAlertWithTitle:@"Import disk" message:@"Failed to pick destination name"];
		return;
	}
	NSString *dstPath = [docs stringByAppendingPathComponent:dstName];
	NSURL *dstURL = [NSURL fileURLWithPath:dstPath];
	NSError *err = nil;
	if (![[NSFileManager defaultManager] copyItemAtURL:url toURL:dstURL error:&err]) {
		if (access) {
			[url stopAccessingSecurityScopedResource];
		}
		[self presentSimpleAlertWithTitle:@"Import disk" message:@"Copy failed"];
		return;
	}
	if (access) {
		[url stopAccessingSecurityScopedResource];
	}
	self.diskFilename = dstName;
	[self saveDefaults];
	[self reloadDocFiles];
	[self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
	UIView *sourceView = cell ?: tableView;
	CGRect sourceRect = cell ? cell.bounds : [tableView rectForRowAtIndexPath:indexPath];
	if (indexPath.section == 0 && indexPath.row == 1) {
		if (self.disableIso) {
			return;
		}
		NSMutableArray<NSString *> *opts = [NSMutableArray arrayWithObject:@"Bundled"];
		for (NSString *f in self.docFiles) {
			if ([f.lowercaseString hasSuffix:@".iso"]) {
				[opts addObject:f];
			}
		}
		[self presentChoiceWithTitle:@"ISO" options:opts fromSourceView:sourceView sourceRect:sourceRect handler:^(NSInteger idx) {
			self.isoFilename = (idx == 0) ? nil : opts[idx];
			[self saveDefaults];
			[self.tableView reloadData];
		}];
		return;
	}
	if (indexPath.section == 0 && indexPath.row == 2) {
		NSMutableArray<NSString *> *opts = [NSMutableArray arrayWithObject:@"Default (alpine-riscv64.img)"];
		for (NSString *f in self.docFiles) {
			NSString *lower = f.lowercaseString;
			if ([lower hasSuffix:@".img"] || [lower hasSuffix:@".raw"] || [lower hasSuffix:@".qcow2"]) {
				[opts addObject:f];
			}
		}
		[self presentChoiceWithTitle:@"Disk Image" options:opts fromSourceView:sourceView sourceRect:sourceRect handler:^(NSInteger idx) {
			self.diskFilename = (idx == 0) ? nil : opts[idx];
			[self saveDefaults];
			[self.tableView reloadData];
		}];
		return;
	}
	if (indexPath.section == 0 && indexPath.row == 3) {
		[self importDiskFromSourceView:sourceView sourceRect:sourceRect];
		return;
	}
	if (indexPath.section == 0 && indexPath.row == 4) {
		RV64PortForwardsViewController *vc = [[RV64PortForwardsViewController alloc] init];
		vc.items = [self.portForwards mutableCopy] ?: [NSMutableArray array];
		__weak typeof(self) weakSelf = self;
		vc.onChange = ^(NSArray<NSString *> *items) {
			__strong typeof(weakSelf) selfStrong = weakSelf;
			if (!selfStrong) {
				return;
			}
			selfStrong.portForwards = items ?: @[];
			[selfStrong saveDefaults];
		};
		[self.navigationController pushViewController:vc animated:YES];
		return;
	}
	if (indexPath.section == 0 && indexPath.row == 5) {
		UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Reinit network"
		                                                            message:@"This drops active connections and reinitializes the host networking backend."
		                                                     preferredStyle:UIAlertControllerStyleAlert];
		[ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
		__weak typeof(self) weakSelf = self;
		[ac addAction:[UIAlertAction actionWithTitle:@"Reinit" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
			__strong typeof(weakSelf) selfStrong = weakSelf;
			if (!selfStrong) {
				return;
			}
			UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"Network" message:@"Reinitializing…" preferredStyle:UIAlertControllerStyleAlert];
			[selfStrong presentViewController:progress animated:YES completion:nil];
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
				NSString *err = nil;
				BOOL ok = [RV64Runner reinitNetwork:&err];
				dispatch_async(dispatch_get_main_queue(), ^{
					[progress dismissViewControllerAnimated:YES completion:^{
						NSString *title = ok ? @"Network reinitialized" : @"Network failed";
						NSString *msg = ok ? @"OK" : (err ?: @"Unknown error");
						UIAlertController *done = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
						[done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
						[selfStrong presentViewController:done animated:YES completion:nil];
					}];
				});
			});
		}]];
		[self presentViewController:ac animated:YES completion:nil];
		return;
	}
	if (indexPath.section == 0 && indexPath.row == 6) {
		UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Restart emulation"
		                                                            message:@"Restart RVVM with current settings?"
		                                                     preferredStyle:UIAlertControllerStyleAlert];
		[ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
		__weak typeof(self) weakSelf = self;
		[ac addAction:[UIAlertAction actionWithTitle:@"Restart" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
			__strong typeof(weakSelf) selfStrong = weakSelf;
			[selfStrong saveDefaults];
			[RV64Runner requestRestart];
			[selfStrong.navigationController popViewControllerAnimated:YES];
		}]];
		[self presentViewController:ac animated:YES completion:nil];
		return;
	}
	if (indexPath.section == 0 && indexPath.row == 7) {
		UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Save snapshot"
		                                                            message:@"This saves the current VM state (RAM + CPU registers) to Documents/rvvm.snapshot.img"
		                                                     preferredStyle:UIAlertControllerStyleAlert];
		[ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
		__weak typeof(self) weakSelf = self;
		[ac addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
			__strong typeof(weakSelf) selfStrong = weakSelf;
			if (!selfStrong) {
				return;
			}
			UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"Snapshot" message:@"Saving…" preferredStyle:UIAlertControllerStyleAlert];
			[selfStrong presentViewController:progress animated:YES completion:nil];
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
				NSString *err = nil;
				BOOL ok = [RV64Runner saveSnapshot:&err];
				dispatch_async(dispatch_get_main_queue(), ^{
					[progress dismissViewControllerAnimated:YES completion:^{
						NSString *title = ok ? @"Snapshot saved" : @"Snapshot failed";
						NSString *msg = ok ? @"Saved to Documents/rvvm.snapshot.img" : (err ?: @"Unknown error");
						UIAlertController *done = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
						[done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
						[selfStrong presentViewController:done animated:YES completion:nil];
						[selfStrong.tableView reloadData];
					}];
				});
			});
		}]];
		[self presentViewController:ac animated:YES completion:nil];
		return;
	}
	if (indexPath.section == 0 && indexPath.row == 8) {
		if (![self snapshotExists]) {
			return;
		}
		UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Load snapshot"
		                                                            message:@"This overwrites the current VM state (RAM + CPU registers)."
		                                                     preferredStyle:UIAlertControllerStyleAlert];
		[ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
		__weak typeof(self) weakSelf = self;
		[ac addAction:[UIAlertAction actionWithTitle:@"Load" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
			__strong typeof(weakSelf) selfStrong = weakSelf;
			if (!selfStrong) {
				return;
			}
			UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"Snapshot" message:@"Loading…" preferredStyle:UIAlertControllerStyleAlert];
			[selfStrong presentViewController:progress animated:YES completion:nil];
			dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
				NSString *err = nil;
				BOOL ok = [RV64Runner loadSnapshot:&err];
				dispatch_async(dispatch_get_main_queue(), ^{
					[progress dismissViewControllerAnimated:YES completion:^{
						if (ok) {
							[selfStrong.navigationController popViewControllerAnimated:YES];
							return;
						}
						UIAlertController *done = [UIAlertController alertControllerWithTitle:@"Snapshot failed" message:(err ?: @"Unknown error") preferredStyle:UIAlertControllerStyleAlert];
						[done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
						[selfStrong presentViewController:done animated:YES completion:nil];
						[selfStrong.tableView reloadData];
					}];
				});
			});
		}]];
		[self presentViewController:ac animated:YES completion:nil];
		return;
	}
	if (indexPath.section == 1 && indexPath.row == 0) {
		NSMutableArray<NSString *> *opts = [NSMutableArray array];
		for (NSInteger i = 1; i <= 8; i++) {
			[opts addObject:[NSString stringWithFormat:@"%ld", (long)i]];
		}
		[self presentChoiceWithTitle:@"Cores" options:opts fromSourceView:sourceView sourceRect:sourceRect handler:^(NSInteger idx) {
			self.cores = idx + 1;
			[self saveDefaults];
			[self.tableView reloadData];
		}];
		return;
	}
	if (indexPath.section == 1 && indexPath.row == 1) {
		NSArray<NSNumber *> *vals = @[@256, @512, @768, @1024, @1536, @2048];
		NSMutableArray<NSString *> *opts = [NSMutableArray array];
		for (NSNumber *n in vals) {
			[opts addObject:[NSString stringWithFormat:@"%@ MB", n]];
		}
		[self presentChoiceWithTitle:@"RAM" options:opts fromSourceView:sourceView sourceRect:sourceRect handler:^(NSInteger idx) {
			self.ramMB = vals[idx].integerValue;
			[self saveDefaults];
			[self.tableView reloadData];
		}];
		return;
	}
	if (indexPath.section == 3 && indexPath.row == 2) {
		RV64VirtioFSDebugViewController *vc = [RV64VirtioFSDebugViewController new];
		[self.navigationController pushViewController:vc animated:YES];
		return;
	}
	if (indexPath.section == 2 && indexPath.row == 0) {
		[self exportDocumentsFromSourceView:sourceView sourceRect:sourceRect];
		return;
	}
	if (indexPath.section == 2 && indexPath.row == 1) {
		[self deleteAllDocumentsFromSourceView:sourceView sourceRect:sourceRect];
		return;
	}
}

@end

@implementation RV64RootViewController

static uint8_t CtrlifyByte(uint8_t c)
{
	if (c >= 'a' && c <= 'z') {
		return (uint8_t)(c - 'a' + 1);
	}
	if (c >= 'A' && c <= 'Z') {
		return (uint8_t)(c - 'A' + 1);
	}
	switch (c) {
		case ' ': return 0x00;
		case '[': return 0x1b;
		case '\\': return 0x1c;
		case ']': return 0x1d;
		case '^': return 0x1e;
		case '_': return 0x1f;
		default: return c;
	}
}

- (void)updateModifierButtons
{
	self.ctrlButton.selected = self.ctrlArmed;
	self.altButton.selected = self.altArmed;
	UIColor *activeBg = UIColor.tertiarySystemFillColor;
	UIColor *inactiveBg = UIColor.clearColor;
	self.ctrlButton.backgroundColor = self.ctrlButton.selected ? activeBg : inactiveBg;
	self.altButton.backgroundColor = self.altButton.selected ? activeBg : inactiveBg;
}

- (void)sendConsoleData:(NSData *)data
{
	if (!data || data.length == 0) {
		return;
	}
	[RV64Runner sendConsoleBytes:data];
	[self.terminalView evaluateJavaScript:@"window.rvvmFocus && window.rvvmFocus();" completionHandler:nil];
}

- (UIButton *)keyButtonWithTitle:(NSString *)title action:(SEL)action
{
	UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
	[b setTitle:title forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
	b.contentEdgeInsets = UIEdgeInsetsMake(6, 10, 6, 10);
	b.layer.cornerRadius = 8;
	b.layer.masksToBounds = YES;
	[b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
	return b;
}

- (UIView *)buildKeyboardAccessoryView
{
	UIView *root = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 44)];

	UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
	blur.translatesAutoresizingMaskIntoConstraints = NO;
	[root addSubview:blur];
	[NSLayoutConstraint activateConstraints:@[
		[blur.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
		[blur.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
		[blur.topAnchor constraintEqualToAnchor:root.topAnchor],
		[blur.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
	]];

	UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
	scroll.translatesAutoresizingMaskIntoConstraints = NO;
	scroll.showsHorizontalScrollIndicator = NO;
	scroll.alwaysBounceHorizontal = YES;
	[blur.contentView addSubview:scroll];
	[NSLayoutConstraint activateConstraints:@[
		[scroll.leadingAnchor constraintEqualToAnchor:blur.contentView.leadingAnchor],
		[scroll.trailingAnchor constraintEqualToAnchor:blur.contentView.trailingAnchor],
		[scroll.topAnchor constraintEqualToAnchor:blur.contentView.topAnchor],
		[scroll.bottomAnchor constraintEqualToAnchor:blur.contentView.bottomAnchor],
	]];

	UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	stack.axis = UILayoutConstraintAxisHorizontal;
	stack.spacing = 8;
	stack.alignment = UIStackViewAlignmentCenter;
	stack.layoutMarginsRelativeArrangement = YES;
	stack.layoutMargins = UIEdgeInsetsMake(6, 8, 6, 8);
	[scroll addSubview:stack];
	[NSLayoutConstraint activateConstraints:@[
		[stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
		[stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
		[stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
		[stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
		[stack.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
	]];

	UIButton *esc = [self keyButtonWithTitle:@"Esc" action:@selector(keyEscPressed:)];
	UIButton *uart = [self keyButtonWithTitle:@"UART" action:@selector(switchToUARTPressed:)];
	UIButton *fb = [self keyButtonWithTitle:@"FB" action:@selector(switchToFramebufferPressed:)];
	UIButton *settings = [self keyButtonWithTitle:@"Settings" action:@selector(keySettingsPressed:)];
	UIButton *tab = [self keyButtonWithTitle:@"Tab" action:@selector(keyTabPressed:)];
	UIButton *ctrl = [self keyButtonWithTitle:@"Ctrl" action:@selector(keyCtrlPressed:)];
	UIButton *alt = [self keyButtonWithTitle:@"Alt" action:@selector(keyAltPressed:)];
	self.ctrlButton = ctrl;
	self.altButton = alt;

	UIButton *up = [self keyButtonWithTitle:@"↑" action:@selector(keyUpPressed:)];
	UIButton *down = [self keyButtonWithTitle:@"↓" action:@selector(keyDownPressed:)];
	UIButton *left = [self keyButtonWithTitle:@"←" action:@selector(keyLeftPressed:)];
	UIButton *right = [self keyButtonWithTitle:@"→" action:@selector(keyRightPressed:)];

	UIButton *hide = [self keyButtonWithTitle:@"Hide" action:@selector(keyHidePressed:)];

	NSArray<UIButton *> *all = @[esc, uart, fb, settings, tab, ctrl, alt, left, up, down, right, hide];
	for (UIButton *b in all) {
		[stack addArrangedSubview:b];
	}

	[self updateModifierButtons];
	return root;
}

- (void)switchToUARTPressed:(id)sender
{
	(void)sender;
	if (self.tabBarController) {
		self.tabBarController.selectedIndex = 0;
	}
}

- (void)switchToFramebufferPressed:(id)sender
{
	(void)sender;
	if (self.tabBarController) {
		self.tabBarController.selectedIndex = 1;
	}
}

- (void)keyEscPressed:(id)sender
{
	(void)sender;
	uint8_t b = 0x1b;
	[self sendConsoleData:[NSData dataWithBytes:&b length:1]];
}

- (void)keySettingsPressed:(id)sender
{
	(void)sender;
	[self.terminalView evaluateJavaScript:@"try{document.activeElement && document.activeElement.blur();}catch(e){}" completionHandler:nil];
	[self.view endEditing:YES];
	[self openSettings:nil];
}

- (void)keyTabPressed:(id)sender
{
	(void)sender;
	uint8_t b = '\t';
	[self sendConsoleData:[NSData dataWithBytes:&b length:1]];
}

- (void)keyCtrlPressed:(id)sender
{
	(void)sender;
	self.ctrlArmed = !self.ctrlArmed;
	[self updateModifierButtons];
	[self.terminalView evaluateJavaScript:@"window.rvvmFocus && window.rvvmFocus();" completionHandler:nil];
}

- (void)keyAltPressed:(id)sender
{
	(void)sender;
	self.altArmed = !self.altArmed;
	[self updateModifierButtons];
	[self.terminalView evaluateJavaScript:@"window.rvvmFocus && window.rvvmFocus();" completionHandler:nil];
}

- (void)keyUpPressed:(id)sender
{
	(void)sender;
	const char *s = "\x1b[A";
	[self sendConsoleData:[NSData dataWithBytes:s length:3]];
}

- (void)keyDownPressed:(id)sender
{
	(void)sender;
	const char *s = "\x1b[B";
	[self sendConsoleData:[NSData dataWithBytes:s length:3]];
}

- (void)keyLeftPressed:(id)sender
{
	(void)sender;
	const char *s = "\x1b[D";
	[self sendConsoleData:[NSData dataWithBytes:s length:3]];
}

- (void)keyRightPressed:(id)sender
{
	(void)sender;
	const char *s = "\x1b[C";
	[self sendConsoleData:[NSData dataWithBytes:s length:3]];
}

- (void)keyPastePressed:(id)sender
{
	(void)sender;
	NSString *s = [UIPasteboard generalPasteboard].string;
	if (s.length == 0) {
		return;
	}
	NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
	[self sendConsoleData:d];
}

- (void)keyHidePressed:(id)sender
{
	(void)sender;
	[self.terminalView evaluateJavaScript:@"try{document.activeElement && document.activeElement.blur();}catch(e){}" completionHandler:nil];
	[self.view endEditing:YES];
}

- (void)loadView
{
	UIView *root = [[UIView alloc] initWithFrame:CGRectZero];
	root.backgroundColor = UIColor.systemBackgroundColor;
	self.view = root;
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	[self.navigationController setNavigationBarHidden:YES animated:animated];
}

- (void)viewWillDisappear:(BOOL)animated
{
	[super viewWillDisappear:animated];
	[self.navigationController setNavigationBarHidden:NO animated:animated];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
	(void)gestureRecognizer;
	(void)otherGestureRecognizer;
	return YES;
}

- (void)tapPressed:(UITapGestureRecognizer *)gr
{
	(void)gr;
	[self.terminalView evaluateJavaScript:@"window.rvvmFocus && window.rvvmFocus();" completionHandler:nil];
}

- (void)panMoved:(UIPanGestureRecognizer *)gr
{
	if (gr.state == UIGestureRecognizerStateBegan || gr.state == UIGestureRecognizerStateChanged) {
		UIView *v = gr.view ?: self.view;
		CGPoint t = [gr translationInView:v];
		const CGFloat stepPx = 24.0;
		int32_t steps = (int32_t)llround(t.y / stepPx);
		if (steps == 0) {
			return;
		}
		int32_t lines = -steps;
		NSString *js = [NSString stringWithFormat:@"window.rvvmScrollLines && window.rvvmScrollLines(%d);", lines];
		[self.terminalView evaluateJavaScript:js completionHandler:nil];
		[gr setTranslation:CGPointZero inView:v];
	}
}

- (void)longPressChanged:(UILongPressGestureRecognizer *)gr
{
	(void)gr;
}

- (void)keyboardWillChangeFrame:(NSNotification *)note
{
	NSDictionary *ui = note.userInfo;
	CGRect kbEnd = [ui[UIKeyboardFrameEndUserInfoKey] CGRectValue];
	CGRect kbEndInView = [self.view convertRect:kbEnd fromView:nil];
	CGRect bounds = self.view.bounds;
	CGRect inter = CGRectIntersection(bounds, kbEndInView);
	CGFloat overlap = CGRectIsNull(inter) ? 0.0 : inter.size.height;

	NSTimeInterval duration = [ui[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
	NSInteger curve = [ui[UIKeyboardAnimationCurveUserInfoKey] integerValue];
	UIViewAnimationOptions options = (UIViewAnimationOptions)(curve << 16);

	self.terminalBottomConstraint.constant = -overlap;
	[UIView animateWithDuration:duration delay:0 options:options animations:^{
		[self.view layoutIfNeeded];
	} completion:^(__unused BOOL finished) {
		[self.terminalView evaluateJavaScript:@"window.rvvmFit && window.rvvmFit(); try{term && term.scrollToBottom && term.scrollToBottom();}catch(e){}" completionHandler:nil];
	}];
}

- (void)viewDidLoad {
	[super viewDidLoad];

	self.pendingWritesB64 = [NSMutableArray array];
	self.terminalReady = NO;

	WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
	WKUserContentController *ucc = [[WKUserContentController alloc] init];
	[ucc addScriptMessageHandler:self name:@"rvvm"];
	cfg.userContentController = ucc;

	RV64TerminalWebView *web = [[RV64TerminalWebView alloc] initWithFrame:CGRectZero configuration:cfg];
	web.translatesAutoresizingMaskIntoConstraints = NO;
	web.navigationDelegate = self;
	web.opaque = NO;
	web.backgroundColor = UIColor.clearColor;
	web.scrollView.backgroundColor = UIColor.clearColor;
	web.scrollView.scrollEnabled = YES;
	web.scrollView.bounces = NO;
	web.scrollView.alwaysBounceVertical = NO;
	web.scrollView.alwaysBounceHorizontal = NO;
	if ([web.scrollView respondsToSelector:@selector(setContentInsetAdjustmentBehavior:)]) {
		web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
	}
	web.scrollView.contentInset = UIEdgeInsetsZero;
	web.scrollView.scrollIndicatorInsets = UIEdgeInsetsZero;
	web.rvvmAccessoryView = [self buildKeyboardAccessoryView];
	[self.view addSubview:web];
	self.terminalView = web;

	NSLayoutConstraint *bottom = [web.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:0];
	self.terminalBottomConstraint = bottom;
	[NSLayoutConstraint activateConstraints:@[
		[web.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:0],
		[web.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:0],
		[web.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:0],
		bottom,
	]];

	UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapPressed:)];
	tap.cancelsTouchesInView = NO;
	tap.delegate = self;
	[self.view addGestureRecognizer:tap];

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(rv64UartText:) name:RV64RunnerUARTTextNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChangeFrame:) name:UIKeyboardWillChangeFrameNotification object:nil];
	[RV64Runner startLinux];

	NSString *html =
	@"<!doctype html><html><head><meta charset='utf-8'/>"
	"<meta name='viewport' content='width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover'/>"
	"<link rel='stylesheet' href='xterm/xterm.css'/>"
	"<style>"
	":root{--bg:#ffffff;--fg:#111111;}"
	"html,body{position:fixed;inset:0;width:100vw;height:100vh;margin:0;padding:0;overflow:hidden;background:var(--bg);}"
	"#term{position:fixed;inset:0;width:100vw;height:100vh;background:var(--bg);}"
	"#term .xterm{position:absolute;inset:0;width:100%;height:100%;}"
	".xterm,.xterm-viewport,.xterm-screen{background:var(--bg)!important;}"
	".xterm-viewport{overflow-y:scroll;-webkit-overflow-scrolling:touch;}"
	"#fallback{position:absolute;left:12px;top:12px;right:12px;color:var(--fg);font-family:ui-monospace,Menlo,monospace;font-size:12px;white-space:pre-wrap;}"
	"</style>"
	"</head><body><div id='term'></div><div id='fallback'>Loading terminal…\nIf it stays black, xterm assets didn’t load.</div>"
	"<script src='xterm/xterm.js'></script>"
	"<script src='xterm/xterm-addon-fit.js'></script>"
	"<script>"
	"let term=null; let fit=null;"
	"function postLog(msg){try{window.webkit.messageHandlers.rvvm.postMessage({t:'log', msg:String(msg)});}catch(e){}}"
	"window.onerror=function(msg, src, line, col, err){postLog('JS error: '+msg+' @'+src+':'+line+':'+col);};"
	"function b64FromBytes(bytes){let bin=''; for(let i=0;i<bytes.length;i++){bin+=String.fromCharCode(bytes[i]);} return btoa(bin);}"
	"function bytesFromB64(b64){let bin=atob(b64); let bytes=new Uint8Array(bin.length); for(let i=0;i<bin.length;i++){bytes[i]=bin.charCodeAt(i);} return bytes;}"
	"window.rvvmWriteBase64=function(b64){try{let bytes=bytesFromB64(b64); let txt=new TextDecoder('utf-8').decode(bytes); term && term.write(txt);}catch(e){}};"
	"window.rvvmFocus=function(){try{term && term.focus();}catch(e){}};"
	"window.rvvmScrollLines=function(n){try{term && term.scrollLines(Number(n)||0);}catch(e){}};"
	"function refit(){try{fit && fit.fit();}catch(e){}}"
	"function scheduleFit(){try{requestAnimationFrame(function(){refit(); requestAnimationFrame(refit);});}catch(e){refit();}}"
	"window.rvvmFit=function(){scheduleFit();};"
	"function init(){"
	"if(typeof Terminal==='undefined'){postLog('Terminal is undefined (xterm.js not loaded)'); return;}"
	"term=new Terminal({convertEol:true, fontSize:12, fontFamily:'ui-monospace, Menlo, monospace', theme:{background:'#ffffff', foreground:'#111111', cursor:'#111111', cursorAccent:'#ffffff', selectionBackground:'#cce3ff'}});"
	"if(typeof FitAddon==='undefined'){postLog('FitAddon is undefined (xterm-addon-fit not loaded)');}"
	"try{fit=new FitAddon.FitAddon(); term.loadAddon(fit);}catch(e){postLog('Fit init failed: '+e);}"
	"term.open(document.getElementById('term')); scheduleFit(); term.focus();"
	"let fb=document.getElementById('fallback'); if(fb) fb.style.display='none';"
	"term.write('booting...\\r\\n');"
	"term.onData(function(data){try{"
	"let bytes=new TextEncoder().encode(data);"
	"let b64=b64FromBytes(bytes);"
	"window.webkit.messageHandlers.rvvm.postMessage({t:'in', b64:b64});"
	"if(data && (data.indexOf('\\r')>=0 || data.indexOf('\\n')>=0)){ term.scrollToBottom(); }"
	"}catch(e){postLog('onData failed: '+e);}});"
	"window.addEventListener('resize', scheduleFit);"
	"try{window.visualViewport && window.visualViewport.addEventListener('resize', scheduleFit);}catch(e){}"
	"try{if('ResizeObserver' in window){let ro=new ResizeObserver(scheduleFit); ro.observe(document.body); ro.observe(document.getElementById('term'));}}catch(e){}"
	"try{document.fonts && document.fonts.ready && document.fonts.ready.then(scheduleFit);}catch(e){}"
	"setTimeout(scheduleFit, 0); setTimeout(scheduleFit, 100); setTimeout(scheduleFit, 500);"
	"}"
	"try{init();}catch(e){postLog('init exception: '+e);}"
	"</script></body></html>";
	NSURL *baseURL = [NSBundle mainBundle].resourceURL;
	[self.terminalView loadHTMLString:html baseURL:baseURL];
}

- (BOOL)prefersStatusBarHidden
{
	return YES;
}

- (void)openSettings:(id)sender
{
	(void)sender;
	[self.navigationController setNavigationBarHidden:NO animated:YES];
	RV64SettingsViewController *vc = [[RV64SettingsViewController alloc] init];
	[self.navigationController pushViewController:vc animated:YES];
}

- (void)viewDidLayoutSubviews
{
	[super viewDidLayoutSubviews];
	[self setNeedsStatusBarAppearanceUpdate];
	if ([self.terminalView.scrollView respondsToSelector:@selector(setContentInsetAdjustmentBehavior:)]) {
		self.terminalView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
	}
	if ([self.terminalView.scrollView respondsToSelector:@selector(setAutomaticallyAdjustsScrollIndicatorInsets:)]) {
		self.terminalView.scrollView.automaticallyAdjustsScrollIndicatorInsets = NO;
	}
	self.terminalView.scrollView.contentInset = UIEdgeInsetsZero;
	self.terminalView.scrollView.scrollIndicatorInsets = UIEdgeInsetsZero;
	[self.terminalView evaluateJavaScript:@"window.rvvmFit && window.rvvmFit();" completionHandler:nil];
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	[self.terminalView evaluateJavaScript:@"window.rvvmFocus && window.rvvmFocus();" completionHandler:nil];
}

- (void)dealloc {
	[self.terminalView.configuration.userContentController removeScriptMessageHandlerForName:@"rvvm"];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)rv64UartText:(NSNotification *)note {
	NSString *text = note.object;
	if (![text isKindOfClass:[NSString class]] || text.length == 0) {
		return;
	}
	NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
	if (data.length == 0) {
		return;
	}
	NSString *b64 = [data base64EncodedStringWithOptions:0];
	if (!self.terminalReady) {
		[self.pendingWritesB64 addObject:b64];
		return;
	}
	NSString *js = [NSString stringWithFormat:@"window.rvvmWriteBase64 && window.rvvmWriteBase64('%@');", b64];
	[self.terminalView evaluateJavaScript:js completionHandler:nil];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
	(void)webView;
	(void)navigation;
	self.terminalReady = YES;
	if (self.pendingWritesB64.count > 0) {
		NSArray<NSString *> *writes = [self.pendingWritesB64 copy];
		[self.pendingWritesB64 removeAllObjects];
		for (NSString *b64 in writes) {
			NSString *js = [NSString stringWithFormat:@"window.rvvmWriteBase64 && window.rvvmWriteBase64('%@');", b64];
			[self.terminalView evaluateJavaScript:js completionHandler:nil];
		}
	}
	[self.terminalView evaluateJavaScript:@"window.rvvmFocus && window.rvvmFocus();" completionHandler:nil];
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message
{
	(void)userContentController;
	if (![message.name isEqualToString:@"rvvm"]) {
		return;
	}
	NSDictionary *body = [message.body isKindOfClass:[NSDictionary class]] ? (NSDictionary *)message.body : nil;
	if (!body) {
		return;
	}
	NSString *t = [body[@"t"] isKindOfClass:[NSString class]] ? body[@"t"] : nil;
	if ([t isEqualToString:@"log"]) {
		NSString *msg = [body[@"msg"] isKindOfClass:[NSString class]] ? body[@"msg"] : nil;
		if (msg.length == 0) {
			return;
		}
		UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Terminal"
		                                                           message:msg
		                                                    preferredStyle:UIAlertControllerStyleAlert];
		[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
		[self presentViewController:a animated:YES completion:nil];
		return;
	}
	if (![t isEqualToString:@"in"]) {
		return;
	}
	NSString *b64 = [body[@"b64"] isKindOfClass:[NSString class]] ? body[@"b64"] : nil;
	if (b64.length == 0) {
		return;
	}
	NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
	if (data.length == 0) {
		return;
	}
	BOOL ctrl = self.ctrlArmed;
	BOOL alt = self.altArmed;
	if (ctrl || alt) {
		self.ctrlArmed = NO;
		self.altArmed = NO;
		[self updateModifierButtons];
	}

	const uint8_t *in = (const uint8_t *)data.bytes;
	NSUInteger len = data.length;
	NSMutableData *out = [NSMutableData dataWithCapacity:len + 1];
	if (alt) {
		uint8_t esc = 0x1b;
		[out appendBytes:&esc length:1];
	}
	if (ctrl && len > 0) {
		uint8_t first = CtrlifyByte(in[0]);
		[out appendBytes:&first length:1];
		if (len > 1) {
			[out appendBytes:in + 1 length:len - 1];
		}
	} else {
		[out appendData:data];
	}
	[self sendConsoleData:out];
}

@end
