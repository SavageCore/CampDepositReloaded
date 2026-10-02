INSTALL_DIR ?= $(HOME)/.local/share/Steam/steamapps/common/Windrose/R5/Binaries/Win64/ue4ss/Mods
# Harness switch: `make test DEPOSIT_CLASSES_STALE=1` simulates a game update that
# renamed the Deposit Similar option, which must warn rather than go inert.
DEPOSIT_CLASSES_STALE ?= 0

MOD_NAME    := CampDepositReloaded
BUILD_DIR   := build/$(MOD_NAME)
SCRIPTS_DIR := $(BUILD_DIR)/Scripts
CONFIG_FILE := CampDepositReloaded.cfg.lua

.PHONY: all build test install uninstall clean

all: build

build: $(SCRIPTS_DIR)/main.lua $(BUILD_DIR)/enabled.txt

$(SCRIPTS_DIR)/main.lua: src/main.lua
	@mkdir -p $(SCRIPTS_DIR)
	cp src/main.lua $(SCRIPTS_DIR)/main.lua

$(BUILD_DIR)/enabled.txt:
	@mkdir -p $(BUILD_DIR)
	touch $(BUILD_DIR)/enabled.txt

# Stubs UE4SS and drives main.lua outside the game: identity gate, fan-out
# invariants, camp scoping and the stale-class warning.
test: build
	@mkdir -p build/harness/run
	DEPOSIT_CLASSES_STALE=$(DEPOSIT_CLASSES_STALE) lua tests/harness.lua

install: build
	@mkdir -p $(INSTALL_DIR)/$(MOD_NAME)/Scripts
	ln -sf $(CURDIR)/$(SCRIPTS_DIR)/main.lua $(INSTALL_DIR)/$(MOD_NAME)/Scripts/main.lua
	ln -sf $(CURDIR)/$(BUILD_DIR)/enabled.txt $(INSTALL_DIR)/$(MOD_NAME)/enabled.txt
	@# main.lua resolves its config next to *itself*, and the installed copy is a
	@# symlink into build/ - so without this line the config is never found and
	@# every session silently runs on the hardcoded defaults.
	@if [ -f "$(SCRIPTS_DIR)/$(CONFIG_FILE)" ]; then \
		ln -sf $(CURDIR)/$(SCRIPTS_DIR)/$(CONFIG_FILE) $(INSTALL_DIR)/$(MOD_NAME)/Scripts/$(CONFIG_FILE); \
		echo "Config linked: $(SCRIPTS_DIR)/$(CONFIG_FILE)"; \
	else \
		echo "No config found - the mod will run on defaults. Create $(SCRIPTS_DIR)/$(CONFIG_FILE)"; \
	fi
	@echo "Installed to $(INSTALL_DIR)/$(MOD_NAME)"

uninstall:
	rm -rf $(INSTALL_DIR)/$(MOD_NAME)

clean:
	rm -rf build/
