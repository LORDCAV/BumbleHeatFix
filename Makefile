TARGET := iphone:clang:16.0:14.0

ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := BumbleHeatFix

BumbleHeatFix_FILES := Tweak.x
BumbleHeatFix_CFLAGS := -fobjc-arc
BumbleHeatFix_FRAMEWORKS := Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
