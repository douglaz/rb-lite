.PHONY: test

test:
	bash -n bin/rb-lite
	bash tests/smoke.sh
