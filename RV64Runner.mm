#import "RV64Runner.h"

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

#include <rvvm/rvvm.h>

extern "C" {
#include "devices/chardev.h"
#include "devices/eth-oc.h"
#include "devices/nvme.h"
#include "devices/ns16550a.h"
#include "devices/pci-bus.h"
#include "devices/riscv-aclint.h"
#include "devices/riscv-plic.h"
#include "devices/rtl8169.h"
#include "devices/rtc-goldfish.h"
#include "devices/syscon.h"
#include "devices/virtio-fs.h"
}

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <limits.h>
#include <mutex>
#include <sys/stat.h>
#include <string>
#include <unistd.h>
#include <vector>

NSString *const RV64RunnerUARTTextNotification = @"RV64RunnerUARTTextNotification";
NSString *const RV64RunnerUARTTextKey = @"text";
NSString *const RV64RunnerVirtioFSDebugNotification = @"RV64RunnerVirtioFSDebugNotification";

static NSString *const kRVVMDefaultsBootMode = @"rvvm.bootMode";
static NSString *const kRVVMDefaultsCores = @"rvvm.cores";
static NSString *const kRVVMDefaultsRamMB = @"rvvm.ramMB";
static NSString *const kRVVMDefaultsDisableIso = @"rvvm.disableIso";
static NSString *const kRVVMDefaultsIsoFilename = @"rvvm.isoFilename";
static NSString *const kRVVMDefaultsDiskFilename = @"rvvm.diskFilename";
static NSString *const kRVVMDefaultsArchImgFilename = @"rvvm.archImgFilename";
static NSString *const kRVVMDefaultsPortForwards = @"rvvm.portForwards";
static NSString *const kRVVMDefaultsVirtioFSDebugToUART = @"rvvm.virtiofsDebugToUart";

typedef NS_ENUM(NSInteger, RVVMBootMode) {
	RVVMBootModeAuto = 0,
	RVVMBootModeAlpine = 1,
	RVVMBootModeArch = 2,
	RVVMBootModeCustom = 3,
};

static void PostUARTText(const std::string& s)
{
	CFStringRef cfText = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)s.data(), (CFIndex)s.size(),
	                                            kCFStringEncodingUTF8, false);
	NSString *text = cfText ? (__bridge_transfer NSString *)cfText : nil;
	if (!text || text.length == 0) {
		return;
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		[[NSNotificationCenter defaultCenter] postNotificationName:RV64RunnerUARTTextNotification object:text userInfo:nil];
	});
}

static void PostVirtioFSDebugText(const std::string& s)
{
	CFStringRef cfText = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)s.data(), (CFIndex)s.size(),
	                                            kCFStringEncodingUTF8, false);
	NSString *text = cfText ? (__bridge_transfer NSString *)cfText : nil;
	if (!text || text.length == 0) {
		return;
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		[[NSNotificationCenter defaultCenter] postNotificationName:RV64RunnerVirtioFSDebugNotification object:text userInfo:nil];
	});
}

static std::mutex s_vfs_debug_mu;
static std::deque<std::string> s_vfs_debug_lines;
static size_t s_vfs_debug_bytes = 0;
static std::atomic<bool> s_vfs_debug_to_uart(true);

static void AppendVirtioFSDebugLine(const std::string& s)
{
	constexpr size_t kMaxLines = 1000;
	constexpr size_t kMaxBytes = 256 * 1024;
	std::lock_guard<std::mutex> lock(s_vfs_debug_mu);
	s_vfs_debug_lines.push_back(s);
	s_vfs_debug_bytes += s.size();
	while (!s_vfs_debug_lines.empty() && (s_vfs_debug_lines.size() > kMaxLines || s_vfs_debug_bytes > kMaxBytes)) {
		s_vfs_debug_bytes -= s_vfs_debug_lines.front().size();
		s_vfs_debug_lines.pop_front();
	}
}

extern "C" void rvvm_ios_uart_debug_print(const char* s) __attribute__((used));
extern "C" void rvvm_ios_uart_debug_print(const char* s)
{
	if (!s) {
		return;
	}
	PostUARTText(std::string(s));
}

extern "C" void rvvm_ios_virtiofs_debug_print(const char* s) __attribute__((used));
extern "C" void rvvm_ios_virtiofs_debug_print(const char* s)
{
	if (!s) {
		return;
	}
	std::string str(s);
	AppendVirtioFSDebugLine(str);
	PostVirtioFSDebugText(str);
	if (s_vfs_debug_to_uart.load()) {
		PostUARTText(str);
	}
}

static std::string FileSystemPath(NSURL *url)
{
	if (!url) {
		return {};
	}

	CFURLRef cfURL = (__bridge CFURLRef)url;
	if (!cfURL) {
		return {};
	}

	CFStringRef cfPath = CFURLCopyFileSystemPath(cfURL, kCFURLPOSIXPathStyle);
	if (!cfPath) {
		return {};
	}

	char buf[PATH_MAX];
	Boolean ok = CFStringGetCString(cfPath, buf, sizeof(buf), kCFStringEncodingUTF8);
	CFRelease(cfPath);
	if (!ok) {
		return {};
	}
	return std::string(buf);
}

