APP = Notchification

run:
	swift run

app:
	swift build -c release
	rm -rf $(APP).app
	mkdir -p $(APP).app/Contents/MacOS $(APP).app/Contents/Resources
	cp .build/release/$(APP) $(APP).app/Contents/MacOS/
	git rev-parse HEAD > $(APP).app/Contents/Resources/sha
	printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n<key>CFBundleIdentifier</key><string>com.osbr.notchification</string>\n<key>CFBundleName</key><string>$(APP)</string>\n<key>CFBundleExecutable</key><string>$(APP)</string>\n<key>CFBundlePackageType</key><string>APPL</string>\n<key>LSUIElement</key><true/>\n</dict></plist>\n' > $(APP).app/Contents/Info.plist

install: app
	rm -rf /Applications/$(APP).app
	cp -R $(APP).app /Applications/
	open /Applications/$(APP).app

.PHONY: run app install
