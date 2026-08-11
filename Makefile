.PHONY: build test app release prepare-update run clean

build:
	swift build

test:
	swift test

app:
	./Scripts/build-app.sh debug

release:
	./Scripts/build-app.sh release

prepare-update: release
	./Scripts/prepare-update.sh

run: app
	open .build/ZeroSound.app

clean:
	swift package clean
