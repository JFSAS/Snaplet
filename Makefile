.PHONY: build release run

build:
	./scripts/build-app.sh debug

release:
	./scripts/build-app.sh release

run: build
	open build/debug/Snaplet.app
