local adapter = require("hypraxis.hyprland")
local count = 0
local function check(condition, message)
    assert(condition, message)
    count = count + 1
end

local function fixture(initial_id)
    local f = { active = initial_id and { id = initial_id }, calls = {}, events = {}, window = {} }
    f.api = {
        get_active_workspace = function() return f.active end,
        get_active_special_workspace = function() return f.special end,
        get_active_window = function() return f.window end,
        on = function(event, callback)
            f.events[event] = callback
            return { remove = function() f.events[event] = nil end }
        end,
        dsp = {
            focus = function(options) return { kind = "focus", options = options } end,
            window = { move = function(options) return { kind = "move", options = options } end },
        },
        dispatch = function(action)
            f.calls[#f.calls + 1] = action
            if f.fail then return { ok = false, error = "simulated failure" } end
            if action.kind == "focus" or action.options.follow then
                f.active = { id = tonumber(action.options.workspace) }
                f.events["workspace.active"](f.active)
            end
            return { ok = true }
        end,
    }
    f.grid = adapter.new(f.api)
    return f
end

local f = fixture(1)
local grid = f.grid
check(grid.step(-1) == nil and #f.calls == 0, "top row never dispatches")
check(grid.step(1) and f.active.id == 11, "down creates the next row")
check(f.calls[1].options.on_current_monitor == true, "operate on the current monitor")
check(grid.switch_column(2) and f.active.id == 2, "unvisited column starts at row one")
for _ = 1, 4 do check(grid.step(1), "increase row") end
check(f.active.id == 42, "reach column two, row five")
check(grid.switch_column(1) and f.active.id == 11, "restore first column")
check(grid.switch_column(2) and f.active.id == 42, "restore second column")
local before = #f.calls
check(grid.switch_column(2) and #f.calls == before, "same column avoids back-and-forth")
check(grid.switch_column(0) == nil and #f.calls == before, "reject invalid destination")
check(grid.step(0) == nil and #f.calls == before, "reject invalid step")

f.active = { id = 72 }
f.events["workspace.active"](f.active)
grid.switch_column(1)
check(grid.switch_column(2) and f.active.id == 72, "remember external workspace events")
f.active = { id = 92 }
grid.switch_column(1)
check(grid.switch_column(2) and f.active.id == 92, "resync before commands even without an event")
f.active = { id = 21 }
f.events["monitor.focused"]({})
grid.switch_column(2)
check(grid.switch_column(1) and f.active.id == 21, "resync focused monitor")
local x, y = grid.position()
check(x == 1 and y == 3, "report actual coordinates")

f.fail = true
local ok, err = grid.step(1)
check(ok == nil and err == "simulated failure", "propagate dispatcher failure")
f.fail = false
grid.switch_column(2)
check(grid.switch_column(1) and f.active.id == 21, "failed dispatch never changes row memory")

before = #f.calls
f.special = { id = -99, special = true }
check(grid.step(1) == nil, "do not navigate from a special workspace")
check(grid.switch_column(2) == nil, "do not switch columns from a special workspace")
check(grid.move_vertical(1) == nil, "do not move a special window")
f.events["workspace.active"](f.special)
check(#f.calls == before, "special workspace never dispatches")
f.special = nil
check(grid.switch_column(1) and f.active.id == 21, "special events preserve regular memory")
f.active = { id = -1 }
check(grid.step(1) == nil, "ignore named or invalid negative identifiers")
f.active = { id = 21, special = true }
check(grid.step(1) == nil, "ignore special flag even with a positive identifier")
f.active = nil
check(grid.switch_column(2) == nil, "ignore missing active workspace")
f.active = { id = 21 }

f.window = nil
before = #f.calls
check(grid.move_vertical(1) == nil and #f.calls == before, "empty workspace cannot move a window")
f.window = { pinned = true }
check(grid.move_vertical(1) == nil and #f.calls == before, "ignore pinned windows")
f.window = {}
check(grid.move_vertical(1) and f.active.id == 31, "move down and follow the window")
check(f.calls[#f.calls].kind == "move", "use the existing window dispatcher")
check(grid.move_to_column(2) and f.active.id == 92, "move to the destination column's remembered row")
check(grid.move_vertical(-1, false) and f.active.id == 92, "silent movement preserves focus")
check(f.calls[#f.calls].options.workspace == "82" and not f.calls[#f.calls].options.follow,
    "silent movement uses follow=false")
grid.switch_column(1)
check(grid.switch_column(2) and f.active.id == 92, "silent movement does not record an unvisited row")

local startup = fixture(nil)
startup.active = { id = 42 }
startup.events["hyprland.start"]()
startup.grid.switch_column(1)
check(startup.grid.switch_column(2) and startup.active.id == 42, "initialize after compositor startup")
local reload = fixture(42)
reload.events["config.reloaded"]()
check(reload.grid.switch_column(1) and reload.active.id == 1, "new Lua session resets other rows")
check(reload.grid.switch_column(2) and reload.active.id == 42, "reload learns the active row")
check(not pcall(adapter.new, {}), "reject unavailable APIs before registering handlers")
grid.stop()
grid.stop()
check(next(f.events) == nil, "event subscriptions can be removed idempotently")

print(string.format("hyprland: %d checks passed", count))
