EMACS ?= emacs

.PHONY: all compile test lint check clean

all: compile

compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile proton-pass.el

test:
	$(EMACS) -Q --batch -L . -L test \
	  -l proton-pass-test.el -f ert-run-tests-batch-and-exit

lint:
	$(EMACS) -Q --batch -L . \
	  --eval '(checkdoc-file "proton-pass.el")'

check: compile lint test

clean:
	rm -f *.elc test/*.elc
