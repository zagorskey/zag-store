NAME := Feather
SCHEME := Feather
PLATFORMS := iphoneos maccatalyst

TMP := $(TMPDIR)/$(NAME)
CERT_JSON_URL := https://backloop.dev/pack.json

.PHONY: all clean $(PLATFORMS)

all: $(PLATFORMS)

clean:
	rm -rf $(TMP)
	rm -rf packages
	rm -rf Payload

$(PLATFORMS):
	rm -rf _build

	@if [ "$@" = "iphoneos" ]; then \
		DEST="generic/platform=iOS"; \
	else \
		DEST="generic/platform=macOS,variant=Mac Catalyst"; \
	fi; \
	xcodebuild \
		-project Feather.xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination "$$DEST" \
		-derivedDataPath $(TMP)/$@ \
		-skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO \
		ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	mkdir -p _build/Payload
	cp -R _build/Applications/*.app _build/Payload/Feather.app
	chmod -R 0755 _build/Payload/Feather.app
	# Legacy server-installation credentials must never ship in the IPA.
	rm -f _build/Payload/Feather.app/server.crt _build/Payload/Feather.app/server.pem _build/Payload/Feather.app/commonName.txt
	@if [ -d _build/Payload/Feather.app/Frameworks/OpenSSL.framework ]; then codesign --force --sign - --timestamp=none _build/Payload/Feather.app/Frameworks/OpenSSL.framework; fi
	codesign --force --sign - --timestamp=none _build/Payload/Feather.app
	codesign --verify --deep --strict --verbose=2 _build/Payload/Feather.app

	mkdir -p packages

	@if [ "$@" = "iphoneos" ]; then \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload "packages/ZagStore.ipa"; \
	else \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload/Feather.app "packages/Feather_Catalyst.zip"; \
	fi
