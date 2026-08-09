.PHONY: rename-preflight test-rename-preflight

PARTITIONS ?= 4

rename-preflight:
	@python3 scripts/rename_preflight.py --root "$(CURDIR)" --old "$(OLD)" --new "$(NEW)" --partitions "$(PARTITIONS)"

test-rename-preflight:
	@python3 scripts/test_rename_preflight.py
