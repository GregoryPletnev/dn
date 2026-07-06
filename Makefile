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

$(BIN): $(SRC) src/dnscreen.pas src/dnpanel.pas src/dnmenu.pas src/dndialog.pas src/dnfileops.pas src/dntetris.pas src/dnwin.pas src/dnview.pas src/dnedit.pas src/dnconfig.pas src/dnoptions.pas src/dnvfs.pas src/dnarcvfs.pas src/dnmount.pas src/dnsftp.pas src/dnsession.pas src/dnsessui.pas src/dnuu.pas src/dnusermenu.pas
	@mkdir -p bin $(UNITDIR)
	$(FPC) $(FPCFLAGS) $(SRC)

run: $(BIN)
	$(BIN)

VENV := tests/.venv

$(VENV)/bin/pytest:
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --quiet pyte pytest

bin/unittests: tests/unittests.pas src/dnscreen.pas src/dnpanel.pas src/dnfileops.pas src/dnvfs.pas src/dnuu.pas src/dnsession.pas src/dnoptions.pas src/dnusermenu.pas
	@mkdir -p bin $(UNITDIR)
	$(FPC) $(FPCFLAGS) tests/unittests.pas

test: all bin/unittests $(VENV)/bin/pytest
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

.PHONY: all run test dmg deb clean distclean
