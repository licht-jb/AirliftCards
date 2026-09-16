CLANG := xcrun clang
CFLAGS := -fobjc-arc -O2 -Wall -Wextra
FOUNDATION := -framework Foundation -framework CoreFoundation
MOBILEDEVICE := /System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice
AIRTRAFFIC := /System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost

.PHONY: all app backend clean project

all: app

app: backend project
	xcodebuild -project AirliftCards.xcodeproj \
		-scheme AirliftCards \
		-configuration Release \
		-derivedDataPath build/AirliftCardsDerivedData \
		CONFIGURATION_BUILD_DIR="$(CURDIR)/build" \
		CODE_SIGNING_ALLOWED=NO \
		build

backend: Backend/build/device_helper Backend/build/airtraffic_host

project:
	xcodegen generate

Backend/build:
	mkdir -p $@

Backend/build/device_helper: Backend/Sources/device_helper.m Backend/Sources/airlift_target.h | Backend/build
	$(CLANG) $(CFLAGS) $(FOUNDATION) $(MOBILEDEVICE) $< -o $@
	codesign --force --sign - $@

Backend/build/airtraffic_host: Backend/Sources/airtraffic_host.m | Backend/build
	$(CLANG) $(CFLAGS) $(FOUNDATION) $(AIRTRAFFIC) $< -o $@
	codesign --force --sign - $@

clean:
	rm -rf build Backend/build AirliftCards.xcodeproj
