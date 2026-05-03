.PHONY: build run release clean

build:
	swift build

run: build
	.build/debug/AutoTranslator

release:
	swift build -c release

clean:
	swift package clean
	rm -rf .build
