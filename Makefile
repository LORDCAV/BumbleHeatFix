TARGET := iphone:clang:latest
ARCHS = arm64 arm64e

TWEAK_NAME = ThermalThrottle
ThermalThrottle_FILES = Tweak.xm
ThermalThrottle_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
ThermalThrottle_LDFLAGS = -framework Foundation -framework UIKit -framework CoreLocation
ThermalThrottle_FILTER = ThermalThrottle.plist   # <- Add this line

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
