SHELL = /usr/bin/env bash

ifdef V
	VVAL=--verbose
endif
ifdef VERBOSE
	VVAL=--verbose
endif

APPLICATIONS_DIR ?= /Applications
APP ?= kitty.app
APP_TARGET ?= $(join $(addsuffix /,${APPLICATIONS_DIR}), $(APP))

default: devel

# devel: clean fetch
devel: CC=$(shell xcrun -f clang)
devel: CXX=$(shell xcrun -f clang++)
devel: VVAL=--verbose
devel: LDFLAGS=-F/System/Library/PrivateFrameworks -F/System/Library/Frameworks -F/usr/local/Frameworks
devel: clean fetch
	export PYTHONOPTIMIZE=2
	python3.7 setup.py build --full $(VVAL)
	python3.7 setup.py kitty.app $(VVAL)
	rm -rf /usr/local/share/man/man1/kitty.1 /usr/local/share/doc/kitty
	command cp -f docs/_build/man/kitty.1 /usr/local/share/man/man1
	command cp -rf docs/_build/html /usr/local/share/doc/kitty
	rm -rf ${APP_TARGET}
	mv ./kitty.app $(APPLICATIONS_DIR)

fetch:
	git fetch --all
	git rebase --autostash origin/master

all:
	python3 -OO setup.py $(VVAL)

test:
	python3 setup.py $(VVAL) test

clean:
	python3 setup.py $(VVAL) clean

# A debug build
debug:
	python3 setup.py build $(VVAL) --debug

debug-event-loop:
	python3 setup.py build $(VVAL) --debug --extra-logging=event-loop

# Build with the ASAN and UBSAN sanitizers
asan:
	python3 setup.py build $(VVAL) --debug --sanitize

profile:
	python3 setup.py build $(VVAL) --profile

app:
	python3 setup.py kitty.app $(VVAL)

man:
	$(MAKE) FAIL_WARN=$(FAIL_WARN) -C docs man

html:
	$(MAKE) FAIL_WARN=$(FAIL_WARN) -C docs html

linkcheck:
	$(MAKE) FAIL_WARN=$(FAIL_WARN) -C docs linkcheck

docs: man html
