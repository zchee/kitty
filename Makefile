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

devel: VVAL=--verbose
devel: CC=/usr/local/opt/ccache/libexec/clang
devel: clean fetch
	export PYTHONOPTIMIZE=2
	python3 -OO setup.py build --full $(VVAL)
	python3 -OO setup.py kitty.app $(VVAL)
	rm -rf /usr/local/share/man/man1/kitty.1 /usr/local/share/doc/kitty
	command cp -f docs/_build/man/kitty.1 /usr/local/share/man/man1
	command cp -rf docs/_build/html /usr/local/share/doc/kitty
	command cp -r terminfo/6b ${APP}/Contents/Resources/terminfo/
	command cp -r terminfo/6b ${APP}/Contents/Frameworks/kitty/terminfo/
	rm -rf ${APP_TARGET}
	mv ${APP} $(APPLICATIONS_DIR)
	rm -f clangd.dex
	/opt/llvm/devel/bin/clangd-indexer --execute-concurrency=16 --extra-arg-before='-isystem /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/11.0.3 -isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk' --extra-arg='-I/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include -I/Library/Developer/CommandLineTools/usr/lib/clang/11.0.3/include -Wno-unused-command-line-argument' -p . --format=binary --executor=all-TUs ./compile_commands.json > clangd.dex

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
