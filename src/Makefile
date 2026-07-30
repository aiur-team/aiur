.PHONY: help all setup deps build fmt fmt-check lint test test-partition coverage ci dialyzer e2e regression

MIX ?= mix
TEST_PARTITIONS ?= 4

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, test-partition, coverage, dialyzer, e2e, regression, ci"

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

test-partition:
	$(MIX) test --partitions $(TEST_PARTITIONS)

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
