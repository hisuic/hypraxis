local core = require("workspace_grid.core")
local M = {}

function M.new(api)
    assert(type(api) == "table", "workspace_grid requires Hyprland's hl API")
    for _, name in ipairs({ "get_active_workspace", "get_active_special_workspace",
        "get_active_window", "on", "dispatch" }) do
        assert(type(api[name]) == "function", "workspace_grid requires hl." .. name)
    end
    assert(type(api.dsp) == "table" and type(api.dsp.focus) == "function"
        and type(api.dsp.window) == "table" and type(api.dsp.window.move) == "function",
        "workspace_grid requires hl.dsp.focus and hl.dsp.window.move")

    local state = core.new()
    local subscriptions = {}
    local controller = {}

    local function current_id()
        if api.get_active_special_workspace() ~= nil then
            return nil, "grid navigation is disabled on special workspaces"
        end
        local workspace = api.get_active_workspace()
        if not workspace or workspace.special or not core.from_id(workspace.id) then
            return nil, "no active numbered workspace"
        end
        return workspace.id
    end

    local function sync()
        local id, err = current_id()
        if not id then
            return nil, err
        end
        state.remember(id)
        return id
    end

    function controller.position()
        local id, err = sync()
        if not id then
            return nil, err
        end
        return core.from_id(id)
    end

    local function execute(id, move, follow)
        if not id then
            return nil, "no destination workspace"
        end
        local current, err = current_id()
        if not current then
            return nil, err
        end
        if id == current then
            -- Do not trigger Hyprland's workspace_back_and_forth behavior.
            return true
        end
        local dispatcher
        local selector = string.format("%.0f", id)
        if move then
            local window = api.get_active_window()
            if not window or window.pinned then
                return nil, "no movable active window"
            end
            dispatcher = api.dsp.window.move({ workspace = selector, follow = follow ~= false })
        else
            dispatcher = api.dsp.focus({ workspace = selector, on_current_monitor = true })
        end
        local result = api.dispatch(dispatcher)
        if type(result) ~= "table" or result.ok ~= true then
            return nil, type(result) == "table" and result.error or "Hyprland dispatch failed"
        end
        -- Commit only the compositor's actual position, never a planned destination.
        sync()
        return true
    end

    local function column(x, move, follow)
        local id, err = sync()
        if not id then
            return nil, err
        end
        local target, target_err = state.column_target(x)
        if not target then
            return nil, target_err
        end
        return execute(target, move, follow)
    end

    local function vertical(delta, move, follow)
        local id, err = sync()
        if not id then
            return nil, err
        end
        local target, target_err = state.vertical_target(id, delta)
        if not target then
            return nil, target_err
        end
        return execute(target, move, follow)
    end

    function controller.switch_column(x)
        return column(x, false)
    end

    function controller.step(delta)
        return vertical(delta, false)
    end

    function controller.move_to_column(x, follow)
        return column(x, true, follow)
    end

    function controller.move_vertical(delta, follow)
        return vertical(delta, true, follow)
    end

    function controller.overview_state()
        local id, err = sync()
        if not id then
            return nil, err
        end
        local x, y = core.from_id(id)
        local snapshot = { id = id, x = x, y = y, rows = {} }
        for column = 1, core.DEFAULT_COLUMNS do
            local _, row = core.from_id(state.column_target(column))
            snapshot.rows[column] = row
        end
        return snapshot
    end

    function controller.go_to(x, y)
        local target, err = core.to_id(x, y)
        if not target then
            return nil, err
        end
        local id, sync_err = sync()
        if not id then
            return nil, sync_err
        end
        return execute(target, false)
    end

    function controller.stop()
        for _, subscription in ipairs(subscriptions) do
            subscription:remove()
        end
        subscriptions = {}
    end

    for _, event in ipairs({ "workspace.active", "monitor.focused",
        "config.reloaded", "hyprland.start" }) do
        subscriptions[#subscriptions + 1] = api.on(event, sync)
    end
    sync()
    return controller
end

return M