static std::mutex s_state_mutex;
static dispatch_source_t s_uart_flush_timer;
static dispatch_once_t s_uart_flush_once;
static rvvm_machine_t* s_machine = nullptr;
static chardev_t* s_chardev = nullptr;
static dispatch_semaphore_t s_restart_sema;
static dispatch_once_t s_restart_once;
static std::atomic<bool> s_restart_requested(false);
static dispatch_semaphore_t s_snapshot_done_sema;
static dispatch_once_t s_snapshot_once;
static std::atomic<int> s_snapshot_op(0);
static std::mutex s_snapshot_result_mu;
static bool s_snapshot_result_ok = false;
static std::string s_snapshot_result_msg;
static std::string s_active_writable_disk_path;
static dispatch_semaphore_t s_network_done_sema;
static dispatch_once_t s_network_once;
static std::atomic<int> s_network_op(0);
static std::mutex s_network_result_mu;
static bool s_network_result_ok = false;
static std::string s_network_result_msg;

static void EnsureSnapshotPrimitives()
{
	dispatch_once(&s_snapshot_once, ^{
		s_snapshot_done_sema = dispatch_semaphore_create(0);
	});
}

static void SetSnapshotResult(bool ok, const std::string& msg)
{
	{
		std::lock_guard<std::mutex> lock(s_snapshot_result_mu);
		s_snapshot_result_ok = ok;
		s_snapshot_result_msg = msg;
	}
	dispatch_semaphore_signal(s_snapshot_done_sema);
}

static void EnsureRestartSemaphore()
{
	dispatch_once(&s_restart_once, ^{
		s_restart_sema = dispatch_semaphore_create(0);
	});
}

static void EnsureNetworkPrimitives()
{
	dispatch_once(&s_network_once, ^{
		s_network_done_sema = dispatch_semaphore_create(0);
	});
}

static void SetNetworkResult(bool ok, const std::string& msg)
{
	{
		std::lock_guard<std::mutex> lock(s_network_result_mu);
		s_network_result_ok = ok;
		s_network_result_msg = msg;
	}
	dispatch_semaphore_signal(s_network_done_sema);
}

struct UIKitChardevState
{
	std::mutex mu;
	std::deque<uint8_t> rx;
	std::string tx_buf;
	CFAbsoluteTime lastPost = 0;
};

static void EnsureUARTFlushTimerStarted()
{
	dispatch_once(&s_uart_flush_once, ^{
		s_uart_flush_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
		if (!s_uart_flush_timer) {
			return;
		}
		dispatch_source_set_timer(s_uart_flush_timer,
		                         dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)),
		                         (uint64_t)(50 * NSEC_PER_MSEC),
		                         (uint64_t)(5 * NSEC_PER_MSEC));
		dispatch_source_set_event_handler(s_uart_flush_timer, ^{
			chardev_t* dev = nullptr;
			{
				std::lock_guard<std::mutex> lock(s_state_mutex);
				dev = s_chardev;
			}
			auto* state = (dev && dev->data) ? (UIKitChardevState *)dev->data : nullptr;
			if (!state) {
				return;
			}
			std::string out;
			{
				std::lock_guard<std::mutex> lock(state->mu);
				if (state->tx_buf.empty()) {
					return;
				}
				state->lastPost = CFAbsoluteTimeGetCurrent();
				out = std::move(state->tx_buf);
				state->tx_buf.clear();
			}
			if (!out.empty()) {
				PostUARTText(out);
			}
		});
		dispatch_resume(s_uart_flush_timer);
	});
}

static uint32_t UIKitChardevPoll(chardev_t* dev)
{
	auto* state = dev ? (UIKitChardevState *)dev->data : nullptr;
	if (!state) {
		return CHARDEV_TX;
	}
	std::lock_guard<std::mutex> lock(state->mu);
	uint32_t flags = CHARDEV_TX;
	if (!state->rx.empty()) {
		flags |= CHARDEV_RX;
	}
	return flags;
}

static size_t UIKitChardevRead(chardev_t* dev, void* buf, size_t nbytes)
{
	auto* state = dev ? (UIKitChardevState *)dev->data : nullptr;
	if (!state || !buf || nbytes == 0) {
		return 0;
	}
	std::lock_guard<std::mutex> lock(state->mu);
	size_t n = 0;
	auto* out = (uint8_t *)buf;
	while (n < nbytes && !state->rx.empty()) {
		out[n++] = state->rx.front();
		state->rx.pop_front();
	}
	return n;
}

static size_t UIKitChardevWrite(chardev_t* dev, const void* buf, size_t nbytes)
{
	auto* state = dev ? (UIKitChardevState *)dev->data : nullptr;
	if (!state || !buf || nbytes == 0) {
		return nbytes;
	}

	std::vector<std::string> posts;
	posts.reserve(4);

	std::unique_lock<std::mutex> lock(state->mu);
	const auto* in = (const uint8_t *)buf;
	for (size_t i = 0; i < nbytes; i++) {
		uint8_t c = in[i];
		state->tx_buf.push_back((char)c);
		if (c == '\n' || c == '\r' || state->tx_buf.size() >= 1024) {
			posts.push_back(std::move(state->tx_buf));
			state->tx_buf.clear();
		}
	}

	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (!state->tx_buf.empty() && (state->lastPost == 0 || (now - state->lastPost) >= (1.0 / 60.0))) {
		state->lastPost = now;
		posts.push_back(std::move(state->tx_buf));
		state->tx_buf.clear();
	}
	lock.unlock();

	for (const auto& s : posts) {
		if (!s.empty()) {
			PostUARTText(s);
		}
	}
	return nbytes;
}

