local core = require("workspace_grid.core")
local count = 0

local function check(condition, message)
    assert(condition, message)
    count = count + 1
end

for _, point in ipairs({ {1, 1, 1}, {2, 1, 2}, {10, 1, 10},
    {1, 2, 11}, {2, 2, 12}, {1, 3, 21}, {2, 5, 42} }) do
    local x, y, id = point[1], point[2], point[3]
    check(core.to_id(x, y) == id, "coordinate mapping")
    local actual_x, actual_y = core.from_id(id)
    check(actual_x == x and actual_y == y, "inverse mapping")
end

for id = 1, 10000 do
    local x, y = core.from_id(id)
    check(core.to_id(x, y) == id, "round trip across many rows")
end

for _, value in ipairs({ 0, -1, -99, 1.5, "1", "special:magic", false,
    {}, math.huge, -math.huge, 0/0, core.MAX_ID + 1 }) do
    check(core.from_id(value) == nil, "reject invalid identifiers")
    check(core.to_id(value, 1) == nil, "reject invalid columns")
    check(core.to_id(1, value) == nil, "reject invalid rows")
end
check(core.from_id(nil) == nil, "reject absent identifier")
check(core.to_id(11, 1) == nil, "column boundary")
check(core.to_id(1, core.MAX_ID) == nil, "prevent overflow")
local last_x, last_y = core.from_id(core.MAX_ID)
check(core.to_id(last_x, last_y) == core.MAX_ID, "largest exact identifier")
check(core.to_id(3, 2, 3) == 6, "configurable coordinate width")
check(core.to_id(1, 1, 0) == nil, "invalid width")
check(not pcall(core.new, -1), "invalid state width")

local state = core.new()
check(state.vertical_target(1, -1) == nil, "top row is a no-op")
check(state.vertical_target(10, -1) == nil, "top row in last column")
check(state.vertical_target(10, 1) == 20, "down stays in the same column")
check(state.vertical_target(42, -1) == 32, "up stays in the same column")
check(state.vertical_target(42, 2) == nil, "invalid delta")
check(state.vertical_target(-99, 1) == nil, "special workspace")
check(state.vertical_target(core.MAX_ID, 1) == nil, "vertical overflow")
check(state.column_target(1) == 1, "unvisited column starts at row one")
state.remember(42)
state.remember(21)
check(state.column_target(2) == 42, "remember independent row in column two")
check(state.column_target(1) == 21, "remember independent row in column one")
check(state.remember(-1) == nil, "invalid state update")
check(state.column_target(1) == 21, "invalid update preserves memory")
check(state.vertical_target(42, 1) == 52, "plan navigation")
check(state.column_target(2) == 42, "planning does not commit an unvisited row")
check(core.new().column_target(2) == 2, "sessions are independent")

print(string.format("core: %d checks passed", count))
