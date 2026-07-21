INSTALL_DIR ?= $(HOME)/.local/share/Steam/steamapps/common/Windrose/R5/Binaries/Win64/ue4ss/Mods

MOD_NAME    := CampDepositReloaded
BUILD_DIR   := build/$(MOD_NAME)
SCRIPTS_DIR := $(BUILD_DIR)/Scripts

.PHONY: all build install uninstall clean

all: build

build: $(SCRIPTS_DIR)/main.lua $(BUILD_DIR)/enabled.txt

$(SCRIPTS_DIR)/main.lua: src/main.lua
	@mkdir -p $(SCRIPTS_DIR)
	cp src/main.lua $(SCRIPTS_DIR)/main.lua

$(BUILD_DIR)/enabled.txt:
	@mkdir -p $(BUILD_DIR)
	touch $(BUILD_DIR)/enabled.txt

install: build
	@mkdir -p $(INSTALL_DIR)/$(MOD_NAME)/Scripts
	ln -sf $(CURDIR)/$(SCRIPTS_DIR)/main.lua $(INSTALL_DIR)/$(MOD_NAME)/Scripts/main.lua
	ln -sf $(CURDIR)/$(BUILD_DIR)/enabled.txt $(INSTALL_DIR)/$(MOD_NAME)/enabled.txt
	@echo "Installed to $(INSTALL_DIR)/$(MOD_NAME)"

uninstall:
	rm -rf $(INSTALL_DIR)/$(MOD_NAME)

clean:
	rm -rf build/