static void UIKitChardevRemove(chardev_t* dev)
{
	if (!dev) {
		return;
	}
	auto* state = (UIKitChardevState *)dev->data;
	if (state) {
		std::string tail;
		{
			std::lock_guard<std::mutex> lock(state->mu);
			tail = std::move(state->tx_buf);
			state->tx_buf.clear();
			state->rx.clear();
		}
		if (!tail.empty()) {
			PostUARTText(tail);
		}
		delete state;
		dev->data = nullptr;
	}
	free(dev);
}

static chardev_t* CreateUIKitChardev()
{
	chardev_t* dev = (chardev_t *)calloc(1, sizeof(chardev_t));
	if (!dev) {
		return nullptr;
	}
	dev->poll = UIKitChardevPoll;
	dev->read = UIKitChardevRead;
	dev->write = UIKitChardevWrite;
	dev->remove = UIKitChardevRemove;
	dev->data = new UIKitChardevState();
	EnsureUARTFlushTimerStarted();
	return dev;
}

static std::string UTF8FromNSString(NSString *str)
{
	if (!str) {
		return {};
	}
	CFStringRef cf = (__bridge CFStringRef)str;
	if (!cf) {
		return {};
	}
	CFIndex length = CFStringGetLength(cf);
	if (length <= 0) {
		return {};
	}
	CFIndex maxBytes = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
	std::string out;
	out.resize((size_t)maxBytes);
	if (!CFStringGetCString(cf, out.data(), (CFIndex)out.size(), kCFStringEncodingUTF8)) {
		return {};
	}
	out.resize(strlen(out.c_str()));
	return out;
}

static bool EnsureSparseRawImage(const std::string& path, size_t preferredSize, size_t* actualSizeOut)
{
	if (path.empty() || preferredSize == 0) {
		return false;
	}

	struct stat st;
	if (stat(path.c_str(), &st) == 0 && (size_t)st.st_size >= preferredSize) {
		if (actualSizeOut) {
			*actualSizeOut = (size_t)st.st_size;
		}
		return true;
	}

	int fd = open(path.c_str(), O_RDWR | O_CREAT, 0644);
	if (fd < 0) {
		return false;
	}
	int ok = ftruncate(fd, (off_t)preferredSize);
	close(fd);
	if (ok != 0) {
		return false;
	}
	if (actualSizeOut) {
		*actualSizeOut = preferredSize;
	}
	return true;
}

static NSString *NSStringFromUTF8String(const std::string& s)
{
	if (s.empty()) {
		return nil;
	}
	CFStringRef cf = CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)s.data(), (CFIndex)s.size(), kCFStringEncodingUTF8, false);
	return cf ? (__bridge_transfer NSString *)cf : nil;
}

static bool PathExists(const std::string& path)
{
	if (path.empty()) {
		return false;
	}
	struct stat st;
	return (stat(path.c_str(), &st) == 0);
}

static std::string SnapshotFilePathUTF8()
{
	@autoreleasepool {
		NSArray<NSString *> *docsDirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
		NSString *docsDirPath = (docsDirs.count > 0) ? [docsDirs objectAtIndex:0] : nil;
		std::string docsPathUTF8 = UTF8FromNSString(docsDirPath);
		if (!docsPathUTF8.empty() && docsPathUTF8.back() == '/') {
			docsPathUTF8.pop_back();
		}
		if (docsPathUTF8.empty()) {
			return {};
		}
		return docsPathUTF8 + "/rvvm.snapshot.img";
	}
}

struct RvvmSnapshotHeader
{
	char magic[8];
	uint32_t version;
	uint32_t flags;
	uint64_t mem_addr;
	uint64_t mem_size;
	uint32_t hart_count;
	uint32_t reserved;
	uint64_t timer_freq;
	uint64_t timer_time;
};

static bool ReadRvvmSnapshotHeader(const std::string& path, RvvmSnapshotHeader* out)
{
	if (!out || path.empty()) {
		return false;
	}
	int fd = open(path.c_str(), O_RDONLY);
	if (fd < 0) {
		return false;
	}
	ssize_t n = read(fd, out, sizeof(*out));
	close(fd);
	if (n != (ssize_t)sizeof(*out)) {
		return false;
	}
	if (memcmp(out->magic, "RVVMSNAP", 8) != 0) {
		return false;
	}
	if (out->version != 1 || out->reserved != 0) {
		return false;
	}
	return true;
}

