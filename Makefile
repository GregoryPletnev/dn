FPC      ?= fpc
SRC      := src/dn.pas
BIN      := bin/dn
UNITDIR  := build
FPCFLAGS := -MObjFPC -Sh -O2 -Fusrc -FU$(UNITDIR) -FEbin

UNAME := $(shell uname -s)
ifeq ($(UNAME),Darwin)
  NCURSES_PREFIX := $(shell brew --prefix ncurses 2>/dev/null)
  ifneq ($(NCURSES_PREFIX),)
    FPCFLAGS += -Fl$(NCURSES_PREFIX)/lib
  endif
endif

all: $(BIN)

$(BIN): $(SRC) src/dnscreen.pas src/dnpanel.pas src/dnmenu.pas src/dndialog.pas src/dnfileops.pas src/dntetris.pas src/dnwin.pas src/dnview.pas src/dnedit.pas src/dnconfig.pas src/dnoptions.pas src/dnvfs.pas src/dnarcvfs.pas src/dnmount.pas src/dnsftp.pas src/dnsession.pas src/dnsessui.pas src/dnuu.pas src/dnusermenu.pas src/dnhighlite.pas src/dnsaver.pas src/dnconsole.pas src/dngpm.pas src/dnplaylist.pas src/dnaudio.pas src/dnplayer.pas src/dnlsproto.pas src/dnlshttp.pas src/dnls.pas src/dnpath.pas src/dnhttp.pas src/dnhtml.pas src/dncss.pas src/dnlayout.pas src/dnjs.pas src/dnbrowser.pas src/dndisks.pas src/dndisksui.pas
	@mkdir -p bin $(UNITDIR)
	$(FPC) $(FPCFLAGS) $(SRC)

run: $(BIN)
	$(BIN)

# Install a `dn` symlink into a PATH directory. An explicit PREFIX puts it
# in $(PREFIX)/bin; otherwise it goes where `dn --install-path` puts it:
# $XDG_BIN_HOME, else ~/.local/bin. BINDIR overrides both.
ifeq ($(origin PREFIX),undefined)
  BINDIR ?= $(or $(XDG_BIN_HOME),$(HOME)/.local/bin)
else
  BINDIR ?= $(PREFIX)/bin
endif

install: $(BIN)
	@mkdir -p $(DESTDIR)$(BINDIR)
	ln -sfn $(CURDIR)/$(BIN) $(DESTDIR)$(BINDIR)/dn
	@echo "installed: $(DESTDIR)$(BINDIR)/dn -> $(CURDIR)/$(BIN)"

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/dn

VENV := tests/.venv

$(VENV)/bin/pytest:
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --quiet pyte pytest

bin/unittests: tests/unittests.pas src/dnscreen.pas src/dnpanel.pas src/dnfileops.pas src/dnvfs.pas src/dnuu.pas src/dnsession.pas src/dnoptions.pas src/dnusermenu.pas src/dnhighlite.pas src/dnplaylist.pas src/dnaudio.pas src/dnlsproto.pas src/dnls.pas src/dnlshttp.pas src/dnhttp.pas src/dnhtml.pas src/dncss.pas src/dnlayout.pas src/dnjs.pas src/dndisks.pas
	@mkdir -p bin $(UNITDIR)
	$(FPC) $(FPCFLAGS) tests/unittests.pas

# Fail on any src unit that no other src file uses. Such a unit is orphaned: it
# compiles but nothing links it in. src/dn.pas is the program root; a unit that
# only it uses still counts as used. The awk script scans the uses clause from
# the "uses" keyword to its terminating semicolon and reports whether the unit
# name appears there as a whole word.
CHECK_UNITS_AWK = awk -v u="$(1)" ' \
  BEGIN { inuses = 0; found = 0 } \
  { \
    line = tolower($$0); \
    if (!inuses) { \
      if (line ~ /(^|[^a-z0-9_])uses([^a-z0-9_]|$$)/) { \
        sub(/.*[^a-z0-9_]uses/, " ", line); \
        sub(/(^|[^a-z0-9_])uses/, " ", line); \
        inuses = 1; \
      } else next; \
    } \
    gsub(/[^a-z0-9_]/, " ", line); \
    n = split(line, w, /[ \t]+/); \
    for (i = 1; i <= n; i++) if (w[i] == u) { found = 1; exit }; \
    if ($$0 ~ /;/) exit; \
  } \
  END { exit !found }'

check-units:
	@orphans=""; \
	for f in src/*.pas; do \
	  u=$$(basename "$$f" .pas); \
	  [ "$$u" = dn ] && continue; \
	  used=0; \
	  for g in src/*.pas; do \
	    [ "$$g" = "$$f" ] && continue; \
	    if $(call CHECK_UNITS_AWK,$$u) $$g; then used=1; break; fi; \
	  done; \
	  [ "$$used" = 0 ] && orphans="$$orphans $$u"; \
	done; \
	if [ -n "$$orphans" ]; then \
	  for u in $$orphans; do \
	    echo "orphaned unit: $$u (src/$$u.pas is used by no other src file)"; \
	  done; \
	  set -- $$orphans; \
	  echo "check-units: $$# orphaned unit(s)"; \
	  exit 1; \
	fi; \
	echo "check-units: no orphaned units"

test: check-units all bin/unittests $(VENV)/bin/pytest
	DN_CONFIG_DIR=$(shell mktemp -d) bin/unittests
	$(VENV)/bin/pytest tests -q

dmg:
	scripts/build-dmg.sh

deb:
	scripts/build-deb.sh

clean:
	rm -rf bin $(UNITDIR) dist

distclean: clean
	rm -rf $(VENV)

.PHONY: all run test check-units dmg deb install uninstall clean distclean
