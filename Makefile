TARGET := iphone:clang:16.0
ARCHS = arm64 arm64e

TWEAK_NAME = ThermalThrottle
ThermalThrottle_FILES = Tweak.xm
ThermalThrottle_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
ThermalThrottle_LDFLAGS = -framework Foundation -framework UIKit -framework CoreLocation

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