static bool RunLinuxOnce()
{
	@autoreleasepool {
		NSBundle *bundle = [NSBundle mainBundle];
		NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
		RVVMBootMode bootMode = (RVVMBootMode)[defaults integerForKey:kRVVMDefaultsBootMode];
		NSInteger cores = [defaults integerForKey:kRVVMDefaultsCores];
		NSInteger ramMB = [defaults integerForKey:kRVVMDefaultsRamMB];
		BOOL disableIso = [defaults boolForKey:kRVVMDefaultsDisableIso];
		NSString *isoFilename = [defaults stringForKey:kRVVMDefaultsIsoFilename];
		NSString *diskFilename = [defaults stringForKey:kRVVMDefaultsDiskFilename];
		NSString *archImgFilename = [defaults stringForKey:kRVVMDefaultsArchImgFilename];
		NSArray *portForwards = (NSArray *)[defaults objectForKey:kRVVMDefaultsPortForwards];
		id vfsDbgObj = [defaults objectForKey:kRVVMDefaultsVirtioFSDebugToUART];
		BOOL virtioFSDebugToUart = vfsDbgObj ? [defaults boolForKey:kRVVMDefaultsVirtioFSDebugToUART] : YES;
		s_vfs_debug_to_uart.store(virtioFSDebugToUart);

		NSArray<NSString *> *docsDirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
		NSString *docsDirPath = (docsDirs.count > 0) ? [docsDirs objectAtIndex:0] : nil;
		std::string docsPathUTF8 = UTF8FromNSString(docsDirPath);
		if (!docsPathUTF8.empty() && docsPathUTF8.back() == '/') {
			docsPathUTF8.pop_back();
		}

		auto DocsFilePathIfExists = [&](NSString *filename) -> std::string {
			if (docsPathUTF8.empty() || filename.length == 0) {
				return {};
			}
			std::string name = UTF8FromNSString(filename);
			if (name.empty()) {
				return {};
			}
			std::string p = docsPathUTF8 + "/" + name;
			struct stat st;
			if (stat(p.c_str(), &st) != 0) {
				return {};
			}
			return p;
		};

		auto DocsFilePath = [&](NSString *filename) -> std::string {
			if (docsPathUTF8.empty() || filename.length == 0) {
				return {};
			}
			std::string name = UTF8FromNSString(filename);
			if (name.empty()) {
				return {};
			}
			return docsPathUTF8 + "/" + name;
		};

		NSURL *fwPayloadURL = [bundle URLForResource:@"fw_payload" withExtension:@"bin" subdirectory:@"rv64linux"];
		NSURL *alpineIsoURL = [bundle URLForResource:@"alpine-standard-3.23.3-riscv64" withExtension:@"iso" subdirectory:@"rv64linux"];
		NSURL *alpineDiskSeedURL = [bundle URLForResource:@"alpine-riscv64" withExtension:@"img" subdirectory:@"rv64linux"];
		NSURL *archImgURL = [bundle URLForResource:@"archriscv-2026-01-07-4g" withExtension:@"img" subdirectory:@"rv64linux"];

		std::string snapPath = SnapshotFilePathUTF8();
		RvvmSnapshotHeader snapHdr = {};
		bool haveSnap = (!snapPath.empty() && ReadRvvmSnapshotHeader(snapPath, &snapHdr));
		if (!haveSnap && !snapPath.empty() && PathExists(snapPath)) {
			PostUARTText("rvvm: snapshot present but incompatible, ignoring\n");
		}

		std::string isoPath;
		if (!disableIso) {
			isoPath = (isoFilename.length > 0) ? DocsFilePathIfExists(isoFilename) : FileSystemPath(alpineIsoURL);
		}
		bool isoPossible = (!disableIso) && (fwPayloadURL != nil) && !isoPath.empty();
		std::string diskImgPath = DocsFilePathIfExists(diskFilename);
		bool diskImgPossible = (diskFilename.length > 0) && !diskImgPath.empty();
		bool archPossible = (fwPayloadURL != nil) && (diskImgPossible || (archImgFilename.length > 0 && !DocsFilePathIfExists(archImgFilename).empty()) || (archImgURL != nil));

		BOOL useIso = NO;
		BOOL useArchImage = NO;
		switch (bootMode) {
			case RVVMBootModeAlpine:
				if (!isoPossible) {
					PostUARTText("rvvm: alpine ISO disabled or missing\n");
					return false;
				}
				useIso = YES;
				break;
			case RVVMBootModeArch:
				if (!archPossible) {
					PostUARTText("rvvm: arch image missing\n");
					return false;
				}
				useArchImage = YES;
				break;
			case RVVMBootModeCustom:
				if (isoPossible) {
					useIso = YES;
				} else if (archPossible) {
					useArchImage = YES;
				} else {
					PostUARTText("rvvm: no bootable image (ISO disabled/missing and no disk image)\n");
					return false;
				}
				break;
			case RVVMBootModeAuto:
			default:
				if (isoPossible) {
					useIso = YES;
				} else if (archPossible) {
					useArchImage = YES;
				} else {
					PostUARTText("rvvm: no bootable image (ISO disabled/missing and no disk image)\n");
					return false;
				}
				break;
		}

		NSURL *biosURL = fwPayloadURL;
		if (!biosURL || (!useIso && !useArchImage)) {
			PostUARTText("rvvm: missing boot resources\n");
			return false;
		}

		std::string biosPath = FileSystemPath(biosURL);
		std::string imagePath;
		std::string installDiskPath;
		if (useArchImage) {
			if (diskImgPossible) {
				imagePath = diskImgPath;
			} else if (archImgFilename.length > 0) {
				imagePath = DocsFilePathIfExists(archImgFilename);
				if (imagePath.empty()) {
					PostUARTText("rvvm: arch image missing\n");
					return false;
				}
			} else {
				if (haveSnap) {
					PostUARTText("rvvm: snapshot load requires existing disk image\n");
					return false;
				}
				if (docsDirPath.length == 0 || docsPathUTF8.empty()) {
					PostUARTText("rvvm: missing documents dir\n");
					return false;
				}
				std::string dstPathUTF8 = docsPathUTF8 + "/archriscv-2026-01-07-4g.img";
				CFStringRef cfDstPath = CFStringCreateWithCString(kCFAllocatorDefault, dstPathUTF8.c_str(), kCFStringEncodingUTF8);
				NSString *dstPath = cfDstPath ? (__bridge_transfer NSString *)cfDstPath : nil;
				if (!dstPath) {
					PostUARTText("rvvm: disk image dst path failed\n");
					return false;
				}

				if (![[NSFileManager defaultManager] fileExistsAtPath:dstPath]) {
					std::string srcPath = FileSystemPath(archImgURL);
					if (srcPath.empty()) {
						PostUARTText("rvvm: disk image missing path\n");
						return false;
					}
					CFStringRef cfSrcPath = CFStringCreateWithCString(kCFAllocatorDefault, srcPath.c_str(), kCFStringEncodingUTF8);
					NSString *srcPathStr = cfSrcPath ? (__bridge_transfer NSString *)cfSrcPath : nil;
					if (!srcPathStr) {
						PostUARTText("rvvm: disk image src path failed\n");
						return false;
					}
					NSError *err = nil;
					PostUARTText("rvvm: copying disk image...\n");
					if (![[NSFileManager defaultManager] copyItemAtPath:srcPathStr toPath:dstPath error:&err]) {
						PostUARTText("rvvm: disk image copy failed\n");
						return false;
					}
				}
				imagePath = dstPathUTF8;
			}
		}
		if (useIso) {
			if (isoPath.empty()) {
				PostUARTText("rvvm: iso path failed\n");
				return false;
			}
			if (docsDirPath.length == 0 || docsPathUTF8.empty()) {
				PostUARTText("rvvm: missing documents dir\n");
				return false;
			}
			installDiskPath = (diskFilename.length > 0) ? DocsFilePath(diskFilename) : (docsPathUTF8 + "/alpine-riscv64.img");

			CFStringRef cfInstallDiskPath = CFStringCreateWithCString(kCFAllocatorDefault, installDiskPath.c_str(), kCFStringEncodingUTF8);
			NSString *installDiskPathStr = cfInstallDiskPath ? (__bridge_transfer NSString *)cfInstallDiskPath : nil;
			if (!installDiskPathStr) {
				PostUARTText("rvvm: install disk path failed\n");
				return false;
			}
			if (!haveSnap && diskFilename.length == 0 && ![[NSFileManager defaultManager] fileExistsAtPath:installDiskPathStr]) {
				std::string seedPath = FileSystemPath(alpineDiskSeedURL);
				if (!seedPath.empty()) {
					CFStringRef cfSeedPath = CFStringCreateWithCString(kCFAllocatorDefault, seedPath.c_str(), kCFStringEncodingUTF8);
					NSString *seedPathStr = cfSeedPath ? (__bridge_transfer NSString *)cfSeedPath : nil;
					if (seedPathStr) {
						NSError *err = nil;
						PostUARTText("rvvm: copying install disk seed...\n");
						if (![[NSFileManager defaultManager] copyItemAtPath:seedPathStr toPath:installDiskPathStr error:&err]) {
							PostUARTText("rvvm: install disk seed copy failed\n");
						}
					}
				}
			}

			if (!haveSnap) {
				size_t diskSize = 0;
				static const size_t sizes[] = {
					(size_t)(1ULL << 30),
				};

				bool ok = false;
				for (size_t s : sizes) {
					if (EnsureSparseRawImage(installDiskPath, s, &diskSize)) {
						ok = true;
						break;
					}
				}
				if (!ok) {
					PostUARTText("rvvm: install disk create failed\n");
					return false;
				}
				char buf[128];
				snprintf(buf, sizeof(buf), "rvvm: install disk %zu MiB\n", (size_t)(diskSize >> 20));
				PostUARTText(std::string(buf));
			} else {
				if (![[NSFileManager defaultManager] fileExistsAtPath:installDiskPathStr]) {
					PostUARTText("rvvm: snapshot load requires existing install disk\n");
					return false;
				}
			}
		}

		PostUARTText("rvvm: starting...\n");

		size_t preferredMem = 0;
		if (haveSnap) {
			preferredMem = (size_t)snapHdr.mem_size;
		} else if (ramMB > 0) {
			preferredMem = (size_t)ramMB << 20;
		} else {
			preferredMem = useIso ? (size_t)(1ULL << 30) : (useArchImage ? (size_t)(2ULL << 30) : (size_t)(256ULL << 20));
		}
		static const size_t fallbacks[] = {
			(size_t)(2ULL << 30),
			(size_t)(1536ULL << 20),
			(size_t)(1024ULL << 20),
			(size_t)(768ULL << 20),
			(size_t)(512ULL << 20),
			(size_t)(256ULL << 20),
		};

		rvvm_machine_t* machine = nullptr;
		size_t chosenMem = 0;
		size_t smp = 0;
		if (haveSnap) {
			smp = (size_t)std::min<uint32_t>(8, std::max<uint32_t>(1, snapHdr.hart_count));
		} else if (cores > 0) {
			smp = (size_t)std::min<NSInteger>(8, std::max<NSInteger>(1, cores));
		} else {
			smp = useIso ? 2 : 1;
		}

		if (preferredMem != 0) {
			machine = rvvm_create_machine(preferredMem, smp, "rv64gc");
			if (machine) {
				chosenMem = preferredMem;
			}
		}

		if (!machine) {
			for (size_t candidate : fallbacks) {
				if (candidate > preferredMem) {
					continue;
				}
				machine = rvvm_create_machine(candidate, smp, "rv64gc");
				if (machine) {
					chosenMem = candidate;
					break;
				}
			}
		}
		if (!machine) {
			PostUARTText("rvvm: rvvm_create_machine failed (RAM allocation)\n");
			return false;
		}
		if (chosenMem != 0 && chosenMem != preferredMem) {
			char buf[128];
			snprintf(buf, sizeof(buf), "rvvm: RAM fallback to %zu MiB\n", (size_t)(chosenMem >> 20));
			PostUARTText(std::string(buf));
		}
		rvvm_set_opt(machine, RVVM_OPT_JIT, 0);

		chardev_t* chardev = CreateUIKitChardev();
		if (!chardev) {
			PostUARTText("rvvm: failed to create uart chardev\n");
			rvvm_free_machine(machine);
			return false;
		}

		riscv_clint_init_auto(machine);
		riscv_plic_init_auto(machine);
		tap_dev_t* tap = nullptr;
		pci_bus_t* pci = pci_bus_init_auto(machine);
		if (!pci) {
			PostUARTText("rvvm: pci bus failed\n");
			chardev_free(chardev);
			rvvm_free_machine(machine);
			return false;
		}
		PostUARTText("rvvm: pci bus ok\n");

		tap = tap_open();
		if (!tap) {
			PostUARTText("rvvm: tap open failed\n");
			chardev_free(chardev);
			rvvm_free_machine(machine);
			return false;
		}
		if (!rtl8169_init(pci, tap)) {
			PostUARTText("rvvm: rtl8169 failed\n");
			tap_close(tap);
			chardev_free(chardev);
			rvvm_free_machine(machine);
			return false;
		}
		PostUARTText("rvvm: rtl8169 ok\n");

		if (portForwards) {
			for (NSUInteger i = 0; i < portForwards.count; i++) {
				NSString *s = (NSString *)[portForwards objectAtIndex:i];
				if (!s || s.length == 0) {
					continue;
				}
				std::string fwd = UTF8FromNSString(s);
				if (fwd.empty()) {
					continue;
				}
				if (!tap_portfwd(tap, fwd.c_str())) {
					PostUARTText("rvvm: port forward failed\n");
				}
			}
		}
		if (useArchImage) {
			if (nvme_init_auto(machine, imagePath.c_str(), true)) {
				PostUARTText("rvvm: nvme ok\n");
			} else {
				PostUARTText("rvvm: nvme failed\n");
				if (tap) {
					tap_close(tap);
				}
				chardev_free(chardev);
				rvvm_free_machine(machine);
				return false;
			}
		}
		if (useIso) {
			if (!nvme_init_auto(machine, isoPath.c_str(), false)) {
				PostUARTText("rvvm: nvme iso failed\n");
				if (tap) {
					tap_close(tap);
				}
				chardev_free(chardev);
				rvvm_free_machine(machine);
				return false;
			}
			if (!nvme_init_auto(machine, installDiskPath.c_str(), true)) {
				PostUARTText("rvvm: nvme disk failed\n");
				if (tap) {
					tap_close(tap);
				}
				chardev_free(chardev);
				rvvm_free_machine(machine);
				return false;
			}
			PostUARTText("rvvm: nvme iso+disk ok\n");
		}
		syscon_init_auto(machine);
		rtc_goldfish_init_auto(machine);
		ns16550a_init_auto(machine, chardev);
		if (!docsPathUTF8.empty()) {
			if (virtio_fs_init_auto(machine, "share", docsPathUTF8.c_str())) {
				PostUARTText("rvvm: virtio-fs ok\n");
			} else {
				PostUARTText("rvvm: virtio-fs failed\n");
			}
		}

		if (!rvvm_load_firmware(machine, biosPath.c_str())) {
			PostUARTText("rvvm: load firmware failed\n");
			if (tap) {
				tap_close(tap);
			}
			chardev_free(chardev);
			rvvm_free_machine(machine);
			return false;
		}

		{
			if (haveSnap) {
#if defined(USE_FPU)
				const uint32_t expectedFlags = 0x1;
#else
				const uint32_t expectedFlags = 0x0;
#endif
				if ((snapHdr.flags & 0x1) != expectedFlags) {
					PostUARTText("rvvm: snapshot flags mismatch, continuing boot\n");
				} else if (snapHdr.mem_size != (uint64_t)chosenMem) {
					PostUARTText("rvvm: snapshot RAM mismatch, continuing boot\n");
				} else if (snapHdr.hart_count != (uint32_t)smp) {
					PostUARTText("rvvm: snapshot core count mismatch, continuing boot\n");
				} else {
					PostUARTText("rvvm: snapshot found, loading...\n");
					if (rvvm_load_snapshot(machine, snapPath.c_str())) {
						PostUARTText("rvvm: snapshot loaded\n");
					} else {
						PostUARTText("rvvm: snapshot load failed, continuing boot\n");
					}
				}
			}
		}

		{
			std::lock_guard<std::mutex> lock(s_state_mutex);
			s_machine = machine;
			s_chardev = chardev;
			s_active_writable_disk_path = useIso ? installDiskPath : (useArchImage ? imagePath : std::string());
		}
		rvvm_start_machine(machine);
		for (;;) {
			rvvm_run_eventloop();
			int op = s_snapshot_op.exchange(0);
			if (op == 1) {
				std::string snapPath = SnapshotFilePathUTF8();
				if (snapPath.empty()) {
					SetSnapshotResult(false, "snapshot: path unavailable");
					rvvm_start_machine(machine);
					continue;
				}
				if (!rvvm_save_snapshot(machine, snapPath.c_str())) {
					SetSnapshotResult(false, "snapshot save failed");
					rvvm_start_machine(machine);
					continue;
				}
				SetSnapshotResult(true, "snapshot saved");
				rvvm_start_machine(machine);
				continue;
			}
			if (op == 2) {
				std::string snapPath = SnapshotFilePathUTF8();
				if (snapPath.empty()) {
					SetSnapshotResult(false, "snapshot: path unavailable");
					rvvm_start_machine(machine);
					continue;
				}
				if (!PathExists(snapPath)) {
					SetSnapshotResult(false, "snapshot file not found");
					rvvm_start_machine(machine);
					continue;
				}
				if (!rvvm_load_snapshot(machine, snapPath.c_str())) {
					SetSnapshotResult(false, "snapshot load failed");
					rvvm_start_machine(machine);
					continue;
				}
				SetSnapshotResult(true, "snapshot loaded");
				rvvm_start_machine(machine);
				continue;
			}
			int netOp = s_network_op.exchange(0);
			if (netOp == 1) {
				if (!tap) {
					SetNetworkResult(false, "network: tap unavailable");
					rvvm_start_machine(machine);
					continue;
				}
				if (!tap_reinit(tap)) {
					SetNetworkResult(false, "network reinit failed");
					rvvm_start_machine(machine);
					continue;
				}
				SetNetworkResult(true, "network reinitialized");
				rvvm_start_machine(machine);
				continue;
			}
			break;
		}

		{
			std::lock_guard<std::mutex> lock(s_state_mutex);
			s_chardev = nullptr;
			s_machine = nullptr;
			s_active_writable_disk_path.clear();
		}
		if (tap) {
			tap_close(tap);
		}
		chardev_free(chardev);
		rvvm_free_machine(machine);
		return true;
	}
}

