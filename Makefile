LUA ?= lua
LUAC ?= luac
BUILD_DIR ?= .local/build

.PHONY: check test plugin install test-overview

check:
	@for file in workspace_grid.lua workspace_grid/*.lua tests/*.lua; do \
		$(LUAC) -p "$$file" || exit 1; \
	done

test: check
	$(LUA) tests/core.lua
	$(LUA) tests/hyprland.lua
	$(LUA) tests/bindings.lua
	$(LUA) tests/overview.lua
	sh tests/install.sh

plugin:
	cmake -S . -B "$(BUILD_DIR)" -DCMAKE_BUILD_TYPE=Release
	cmake --build "$(BUILD_DIR)" -j 2

install: plugin
	sh scripts/install.sh --plugin "$(BUILD_DIR)/hypraxis_overview.so"

test-overview: plugin
	python3 scripts/test-overview.py --plugin "$(BUILD_DIR)/hypraxis_overview.so"
