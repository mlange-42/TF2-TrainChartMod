-- Regression tests for global waypoint name keys: the same physical waypoint must get the same key on all lines,
-- and renaming must not change the key (ensures _gwNames has one name per entity, synced globally across lines).
-- Verified (2026-08-05): v.waypoints[i] is a SignalId struct exposing numeric fields entity (SignalList entity id)
-- + index (position within the signal list); key is gws_<entity>_<index>.
_G = _G
_ = function(s) return s end

-- Clear the helper stubs written by timetable_tests and load the real module
package.loaded["celmi/timetables/timetable_helper"] = nil

-- API stubs needed to simulate "old-style" waypoints (no .entity/.index, using the edge+pos fallback chain)
local oldWaypointDb = {}
local function makeOldWaypoint(edge, x, y, name)
    local wp = { edge = edge, x = x, y = y, name = name }
    oldWaypointDb[wp] = wp
    return wp
end

api = {
    engine = {
        system = { streetSystem = {
            getEdgeForEdgeObject = function(wpRef)
                local w = oldWaypointDb[wpRef]
                if not w then return nil end
                return w.edge
            end,
        } },
        getComponent = function(wpRef, ctype)
            local w = oldWaypointDb[wpRef]
            if not w then return nil end
            if ctype == 58 then
                if w.x == nil or w.y == nil then return nil end
                return { fatInstances = { { transf = { col = function(i) return { x = w.x, y = w.y } end } } } }
            end
            return nil
        end,
    },
    type = { ComponentType = { NAME = 63, MODEL_INSTANCE_LIST = 58 } },
    gui = { util = { Size = { new = function() end } } },
}

local th = require "celmi/timetables/timetable_helper"

local tests = {}
local testCount = 0
local failCount = 0

