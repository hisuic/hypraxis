-- Pure coordinate and session-state logic; no compositor dependencies.
local M = { DEFAULT_COLUMNS = 10, MAX_ID = 9007199254740991 }

local function positive_integer(value)
    return type(value) == "number" and value >= 1
        and value <= M.MAX_ID and value == math.floor(value)
end

local function valid_columns(columns)
    return positive_integer(columns)
end

function M.to_id(x, y, columns)
    columns = columns or M.DEFAULT_COLUMNS
    if not valid_columns(columns) or not positive_integer(x)
        or x > columns or not positive_integer(y) then
        return nil, "invalid grid coordinates"
    end
    -- Stay within Lua's exact integer range, including on LuaJIT.
    if y - 1 > math.floor((M.MAX_ID - x) / columns) then
        return nil, "workspace identifier exceeds the exact integer range"
    end
    return x + columns * (y - 1)
end

function M.from_id(id, columns)
    columns = columns or M.DEFAULT_COLUMNS
    if not valid_columns(columns) or not positive_integer(id) then
        return nil, "invalid workspace identifier"
    end
    return (id - 1) % columns + 1, math.floor((id - 1) / columns) + 1
end

function M.new(columns)
    columns = columns or M.DEFAULT_COLUMNS
    assert(valid_columns(columns), "columns must be a positive integer")
    local rows = {}
    local state = {}

    function state.remember(id)
        local x, y = M.from_id(id, columns)
        if not x then
            return nil, y
        end
        rows[x] = y
        return x, y
    end

    function state.column_target(x)
        return M.to_id(x, rows[x] or 1, columns)
    end

    function state.vertical_target(id, delta)
        if delta ~= -1 and delta ~= 1 then
            return nil, "vertical step must be -1 or 1"
        end
        local x, y = M.from_id(id, columns)
        if not x then
            return nil, y
        end
        if y == 1 and delta == -1 then
            return nil, "already at the top row"
        end
        return M.to_id(x, y + delta, columns)
    end

    return state
end

return M