@implementation RV64Runner

+ (void)startLinux
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		EnsureRestartSemaphore();
		EnsureSnapshotPrimitives();
		EnsureNetworkPrimitives();
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			for (;;) {
				(void)RunLinuxOnce();
				if (s_restart_requested.exchange(false)) {
					dispatch_semaphore_wait(s_restart_sema, DISPATCH_TIME_NOW);
					continue;
				}
				dispatch_semaphore_wait(s_restart_sema, DISPATCH_TIME_FOREVER);
				(void)s_restart_requested.exchange(false);
			}
		});
	});
}

+ (void)setVirtioFSDebugToUARTEnabled:(BOOL)enabled
{
	s_vfs_debug_to_uart.store(enabled);
}

+ (NSArray<NSString *> *)virtioFSDebugLines
{
	std::lock_guard<std::mutex> lock(s_vfs_debug_mu);
	NSMutableArray<NSString *> *out = [[NSMutableArray alloc] initWithCapacity:(NSUInteger)s_vfs_debug_lines.size()];
	for (const std::string& line : s_vfs_debug_lines) {
		NSString *s = NSStringFromUTF8String(line);
		if (s.length > 0) {
			[out addObject:s];
		}
	}
	return out;
}

+ (void)clearVirtioFSDebug
{
	std::lock_guard<std::mutex> lock(s_vfs_debug_mu);
	s_vfs_debug_lines.clear();
	s_vfs_debug_bytes = 0;
}

