ARCHS = arm64
TARGET = iphone:clang:17.5:13.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BumbleHeatFix

BumbleHeatFix_FILES = Tweak.x
BumbleHeatFix_CFLAGS = -fobjc-arc
BumbleHeatFix_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
