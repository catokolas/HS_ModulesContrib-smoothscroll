# Adapted from HS_ModuleWalkthrough/disks/Makefile.
# Installs to ~/.hammerspoon/hs/_ckol/<current_dir>/  (i.e. .../smoothscroll/).

mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(notdir $(patsubst %/,%,$(dir $(mkfile_path))))

MODULE := $(current_dir)
PREFIX ?= ~/.hammerspoon/hs/_ckol
HS_APPLICATION ?= /Applications

OBJCFILE = ${wildcard *.m}
LUAFILE  = ${wildcard *.lua}
HEADERS  = ${wildcard *.h}

SOFILE  := $(OBJCFILE:.m=.so)
DEBUG_CFLAGS ?= -g

space :=
space +=
comma := ,
ALLFILES := $(LUAFILE)
ALLFILES += $(SOFILE)

.SUFFIXES: .m .so

CC = @clang
# -Weverything is kept so our own code stays under scrutiny. The -Wno-*
# entries silence noise from LuaSkin headers and Homebrew include paths
# that we can't fix anyway.
WARNINGS ?= -Weverything \
            -Wno-objc-missing-property-synthesis \
            -Wno-implicit-atomic-properties \
            -Wno-direct-ivar-access \
            -Wno-cstring-format-directive \
            -Wno-padded \
            -Wno-covered-switch-default \
            -Wno-missing-prototypes \
            -Wno-declaration-after-statement \
            -Wno-poison-system-directories \
            -Wno-quoted-include-in-framework-header \
            -Wno-strict-prototypes \
            -Wno-bad-function-cast \
            -Wno-float-equal \
            -Wno-cast-align \
            -Wno-cast-qual \
            -Wno-disabled-macro-expansion \
            -Wno-undef \
            -Wno-pre-c11-compat \
            -Wno-c++98-compat \
            -Werror-implicit-function-declaration

EXTRA_CFLAGS ?= -F$(HS_APPLICATION)/Hammerspoon.app/Contents/Frameworks \
                -mmacosx-version-min=13.0

CFLAGS  += $(DEBUG_CFLAGS) -fmodules -fobjc-arc -DHS_EXTERNAL_MODULE $(WARNINGS) $(EXTRA_CFLAGS)
LDFLAGS += -dynamiclib -undefined dynamic_lookup -framework CoreVideo $(EXTRA_LDFLAGS)

all: verify $(SOFILE)

.m.so: $(HEADERS) $(OBJCFILE)
	$(CC) $< $(CFLAGS) $(LDFLAGS) -o $@

install: verify install-objc install-lua

verify: $(LUAFILE)
	@if $$(hash lua >& /dev/null); then \
	  (luac -p $(LUAFILE) && echo "Lua compile verification passed"); \
	else echo "Skipping Lua compile verification"; fi

install-objc: $(SOFILE)
	mkdir -p $(PREFIX)/$(MODULE)
	install -m 0644 $(SOFILE) $(PREFIX)/$(MODULE)
	cp -vpR $(OBJCFILE:.m=.so.dSYM) $(PREFIX)/$(MODULE)

install-lua: $(LUAFILE)
	mkdir -p $(PREFIX)/$(MODULE)
	install -m 0644 $(LUAFILE) $(PREFIX)/$(MODULE)

# Development install: symlinks instead of copies, so future `make` rebuilds
# are picked up without re-running install. (You still need to quit and
# relaunch Hammerspoon to reload internal.so.)
SOURCE_DIR := $(abspath .)
link: verify $(SOFILE)
	mkdir -p $(PREFIX)/$(MODULE)
	@for f in $(LUAFILE) $(SOFILE); do \
	  rm -f $(PREFIX)/$(MODULE)/$$f; \
	  ln -s $(SOURCE_DIR)/$$f $(PREFIX)/$(MODULE)/$$f; \
	  echo "linked $(PREFIX)/$(MODULE)/$$f -> $(SOURCE_DIR)/$$f"; \
	done

clean:
	rm -v -rf $(SOFILE) *.dSYM

uninstall:
	rm -v -f $(PREFIX)/$(MODULE)/{$(subst $(space),$(comma),$(ALLFILES))}
	(pushd $(PREFIX)/$(MODULE)/ ; rm -v -fr $(OBJCFILE:.m=.so.dSYM) ; popd)
	rmdir -p $(PREFIX)/$(MODULE) ; exit 0

# Release-bundle target (universal arm64 + x86_64).
VERSION    ?= 0.1
DIST_NAME  := $(MODULE)-$(VERSION)-macos-universal
DIST_DIR   := dist
DIST_STAGE := $(DIST_DIR)/staging
DIST_ZIP   := $(DIST_DIR)/$(DIST_NAME).zip

dist: dist-clean
	@echo "Building universal binary (arm64 + x86_64)..."
	$(MAKE) -B $(SOFILE) DEBUG_CFLAGS= EXTRA_CFLAGS="-F$(HS_APPLICATION)/Hammerspoon.app/Contents/Frameworks -mmacosx-version-min=13.0 -arch arm64 -arch x86_64"
	@echo
	@echo "Staging release files..."
	mkdir -p $(DIST_STAGE)/hs/_ckol/$(MODULE)
	install -m 0644 $(SOFILE)  $(DIST_STAGE)/hs/_ckol/$(MODULE)/
	install -m 0644 $(LUAFILE) $(DIST_STAGE)/hs/_ckol/$(MODULE)/
	@if [ -f ../LICENSE   ]; then install -m 0644 ../LICENSE   $(DIST_STAGE)/hs/_ckol/$(MODULE)/; fi
	@if [ -f ../README.md ]; then install -m 0644 ../README.md $(DIST_STAGE)/hs/_ckol/$(MODULE)/; fi
	@echo
	@echo "Packaging $(DIST_ZIP)..."
	cd $(DIST_STAGE) && zip -r ../$(DIST_NAME).zip hs
	@echo
	@echo "=== Done ==="
	@file $(SOFILE)
	@echo
	@unzip -l $(DIST_ZIP)
	@echo
	@echo "Artifact: $(DIST_DIR)/$(DIST_NAME).zip"

dist-clean:
	rm -rf $(DIST_DIR)

.PHONY: all clean uninstall verify install install-objc install-lua link dist dist-clean