+ (void)requestRestart
{
	EnsureRestartSemaphore();
	bool already = s_restart_requested.exchange(true);
	if (!already) {
		dispatch_semaphore_signal(s_restart_sema);
	}
	rvvm_machine_t* machine = nullptr;
	{
		std::lock_guard<std::mutex> lock(s_state_mutex);
		machine = s_machine;
	}
	if (machine) {
		rvvm_pause_machine(machine);
	}
}

+ (BOOL)saveSnapshot:(NSString * _Nullable * _Nullable)errorOut
{
	EnsureSnapshotPrimitives();
	rvvm_machine_t* machine = nullptr;
	bool running = false;
	{
		std::lock_guard<std::mutex> lock(s_state_mutex);
		machine = s_machine;
		running = machine ? rvvm_machine_running(machine) : false;
	}
	if (!machine || !running) {
		if (errorOut) {
			*errorOut = @"VM is not running";
		}
		return NO;
	}
	int expected = 0;
	if (!s_snapshot_op.compare_exchange_strong(expected, 1)) {
		if (errorOut) {
			*errorOut = @"Snapshot operation already in progress";
		}
		return NO;
	}
	while (dispatch_semaphore_wait(s_snapshot_done_sema, DISPATCH_TIME_NOW) == 0) {
	}
	if (!rvvm_pause_machine(machine)) {
		s_snapshot_op.store(0);
		if (errorOut) {
			*errorOut = @"Failed to pause VM";
		}
		return NO;
	}
	int64_t timeoutNsec = (int64_t)(300 * NSEC_PER_SEC);
	long waitRes = dispatch_semaphore_wait(s_snapshot_done_sema, dispatch_time(DISPATCH_TIME_NOW, timeoutNsec));
	if (waitRes != 0) {
		s_snapshot_op.store(0);
		rvvm_start_machine(machine);
		if (errorOut) {
			*errorOut = @"Snapshot save timed out";
		}
		return NO;
	}
	bool ok = false;
	std::string msg;
	{
		std::lock_guard<std::mutex> lock(s_snapshot_result_mu);
		ok = s_snapshot_result_ok;
		msg = s_snapshot_result_msg;
	}
	if (!ok) {
		if (errorOut) {
			NSString *m = NSStringFromUTF8String(msg);
			*errorOut = (m.length > 0) ? m : @"Snapshot save failed";
		}
		return NO;
	}
	return YES;
}

