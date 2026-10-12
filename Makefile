.PHONY: build app run test icon clean

APP := build/Dbee.app

build:
	swift build

app:
	scripts/build-app.sh

run: app
	open $(APP)

test:
	swift test

icon:
	swift scripts/make-icon.swift Resources

clean:
	swift package clean
	rm -rf build
