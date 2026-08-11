.PHONY: build test icon app release prepare-update run clean

build:
	swift build

test:
	swift test

icon:
	./Scripts/build-icon.sh

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