+ (BOOL)loadSnapshot:(NSString * _Nullable * _Nullable)errorOut
{
	EnsureSnapshotPrimitives();
	rvvm_machine_t* machine = nullptr;
	bool running = false;
	{
		std::lock_guard<std::mutex> lock(s_state_mutex);
		machine = s_machine;
		running = machine ? rvvm_machine_running(machine) : false;
	}
	if (!machine || !running) {
		if (errorOut) {
			*errorOut = @"VM is not running";
		}
		return NO;
	}
	int expected = 0;
	if (!s_snapshot_op.compare_exchange_strong(expected, 2)) {
		if (errorOut) {
			*errorOut = @"Snapshot operation already in progress";
		}
		return NO;
	}
	while (dispatch_semaphore_wait(s_snapshot_done_sema, DISPATCH_TIME_NOW) == 0) {
	}
	if (!rvvm_pause_machine(machine)) {
		s_snapshot_op.store(0);
		if (errorOut) {
			*errorOut = @"Failed to pause VM";
		}
		return NO;
	}
	int64_t timeoutNsec = (int64_t)(300 * NSEC_PER_SEC);
	long waitRes = dispatch_semaphore_wait(s_snapshot_done_sema, dispatch_time(DISPATCH_TIME_NOW, timeoutNsec));
	if (waitRes != 0) {
		s_snapshot_op.store(0);
		rvvm_start_machine(machine);
		if (errorOut) {
			*errorOut = @"Snapshot load timed out";
		}
		return NO;
	}
	bool ok = false;
	std::string msg;
	{
		std::lock_guard<std::mutex> lock(s_snapshot_result_mu);
		ok = s_snapshot_result_ok;
		msg = s_snapshot_result_msg;
	}
	if (!ok) {
		if (errorOut) {
			NSString *m = NSStringFromUTF8String(msg);
			*errorOut = (m.length > 0) ? m : @"Snapshot load failed";
		}
		return NO;
	}
	return YES;
}

