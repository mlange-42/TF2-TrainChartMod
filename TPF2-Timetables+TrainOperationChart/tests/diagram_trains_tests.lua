local diagramTrains = require "celmi/timetables/diagram_trains"

local tests = {}

local function station(stopIndex, key, times)
    return { stopIndex = stopIndex, isLineStop = true, uniqueKey = key, times = times or {} }
end

local function waypoint(stopIndex, key, times)
    return { stopIndex = stopIndex, isLineStop = false, uniqueKey = key, times = times or {} }
end

tests[#tests + 1] = function()
    assert(diagramTrains.median({}) == nil)
    assert(diagramTrains.median({5}) == 5)
    assert(diagramTrains.median({9, 1, 5}) == 5)
    assert(diagramTrains.median({4, 1, 3, 2}) == 2.5)
end

tests[#tests + 1] = function()
    -- measured legs are kept, the remaining round trip is split by distance
    local r = diagramTrains.estimateLegTimes({ [1] = {100, 120, 110} }, { [2] = 1000, [3] = 3000 }, 910, 3)
    assert(r[1] == 110, "measured median")
    assert(r[2] == 200, "1/4 of the remaining 800s, got " .. tostring(r[2]))
    assert(r[3] == 600, "3/4 of the remaining 800s, got " .. tostring(r[3]))
    -- no round trip: unmeasured legs stay unknown
    r = diagramTrains.estimateLegTimes({ [1] = {100} }, {}, nil, 2)
    assert(r[1] == 100 and r[2] == nil)
    -- no distances: equal split
    r = diagramTrains.estimateLegTimes({}, {}, 600, 2)
    assert(r[1] == 300 and r[2] == 300)
end

tests[#tests + 1] = function()
    local slots = { {40, 0, 41, 0}, {10, 0, 11, 0} }
    local p = diagramTrains.pickSlot(slots, 9 * 60, nil)
    assert(p.arr == 600 and p.dep == 660, "nearest slot")
    p = diagramTrains.pickSlot(slots, 10 * 60 + 30, nil)
    assert(p.arr == 600, "inside the slot interval")
    -- arrival slightly after the scheduled departure still matches that slot
    p = diagramTrains.pickSlot(slots, 11 * 60 + 20, nil)
    assert(p.arr == 600, "slightly late")
    -- slot from the next hour
    p = diagramTrains.pickSlot(slots, 3600 + 8 * 60, nil)
    assert(p.arr == 3600 + 600, "next hour, got " .. tostring(p.arr))
    -- notBefore excludes earlier slots
    p = diagramTrains.pickSlot(slots, 9 * 60, 700)
    assert(p.arr == 2400, "notBefore")
end

tests[#tests + 1] = function()
    -- slots entered in different orders per station; pairing must follow travel times
    local stations = {
        station(1, "A", { {50, 0, 51, 0}, {10, 0, 11, 0} }),
        station(2, "B", { {18, 0, 19, 0}, {58, 0, 59, 0} }),
        station(3, "C", { {6, 0, 7, 0}, {26, 0, 27, 0} }),
    }
    local runs = diagramTrains.buildRuns(stations, { 420, 420, 240 })
    assert(#runs == 2)
    local r1 = runs[1]
    assert(#r1 == 4, "A B C A")
    assert(r1[1].dep == 51 * 60)
    assert(r1[2].arr == 58 * 60, "B 58:00, got " .. tostring(r1[2].arr))
    assert(r1[3].arr == 3600 + 6 * 60, "C 06:00 next hour, got " .. tostring(r1[3].arr))
    assert(r1[4].flatIdx == 1 and r1[4].arr == 3600 + 10 * 60, "back at A 10:00")
    local r2 = runs[2]
    assert(r2[2].arr == 18 * 60 and r2[3].arr == 26 * 60)
    assert(r2[4].arr == 50 * 60, "back at A 50:00, got " .. tostring(r2[4].arr))
end

tests[#tests + 1] = function()
    -- unknown leg times: earliest slot after the previous departure; stations without slots
    -- and attached waypoints are passed through
    local stations = {
        station(1, "A", { {0, 0, 1, 0} }),
        waypoint(1, "W", { {3, 0, 3, 0}, {33, 0, 33, 0} }),
        station(2, "B", {}),
        station(3, "C", { {20, 0, 21, 0} }),
    }
    local runs = diagramTrains.buildRuns(stations, {})
    assert(#runs == 1)
    local r = runs[1]
    assert(#r == 5)
    assert(r[2].arr == 180, "waypoint")
    assert(r[3].arr == nil, "station without slots")
    assert(r[4].arr == 1200)
    assert(r[5].arr == 3600, "back at A next hour, got " .. tostring(r[5].arr))
end

tests[#tests + 1] = function()
    -- waypoint time is interpolated along the leg
    local stations = {
        station(1, "A", { {0, 0, 0, 0} }),
        waypoint(1, "W", { {5, 0, 5, 0}, {9, 0, 9, 0} }),
        station(2, "B", { {20, 0, 20, 0} }),
    }
    local runs = diagramTrains.buildRuns(stations, { 1200, 1200 })
    assert(runs[1][2].arr == 540, "waypoint near the middle of the leg, got " .. tostring(runs[1][2].arr))
    assert(runs[1][3].arr == 1200)
end

tests[#tests + 1] = function()
    -- no slots at all: no runs
    assert(#diagramTrains.buildRuns({ station(1, "A"), station(2, "B") }, {}) == 0)
end

return {
    test = function()
        for k, v in pairs(tests) do
            print("Running test: " .. tostring(k))
            v()
        end
    end
}
