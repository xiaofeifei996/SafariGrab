TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SafariGrab

SafariGrab_FILES = Tweak.xm SGDownloader.m
SafariGrab_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
SafariGrab_FRAMEWORKS = UIKit WebKit Foundation
SafariGrab_PRIVATE_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk
