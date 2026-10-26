local diagramLayout = require "celmi/timetables/diagram_layout"

local tests = {}

local function station(stopIndex, key)
    return { stopIndex = stopIndex, isLineStop = true, uniqueKey = key }
end

local function waypoint(stopIndex, key)
    return { stopIndex = stopIndex, isLineStop = false, uniqueKey = key }
end

local function near(a, b) return a and math.abs(a - b) < 1e-9 end

tests[#tests + 1] = function()
    -- one direction: A -> B -> C -> back to A
    local lines = { { stations = { station(1, "A"), station(2, "B"), station(3, "C") }, metric = { 100, 300, 400 } } }
    local g = diagramLayout.lineGaps(lines, { A = 1, B = 2, C = 3 }, 3)
    assert(g[1] == 100 and g[2] == 300, "gaps " .. tostring(g[1]) .. ", " .. tostring(g[2]))
end

tests[#tests + 1] = function()
    -- both directions are averaged: A -> B -> C -> B -> back to A
    local lines = { { stations = { station(1, "A"), station(2, "B"), station(3, "C"), station(4, "B2") },
                      metric = { 100, 300, 280, 120 } } }
    local g = diagramLayout.lineGaps(lines, { A = 1, B = 2, B2 = 2, C = 3 }, 3)
    assert(g[1] == 110 and g[2] == 290, "gaps " .. tostring(g[1]) .. ", " .. tostring(g[2]))
end

tests[#tests + 1] = function()
    -- unknown leg breaks the measurement
    local lines = { { stations = { station(1, "A"), station(2, "B"), station(3, "C") }, metric = { 100, nil, 400 } } }
    local g = diagramLayout.lineGaps(lines, { A = 1, B = 2, C = 3 }, 3)
    assert(g[1] == 100 and g[2] == nil)
end

tests[#tests + 1] = function()
    -- stops not on the chart are summed into the gap; waypoints are interpolated
    local lines = { { stations = { station(1, "A"), waypoint(1, "W"), station(2, "B"), station(3, "C") },
                      metric = { 100, 300, 400 } } }
    local g = diagramLayout.lineGaps(lines, { A = 1, W = 2, C = 3 }, 3)
    assert(g[1] == 50 and g[2] == 350, "gaps " .. tostring(g[1]) .. ", " .. tostring(g[2]))
end

tests[#tests + 1] = function()
    local f = diagramLayout.fillGaps({ 10, nil, 30 }, { 100, 50, 300 }, 3)
    assert(f[1] == 10 and near(f[2], 5) and f[3] == 30, "converted by ratio")
    f = diagramLayout.fillGaps({}, { 100, 50 }, 2)
    assert(f[1] == 100 and f[2] == 50, "fallback only")
    f = diagramLayout.fillGaps({ 10, nil }, {}, 2)
    assert(f[1] == 10 and f[2] == 10, "mean")
    assert(diagramLayout.fillGaps({}, {}, 2) == nil, "nothing known")
end

tests[#tests + 1] = function()
    local y = diagramLayout.rowYs({ 1, 3 }, 3, 400)
    assert(y[1] == 400 and y[2] == 300 and y[3] == 0, "proportional")
    y = diagramLayout.rowYs(nil, 3, 400)
    assert(y[1] == 400 and y[2] == 200 and y[3] == 0, "equal")
    y = diagramLayout.rowYs({ 1, 99 }, 3, 109)
    assert(near(y[2], 99), "small gap clamped to 20% of the mean, got " .. tostring(y[2]))
    y = diagramLayout.rowYs(nil, 1, 400)
    assert(y[1] == 200, "single row centered")
end

return {
    test = function()
        for k, v in pairs(tests) do
            print("Running test: " .. tostring(k))
            v()
        end
    end
}
