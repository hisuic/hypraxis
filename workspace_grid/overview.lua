-- The compositor renders the overview; Lua owns its uncommitted grid cursor.
local core = require("workspace_grid.core")
local M = {}

local function invoke(native, operation, ...)
    local ok, result, err = pcall(native[operation], ...)
    if not ok then
        return nil, result
    end
    if result ~= true then
        return nil, err or "overview " .. operation .. " failed"
    end
    return true
end

local function cursor_from(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.rows) ~= "table" then
        return nil, "invalid overview grid state"
    end
    local x, y = core.from_id(snapshot.id)
    if not x or snapshot.x ~= x or snapshot.y ~= y then
        return nil, "invalid overview grid coordinates"
    end
    local cursor = { x = x, y = y, rows = {} }
    for column = 1, core.DEFAULT_COLUMNS do
        local row = snapshot.rows[column]
        if not core.to_id(column, row) then
            return nil, "invalid overview remembered row"
        end
        cursor.rows[column] = row
    end
    cursor.rows[x] = y
    return cursor
end

local function view(cursor)
    local x, y, rows = cursor.x, cursor.y, cursor.rows
    return {
        id = core.to_id(x, y), x = x, y = y,
        left = x > 1 and core.to_id(x - 1, rows[x - 1]) or 0,
        right = x < core.DEFAULT_COLUMNS and core.to_id(x + 1, rows[x + 1]) or 0,
        up = y > 1 and core.to_id(x, y - 1) or 0,
        down = core.to_id(x, y + 1) or 0,
    }
end

function M.new(api, grid)
    assert(type(api) == "table" and type(grid) == "table"
        and type(grid.overview_state) == "function" and type(grid.go_to) == "function",
        "workspace overview requires the workspace grid controller")
    local controller = {}
    local session

    local function close(commit)
        if not session then
            return true
        end
        local current = session
        current.closing = true
        local ok, err = invoke(current.native, "close", commit)
        current.closing = false
        if not ok then
            return nil, err
        end
        session = nil
        if commit then
            return grid.go_to(current.cursor.x, current.cursor.y)
        end
        return true
    end

    function controller.is_open()
        if not session then
            return false
        end
        local ok, opened = pcall(session.native.is_open)
        if not ok or opened ~= true then
            session = nil
            return false
        end
        return true
    end

    function controller.key(key)
        if not session or session.closing then
            return true
        end
        if key == "cancel" then
            -- Native lifecycle cancellation has already closed its overlay.
            session = nil
            return true
        elseif key == "escape" then
            return close(false)
        elseif key == "enter" then
            return close(true)
        end

        local cursor = session.cursor
        local x, y = cursor.x, cursor.y
        if key == "h" then
            x = math.max(1, x - 1)
            y = cursor.rows[x]
        elseif key == "l" then
            x = math.min(core.DEFAULT_COLUMNS, x + 1)
            y = cursor.rows[x]
        elseif key == "j" then
            y = y + 1
        elseif key == "k" then
            y = math.max(1, y - 1)
        else
            return true
        end
        if (x == cursor.x and y == cursor.y) or not core.to_id(x, y) then
            return true
        end

        local previous_x, previous_y, previous_row = cursor.x, cursor.y, cursor.rows[x]
        cursor.x, cursor.y, cursor.rows[x] = x, y, y
        local ok, err = invoke(session.native, "update", view(cursor))
        if not ok then
            cursor.x, cursor.y, cursor.rows[x] = previous_x, previous_y, previous_row
            return nil, err
        end
        return true
    end

    function controller.open()
        if controller.is_open() then
            return true
        end
        local native = type(api.plugin) == "table" and api.plugin.hypraxis_overview
        if type(native) ~= "table" then
            return nil, "load the hypraxis-overview plugin to enable the workspace overview"
        end
        for _, operation in ipairs({ "open", "update", "close", "is_open" }) do
            if type(native[operation]) ~= "function" then
                return nil, "incompatible hypraxis-overview plugin: missing " .. operation
            end
        end
        local snapshot, err = grid.overview_state()
        if not snapshot then
            return nil, err
        end
        local cursor, cursor_err = cursor_from(snapshot)
        if not cursor then
            return nil, cursor_err
        end
        local current = { cursor = cursor, native = native }
        session = current
        local ok, open_err = invoke(native, "open", view(cursor), function(key)
            if session ~= current then
                return true
            end
            return controller.key(key)
        end)
        if not ok then
            if session == current then session = nil end
            return nil, open_err
        end
        return true
    end

    function controller.toggle()
        if controller.is_open() then
            return close(false)
        end
        return controller.open()
    end

    function controller.stop()
        return close(false)
    end

    return controller
end

return M
