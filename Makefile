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

$(BIN): $(SRC) src/dnscreen.pas src/dnpanel.pas src/dnmenu.pas src/dndialog.pas src/dnfileops.pas src/dntetris.pas src/dnwin.pas src/dnview.pas src/dnedit.pas src/dnconfig.pas
	@mkdir -p bin $(UNITDIR)
	$(FPC) $(FPCFLAGS) $(SRC)

run: $(BIN)
	$(BIN)

VENV := tests/.venv

$(VENV)/bin/pytest:
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --quiet pyte pytest

bin/unittests: tests/unittests.pas src/dnscreen.pas src/dnpanel.pas src/dnfileops.pas
	@mkdir -p bin $(UNITDIR)
	$(FPC) $(FPCFLAGS) tests/unittests.pas

test: all bin/unittests $(VENV)/bin/pytest
	bin/unittests
	$(VENV)/bin/pytest tests -q

clean:
	rm -rf bin $(UNITDIR)

distclean: clean
	rm -rf $(VENV)

.PHONY: all run test clean distclean
