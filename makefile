ARCHS = arm64
TARGET = iphone:14.0:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = metalbiew
metalbiew_FILES = metalbiew.mm
metalbiew_FRAMEWORKS = UIKit CoreGraphics
metalbiew_CFLAGS = -fobjc-arc -std=c++17 -O3 -march=arm64 -mtune=apple-a13
metalbiew_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
