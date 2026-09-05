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
# renumbers the rest of the suite: measured on an 819-file tree, inserting one
# file moved 320 of them, churning each shard by ~160 files. A green `main`
# then stops predicting a green PR, because the PR runs a grouping that has
# never run anywhere.
#
# So the file list is computed here instead, keyed on each file's own path
# (`Aiur.TestShard`), and passed to `mix test` explicitly. `--export-coverage`
# reproduces exactly the `cover/<n>.coverdata` name that `--partitions` used to
# derive from MIX_TEST_PARTITION, so the aggregate `coverage` job is unchanged.
#
# The file list is word-split rather than piped through `xargs`, so that a test
# failure stays exit 1: `xargs` remaps its child's status (1..125 becomes 123,
# 255 becomes 124), and 124 is precisely the code the CI step reads as "this
# shard timed out". `mix aiur.test_shard` refuses to emit a path containing
# whitespace, which is what makes the unquoted expansion safe.
#
# Both counts are printed on every run: shard balance is no longer guaranteed by
# construction, so it has to be observable in the log rather than discovered as
# a timeout.
coverage-partition:
	@set -eu; \
	shard="$${MIX_TEST_PARTITION:?MIX_TEST_PARTITION must be set to the 1-based shard number}"; \
	list="$$(mktemp)"; \
	trap 'rm -f "$$list"' EXIT INT TERM; \
	MIX_ENV=test $(MIX) aiur.test_shard --shard "$$shard" --shards $(TEST_PARTITIONS) --output "$$list"; \
	echo "coverage-partition: shard $$shard/$(TEST_PARTITIONS) -> $$(wc -l < "$$list") test files"; \
	MIX_ENV=test $(MIX) aiur.test_shard --shards $(TEST_PARTITIONS) --counts \
	  | while IFS="$$(printf '\t')" read -r s n; do echo "coverage-partition: shard $$s holds $$n files"; done; \
	$(MIX) test --cover --export-coverage "$$shard" $$(cat "$$list")

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
