# mxswitch - macOS build. Other platforms need no build step.
#
# Local (no sudo):  make && ./mxswitch --info
#                    make install PREFIX=$HOME/.local
# System-wide:       sudo make install

CC      ?= clang
CFLAGS  ?= -O2 -Wall -Wextra
PREFIX  ?= /usr/local
FRAMEWORKS = -framework IOKit -framework CoreFoundation -framework CoreGraphics

.PHONY: all install uninstall clean

all: mxswitch

mxswitch: macos/mxswitch.c
	$(CC) $(CFLAGS) -o $@ $< $(FRAMEWORKS)
	@# Ad-hoc signing gives the binary a stable identity so that its
	@# Input Monitoring grant survives recompilation.
	codesign -s - $@

install: mxswitch
	install -d $(PREFIX)/bin
	install -m 755 mxswitch $(PREFIX)/bin/mxswitch
	@echo
	@echo "Installed to $(PREFIX)/bin/mxswitch"
	@# Prompt for Input Monitoring only when this binary is not already allowed.
	@# Under sudo make install, run as the invoking user so TCC/Settings apply
	@# to them rather than root.
	@if [ -n "$$SUDO_USER" ]; then \
		sudo -u "$$SUDO_USER" "$(PREFIX)/bin/mxswitch" --setup; \
	else \
		"$(PREFIX)/bin/mxswitch" --setup; \
	fi

uninstall:
	rm -f $(PREFIX)/bin/mxswitch

clean:
	rm -f mxswitch
