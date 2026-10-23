local adapter = require("hypraxis.hyprland")
local overview = require("hypraxis.overview")
local core = require("hypraxis.core")
local count = 0
local function check(condition, message)
    assert(condition, message)
    count = count + 1
end

local function fixture(id)
    local f = { active = id and { id = id }, calls = {}, events = {}, views = {}, closes = {} }
    f.api = {
        get_active_workspace = function() return f.active end,
        get_active_special_workspace = function() return f.special end,
        get_active_window = function() return {} end,
        on = function(event, callback)
            f.events[event] = callback
            return { remove = function() f.events[event] = nil end }
        end,
        dsp = {
            focus = function(options) return options end,
            window = { move = function(options) return options end },
        },
        dispatch = function(options)
            f.calls[#f.calls + 1] = options
            if f.dispatch_fail then return { ok = false, error = "dispatch rejected" } end
            f.active = { id = tonumber(options.workspace) }
            f.events["workspace.active"]()
            return { ok = true }
        end,
    }
    f.native = {
        open = function(state, callback)
            if f.open_fail then return nil, "open rejected" end
            f.opened, f.callback = true, callback
            f.views[#f.views + 1] = state
            return true
        end,
        update = function(state)
            if f.update_throw then error("update exception") end
            if f.update_fail then return nil, "update rejected" end
            f.views[#f.views + 1] = state
            return true
        end,
        close = function(commit)
            if f.close_fail then return nil, "close rejected" end
            f.closes[#f.closes + 1] = commit
            f.closed_before_dispatch = #f.calls
            f.opened = false
            return true
        end,
        is_open = function() return f.opened == true end,
    }
    f.api.plugin = { hypraxis_overview = f.native }
    f.grid = adapter.new(f.api)
    f.overview = overview.new(f.api, f.grid)
    function f.view() return f.views[#f.views] end
    return f
end

local f = fixture(1)
check(f.grid.go_to(1, 3) and f.grid.go_to(2, 5), "prepare independently remembered rows")
local snapshot = f.grid.overview_state()
check(snapshot.id == 42 and snapshot.x == 2 and snapshot.y == 5, "snapshot reports actual coordinates")
check(#snapshot.rows == 10 and snapshot.rows[1] == 3 and snapshot.rows[3] == 1,
    "snapshot includes every column with row-one defaults")
snapshot.rows[1] = 100
check(f.grid.overview_state().rows[1] == 3, "snapshot rows cannot mutate persistent memory")
local before = #f.calls
check(f.overview.open() and f.overview.is_open(), "open through the native plugin API")
local view = f.view()
check(view.id == 42 and view.left == 21 and view.right == 3 and view.up == 32 and view.down == 52,
    "cross previews use remembered horizontal rows and adjacent vertical rows")
check(f.overview.open() and #f.views == 1, "opening twice is idempotent")
check(f.callback("j") and f.view().id == 52, "J moves the temporary cursor down")
check(f.callback("l") and f.view().id == 3, "L selects the next column's remembered row")
check(f.callback("j") and f.view().id == 13, "temporary rows are independent per column")
check(f.callback("h") and f.view().id == 52, "H restores a temporarily visited row")
check(f.callback("l") and f.view().id == 13, "revisiting another column restores its temporary row")
check(f.active.id == 42 and #f.calls == before, "browsing never switches the actual workspace")
snapshot = f.grid.overview_state()
check(snapshot.rows[2] == 5 and snapshot.rows[3] == 1, "browsing never commits persistent row memory")
check(f.callback("escape") and not f.overview.is_open(), "Escape closes the overview")
check(f.closes[1] == false and #f.calls == before, "Escape cancels without dispatching")
check(f.grid.overview_state().rows[3] == 1, "cancel discards every temporary row")

check(f.overview.open() and f.callback("j") and f.callback("l") and f.callback("j"),
    "prepare a new selection after cancellation")
check(f.callback("enter") and f.active.id == 13, "Enter commits the exact selected coordinates")
check(#f.calls == before + 1 and f.closes[2] == true and f.closed_before_dispatch == before,
    "Enter closes native input before its single workspace dispatch")
snapshot = f.grid.overview_state()
check(snapshot.rows[2] == 5 and snapshot.rows[3] == 2,
    "commit remembers only the actual selected destination")
check(f.overview.open() and f.callback("enter") and #f.calls == before + 1,
    "confirming the original workspace avoids back-and-forth")
check(f.overview.toggle() and f.overview.toggle() and not f.overview.is_open(),
    "toggle opens and cancels")
check(f.overview.open() and f.overview.stop() and f.overview.stop(), "stop closes idempotently")

local edges = fixture(1)
check(edges.overview.open(), "open at the upper-left corner")
check(edges.view().left == 0 and edges.view().up == 0, "missing edge previews use ID zero")
before = #edges.views
check(edges.callback("h") and edges.callback("k") and #edges.views == before,
    "H and K stop at column one and row one")
check(edges.callback("unknown") and #edges.views == before, "unrecognized keys do nothing")
for _ = 1, 9 do check(edges.callback("l"), "walk across ten columns") end
check(edges.view().id == 10 and edges.view().right == 0, "right edge has no eleventh column")
before = #edges.views
check(edges.callback("l") and #edges.views == before, "L stops at column ten")
check(edges.callback("k") and #edges.views == before, "top-row K does not update native state")

local large = fixture(core.MAX_ID)
check(large.overview.open() and large.view().id == core.MAX_ID, "large exact workspace IDs are preserved")
check(large.view().down == 0, "unrepresentable lower workspace is absent")
before = #large.views
check(large.callback("j") and #large.views == before, "downward browsing cannot overflow exact IDs")
check(large.callback("l") and large.callback("h") and large.view().id == core.MAX_ID,
    "horizontal browsing restores a large temporary row exactly")
check(large.callback("enter") and #large.calls == 0, "large unchanged confirmation never dispatches")

local failures = fixture(12)
failures.open_fail = true
local ok, err = failures.overview.open()
check(ok == nil and err == "open rejected" and not failures.overview.is_open(),
    "native open failure leaves no live cursor")
failures.open_fail = false
check(failures.overview.open(), "recover after native open failure")
failures.update_fail = true
ok, err = failures.callback("j")
check(ok == nil and err == "update rejected", "propagate rejected native updates")
failures.update_fail = false
check(failures.callback("j") and failures.view().id == 22, "failed update rolls back the cursor")
failures.update_throw = true
ok, err = failures.callback("j")
check(ok == nil and err:match("update exception"), "native exceptions stay inside the Lua callback")
failures.update_throw = false
check(failures.callback("j") and failures.view().id == 32, "exceptional update also rolls back")
failures.close_fail = true
ok, err = failures.callback("enter")
check(ok == nil and err == "close rejected" and #failures.calls == 0 and failures.overview.is_open(),
    "failed close prevents committing and retains a usable session")
failures.close_fail = false
failures.dispatch_fail = true
ok, err = failures.callback("enter")
check(ok == nil and err == "dispatch rejected" and not failures.overview.is_open(),
    "dispatch failure closes the overlay and propagates its error")
check(failures.grid.overview_state().rows[2] == 2, "failed commit preserves actual row memory")

local lifecycle = fixture(1)
check(lifecycle.overview.open() and lifecycle.callback("j"), "prepare lifecycle cancellation")
local stale_callback = lifecycle.callback
lifecycle.opened = false
check(stale_callback("cancel") and not lifecycle.overview.is_open() and #lifecycle.closes == 0,
    "native cancellation drops the cursor without a second native close")
check(lifecycle.overview.open(), "reopen after native cancellation")
before = #lifecycle.views
check(stale_callback("j") and stale_callback("cancel") and lifecycle.overview.is_open()
    and #lifecycle.views == before, "late callbacks cannot control or cancel a new session")
lifecycle.opened = false
check(not lifecycle.overview.is_open() and lifecycle.overview.toggle(),
    "detect an overlay closed by native lifecycle code even without a callback")

local unavailable = fixture(1)
unavailable.api.plugin = nil
ok, err = unavailable.overview.open()
check(ok == nil and err:match("load the hypraxis%-overview plugin"), "missing plugin reports setup guidance")
unavailable.api.plugin = { hypraxis_overview = {} }
check(unavailable.overview.open() == nil, "reject an incompatible native API")
unavailable.api.plugin.hypraxis_overview = unavailable.native
check(unavailable.overview.open(), "resolve plugins lazily after configuration load")

for _, active in ipairs({ false, { id = -1 }, { id = 1, special = true }, { id = core.MAX_ID + 1 } }) do
    local invalid = fixture(1)
    invalid.active = active or nil
    check(invalid.overview.open() == nil and #invalid.views == 0,
        "invalid and missing workspaces never open the native overview")
    check(invalid.grid.go_to(2, 2) == nil and #invalid.calls == 0,
        "absolute navigation rejects invalid actual workspaces")
end
local special = fixture(1)
special.special = { id = -99 }
check(special.grid.overview_state() == nil and special.overview.open() == nil,
    "special overlays disable snapshots and overview navigation")
check(special.grid.go_to(2, 2) == nil and #special.calls == 0, "special overlays block absolute dispatch")
local coordinates = fixture(1)
for _, point in ipairs({ { 0, 1 }, { 11, 1 }, { 1, 0 }, { 1, 1.5 }, { 1, math.huge }, { 10, core.MAX_ID } }) do
    check(coordinates.grid.go_to(point[1], point[2]) == nil and #coordinates.calls == 0,
        "absolute navigation rejects invalid coordinates and overflow")
end
coordinates.active = { id = 52 }
check(coordinates.grid.overview_state().rows[2] == 6, "snapshots resync external changes without an event")

local valid_rows = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }
for _, state in ipairs({ {}, { id = 1, x = 2, y = 1, rows = valid_rows },
    { id = 1, x = 1, y = 2, rows = valid_rows }, { id = 1, x = 1, y = 1, rows = {} } }) do
    local malformed = fixture(1)
    local controller = overview.new(malformed.api, {
        overview_state = function() return state end,
        go_to = function() error("malformed state dispatched") end,
    })
    check(controller.open() == nil and #malformed.views == 0,
        "malformed snapshots are rejected before native rendering")
end

print(string.format("overview: %d checks passed", count))
