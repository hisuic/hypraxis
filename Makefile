LUA ?= lua
LUAC ?= luac

.PHONY: check test

check:
	@for file in workspace_grid.lua workspace_grid/*.lua tests/*.lua; do \
		$(LUAC) -p "$$file" || exit 1; \
	done

test: check
	$(LUA) tests/core.lua
	$(LUA) tests/hyprland.lua
	$(LUA) tests/bindings.lua
