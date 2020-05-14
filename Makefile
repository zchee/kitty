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

devel: CC=/usr/local/opt/ccache-head/libexec/clang
devel: VVAL=--verbose
devel: fetch
devel: clean
	export PYTHONOPTIMIZE=2
	# python3 setup.py build --full $(VVAL)
	python3 setup.py kitty.app --update-check-interval=0 $(VVAL)
	${MAKE} docs
	rm -rf /usr/local/share/man/man1/kitty.1 /usr/local/share/doc/kitty
	install -m 0644 docs/_build/man/kitty.1 /usr/local/share/man/man1
	rm -rf /usr/local/share/doc/kitty
	command cp -rf docs/_build/html /usr/local/share/doc/kitty
	for f in `find ${APP} -type f -name '*.so'`; \
		do \
		codesign -dvvvvv --options=runtime --entitlements ./entitlements.plist -s "$(shell security find-identity -v | grep 'Developer ID Application' | awk -F'"' '{print $$2}')" $${f}; \
	done
	codesign -dvvvvv --options=runtime --entitlements ./entitlements.plist -s "$(shell security find-identity -v | grep 'Developer ID Application' | awk -F'"' '{print $$2}')" ${APP}/Contents/MacOS/kitty
	rm -rf ${APP_TARGET}
	mv ${APP} $(APPLICATIONS_DIR)

devel/signed: devel
	codesign -vvvvv --deep -f -s "$(shell security find-identity -v | grep 'Developer ID Application' | awk -F'"' '{print $$2}')" --entitlements ./entitlements.plist $(APPLICATIONS_DIR)/${APP}

devel/signed-noentitlements: devel
	codesign -vvvvv --deep -f -s "$(shell security find-identity -v | grep 'Developer ID Application' | awk -F'"' '{print $$2}')" $(APPLICATIONS_DIR)/${APP}

fetch:
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

man:
	$(MAKE) FAIL_WARN=$(FAIL_WARN) -C docs man

html:
	$(MAKE) FAIL_WARN=$(FAIL_WARN) -C docs html

linkcheck:
	$(MAKE) FAIL_WARN=$(FAIL_WARN) -C docs linkcheck

docs: man html
