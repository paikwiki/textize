DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

.PHONY: build run debug test clean release
build:
	./scripts/build-app.sh release
debug:
	./scripts/build-app.sh debug

run: build
	open build/Textize.app
test:
	swift test
clean:
	rm -rf .build build
release:
	./scripts/release.sh
