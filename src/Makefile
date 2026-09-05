.PHONY: help all setup deps build fmt fmt-check lint test coverage coverage-partition coverage-report ci dialyzer e2e regression rename-preflight

MIX ?= mix
TEST_PARTITIONS ?= 4

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, coverage-partition, coverage-report, dialyzer, e2e, regression, rename-preflight, ci"

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

# Content-stable coverage sharding (#2568).
#
# `mix test --partitions N` shards round-robin over the sorted file list, so a
# file's shard depends on how many files sort before it and adding one test file
# renumbers the rest of the suite (measured: 159 files churned in and out of
# shard 2). A green `main` then stops predicting a green PR, because an
# unrelated diff inherits a brand-new test grouping.
#
# So the file list is computed here instead, keyed on each file's own path
# (`Aiur.TestShard`), and passed to `mix test` explicitly. `--export-coverage`
# reproduces exactly the `cover/<n>.coverdata` name that `--partitions` used to
# derive from MIX_TEST_PARTITION, so the aggregate `coverage` job is unchanged.
#
# `xargs -x` rather than a bare expansion: it fails loudly if the argument list
# ever outgrows one invocation instead of quietly running `mix test` twice and
# leaving the second export overwriting the first.
coverage-partition:
	@set -eu; \
	shard="$${MIX_TEST_PARTITION:?MIX_TEST_PARTITION must be set to the 1-based shard number}"; \
	list="$$(mktemp)"; \
	trap 'rm -f "$$list"' EXIT INT TERM; \
	MIX_ENV=test $(MIX) aiur.test_shard --shard "$$shard" --shards $(TEST_PARTITIONS) --output "$$list"; \
	echo "coverage-partition: shard $$shard/$(TEST_PARTITIONS) -> $$(wc -l < "$$list") test files"; \
	MIX_ENV=test $(MIX) aiur.test_shard --shards $(TEST_PARTITIONS) --counts \
	  | while IFS="$$(printf '\t')" read -r s n; do echo "coverage-partition: shard $$s holds $$n files"; done; \
	xargs -x -a "$$list" $(MIX) test --cover --export-coverage "$$shard"

test:
	$(MIX) test

coverage-report:
	$(MIX) test.coverage

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	AIUR_RUN_LIVE_E2E=1 $(MIX) test test/aiur/live_e2e_test.exs

# Hermetic shell regression for agent teardown reaping (#423). SKIPs cleanly when
# tmux is absent, so it is safe to run anywhere.
regression:
	bash test/regression/aiur-agent-reap.sh

rename-preflight:
	@python3 ../scripts/rename_preflight.py --root "$(CURDIR)/.." --old "$(OLD)" --new "$(NEW)" --partitions "$(TEST_PARTITIONS)"

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
