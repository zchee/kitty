ifdef V
		VVAL=--verbose
endif
ifdef VERBOSE
		VVAL=--verbose
endif

APP_TARGET ?= /Applications/kitty.app

devel: clean
	rm -rf linux-package
	python3 setup.py $(VVAL) osx-bundle
	rm -fr ${APP_TARGET}/Contents/Frameworks/kitty ${APP_TARGET}/Contents/MacOS/kitty
	cp -r ./linux-package/Contents/Frameworks/kitty ${APP_TARGET}/Contents/Frameworks
	cp -r ./linux-package/Contents/MacOS/kitty ${APP_TARGET}/Contents/MacOS

all:
	python3 setup.py $(VVAL)

test:
	python3 setup.py $(VVAL) test

clean:
	python3 setup.py $(VVAL) clean

# A debug build
debug:
	python3 setup.py build $(VVAL) --debug

# Build with the ASAN and UBSAN sanitizers
asan:
	python3 setup.py build $(VVAL) --debug --sanitize
