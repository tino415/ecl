EMACS ?= emacs
SRC = ecl.el ecl-org.el ecl-eval.el

.DELETE_ON_ERROR:

check: static-results.txt test-results.txt e2e-results.txt
	@echo "check: all green"

static-results.txt: $(SRC) Makefile
	$(EMACS) -Q --batch -L . -f batch-byte-compile $(SRC) > $@ 2>&1 || (cat $@; exit 1)
	@rm -f *.elc
	@tail -2 $@

test-results.txt: $(SRC) test/ecl-test.el test/ecl-org-test.el test/ecl-eval-test.el Makefile
	$(EMACS) -Q --batch -L . -l ert -l test/ecl-test.el -l test/ecl-org-test.el \
	  -l test/ecl-eval-test.el \
	  -f ert-run-tests-batch-and-exit > $@ 2>&1 || (cat $@; exit 1)
	@tail -3 $@

e2e-results.txt: $(SRC) bin/ecl test/e2e.sh test/e2e-init.el Makefile
	./test/e2e.sh > $@ 2>&1 || (cat $@; exit 1)
	@tail -3 $@

.PHONY: check
