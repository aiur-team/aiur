.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e regression

MIX ?= mix

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, regression, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	AIUR_RUN_LIVE_E2E=1 $(MIX) test test/aiur/live_e2e_test.exs

# Hermetic shell regression for agent teardown reaping (#423). SKIPs cleanly when
# tmux is absent, so it is safe to run anywhere.
regression:
	bash test/regression/aiur-agent-reap.sh

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
