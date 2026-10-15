local count = 0
local function check(condition, message)
    assert(condition, message)
    count = count + 1
end

local registered, removed, calls = {}, {}, {}
local creates = 0
package.preload["workspace_grid.hyprland"] = function()
    return { new = function()
        creates = creates + 1
        return {
            switch_column = function(x) calls[#calls + 1] = { "column", x } end,
            move_to_column = function(x) calls[#calls + 1] = { "move_column", x } end,
            step = function(delta) calls[#calls + 1] = { "step", delta } end,
            move_vertical = function(delta) calls[#calls + 1] = { "move_vertical", delta } end,
            overview_state = function()
                return { id = 1, x = 1, y = 1, rows = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 } }
            end,
            go_to = function(x, y) calls[#calls + 1] = { "go_to", x, y } end,
        }
    end }
end

check(not pcall(require, "workspace_grid"), "fail clearly outside Hyprland")
package.loaded.workspace_grid = nil
local submap = "nested"
_G.hl = {
    get_current_submap = function() return submap end,
    unbind = function(keys)
        removed[#removed + 1] = keys
        registered[keys] = nil
    end,
    bind = function(keys, callback, options)
        check(registered[keys] == nil, "remove an existing binding before replacement")
        check(type(options.description) == "string", "provide binding descriptions")
        registered[keys] = callback
    end,
}
check(not pcall(require, "workspace_grid"), "reject registration inside a submap")
check(#removed == 0 and creates == 0, "preflight leaves existing bindings untouched")
package.loaded.workspace_grid = nil
submap = ""

local unrelated = function() end
for _, key in ipairs({ "SUPER + Q", "SUPER + A", "SUPER + mouse_down", "XF86AudioMute" }) do
    registered[key] = unrelated
end
for x = 1, 10 do
    registered["SUPER + " .. tostring(x % 10)] = function() error("old binding ran") end
    registered["SUPER + SHIFT + " .. tostring(x % 10)] = function() error("old move binding ran") end
end
local grid = require("workspace_grid")
check(#removed == 25 and creates == 1, "install exactly 25 target bindings")
check(type(registered["SUPER + space"]) == "function", "register the overview shortcut")
check(type(grid.toggle_overview) == "function" and type(grid.overview) == "table", "expose overview controls")
local opened, err = grid.toggle_overview()
check(opened == nil and type(err) == "string", "missing optional plugin leaves the grid available")
for x = 1, 10 do
    registered["SUPER + " .. tostring(x % 10)]()
    check(calls[#calls][1] == "column" and calls[#calls][2] == x, "independent numeric closures")
    registered["SUPER + SHIFT + " .. tostring(x % 10)]()
    check(calls[#calls][1] == "move_column" and calls[#calls][2] == x, "independent move closures")
end
for _, operation in ipairs({
    { "SUPER + ALT + Up", "step", -1 },
    { "SUPER + ALT + Down", "step", 1 },
    { "SUPER + ALT + SHIFT + Up", "move_vertical", -1 },
    { "SUPER + ALT + SHIFT + Down", "move_vertical", 1 },
}) do
    registered[operation[1]]()
    check(calls[#calls][1] == operation[2] and calls[#calls][2] == operation[3], "direction mapping")
end
for _, key in ipairs({ "SUPER + Q", "SUPER + A", "SUPER + mouse_down", "XF86AudioMute" }) do
    check(registered[key] == unrelated, "preserve unrelated bindings")
end
check(require("workspace_grid") == grid and #removed == 25, "cached require is idempotent")
package.loaded.workspace_grid = nil
check(require("workspace_grid") == grid and #removed == 25 and creates == 1,
    "manual package cache clearing does not duplicate bindings or handlers")
_G.__hypraxis_workspace_grid = nil
package.loaded.workspace_grid = nil
check(require("workspace_grid") ~= grid and creates == 2 and #removed == 50,
    "fresh Lua session registers once")

print(string.format("bindings: %d checks passed", count))
