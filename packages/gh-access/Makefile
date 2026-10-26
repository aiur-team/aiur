PREFIX ?= $(HOME)/.local
BUILD_FLAGS ?=
.PHONY: build test install
build:
	./build.sh --output dist $(BUILD_FLAGS)
test:
	bash test/standalone_test.sh
install: build
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 dist/gh-access dist/gh-access-broker dist/github_budget_metrics.py "$(DESTDIR)$(PREFIX)/bin/"