+ (BOOL)reinitNetwork:(NSString * _Nullable * _Nullable)errorOut
{
	EnsureNetworkPrimitives();
	rvvm_machine_t* machine = nullptr;
	bool running = false;
	{
		std::lock_guard<std::mutex> lock(s_state_mutex);
		machine = s_machine;
		running = machine ? rvvm_machine_running(machine) : false;
	}
	if (!machine || !running) {
		if (errorOut) {
			*errorOut = @"VM is not running";
		}
		return NO;
	}
	if (s_snapshot_op.load() != 0) {
		if (errorOut) {
			*errorOut = @"Another VM operation is in progress";
		}
		return NO;
	}
	int expected = 0;
	if (!s_network_op.compare_exchange_strong(expected, 1)) {
		if (errorOut) {
			*errorOut = @"Network operation already in progress";
		}
		return NO;
	}
	while (dispatch_semaphore_wait(s_network_done_sema, DISPATCH_TIME_NOW) == 0) {
	}
	if (!rvvm_pause_machine(machine)) {
		s_network_op.store(0);
		if (errorOut) {
			*errorOut = @"Failed to pause VM";
		}
		return NO;
	}
	int64_t timeoutNsec = (int64_t)(60 * NSEC_PER_SEC);
	long waitRes = dispatch_semaphore_wait(s_network_done_sema, dispatch_time(DISPATCH_TIME_NOW, timeoutNsec));
	if (waitRes != 0) {
		s_network_op.store(0);
		rvvm_start_machine(machine);
		if (errorOut) {
			*errorOut = @"Network reinit timed out";
		}
		return NO;
	}
	bool ok = false;
	std::string msg;
	{
		std::lock_guard<std::mutex> lock(s_network_result_mu);
		ok = s_network_result_ok;
		msg = s_network_result_msg;
	}
	if (!ok) {
		if (errorOut) {
			NSString *m = NSStringFromUTF8String(msg);
			*errorOut = (m.length > 0) ? m : @"Network reinit failed";
		}
		return NO;
	}
	return YES;
}

+ (void)sendConsoleBytes:(NSData *)data
{
	if (!data || data.length == 0) {
		return;
	}
	std::lock_guard<std::mutex> lock(s_state_mutex);
	if (!s_chardev || !s_chardev->data) {
		return;
	}
	auto* state = (UIKitChardevState *)s_chardev->data;
	{
		std::lock_guard<std::mutex> rxLock(state->mu);
		const auto* b = (const uint8_t *)data.bytes;
		for (size_t i = 0; i < (size_t)data.length; i++) {
			uint8_t c = b[i];
			if (c == '\r') {
				c = '\n';
			}
			state->rx.push_back(c);
		}
	}
	chardev_notify(s_chardev, UIKitChardevPoll(s_chardev));
}

+ (void)sendConsoleText:(NSString *)text
{
	if (!text || text.length == 0) {
		return;
	}
	std::string bytes = UTF8FromNSString(text);
	if (bytes.empty()) {
		return;
	}
	std::lock_guard<std::mutex> lock(s_state_mutex);
	if (!s_chardev || !s_chardev->data) {
		return;
	}
	auto* state = (UIKitChardevState *)s_chardev->data;
	{
		std::lock_guard<std::mutex> rxLock(state->mu);
		for (char c : bytes) {
			if (c == '\r') {
				c = '\n';
			}
			state->rx.push_back((uint8_t)c);
		}
		state->rx.push_back((uint8_t)'\n');
	}
	chardev_notify(s_chardev, UIKitChardevPoll(s_chardev));
}

@end
