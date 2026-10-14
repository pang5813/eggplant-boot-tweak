ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = EggplantBootTweak
EggplantBootTweak_FILES = eggplant_boot_tweak.m BootPolicy.c
EggplantBootTweak_INSTALL_PATH = /usr/lib/TweakInject
EggplantBootTweak_FRAMEWORKS = Foundation
EggplantBootTweak_LIBRARIES = substrate
EggplantBootTweak_CFLAGS = -Wall -Wextra
EggplantBootTweak_OBJCFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
