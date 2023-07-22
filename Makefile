ifdef V
	VVAL=--verbose
endif
ifdef VERBOSE
	VVAL=--verbose
endif

ifdef FAIL_WARN
export FAIL_WARN
endif

APPLICATIONS_DIR ?= /Applications
APP ?= kitty.app
APP_TARGET ?= $(join $(addsuffix /,${APPLICATIONS_DIR}), $(APP))

IDENTITY = $(shell security find-identity -v | grep 'Apple Development' | awk -F'"' '{print $$2}')
ifeq ($(IDENTITY),)
	IDENTITY=-
endif
export IDENTITY

default: devel

devel: CC=${HOMEBREW_PREFIX}/opt/ccache-head/libexec/clang
devel: VVAL=--verbose
devel: rebase
devel: clean
	python3 -OO setup.py kitty.app --full --update-check-interval=0 $(VVAL)
	# ${MAKE} docs SPHINXBUILD=/usr/local/share/pipx/sphinx-build
	# rm -rf /usr/local/share/man/man1/kitty.1 /usr/local/share/man/man5/kitty.conf.5 /usr/local/share/doc/kitty
	# install -m 0644 docs/_build/man/kitty.1 /usr/local/share/man/man1
	# install -m 0644 docs/_build/man/kitty.conf.5 /usr/local/share/man/man5
	# rm -rf /usr/local/share/doc/kitty
	# command cp -rf docs/_build/html /usr/local/share/doc/kitty
	for f in `find ${APP} -type f -name '*.so'`; \
		do \
		codesign -dvvvvv --options=runtime --entitlements ./entitlements.plist -s "${IDENTITY}" $${f}; \
	done
	codesign -dvvvvv --options=runtime --entitlements ./entitlements.plist -s "${IDENTITY}" ${APP}/Contents/MacOS/kitten
	codesign -dvvvvv --options=runtime --entitlements ./entitlements.plist -s "${IDENTITY}" ${APP}
	rm -rf ${APP_TARGET}
	mv ${APP} $(APPLICATIONS_DIR)

devel/signed: devel
	codesign -vvvvv --deep -f -s "$(shell security find-identity -v | grep 'Developer ID Application' | awk -F'"' '{print $$2}')" --entitlements ./entitlements.plist $(APPLICATIONS_DIR)/${APP}

devel/signed-noentitlements: devel
	codesign -vvvvv --deep -f -s "$(shell security find-identity -v | grep 'Developer ID Application' | awk -F'"' '{print $$2}')" $(APPLICATIONS_DIR)/${APP}

rebase:
	git fetch --all
	git rebase --autostash origin/master

all:
	python3 setup.py $(VVAL)

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

linux-package: FORCE
	rm -rf linux-package
	python3 setup.py linux-package

FORCE:

man:
	$(MAKE) -C docs man

html:
	$(MAKE) -C docs html

dirhtml:
	$(MAKE) -C docs dirhtml

linkcheck:
	$(MAKE) -C docs linkcheck

website:
	./publish.py --only website

docs: man html


develop-docs:
	$(MAKE) -C docs develop-docs


prepare-for-cross-compile: clean all
	python3 setup.py $(VVAL) clean --clean-for-cross-compile

cross-compile:
	python3 setup.py linux-package --skip-code-generation

.PHONY: env/%
env/%: ## Print the value of MAKEFILE_VARIABLE. Use `make env/GO_FLAGS` or etc.
	@echo $($*)
