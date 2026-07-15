ARCHS = arm64
TARGET = iphone:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = metalbiew
metalbiew_FILES = metalbiew.mm
metalbiew_FRAMEWORKS = UIKit CoreGraphics
metalbiew_CFLAGS = -fobjc-arc -std=c++17 -O3
metalbiew_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
