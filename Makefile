.PHONY: bootstrap project test extension app run clean
APP = Hiz Download Manager

bootstrap:
	@command -v xcodegen >/dev/null || brew install xcodegen
	@test -f Local.xcconfig || cp Local.xcconfig.example Local.xcconfig

project: extension
	xcodegen generate

extension:
	./scripts/build-extension.sh

test:
	cd Packages/HDMCore && swift test
	cd Extension && node --test tests/hdm.test.js

app: project
	xcodebuild -project HizDownloadManager.xcodeproj -scheme HizDownloadManager -configuration Debug -derivedDataPath build -quiet build

run: app
	open "build/Build/Products/Debug/$(APP).app"

clean:
	rm -rf build Packages/HDMCore/.build HizDownloadManager.xcodeproj Extension/dist
