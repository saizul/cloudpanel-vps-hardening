SHELLCHECK ?= shellcheck
BATS ?= bats
SCRIPTS := $(wildcard *.sh) lib/common.sh
TESTS := $(wildcard tests/*.bats) tests/test_helper.bash

.PHONY: check lint test

check: lint test

lint:
	for f in $(SCRIPTS); do bash -n "$$f" || exit 1; done
	$(SHELLCHECK) -x $(SCRIPTS) $(TESTS)

test:
	$(BATS) tests
