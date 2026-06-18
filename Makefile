export TARGET = iphone:latest:14.0
export ARCHS = arm64

ifeq ($(ROOTHIDE),1)
	export THEOS_PACKAGE_SCHEME = roothide
	export DEB_ARCH = iphoneos-arm64e
	export INSTALL_PREFIX =
else ifeq ($(ROOTLESS),1)
	export THEOS_PACKAGE_SCHEME = rootless
	export DEB_ARCH = iphoneos-arm64
	export INSTALL_PREFIX = /var/jb
else
	export DEB_ARCH = iphoneos-arm
endif

INSTALL_TARGET_PROCESSES = NewTerm

include $(THEOS)/makefiles/common.mk

XCODEPROJ_NAME = NewTerm

NewTerm_XCODE_SCHEME = NewTerm (iOS)

# -------------------------------------------------------------------------
# [修复]: 强制给 xcodebuild 注入 IPHONEOS_DEPLOYMENT_TARGET=14.0
# 这会覆盖掉 Xcode 工程内部偷偷设定的 iOS 15.0 最低版本限制
# -------------------------------------------------------------------------
NewTerm_XCODEFLAGS = INSTALL_PREFIX=$(INSTALL_PREFIX) IPHONEOS_DEPLOYMENT_TARGET=14.0

NewTerm_CODESIGN_FLAGS = -SApp/entitlements.plist
NewTerm_INSTALL_PATH = $(INSTALL_PREFIX)/Applications

include $(THEOS_MAKE_PATH)/xcodeproj.mk

after-stage::
	@$(TARGET_CODESIGN) $(NewTerm_CODESIGN_FLAGS) $(THEOS_STAGING_DIR)$(INSTALL_PREFIX)/Applications/NewTerm.app/NewTermLoginHelper

clean::
	rm -rf ./packages/*
