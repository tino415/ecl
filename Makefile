EMACS ?= emacs
SRC = ecl.el ecl-org.el ecl-eval.el ecl-browse.el ecl-shell.el

.DELETE_ON_ERROR:

check: static-results.txt test-results.txt e2e-results.txt
	@echo "check: all green"

static-results.txt: $(SRC) Makefile
	$(EMACS) -Q --batch -L . -f batch-byte-compile $(SRC) > $@ 2>&1 || (cat $@; exit 1)
	@rm -f *.elc
	@tail -2 $@

test-results.txt: $(SRC) test/ecl-test.el test/ecl-org-test.el test/ecl-eval-test.el \
	  test/ecl-browse-test.el test/ecl-shell-test.el Makefile
	$(EMACS) -Q --batch -L . -l ert -l test/ecl-test.el -l test/ecl-org-test.el \
	  -l test/ecl-eval-test.el -l test/ecl-browse-test.el -l test/ecl-shell-test.el \
	  -f ert-run-tests-batch-and-exit > $@ 2>&1 || (cat $@; exit 1)
	@tail -3 $@

e2e-results.txt: $(SRC) bin/ecl test/e2e.sh test/e2e-init.el Makefile
	./test/e2e.sh > $@ 2>&1 || (cat $@; exit 1)
	@tail -3 $@

# --- debug daemon ------------------------------------------------------
# A throwaway `emacs -Q --daemon' whose socket is the file .debug/socket,
# so bringing it up is an ordinary file target.  `test/decl' is bin/ecl
# pointed at that socket; nothing here can reach the user's real daemon.
DEBUG_ORG ?= $(HOME)/org/payout/runfile.org

.debug/socket: $(SRC) test/e2e-init.el test/debug-init.el test/debug-daemon.sh Makefile
	./test/debug-daemon.sh up

debug-results.txt: .debug/socket bin/ecl test/decl test/debug.sh
	DEBUG_ORG="$(DEBUG_ORG)" ./test/debug.sh > $@ 2>&1 || (cat $@; exit 1)
	@cat $@

debug-down:
	@./test/debug-daemon.sh down

.PHONY: check debug-down
