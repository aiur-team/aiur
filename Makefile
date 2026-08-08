.PHONY: rename-preflight

PARTITIONS ?= 4

rename-preflight:
	@python3 scripts/rename_preflight.py --root "$(CURDIR)" --old "$(OLD)" --new "$(NEW)" --partitions "$(PARTITIONS)"
