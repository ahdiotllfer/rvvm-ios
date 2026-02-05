TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = rvvm

RVVM_DIR ?= RVVM

rvvm_FILES = \
	main.m \
	RV64AppDelegate.m \
	RV64RootViewController.m \
	RV64Runner.mm \
	$(filter-out $(RVVM_DIR)/src/main.c,$(wildcard $(RVVM_DIR)/src/*.c)) \
	$(wildcard $(RVVM_DIR)/src/cpu/*.c) \
	$(RVVM_DIR)/src/devices/chardev_term.c \
	$(RVVM_DIR)/src/devices/pci-bus.c \
	$(RVVM_DIR)/src/devices/riscv-aclint.c \
	$(RVVM_DIR)/src/devices/riscv-plic.c \
	$(RVVM_DIR)/src/devices/ns16550a.c \
	$(RVVM_DIR)/src/devices/syscon.c \
	$(RVVM_DIR)/src/devices/rtc-goldfish.c \
	$(RVVM_DIR)/src/devices/tap_user.c \
	$(RVVM_DIR)/src/devices/rtl8169.c \
	$(RVVM_DIR)/src/devices/nvme.c \
	$(RVVM_DIR)/src/devices/eth-oc.c

rvvm_FRAMEWORKS = UIKit Foundation WebKit
rvvm_LIBRARIES = pthread

rvvm_CFLAGS = -fobjc-arc
rvvm_CFLAGS += -O3
rvvm_CFLAGS += -std=gnu11
rvvm_CFLAGS += -UUSE_JIT
rvvm_CFLAGS += -Wno-error=ignored-pragmas
rvvm_CFLAGS += -DNDEBUG -DUSE_RV64 -DUSE_FDT -DUSE_FPU -DUSE_NET
rvvm_CFLAGS += -I$(RVVM_DIR)/include -I$(RVVM_DIR)/src

rvvm_CCFLAGS = \
	-std=gnu++20 \
	-DNDEBUG \
	-O3 \
	-DUSE_RV64 \
	-DUSE_FDT \
	-DUSE_FPU \
	-DUSE_NET \
	-UUSE_JIT \
	-Wno-error=ignored-pragmas \
	-I$(RVVM_DIR)/include \
	-I$(RVVM_DIR)/src

rvvm_OBJCCFLAGS = $(rvvm_CCFLAGS)

rvvm_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/application.mk

.PHONY: xterm-assets
xterm-assets: Resources/xterm/xterm.js \
              Resources/xterm/xterm.css \
              Resources/xterm/xterm-addon-fit.js

XTERM_VER = 5.3.0
XTERM_FIT_VER = 0.8.0
XTERM_DIR = Resources/xterm

$(XTERM_DIR):
	@mkdir -p "$(XTERM_DIR)"

$(XTERM_DIR)/xterm.js: | $(XTERM_DIR)
	@test -f "$@" || curl -fsSL "https://cdn.jsdelivr.net/npm/xterm@$(XTERM_VER)/lib/xterm.js" -o "$@"

$(XTERM_DIR)/xterm.css: | $(XTERM_DIR)
	@test -f "$@" || curl -fsSL "https://cdn.jsdelivr.net/npm/xterm@$(XTERM_VER)/css/xterm.css" -o "$@"

$(XTERM_DIR)/xterm-addon-fit.js: | $(XTERM_DIR)
	@test -f "$@" || curl -fsSL "https://cdn.jsdelivr.net/npm/xterm-addon-fit@$(XTERM_FIT_VER)/lib/xterm-addon-fit.js" -o "$@"

before-all:: xterm-assets

.PHONY: ipa
ipa: all
	@rm -rf "$(THEOS_OBJ_DIR)/ipa" "$(THEOS_PACKAGE_DIR)/$(APPLICATION_NAME).ipa"
	@mkdir -p "$(THEOS_OBJ_DIR)/ipa/Payload" "$(THEOS_PACKAGE_DIR)"
	@rm -f "$(THEOS_OBJ_DIR)/$(APPLICATION_NAME).app/rv64linux/alpine-standard-3.23.3-riscv64.iso"
	@rm -f "$(THEOS_OBJ_DIR)/$(APPLICATION_NAME).app/rv64linux/alpine-riscv64.img"
	@rm -f "$(THEOS_OBJ_DIR)/$(APPLICATION_NAME).app/rv64linux/Image"
	@cp -a "$(THEOS_OBJ_DIR)/$(APPLICATION_NAME).app" "$(THEOS_OBJ_DIR)/ipa/Payload/"
	@cd "$(THEOS_OBJ_DIR)/ipa" && zip -qry "$(abspath $(THEOS_PACKAGE_DIR)/$(APPLICATION_NAME).ipa)" Payload