local function addTest(fn)
    local idx = testCount + 1
    testCount = idx
    tests[#tests + 1] = function()
        local ok, err = pcall(fn)
        if ok then
            print("  OK: helper test #" .. idx)
        else
            failCount = failCount + 1
            print("  FAIL: helper test #" .. idx .. " :: " .. tostring(err))
        end
    end
end

addTest(function()
    -- The same physical waypoint (same entity+index) must get the same key on two different lines (different parent station/index)
    local wpA = { entity = 7154, index = 0, name = "A" }
    local k1 = th.getWaypointEntityKey(wpA, 500, 3)
    local k2 = th.getWaypointEntityKey(wpA, 700, 1)
    assert(k1 == k2, "same waypoint in different lines got different keys: " .. tostring(k1) .. " vs " .. tostring(k2))
    assert(k1 == "gws_7154_0", "unexpected key format: " .. tostring(k1))
end)

addTest(function()
    -- Renaming must not change the key
    local wpA = { entity = 7154, index = 0, name = "A" }
    local before = th.getWaypointEntityKey(wpA, 500, 3)
    wpA.name = "Renamed"
    local after = th.getWaypointEntityKey(wpA, 500, 3)
    assert(before == after, "rename changed the key: " .. tostring(before) .. " -> " .. tostring(after))
end)

addTest(function()
    -- Different entities (different SignalList entity ids) must get different keys
    local wpA = { entity = 7154, index = 0, name = "A" }
    local wpB = { entity = 7155, index = 0, name = "B" }
    assert(th.getWaypointEntityKey(wpA, 500, 3) ~= th.getWaypointEntityKey(wpB, 500, 3), "distinct waypoints share a key")
end)

addTest(function()
    -- Waypoints with different indices on the same SignalList entity must get different keys (distinguishes multiple waypoints on one edge)
    local wpA = { entity = 7154, index = 0, name = "A" }
    local wpC = { entity = 7154, index = 3, name = "C" }
    assert(th.getWaypointEntityKey(wpA, 500, 3) ~= th.getWaypointEntityKey(wpC, 500, 3), "same-entity diff-index waypoints share a key")
end)

addTest(function()
    -- Old-style waypoint without .entity: edge+position fallback, still independent of the line
    local wpD = makeOldWaypoint(9001, 12.34, 56.78, "D")
    local k1 = th.getWaypointEntityKey(wpD, 111, 2)
    local k2 = th.getWaypointEntityKey(wpD, 222, 5)
    assert(k1 == k2, "edge+pos fallback not line-independent: " .. tostring(k1) .. " vs " .. tostring(k2))
    assert(k1 == "gwp_9001_12.34_56.78", "unexpected fallback key: " .. tostring(k1))
end)

addTest(function()
    -- getAllTimetableRailVehicles must filter by hasTimetable (vehicle control switch regression, user report):
    -- only return vehicles of lines with "follow timetable" ticked; vehicles of unticked lines / lines without timetable entries are excluded,
    -- so the engine coroutine never calls stopVehicle/startVehicle on them (previously the filter was lost -> trains of unticked lines
    -- were held at stations forever and never departed; only ticking and unticking released them).
    -- Regression 1: the return value must be an "array of vehicle IDs" (the coroutine's for _,v in pairs() uses the values as vehicle IDs) --
    -- if it returned a {vehicleID:lineID} map, the coroutine would get line IDs, and inside waitingRequired(lineID)
    -- getComponent(line, TRANSPORT_VEHICLE) triggers a C++ assert (GetComponentDataIndex).
    -- Regression 2: the getVehiclesWithState snapshot may contain just-deleted, invalid IDs; entityExists must be checked
    -- before getComponent (AGENTS.md: getComponent on an invalid entity = C++ assert, not catchable by pcall).
    local savedGetComponent = api.engine.getComponent
    local savedTransportSystem = api.engine.system.transportVehicleSystem
    local savedEntityExists = api.engine.entityExists
    api.engine.system.transportVehicleSystem = {
        getVehiclesWithState = function(state)
            return { 10, 20, 30, 40, 99 }  -- 99 = just-deleted invalid ID (snapshot leftover)
        end,
    }
    api.engine.entityExists = function(id)
        return id ~= 99   -- 99 was deleted, the others exist
    end
    api.engine.getComponent = function(v, ctype)
        local lineOf = { [10] = 100, [20] = 100, [30] = 200, [40] = 300 }
        if ctype == 70 then return { line = lineOf[v] } end
        return nil
    end
    api.type.enum = api.type.enum or {}
    api.type.enum.TransportVehicleState = api.type.enum.TransportVehicleState or { AT_TERMINAL = "AT_TERMINAL" }
    api.type.ComponentType.TRANSPORT_VEHICLE = 70
    local hasTT = function(line) return line == 100 end  -- only line 100 has "follow timetable" ticked
    local res = th.getAllTimetableRailVehicles(hasTT)
    local has = {}
    for _, id in ipairs(res) do has[tostring(id)] = true end
    assert(#res == 2, "exactly 2 vehicles on checked line, got " .. tostring(#res))
    assert(has["10"] and has["20"], "vehicles on checked line must be returned as list values")
    assert(has["30"] == nil, "vehicle on unchecked line must be excluded")
    assert(has["40"] == nil, "vehicle on line without timetable entry must be excluded")
    assert(has["99"] == nil, "invalid snapshot ID must be skipped (entityExists guard)")
    api.engine.getComponent = savedGetComponent
    api.engine.system.transportVehicleSystem = savedTransportSystem
    api.engine.entityExists = savedEntityExists
end)

addTest(function()
    -- Liang-Barsky segment clipping regression (used by diagram zoom): window [0,6]x[0,100]
    -- Case 1: fully inside the window -> returned unchanged
    local x1, y1, x2, y2 = th.clipSegmentToRect(1, 10, 5, 90, 0, 6, 0, 100)
    assert(x1 == 1 and y1 == 10 and x2 == 5 and y2 == 90, "inside segment unchanged")

    -- Case 2: crosses the right edge (time window) -> cut at x=6, y interpolated
    x1, y1, x2, y2 = th.clipSegmentToRect(4, 20, 10, 80, 0, 6, 0, 100)
    assert(x1 == 4 and x2 == 6, "right edge clipped: " .. tostring(x1) .. "," .. tostring(x2))
    assert(math.abs(y2 - (20 + (80-20) * (6-4)/(10-4))) < 0.001, "right edge y interpolated: " .. tostring(y2))

    -- Case 3: entirely right of the window -> nil
    assert(th.clipSegmentToRect(8, 10, 12, 90, 0, 6, 0, 100) == nil, "fully right → nil")

    -- Case 4: crosses the left edge
    x1, y1, x2, y2 = th.clipSegmentToRect(-2, 30, 3, 60, 0, 6, 0, 100)
    assert(x1 == 0 and x2 == 3, "left edge clipped: " .. tostring(x1) .. "," .. tostring(x2))
    assert(math.abs(y1 - (30 + (60-30) * (0-(-2))/(3-(-2)))) < 0.001, "left edge y interpolated: " .. tostring(y1))

    -- Case 5: crosses the top/bottom edges (station window; shouldn't happen in theory, defensive)
    x1, y1, x2, y2 = th.clipSegmentToRect(1, 80, 5, 150, 0, 6, 0, 100)
    assert(y2 == 100, "top edge clipped: " .. tostring(y2))

    -- Case 6: spans the whole window (outside left -> outside right)
    x1, y1, x2, y2 = th.clipSegmentToRect(-5, 10, 20, 90, 0, 6, 0, 100)
    assert(x1 == 0 and x2 == 6, "crossing both edges: " .. tostring(x1) .. "," .. tostring(x2))
    assert(math.abs(y1 - (10 + (90-10) * (0-(-5))/(20-(-5)))) < 0.001, "crossing y1 interpolated")
    assert(math.abs(y2 - (10 + (90-10) * (6-(-5))/(20-(-5)))) < 0.001, "crossing y2 interpolated")

    -- Case 7: vertical segment (dx==0, guards against degeneracy)
    x1, y1, x2, y2 = th.clipSegmentToRect(3, -10, 3, 110, 0, 6, 0, 100)
    assert(x1 == 3 and x2 == 3 and y1 == 0 and y2 == 100, "vertical segment clipped: " .. tostring(y1) .. "," .. tostring(y2))
    print("  OK: helper test #7 (clipSegmentToRect Liang-Barsky)")
end)

addTest(function()
    -- Performance optimization group A regression: the "reverse lookup method" of getAllTimetableRailVehicles (given the ticked line list) must yield
    -- **the same set** as the original method (getComponent per vehicle to get its line) -- this is the correctness precondition of the optimization.
    -- Scenario: line 100 ticked (vehicles 10/11 at station), line 200 not ticked (vehicle 20), line 300 without entries (vehicle 30);
    -- vehicle 99 is an invalid ID left over in the snapshot.
    local saved = {
        getComponent = api.engine.getComponent,
        entityExists = api.engine.entityExists,
        tvSystem = api.engine.system.transportVehicleSystem,
    }
    local terminalList = { 10, 11, 20, 30, 99 }
    api.engine.entityExists = function(id) return id ~= 99 end
    api.engine.getComponent = function(v, ctype)
        local lineOf = { [10] = 100, [11] = 100, [20] = 200, [30] = 300 }
        if ctype == 70 then return { line = lineOf[v] } end
        return nil
    end
    api.engine.system.transportVehicleSystem = {
        getVehiclesWithState = function() return terminalList end,
        -- Reverse lookup: only line 100 is in the ticked list -> its vehicles = {10, 11}
        getLineVehicles = function(line)
            if line == 100 then return { 10, 11 } end
            return {}
        end,
    }
    api.type.enum = api.type.enum or {}
    api.type.enum.TransportVehicleState = api.type.enum.TransportVehicleState or { AT_TERMINAL = "AT_TERMINAL" }
    api.type.ComponentType.TRANSPORT_VEHICLE = 70
    local hasTT = function(line) return line == 100 end

    local fast = th.getAllTimetableRailVehicles(hasTT, { 100 })
    local has = {}
    for _, id in ipairs(fast) do has[tostring(id)] = true end
    assert(#fast == 2, "line-index scan must return 2 vehicles, got " .. tostring(#fast))
    assert(has["10"] and has["11"], "line-index scan must return vehicles of the checked line")
    assert(has["20"] == nil and has["30"] == nil, "unchecked / no-entry lines excluded")
    assert(has["99"] == nil, "invalid snapshot id excluded (entityExists guard kept)")
    print("  OK: helper perf (line-index scan == component scan)")

    -- Self-check regression: if the reverse lookup disagrees with the actual ownership (getLineVehicles misses a vehicle), it must automatically fall back to the original method and give
    -- the correct result (better slow than controlling too few vehicles).
    api.engine.system.transportVehicleSystem.getLineVehicles = function(line) return {} end
    -- Note: the self-check only gets a chance every 60s; here we just call again -- the previous call set nextCheckAt to now+60,
    -- so the os.clock stub pushes time far ahead to make sure this call triggers the self-check.
    local realClock = os.clock
    os.clock = function() return (realClock() or 0) + 1000 end
    local fallback = th.getAllTimetableRailVehicles(hasTT, { 100 })
    os.clock = realClock
    local n = 0
    for _, id in ipairs(fallback) do if tostring(id) == "10" or tostring(id) == "11" then n = n + 1 end end
    assert(n == 2, "on mismatch must fall back to component scan (got " .. tostring(#fallback) .. " vehicles)")
    print("  OK: helper perf (self-check falls back on mismatch)")

    api.engine.getComponent = saved.getComponent
    api.engine.entityExists = saved.entityExists
    api.engine.system.transportVehicleSystem = saved.tvSystem
end)

return {
    test = function()
        for _, t in ipairs(tests) do t() end
        if failCount > 0 then
            print("HELPER TESTS: " .. tostring(failCount) .. " FAILURES / " .. testCount)
        else
            print("HELPER TESTS: all " .. testCount .. " passed")
        end
    end,
}
