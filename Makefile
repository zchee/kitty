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

IDENTITY ?= $(shell security find-identity -v | grep 'Apple Development' | awk -F'"' '{print $$2}')

PYTHON3 ?= PYTHONUNBUFFERED=1 PYTHONOPTIMIZE=2 python3.14

default: devel

devel: CC=$(shell brew --prefix)/opt/ccache-head/libexec/clang
devel: VVAL=--verbose
devel:
	PKG_CONFIG_PATH=/opt/homebrew/opt/libpng/lib/pkgconfig:/opt/homebrew/opt/freetype2/lib/pkgconfig:${PKG_CONFIG_PATH} KITTY_USE_METAL=1 ${PYTHON3} setup.py kitty.app -v --full --update-check-interval=0 --shell-integration=enabled $(VVAL)
	# ${MAKE} docs SPHINXBUILD=/usr/local/share/pipx/sphinx-build
	# rm -rf /usr/local/share/man/man1/kitty.1 /usr/local/share/man/man5/kitty.conf.5 /usr/local/share/doc/kitty
	# install -m 0644 docs/_build/man/kitty.1 /usr/local/share/man/man1
	# install -m 0644 docs/_build/man/kitty.conf.5 /usr/local/share/man/man5
	# rm -rf /usr/local/share/doc/kitty
	# command cp -rf docs/_build/html /usr/local/share/doc/kitty
	for f in `find ${APP} -type f -name '*.so'`; \
		do \
		sudo codesign -dvvvvv --options=runtime --entitlements ./entitlements.plist -s "${IDENTITY}" $${f}; \
	done
	sudo codesign -dvvvvv --options=runtime --entitlements ./entitlements.plist -fs "${IDENTITY}" ${APP}/Contents/MacOS/kitty || true
	sudo codesign -dvvvvv --options=runtime --entitlements ./entitlements.plist -fs "${IDENTITY}" ${APP}/Contents/MacOS/kitten
	sudo codesign -dvvvvv --deep --options=runtime --entitlements ./entitlements.plist -fs "${IDENTITY}" ${APP}
	rm -rf ${APP_TARGET}
	mv ${APP} $(APPLICATIONS_DIR)

codesign:
	codesign -dvvvvv --options=runtime --entitlements ./entitlements.plist -s "${IDENTITY}" ${APP}/Contents/MacOS/kitten
	codesign -dvvvvv --options=runtime --entitlements ./entitlements.plist -s "${IDENTITY}" ${APP}

devel/signed: devel
	codesign -vvvvv --deep -f -s "$(shell security find-identity -v | grep 'Developer ID Application' | awk -F'"' '{print $$2}')" --entitlements ./entitlements.plist $(APPLICATIONS_DIR)/${APP}

devel/signed-noentitlements: devel
	codesign -vvvvv --deep -f -s "$(shell security find-identity -v | grep 'Developer ID Application' | awk -F'"' '{print $$2}')" $(APPLICATIONS_DIR)/${APP}

rebase:
	git fetch --all
	git rebase --gpg-sign --autostash origin/master

all:
	${PYTHON3} setup.py $(VVAL)

test:
	${PYTHON3} setup.py $(VVAL) test

clean:
	${PYTHON3} setup.py $(VVAL) clean

# A debug build
debug:
	${PYTHON3} setup.py build $(VVAL) --debug

debug-event-loop:
	${PYTHON3} setup.py build $(VVAL) --debug --extra-logging=event-loop

# Build with the ASAN and UBSAN sanitizers
asan:
	${PYTHON3} setup.py build $(VVAL) --debug --sanitize

profile:
	${PYTHON3} setup.py build $(VVAL) --profile

app:
	${PYTHON3} setup.py kitty.app $(VVAL)

linux-package: FORCE
	rm -rf linux-package
	${PYTHON3} setup.py linux-package

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

# Phase-0 baseline benchmark suite for the Metal-backend optimization project
# (scripts/metal-baseline.py): throughput (kitten __benchmark__ --render),
# devlog-006 Japanese `cat` replication, vtebench (if present), RSS, optional
# powermetrics, and KITTY_METAL_STATS frame timing. Requires kitty/launcher/kitty
# to already be built (this target does not build it). JSON lands in
# .omc/baselines/; see docs/metal-performance.md for the GL-backend companion
# run and full methodology. KITTY_USE_METAL=1 here documents intent to match
# the build invocation -- the script itself auto-detects the actual backend
# from the built .app bundle rather than trusting this env var.
metal-baseline:
	KITTY_USE_METAL=1 ${PYTHON3} scripts/metal-baseline.py
