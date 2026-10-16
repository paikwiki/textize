.PHONY: build run debug clean
build:
	./scripts/build-app.sh release
debug:
	./scripts/build-app.sh debug

run: build
	open build/Textize.app
clean:
	rm -rf .build build
