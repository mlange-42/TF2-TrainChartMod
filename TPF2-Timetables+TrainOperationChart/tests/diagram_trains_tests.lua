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
    -- rotation line: the run ends at the last stop with an arrival only, no return to the start
    local stations = {
        station(1, "A", { {0, 0, 1, 0} }),
        station(2, "B", { {10, 0, 11, 0} }),
        station(3, "C", { {20, 0, 21, 0} }),
    }
    local r = diagramTrains.buildRuns(stations, { 540, 540, 600 }, true)[1]
    assert(#r == 3, "A B C, got " .. tostring(#r))
    assert(r[3].flatIdx == 3 and r[3].arr == 1200)
    assert(r[3].dep == nil, "no departure at the last stop")
    assert(r[2].dep == 660)
end

tests[#tests + 1] = function()
    -- no slots at all: no runs
    assert(#diagramTrains.buildRuns({ station(1, "A"), station(2, "B") }, {}) == 0)
end

tests[#tests + 1] = function()
    -- waypoints placed along the leg by straight-line distance: A(0) -> w1(10) -> w2(40) -> B(100)
    local st = {
        station(1, "A"), waypoint(1, "w1"), waypoint(1, "w2"), station(2, "B"),
    }
    st[1].pos = { 0, 0 }; st[2].pos = { 10, 0 }; st[3].pos = { 40, 0 }; st[4].pos = { 100, 0 }
    diagramTrains.assignLegFractions(st)
    assert(math.abs(st[2].legFrac - 0.1) < 1e-9 and math.abs(st[3].legFrac - 0.4) < 1e-9)
    -- missing position: no fraction for the whole leg
    st[2].legFrac, st[3].legFrac, st[3].pos = nil, nil, nil
    diagramTrains.assignLegFractions(st)
    assert(st[2].legFrac == nil and st[3].legFrac == nil)
    -- leg back to the first stop: B(100) -> w(75) -> A(0)
    local st2 = { station(1, "A"), station(2, "B"), waypoint(2, "w") }
    st2[1].pos = { 0, 0 }; st2[2].pos = { 100, 0 }; st2[3].pos = { 75, 0 }
    diagramTrains.assignLegFractions(st2)
    assert(math.abs(st2[3].legFrac - 0.25) < 1e-9)
end

tests[#tests + 1] = function()
    -- buildRuns matches a waypoint's passing time at its legFrac: dep 01:00, leg 400 s,
    -- legFrac 0.25 -> expected 02:40; slots 02:40 and 05:00 -> 02:40 wins (equal spacing: 05:00)
    local st = { station(1, "A", {{0, 0, 1, 0}}), waypoint(1, "w", {{2, 40, 2, 40}, {5, 0, 5, 0}}), station(2, "B") }
    st[2].legFrac = 0.25
    local runs = diagramTrains.buildRuns(st, { 400, 400 })
    assert(runs[1][2].arr == 160, "arr " .. tostring(runs[1][2].arr))
end

tests[#tests + 1] = function()
    assert(diagramTrains.dwellDelay(100, 160, 90) == -10, "early")
    assert(diagramTrains.dwellDelay(100, 160, 130) == 0, "inside the dwell")
    assert(diagramTrains.dwellDelay(100, 160, 175) == 15, "overdue")
end

tests[#tests + 1] = function()
    -- A dep 01:00 -> w 02:00 -> B arr 04:00; leg found for a departure one hour later
    local st = { station(1, "A", {{0, 0, 1, 0}}), waypoint(1, "w", {{2, 0, 2, 0}}),
        station(2, "B", {{4, 0, 5, 0}}) }
    local runs = diagramTrains.buildRuns(st, { 240, 240 })
    local leg = diagramTrains.legVisits(runs, st, 1, 3660)
    assert(leg and #leg == 3, "A, w, B")
    assert(leg[1].dep == 3660 and leg[2].arr == 3720 and leg[3].arr == 3840)
    assert(diagramTrains.legVisits(runs, st, 1, 90) == nil, "no run departs at 01:30")
    -- leg out of B ends at A again
    leg = diagramTrains.legVisits(runs, st, 3, 300)
    assert(leg and #leg == 2 and leg[2].flatIdx == 1)
end

tests[#tests + 1] = function()
    -- two slots at A: the run starting at 01:00 ends back at A on the 31:00 slot. That last
    -- visit must not hide the run that starts at 31:00.
    local st = { station(1, "A", {{0, 0, 1, 0}, {30, 0, 31, 0}}), station(2, "B", {{10, 0, 11, 0}, {40, 0, 41, 0}}) }
    local runs = diagramTrains.buildRuns(st, { 540, 1140 })
    assert(runs[1][#runs[1]].dep % 3600 == 1860, "first run ends on the 31:00 slot")
    local leg = diagramTrains.legVisits(runs, st, 1, 1860)
    assert(leg and #leg == 2 and leg[2].flatIdx == 2 and leg[2].arr == 2400, "leg of the run starting at 31:00")
end

tests[#tests + 1] = function()
    local pts = { {t = 100, y = 0}, {t = 200, y = 50}, {t = 200, y = 50}, {t = 300, y = 100} }
    local y, d = diagramTrains.trainOnLeg(pts, 150, 0)
    assert(y == 25 and d == 0, "on time, halfway along the first segment")
    y, d = diagramTrains.trainOnLeg(pts, 270, 20)
    assert(y == 75 and d == 20, "keeps the departure delay")
    y, d = diagramTrains.trainOnLeg(pts, 330, 0)
    assert(y == 100 and d == 30, "overdue: waits at the end, delay grows")
    y, d = diagramTrains.trainOnLeg(pts, 120, 20)
    assert(y == 0 and d == 20, "just departed late")
end

return {
    test = function()
        for k, v in pairs(tests) do
            print("Running test: " .. tostring(k))
            v()
        end
    end
}
