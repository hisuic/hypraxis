-- Load this after existing workspace keybindings in hyprland.lua.
local existing = rawget(_G, "__hypraxis_workspace_grid")
if existing then
    return existing
end

local api = rawget(_G, "hl")
assert(type(api) == "table" and type(api.bind) == "function"
    and type(api.unbind) == "function" and type(api.get_current_submap) == "function",
    "workspace_grid requires Hyprland 0.56.2's Lua configuration API")
assert(api.get_current_submap() == "", "load workspace_grid in the default submap")
local grid = require("workspace_grid.hyprland").new(api)

local function bind(keys, callback, description)
    -- Replace just this chord so the old dispatcher cannot run alongside ours.
    api.unbind(keys)
    api.bind(keys, callback, { description = "Workspace grid: " .. description })
end

for x = 1, 10 do
    local column = x
    local key = tostring(column % 10)
    bind("SUPER + " .. key, function()
        grid.switch_column(column)
    end, "switch to column " .. column)
    bind("SUPER + SHIFT + " .. key, function()
        grid.move_to_column(column)
    end, "move window to column " .. column)
end

for _, direction in ipairs({ { key = "Up", delta = -1 }, { key = "Down", delta = 1 } }) do
    local delta = direction.delta
    local key = direction.key
    bind("SUPER + ALT + " .. key, function()
        grid.step(delta)
    end, "step " .. key:lower())
    bind("SUPER + ALT + SHIFT + " .. key, function()
        grid.move_vertical(delta)
    end, "move window " .. key:lower())
end

-- Plugin loading is declarative during config evaluation in Hyprland 0.56.2.
-- The Lua grid stays usable when the optional native module is not installed.
if type(api.plugin) == "table" and type(api.plugin.load) == "function" then
    local module_file = package.searchpath and package.searchpath("workspace_grid", package.path)
    if module_file then
        local directory = module_file:match("^(.*)/[^/]+$") or "."
        local plugin_file = directory .. "/hypraxis_overview.so"
        local file = io.open(plugin_file, "rb")
        if file then
            file:close()
            api.plugin.load(plugin_file)
        end
    end
end

grid.overview = require("workspace_grid.overview").new(api, grid)
function grid.toggle_overview()
    return grid.overview.toggle()
end
bind("SUPER + space", function()
    local ok, err = grid.toggle_overview()
    if not ok and api.notification and type(api.notification.create) == "function" then
        api.notification.create({ text = tostring(err), timeout = 4000, icon = "warning" })
    end
end, "open desktop overview")

rawset(_G, "__hypraxis_workspace_grid", grid)
return grid
