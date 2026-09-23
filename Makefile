.PHONY: hooks core test

hooks:
	git config core.hooksPath .githooks

core:
	scripts/build-core-macos.sh

test:
	cd core && cargo test
