package.loaded["celmi/timetables/timetable_helper"] = {}

local timetable = require ".res.scripts.celmi.timetables.timetable"

local timetableTests = {}

timetableTests[#timetableTests + 1] = function()
    local x = { testfield = 0 }
    timetable.setTimetableObject(x)
    local y = timetable.getTimetableObject()
    assert(x.testfield == y.testfield, "Error while setting and retriving the same object from the timetable")
end

timetableTests[#timetableTests + 1] = function()
    timetable.setTimetableObject({})
    local x = timetable.getTimeDifference(0,0)
    assert(x == 0, "Difference between same time should be 0")
    x = timetable.getTimeDifference(5,5)
    assert(x == 0, "Difference between same time should be 0")
    x = timetable.getTimeDifference(59,60)
    assert(x == 1, "Difference between 2 times should be 1")
    x = timetable.getTimeDifference(60,59)
    assert(x == 1, "Difference between 2 times should be 1")
    x = timetable.getTimeDifference(10,5)
    assert(x == 5, "Difference between 2 times should be 5")
    x = timetable.getTimeDifference(0,5)
    assert(x == 5, "Difference between 2 times should be 5")
    x = timetable.getTimeDifference(3300,300)
    assert(x == 600, "Difference between 2 times should be 600")
    x = timetable.getTimeDifference(600,2400)
    assert(x == 1800, "Difference between 2 times should be 1800")
end

timetableTests[#timetableTests + 1] = function()
    timetable.setTimetableObject({})
    local x = timetable.getNextConstraint({{30,0,59,0},{9,0,59,0} },1200)
    assert(x[1] == 30 and x[2] == 0 and x[3] == 59 and x[4] == 0, "should choose the closest time constraint")
    x = timetable.getNextConstraint({{30,0,59,0},{11,0,59,0} },1200)
    assert(x[1] == 11 and x[2] == 0 and x[3] == 59 and x[4] == 0, "should choose the closest time constraint")
    x = timetable.getNextConstraint({{51,0,0,0},{50,0,59,0} },1200)
    assert(x[1] == 51 and x[2] == 0 and x[3] == 0 and x[4] == 0, "should choose the closest time constraint")
    x = timetable.getNextConstraint({{51,0,0,0},{49,0,1,0} },1200)
    assert(x[1] == 51 and x[2] == 0 and x[3] == 0 and x[4] == 0, "should choose the closest time constraint")
    x = timetable.getNextConstraint({{0,59,1,0},{1,30,1,30} },60)
    assert(x[1] == 0 and x[2] == 59 and x[3] == 1 and x[4] == 0, "should choose the closest time constraint")
    x = timetable.getNextConstraint({},1200)
    assert(x == nil, "should return nil")
end


timetableTests[#timetableTests + 1] = function()
    timetable.setTimetableObject({})
    local x = timetable.beforeDepature({29,0,30,0}, ((29 * 60) + 30), {{29,0,30,0},{39,0,40,0}})
    assert(x, "should be defore departure")
    x = timetable.beforeDepature({29,0,30,0}, ((24 * 60) + 30), {{29,0,30,0},{39,0,40,0}})
    assert(x, "should be defore departure")
    x = timetable.beforeDepature({29,0,30,0}, ((46 * 60) + 30), {{29,0,30,0},{39,0,40,0}})
    assert(x, "should be defore departure")
    x = timetable.beforeDepature({29,0,30,0}, ((31 * 60) + 30), {{29,0,30,0},{39,0,40,0}})
    assert(not x, "should be after departure")
    x = timetable.beforeDepature({29,0,30,0}, ((34 * 60) + 30), {{29,0,30,0},{39,0,40,0}})
    assert(not x, "should be after departure")
    x = timetable.beforeDepature({45,0,46,0}, ((45 * 60) + 30), {{45,0,46,0},{10,0,11,0}})
    assert(x, "should be defore departure")
    x = timetable.beforeDepature({45,0,46,0}, ((46 * 60) + 30), {{45,0,46,0},{10,0,11,0}})
    assert(not x, "should be after departure")
    x = timetable.beforeDepature({45,0,46,0}, ((1 * 60) + 30), {{45,0,46,0},{10,0,11,0}})
    assert(not x, "should be after departure")
    x = timetable.beforeDepature({45,0,46,0}, ((9 * 60) + 30), {{45,0,46,0},{10,0,11,0}})
    assert(not x, "should be after departure")
    x = timetable.beforeDepature({45,0,46,0}, ((11 * 60) + 30), {{45,0,46,0},{10,0,11,0}})
    assert(x, "should be defore departure")
    x = timetable.beforeDepature({30,0,31,0}, ((29 * 60) ), {{30,0,31,0}})
    assert(x, "should be defore departure")
    x = timetable.beforeDepature({30,0,31,0}, ((31 * 60) + 1 ), {{30,0,31,0}})
    assert(not x, "should be after departure")
    x = timetable.beforeDepature({30,0,31,0}, ((37 * 60) + 1 ), {{30,0,31,0}})
    assert(not x, "should be after departure")
end

timetableTests[#timetableTests + 1] = function()
    timetable.setTimetableObject({})
    local x = timetable.getTimeUntilNextConstraint({29,0,_,_}, {{29,0,_,_},{39,0,_,_}})
    assert(x == 10*60, "time to closest constraint should be 10 min instead of ".. x)
    x = timetable.getTimeUntilNextConstraint({29,30,_,_}, {{29,30,_,_},{30,0,_,_}})
    assert(x == 30, "time to closest constraint should be 30 sec instead of ".. x)
    x = timetable.getTimeUntilNextConstraint({29,30,_,_}, {{29,30,_,_},{30,35,_,_}})
    assert(x == 65, "time to closest constraint should be 65 sec instead of ".. x)
    x = timetable.getTimeUntilNextConstraint({30,00,_,_}, {{30,00,_,_},{25,0,_,_}})
    assert(x == 55*60, "time to closest constraint should be 55 min instead of ".. x)
    x = timetable.getTimeUntilNextConstraint({55,00,_,_}, {{55,00,_,_},{1,0,_,_}})
    assert(x == 6*60, "time to closest constraint should be 55 min instead of ".. x)
    x = timetable.getTimeUntilNextConstraint({55,00,_,_}, {{55,00,_,_},{1,0,_,_},{54,0,_,_}})
    assert(x == 6*60, "time to closest constraint should be 55 min instead of ".. x)
    x = timetable.getTimeUntilNextConstraint({55,00,_,_}, {{55,00,_,_},{1,30,_,_},{1,0,_,_},{54,0,_,_}})
    assert(x == 6*60, "time to closest constraint should be 55 min instead of ".. x)
    x = timetable.getTimeUntilNextConstraint({1,00,_,_}, {{55,00,_,_},{1,0,_,_},{54,0,_,_}})
    assert(x == 53*60, "time to closest constraint should be 55 min instead of ".. x)
    x = timetable.getTimeUntilNextConstraint({1,30,_,_}, {{55,00,_,_},{1,30,_,_},{54,0,_,_}})
    assert(x == 52*60 + 30, "time to closest constraint should be 55 min instead of ".. x)
end

timetableTests[#timetableTests + 1] = function()
    timetable.setTimetableObject({})
    -- Build currentlyWaiting in the old save format:
    --   stop entry whose outboundTime is the old scalar "timestamp shared by the whole station"
    --   stop entry missing outboundTime
    timetable.setCurrentlyWaiting({
        ["10"] = { stations = { [3] = { currentlyWaiting = {}, outboundTime = 12345 } } },
        ["20"] = { stations = { [1] = { currentlyWaiting = {} } } },
    })
    timetable.sanitizeCurrentlyWaiting()
    local cw = timetable.getCurrentlyWaiting()
    assert(type(cw["10"].stations[3].outboundTime) == "table", "scalar outboundTime should be normalized")
    assert(type(cw["10"].stations[3].currentlyWaiting) == "table", "currentlyWaiting preserved")
    assert(type(cw["20"].stations[1].outboundTime) == "table", "missing outboundTime should be created")
    assert(type(cw["20"].stations[1].currentlyWaiting) == "table", "currentlyWaiting preserved")
    print("  OK: sanitizeCurrentlyWaiting")
end

-- waitingRequired regression test: departure time passed, delay within tolerance -> must release (forceDeparture is called)
timetableTests[#timetableTests + 1] = function()
    -- Replace timetable_helper with a stub (the original stub is an empty table; waitingRequired needs getTime etc.)
    local mockTime = 3600 * 13 + 720   -- 13:12
    local mockLine = 100
    local mockStop = 1
    local forceCalls = 0
    package.loaded["celmi/timetables/timetable_helper"] = {
        getTime = function() return mockTime end,
        getCurrentLine = function() return mockLine end,
        getCurrentStation = function() return mockStop end,
        getTimeUntilDeparture = function() return 3 end,  -- door-closing countdown <5, enters the ArrDep check
        forceDeparture = function() forceCalls = forceCalls + 1 end,
    }
    -- The timetable module must be reloaded (resets module-level currentlyWaiting/timetableObject)
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"
    -- Build the timetable object: line 100 ("follow timetable" ticked), station 1 ArrDep arrival 0:00, departure 0:10
    tt.setTimetableObject({
        ["100"] = { hasTimetable = true, stations = { [1] = { conditions = { type = "ArrDep", ArrDep = { {0,0,10,0} } } } } },
    })
    tt.setCurrentlyWaiting({})
    tt.setDelayTolerance(300)  -- 5-minute tolerance

    -- Case 1: vehicle arrives 13:12 (departure 13:10 passed by 2 minutes, delay within tolerance) -> should be released with forceDeparture
    assert(tt.waitingRequired("V1") == false, "late within tolerance should release")
    assert(forceCalls >= 1, "forceDeparture must be called when releasing a late train")
    print("  OK: late-within-tolerance release triggers forceDeparture (" .. forceCalls .. " calls)")

    -- Case 2: vehicle arrives 13:16 (departure 13:10 passed by 6 minutes, beyond tolerance) -> should be held
    forceCalls = 0
    mockTime = 3600 * 13 + 960
    tt.setCurrentlyWaiting({})
    assert(tt.waitingRequired("V2") == true, "late beyond tolerance should be held to next cycle")
    assert(forceCalls == 0, "no forceDeparture when holding")
    print("  OK: late-beyond-tolerance holds to next cycle")
end

-- Departure detection guard regression test (2026-08-05, user scenario: bogus "24:28 early" on a line with multiple slot sets):
-- The user's line has two slot sets at the first station: set 1 22:30/23:30, set 2 46:30/48:00.
-- The train arrives on time at 46:30 in this cycle (set 2 chosen), but lineStopDepartures still holds the old record
-- of departing this station at 23:32 in the previous cycle. The old code treated d>0 as "this departure" -> 1412s(23:32) minus set 2's
-- planned departure 2880s(48:00) -> bogus "24:28 early" (1468s).
-- Fix: timetable.isValidDepartureRecord only accepts records "after this arrival (>=arrTime) and not later than now (<=now)".
timetableTests[#timetableTests + 1] = function()
    -- The timetable module must be reloaded (resets module-level currentlyWaiting/timetableObject)
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"

    -- Case 1 (core of the user report): train arrived 46:30 (2790s), now is 47:29 (2849s),
    -- lineStopDepartures holds the previous cycle's old record from 23:32 (1412s) -> must be rejected, not treated as "this departure"
    assert(tt.isValidDepartureRecord(1412 * 1000, 2849, 2790) == false,
        "stale departure record from previous cycle must be rejected")

    -- Case 2: actual departure 48:00 (2880s), arrival 46:30 (2790s), now is exactly 48:00 -> accepted
    assert(tt.isValidDepartureRecord(2880 * 1000, 2880, 2790) == true,
        "real departure after this visit's arrival must be accepted")

    -- Case 3: record must not be later than the current scan time (future values rejected -- a scan can't see a future departure record)
    assert(tt.isValidDepartureRecord(2990 * 1000, 2880, 2790) == false,
        "future departure record must be rejected")

    -- Case 4: d is nil / 0 -> not a departure (waiting at the station)
    assert(tt.isValidDepartureRecord(nil, 2880, 2790) == false, "nil record rejected")
    assert(tt.isValidDepartureRecord(0, 2880, 2790) == false, "zero record rejected")

    -- Case 5: missed arrival event (arrTime=nil): only <= now is checked as a fallback, real departures are not rejected
    assert(tt.isValidDepartureRecord(2880 * 1000, 2880, nil) == true,
        "arrival-missed fallback accepts a real departure")
    assert(tt.isValidDepartureRecord(1412 * 1000, 2880, nil) == true,
        "arrival-missed fallback cannot distinguish stale (best effort), value <= now accepted")

    -- Case 6: arrival earlier in the same cycle (10:00=600s), departure right after at 10:01 (601s) -> accepted
    assert(tt.isValidDepartureRecord(601 * 1000, 601, 600) == true,
        "short-dwell real departure accepted")
    print("  OK: departure record guard rejects stale / accepts real")
end

-- Multiple slot sets "set selection" regression test (user scenario): a train arriving at 46:30 must select set 2 (46:30/48:00),
-- not set 1 (22:30/23:30); and at 47:29 it is still on set 2 (doesn't jump to another set).
timetableTests[#timetableTests + 1] = function()
    package.loaded["celmi/timetables/timetable_helper"] = {}
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"
    tt.setTimetableObject({
        ["100"] = { stations = { [1] = { conditions = { type = "ArrDep", ArrDep = { {22,30,23,30}, {46,30,48,0} } } } } },
    })

    -- Set selection lives in timetable_gui's getPlannedArrDep; this replicates its algorithm to verify "nearest arrival" selection is correct for the user scenario:
    local function pickSet(actualArr)
        local bestArr, bestDep, bestDist = nil, nil, math.huge
        local conds = tt.getConditions(100, 1, "ArrDep")
        for _, c in ipairs(conds) do
            local arr = (c[1] * 60 + c[2]) % 3600
            local dep = (c[3] * 60 + c[4]) % 3600
            local k = math.floor((actualArr - arr + 1800) / 3600)
            local absArr = arr + 3600 * k
            local absDep = dep + 3600 * k
            if absDep < absArr then absDep = absDep + 3600 end
            local dist = math.abs(actualArr - absArr)
            if dist < bestDist then bestDist = dist; bestArr, bestDep = absArr, absDep end
        end
        return bestArr, bestDep
    end

    local a, d = pickSet(2790)   -- 46:30 arrival
    assert(a == 2790 and d == 2880, "arrival 46:30 must pick set2 (46:30/48:00), got arr=" .. tostring(a) .. " dep=" .. tostring(d))
    a, d = pickSet(2849)         -- 47:29 (waiting at the station)
    assert(a == 2790 and d == 2880, "at 47:29 must still be set2, got arr=" .. tostring(a) .. " dep=" .. tostring(d))
    print("  OK: multi-set selection picks set2 for 46:30 arrival")
end

-- Orphaned line filter regression test (user scenario): after deleting a line that had timetables, orphaned entries in timetableObject
-- (line entity no longer exists) must not appear in the station tab (getAllConditionsOfAllStations), and must be removed by cleanupOrphanLines.
timetableTests[#timetableTests + 1] = function()
    local existingLines = { ["100"] = true, ["200"] = true }
    local stubbedApi = {
        engine = {
            entityExists = function(id)
                return existingLines[tostring(id)] == true
            end,
            system = {
                lineSystem = {
                    getLines = function()
                        local ls = {}
                        for k in pairs(existingLines) do
                            ls[#ls + 1] = tonumber(k)
                        end
                        return ls
                    end,
                },
            },
        },
    }
    local prevApi = _G.api
    _G.api = stubbedApi
    package.loaded["celmi/timetables/timetable_helper"] = {}
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"
    tt.setTimetableObject({
        ["100"] = { stations = { [1] = { stationID = 1001, conditions = { type = "ArrDep", ArrDep = { {1,0,2,0} } } } } },
        ["200"] = { stations = { [1] = { stationID = 2001, conditions = { type = "ArrDep", ArrDep = { {3,0,4,0} } } } } },
        ["999"] = { stations = { [1] = { stationID = 9991, conditions = { type = "ArrDep", ArrDep = { {5,0,6,0} } } } } }, -- orphan: line deleted
        ["_gwNames"] = { ["gws_x"] = "test" }, -- non-line entry: kept (not treated as a line)
    })

    -- getAllConditionsOfAllStations must filter out orphaned line 999 (station tab no longer shows "ERROR" rows)
    local all = tt.getAllConditionsOfAllStations()
    assert(all[1001] and all[1001]["100"], "existing line 100 must appear by station")
    assert(all[2001] and all[2001]["200"], "existing line 200 must appear by station")
    assert(all[9991] == nil, "orphan line 999 must be filtered out from station view")
    assert(all[1001]["999"] == nil, "orphan line 999 must not be listed under station 1001/9991")

    -- getAllWaypointData filters orphaned lines as well
    local wp = tt.getAllWaypointData()
    -- 999 has no waypointTimes; this only checks it doesn't crash; the main assertions are above

    -- cleanupOrphanLines should remove orphaned entry 999 and keep 100/200 and non-numeric keys (_gwNames)
    local removed = tt.cleanupOrphanLines()
    assert(removed == 1, "cleanup must remove exactly 1 orphan line, got " .. tostring(removed))
    local obj = tt.getTimetableObject()
    assert(obj["100"] ~= nil and obj["200"] ~= nil, "existing lines must be kept after cleanup")
    assert(obj["999"] == nil, "orphan line 999 must be removed from timetableObject")
    assert(obj["_gwNames"] ~= nil, "non-line keys (global config) must be kept after cleanup")
    print("  OK: orphan line filtering + cleanup (station view no ERROR)")
    _G.api = prevApi
end

timetableTests[#timetableTests + 1] = function()
    -- Diagram settings persistence getters/setters (time scale / punctuality threshold / auto refresh)
    local saved = {
        ts = _G._diagramTimeScale,
        pt = _G._diagramPunctThreshold,
        ar = _G._diagramAutoRefresh,
    }
    _G._diagramTimeScale = nil
    _G._diagramPunctThreshold = nil
    _G._diagramAutoRefresh = nil
    timetable.setTimetableObject({})

    assert(timetable.getTimeScale() == 5, "default time scale must be 5, got " .. tostring(timetable.getTimeScale()))
    assert(timetable.getPunctThreshold() == 10, "default punct threshold must be 10, got " .. tostring(timetable.getPunctThreshold()))
    assert(timetable.getDiagramAutoRefresh() == false, "default auto refresh must be false")

    timetable.setTimeScale(2)
    assert(timetable.getTimeScale() == 2, "time scale 2 round trip")
    timetable.setPunctThreshold(30)
    assert(timetable.getPunctThreshold() == 30, "punct threshold 30 round trip")
    timetable.setDiagramAutoRefresh(true)
    assert(timetable.getDiagramAutoRefresh() == true, "auto refresh true round trip")

    -- Settings must be written to timetableObject (persisted with the save); after clearing _G (simulating load/module reload) they can still be restored
    local to = timetable.getTimetableObject()
    assert(to._diagramTimeScale == 2 and to._diagramPunctThreshold == 30 and to._diagramAutoRefresh == true,
        "settings must be stored in timetableObject for persistence")
    _G._diagramTimeScale = nil
    _G._diagramPunctThreshold = nil
    _G._diagramAutoRefresh = nil
    assert(timetable.getTimeScale() == 2, "time scale must survive _G reset (read from timetableObject)")
    assert(timetable.getPunctThreshold() == 30, "punct threshold must survive _G reset")
    assert(timetable.getDiagramAutoRefresh() == true, "auto refresh must survive _G reset")

    -- Invalid values are clamped
    timetable.setTimeScale(7)
    assert(timetable.getTimeScale() == 5, "invalid scale 7 must coerce to 5")
    timetable.setTimeScale(99)
    assert(timetable.getTimeScale() == 5, "invalid scale 99 must coerce to 5")
    timetable.setPunctThreshold(-5)
    assert(timetable.getPunctThreshold() == 0, "punct threshold -5 must clamp to 0")
    timetable.setPunctThreshold(999)
    assert(timetable.getPunctThreshold() == 60, "punct threshold 999 must clamp to 60")

    _G._diagramTimeScale = saved.ts
    _G._diagramPunctThreshold = saved.pt
    _G._diagramAutoRefresh = saved.ar
    print("  OK: settings get/set + persistence (time scale / punct threshold / auto refresh)")
end

timetableTests[#timetableTests + 1] = function()
    -- Running direction filter getter/setter (_diagramPolylineFilter, all/up/down)
    local saved = _G._diagramPolylineFilter
    _G._diagramPolylineFilter = nil
    timetable.setTimetableObject({})

    assert(timetable.getPolylineFilter() == "all", "default polyline filter must be 'all', got " .. tostring(timetable.getPolylineFilter()))
    timetable.setPolylineFilter("up")
    assert(timetable.getPolylineFilter() == "up", "polyline filter 'up' round trip")
    local to = timetable.getTimetableObject()
    assert(to._diagramPolylineFilter == "up", "polyline filter must be stored in timetableObject for persistence")
    _G._diagramPolylineFilter = nil
    assert(timetable.getPolylineFilter() == "up", "polyline filter must survive _G reset (read from timetableObject)")

    timetable.setPolylineFilter("down")
    assert(timetable.getPolylineFilter() == "down", "polyline filter 'down' round trip")
    timetable.setPolylineFilter("sideways")
    assert(timetable.getPolylineFilter() == "all", "invalid polyline filter must coerce to 'all'")

    _G._diagramPolylineFilter = saved
    print("  OK: polyline direction filter get/set + persistence")
end

timetableTests[#timetableTests + 1] = function()
    -- Cross-thread sync safeguard: hasLineEntries decides "whether the table has line entries"
    -- Numeric/string line keys match; settings keys (_diagram*), _gwNames and empty tables don't.
    assert(timetable.hasLineEntries({ ["35110"] = {} }) == true, "string line key must count as line entry")
    assert(timetable.hasLineEntries({ [35110] = {} }) == true, "number line key must count as line entry")
    assert(timetable.hasLineEntries({ ["_diagramTimeScale"] = 5, ["_diagramAutoRefresh"] = false }) == false,
        "settings-only table must NOT count as line entries")
    assert(timetable.hasLineEntries({ ["_gwNames"] = {} }) == false, "_gwNames-only table must NOT count as line entries")
    assert(timetable.hasLineEntries({}) == false, "empty table must NOT count as line entries")
    assert(timetable.hasLineEntries(nil) == false, "nil must NOT count as line entries")

    -- hasAnyPreset: matches only if some line has a non-empty dp.presetList; empty / no dp / empty presets don't match
    assert(timetable.hasAnyPreset({ ["35110"] = { dp = { presetList = { {id="1",name="x"} } } } }) == true,
        "line with non-empty presetList must count as preset")
    assert(timetable.hasAnyPreset({ ["35110"] = { dp = { presetList = {} } } }) == false,
        "empty presetList must NOT count as preset")
    assert(timetable.hasAnyPreset({ ["35110"] = { dp = {} } }) == false, "dp without presetList must NOT count")
    assert(timetable.hasAnyPreset({ ["35110"] = {} }) == false, "line without dp must NOT count")
    assert(timetable.hasAnyPreset({}) == false, "empty table must NOT count as preset")
    assert(timetable.hasAnyPreset(nil) == false, "nil must NOT count as preset")
    print("  OK: hasLineEntries + hasAnyPreset (sync-safety guards)")
end

timetableTests[#timetableTests + 1] = function()
    -- Data sync (number->string migration) regression test: the old mod stored line timetables with numeric keys;
    -- migrateNumberLineKeys should migrate them to string keys, appending without overwriting (all slot sets kept),
    -- non-line string keys (_gwNames etc.) are kept as is, and the per-station "added sets" counts in the report are correct.
    -- Case 1: pure number save -> after migration string keys are readable, number keys cleared, report counts correct
    timetable.setTimetableObject({
        [100] = { hasTimetable = true, stations = {
            [1] = { stationID = 1001, conditions = { type = "ArrDep", ArrDep = { {1,0,2,0}, {3,0,4,0} } } },
            [2] = { stationID = 1002, conditions = { type = "ArrDep", ArrDep = { {5,0,6,0} } } },
        } },
    })
    local r = timetable.migrateNumberLineKeys()
    local obj = timetable.getTimetableObject()
    assert(obj[100] == nil, "number key must be removed after migration")
    assert(obj["100"] ~= nil, "string key must exist after migration")
    assert(obj["100"].stations[1].conditions.ArrDep[2][1] == 3, "ArrDep slots preserved after migration")
    assert(r.totalSlots == 3, "totalSlots must be 3, got " .. tostring(r.totalSlots))
    assert(r.lines["100"][1] == 2 and r.lines["100"][2] == 1, "per-station added counts correct")

    -- Case 2: number and string coexist -> append without overwriting, existing string data kept, _gwNames kept as is
    timetable.setTimetableObject({
        [100] = { hasTimetable = true, stations = {
            [1] = { conditions = { type = "ArrDep", ArrDep = { {1,0,2,0} } } },
            [2] = { conditions = { type = "ArrDep", ArrDep = { {5,0,6,0} } } },
        } },
        ["100"] = { hasTimetable = true, stations = {
            [1] = { conditions = { type = "ArrDep", ArrDep = { {9,0,10,0} } } },
        } },
        ["_gwNames"] = { ["gws_x"] = "test" },
    })
    local r2 = timetable.migrateNumberLineKeys()
    local obj2 = timetable.getTimetableObject()
    assert(obj2[100] == nil, "number key must be removed (both-exist case)")
    assert(obj2["_gwNames"] ~= nil and obj2["_gwNames"]["gws_x"] == "test", "_gwNames must be preserved")
    local arr1 = obj2["100"].stations[1].conditions.ArrDep
    assert(#arr1 == 2, "station1 ArrDep must be appended (1 existing + 1 imported), got " .. tostring(#arr1))
    assert(arr1[1][1] == 9 and arr1[2][1] == 1, "existing string slot kept first, number slot appended after")
    assert(obj2["100"].stations[2] ~= nil, "station2 (only in number) must be copied over")
    assert(obj2["100"].stations[2].conditions.ArrDep[1][1] == 5, "copied station2 ArrDep preserved")
    assert(r2.lines["100"][1] == 1 and r2.lines["100"][2] == 1, "report per-station counts for both-exist case")
    assert(r2.totalSlots == 2, "totalSlots must be 2, got " .. tostring(r2.totalSlots))

    -- Case 3: no number keys -> idempotent, totalSlots == 0, pure string table unchanged
    timetable.setTimetableObject({
        ["200"] = { stations = { [1] = { conditions = { type = "ArrDep", ArrDep = { {1,0,2,0} } } } } },
    })
    local r3 = timetable.migrateNumberLineKeys()
    assert(r3.totalSlots == 0, "no number keys → totalSlots 0")
    assert(timetable.getTimetableObject()["200"] ~= nil, "string-only table unchanged")
    print("  OK: migrateNumberLineKeys (number→string append migration + report)")
end

-- Vehicle control switch regression test (user report): when a line doesn't have "follow timetable" ticked (hasTimetable=false),
-- waitingRequired must return false (don't hold), even if the line has leftover station time data.
-- Previously there was no hasTimetable check -> trains of unticked lines were held via setVehicleManualDeparture(true) after arrival
-- and never departed (only the moment of ticking and unticking let startAllLineVehicles release them -> players saw
-- "departs only after unticking"). Final user decision: unticked lines load/unload and depart as the game does by default; only ticked lines are controlled.
timetableTests[#timetableTests + 1] = function()
    local mockTime = 3600 * 13 + 300   -- 13:05 (departure 13:10 not reached -> the old logic would hold until the departure time)
    local forceCalls = 0
    package.loaded["celmi/timetables/timetable_helper"] = {
        getTime = function() return mockTime end,
        getCurrentLine = function() return 100 end,
        getCurrentStation = function() return 1 end,
        getTimeUntilDeparture = function() return 3 end,  -- door-closing countdown <5, enters the ArrDep check
        forceDeparture = function() forceCalls = forceCalls + 1 end,
    }
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"

    -- Case 1: line exists but unticked (hasTimetable=false), leftover ArrDep data at the station -> not held, no forced departure
    tt.setTimetableObject({
        ["100"] = { hasTimetable = false, stations = { [1] = { conditions = { type = "ArrDep", ArrDep = { {0,0,10,0} } } } } },
    })
    tt.setCurrentlyWaiting({})
    assert(tt.waitingRequired("V1") == false, "unchecked line must not hold the train")
    assert(forceCalls == 0, "unchecked line must not forceDeparture either")

    -- Case 2: line has no timetable entries (never scheduled) -> not held
    tt.setTimetableObject({})
    tt.setCurrentlyWaiting({})
    assert(tt.waitingRequired("V1") == false, "line without timetable entry must not hold the train")

    -- Case 3: ticked (hasTimetable=true) + departure time not reached -> held normally (contrast: only ticked lines are controlled)
    tt.setTimetableObject({
        ["100"] = { hasTimetable = true, stations = { [1] = { conditions = { type = "ArrDep", ArrDep = { {0,0,10,0} } } } } },
    })
    tt.setCurrentlyWaiting({})
    assert(tt.waitingRequired("V1") == true, "checked line must hold until departure time")
    print("  OK: unchecked line not controlled (hasTimetable gate)")
end

-- Leftover hold cleanup regression (2026-08-16 diagnosis): the manualDeparture flag set by old mod versions is persisted with the save;
-- vehicles of unticked lines with entries have autoDeparture=false -> clearStaleHolds must clear it;
-- vehicles of ticked lines / lines without entries / with autoDeparture=true already are left alone.
timetableTests[#timetableTests + 1] = function()
    local cmdCalls = {}
    local fleetScanCalls = 0
    local prevApi = _G.api
    _G.api = {
        engine = {
            entityExists = function(id) return true end,
            getComponent = function(id, ctype)
                if ctype == 70 then
                    local autoOf = { [10] = false, [11] = true, [20] = false, [21] = true }
                    if autoOf[id] ~= nil then return { autoDeparture = autoOf[id] } end
                end
                return nil
            end,
            system = {
                transportVehicleSystem = {
                    -- Performance optimization group A (2026-08-16, round 21): clearStaleHolds is now "candidate driven" --
                    -- it first finds lines "with entries but unticked" in plain Lua, then fetches vehicles per line; no more scanning all vehicles at stations worldwide.
                    getLineVehicles = function(line)
                        if line == 100 then return { 10, 11 } end
                        if line == 200 then return { 20, 21 } end
                        return { 30 }   -- line 300 has no entries -> no candidate, must not be queried
                    end,
                    getVehiclesWithState = function() fleetScanCalls = fleetScanCalls + 1 return { 10, 11, 20, 30 } end,
                },
            },
        },
        type = {
            enum = { TransportVehicleState = { AT_TERMINAL = 1 } },
            ComponentType = { TRANSPORT_VEHICLE = 70 },
        },
        cmd = {
            make = { setVehicleManualDeparture = function(v, m) cmdCalls[#cmdCalls + 1] = { v, m } end },
            sendCommand = function() end,
        },
    }
    package.loaded["celmi/timetables/timetable_helper"] = {}
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"
    tt.setTimetableObject({
        ["100"] = { hasTimetable = true, stations = {} },   -- ticked: left alone (controlled normally by the coroutine)
        ["200"] = { hasTimetable = false, stations = {} },  -- unticked + has entries: clear
        -- 300 has no entries: not cleared (this mod never held it)
    })
    local n = tt.clearStaleHolds()
    -- 10: line 100 ticked -> not cleared; 11: line 100 ticked -> not cleared (autoDeparture=true is not cleared either)
    -- 20: line 200 unticked + autoDeparture=false -> cleared; 21: same line but autoDeparture=true -> not cleared
    -- 30: line 300 has no entries -> not cleared
    assert(n == 1, "exactly 1 stale hold cleared, got " .. tostring(n))
    assert(#cmdCalls == 1 and cmdCalls[1][1] == 20 and cmdCalls[1][2] == false,
        "clearStaleHolds must send setVehicleManualDeparture(20, false)")
    assert(fleetScanCalls == 0, "candidate-driven clearStaleHolds must not scan the whole fleet, got "
        .. tostring(fleetScanCalls))
    -- Zero cost without candidates: mark all entries as ticked -> there must be no getLineVehicles / fleet scan at all
    tt.setTimetableObject({ ["100"] = { hasTimetable = true, stations = {} } })
    local n2 = tt.clearStaleHolds()
    assert(n2 == 0 and fleetScanCalls == 0, "no candidate lines → no scan at all")
    print("  OK: clearStaleHolds (candidate-driven stale manualDeparture cleanup)")
    _G.api = prevApi
end

-- Merged 5s maintenance regression (performance optimization group A): maintainTimetableData must
--   * call getLines() only once;
--   * use it for both orphan cleanup and station reconciliation (no more entityExists per line);
--   * return values with the same semantics as the two original calls (removed count + reconciliation stats).
timetableTests[#timetableTests + 1] = function()
    local getLinesCalls, entityExistsCalls = 0, 0
    local prevApi = _G.api
    _G.api = {
        engine = {
            entityExists = function(id) entityExistsCalls = entityExistsCalls + 1 return true end,
            getComponent = function(id, ctype)
                if ctype == 60 then  -- LINE
                    if id == 100 then
                        return { stops = { [1] = { stationGroup = 1001 }, [2] = { stationGroup = 1002 } } }
                    end
                end
                return nil
            end,
            system = {
                lineSystem = {
                    getLines = function() getLinesCalls = getLinesCalls + 1 return { 100 } end,  -- 999 is an orphan
                },
            },
        },
        type = { ComponentType = { LINE = 60 } },
    }
    package.loaded["celmi/timetables/timetable_helper"] = {}
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"
    tt.setTimetableObject({
        ["100"] = { hasTimetable = true, stations = {
            [2] = { stationID = 1002, conditions = { type = "ArrDep", ArrDep = { {3,0,4,0} } } },  -- moves to 2
            [5] = { stationID = 1001, conditions = { type = "ArrDep", ArrDep = { {1,0,2,0} } } },  -- moves to 1
        } },
        ["999"] = { hasTimetable = true, stations = {} },   -- line deleted -> orphan, should be removed
    })
    tt.setCurrentlyWaiting({})
    local removed, stats = tt.maintainTimetableData()
    local obj = tt.getTimetableObject()
    assert(getLinesCalls == 1, "getLines must be called exactly once per maintenance pass, got "
        .. tostring(getLinesCalls))
    assert(entityExistsCalls == 0, "reconcile with validSet must not call entityExists per line, got "
        .. tostring(entityExistsCalls))
    assert(removed == 1, "orphan line 999 removed, got " .. tostring(removed))
    assert(obj["999"] == nil, "orphan line entry must be gone")
    assert(stats and stats.rekeyed == 1, "reconcile stats passed through (rekeyed=1: 1001 moved 5→1), got "
        .. tostring(stats and stats.rekeyed))
    assert(obj["100"].stations[1] and obj["100"].stations[1].stationID == 1001, "1001 rekeyed to 1")
    assert(obj["100"].stations[2] and obj["100"].stations[2].stationID == 1002, "1002 rekeyed to 2")
    print("  OK: maintainTimetableData (single getLines + paired reconcile)")
    _G.api = prevApi
end

-- Station/line structure reconciliation regression (2026-08-16 final design): after removing a station the game renumbers the line's stops,
-- and time data stored by position becomes misaligned. reconcileStationData must:
--   * move data of surviving stations (stationID still on the line) to their new position (time content unchanged);
--   * delete data of removed stations (stationID not on the line);
--   * delete old data without stationID;
--   * pair repeated occurrences of the same station group on loop lines in order;
--   * clear currentlyWaiting leftovers of deleted positions.
timetableTests[#timetableTests + 1] = function()
    local prevApi = _G.api
    _G.api = {
        engine = {
            entityExists = function(id) return id == 100 or id == 200 end,
            getComponent = function(id, ctype)
                if ctype == 60 then  -- LINE
                    if id == 100 then
                        -- originally A B C D E, C(1003) removed -> now A B D E
                        return { stops = { [1] = { stationGroup = 1001 }, [2] = { stationGroup = 1002 },
                                           [3] = { stationGroup = 1004 }, [4] = { stationGroup = 1005 } } }
                    elseif id == 200 then
                        -- loop line: station group 2001 appears twice (positions 1/2), 2002 once
                        return { stops = { [1] = { stationGroup = 2001 }, [2] = { stationGroup = 2001 },
                                           [3] = { stationGroup = 2002 } } }
                    end
                end
                return nil
            end,
        },
        type = { ComponentType = { LINE = 60 } },
    }
    package.loaded["celmi/timetables/timetable_helper"] = {}
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"
    tt.setTimetableObject({
        ["100"] = { hasTimetable = true, stations = {
            [1] = { stationID = 1001, conditions = { type = "ArrDep", ArrDep = { {1,0,2,0} } } },
            [2] = { stationID = 1002, conditions = { type = "ArrDep", ArrDep = { {3,0,4,0} } } },
            [3] = { stationID = 1003, conditions = { type = "ArrDep", ArrDep = { {5,0,6,0} } } },  -- removed
            [4] = { stationID = 1004, conditions = { type = "ArrDep", ArrDep = { {7,0,8,0} } } },  -- moves to 3
            [5] = { stationID = 1005, conditions = { type = "ArrDep", ArrDep = { {9,0,10,0} } } }, -- moves to 4
            [6] = { noSid = true },  -- old data without stationID -> delete
        } },
        ["200"] = { hasTimetable = true, stations = {
            [2] = { stationID = 2001, conditions = { type = "ArrDep", ArrDep = { {11,0,12,0} } } },
            [5] = { stationID = 2001, conditions = { type = "ArrDep", ArrDep = { {13,0,14,0} } } },
            [7] = { stationID = 2004, conditions = { type = "ArrDep", ArrDep = { {15,0,16,0} } } }, -- no longer on the loop line -> delete
        } },
    })
    tt.setCurrentlyWaiting({
        ["100"] = { stations = { [3] = { currentlyWaiting = { ["v1"] = {} }, outboundTime = {} },
                                 [4] = { currentlyWaiting = {}, outboundTime = {} } } },
    })

    local stats = tt.reconcileStationData()
    local obj = tt.getTimetableObject()

    assert(stats.rekeyed == 4, "rekeyed should be 4 (D,E on 100 + 2 on 200), got " .. tostring(stats.rekeyed))
    assert(stats.removed == 3, "removed should be 3 (C, noSid, 2004), got " .. tostring(stats.removed))
    -- Line 100
    assert(obj["100"].stations[1].stationID == 1001, "A stays at 1")
    assert(obj["100"].stations[2].stationID == 1002, "B stays at 2")
    assert(obj["100"].stations[3] and obj["100"].stations[3].stationID == 1004, "D rekeyed to 3")
    assert(obj["100"].stations[4] and obj["100"].stations[4].stationID == 1005, "E rekeyed to 4")
    assert(obj["100"].stations[3].conditions.ArrDep[1][1] == 7, "D's times preserved")
    assert(obj["100"].stations[4].conditions.ArrDep[1][1] == 9, "E's times preserved")
    assert(obj["100"].stations[5] == nil and obj["100"].stations[6] == nil, "C and noSid removed")
    -- Line 200 loop pairing
    assert(obj["200"].stations[1] and obj["200"].stations[1].stationID == 2001, "2001 first → 1")
    assert(obj["200"].stations[2] and obj["200"].stations[2].stationID == 2001, "2001 second → 2")
    assert(obj["200"].stations[1].conditions.ArrDep[1][1] == 11, "first 2001 times preserved")
    assert(obj["200"].stations[2].conditions.ArrDep[1][1] == 13, "second 2001 times preserved")
    assert(obj["200"].stations[7] == nil, "2004 (off line) removed")
    -- currentlyWaiting leftovers: deleted position 3 is cleared
    local cw = tt.getCurrentlyWaiting()
    assert(cw["100"].stations[3] == nil, "currentlyWaiting for removed pos 3 cleared")
    _G.api = prevApi
    print("  OK: reconcileStationData (rekey / drop deleted / noSid / loop pairing)")
end

-- Read validation regression (2026-08-16 final design): in the window between two reconciliations after removing/building stations,
-- waitingRequired must reject "misaligned" data (saved stationID ~= actual station at the current position -> not held).
timetableTests[#timetableTests + 1] = function()
    local mockTime = 3600 * 13 + 300   -- 13:05 (departure 13:10 not reached -> would normally be held)
    local mockLine = 100
    local mockStop = 1
    local forceCalls = 0
    local mockLiveSid = 1002  -- actual station at the current position (doesn't match saved stationID=1001 -> should be rejected)
    package.loaded["celmi/timetables/timetable_helper"] = {
        getTime = function() return mockTime end,
        getCurrentLine = function() return mockLine end,
        getCurrentStation = function() return mockStop end,
        getTimeUntilDeparture = function() return 3 end,
        getStationID = function() return mockLiveSid end,
        forceDeparture = function() forceCalls = forceCalls + 1 end,
    }
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"
    tt.setTimetableObject({
        ["100"] = { hasTimetable = true, stations = { [1] = { stationID = 1001, conditions = { type = "ArrDep", ArrDep = { {0,0,10,0} } } } } },
    })
    tt.setCurrentlyWaiting({})

    -- Case 1: saved stationID=1001 ~= current position 1002 -> rejected (not held, no forced departure)
    assert(tt.waitingRequired("V1") == false, "mismatched stationID must not hold the train")
    assert(forceCalls == 0, "mismatched stationID must not forceDeparture")

    -- Case 2: match -> held until the departure time as usual
    mockLiveSid = 1001
    tt.setCurrentlyWaiting({})
    assert(tt.waitingRequired("V1") == true, "matched stationID must hold until departure")
    print("  OK: waitingRequired rejects position-mismatched station data")
end

-- Auto-generate slots by interval helpers regression (2026-08-16 feature):
-- shiftTime shifting (modulo 1 hour/wrapping around the hour), shiftSlot whole-slot shifting, removeAllConditions clears but keeps type.
timetableTests[#timetableTests + 1] = function()
    package.loaded["celmi/timetables/timetable_helper"] = {}
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"

    -- shiftTime: shift + wrap around the hour (minutes 0-59)
    local a = tt.shiftTime({0, 0}, 60)
    assert(a[1] == 1 and a[2] == 0, "0:00 + 1m = 1:00")
    local b = tt.shiftTime({59, 30}, 60)
    assert(b[1] == 0 and b[2] == 30, "59:30 + 1m wraps to 0:30, got " .. b[1] .. ":" .. b[2])
    local c = tt.shiftTime({28, 45}, 60 * 30)
    assert(c[1] == 58 and c[2] == 45, "28:45 + 30m = 58:45")

    -- shiftSlot: {0,0,10,0} + 10min -> {10,0,20,0}
    local s = tt.shiftSlot({0, 0, 10, 0}, 10 * 60)
    assert(s[1] == 10 and s[2] == 0 and s[3] == 20 and s[4] == 0,
        "shiftSlot +10min: " .. s[1] .. ":" .. s[2] .. "-" .. s[3] .. ":" .. s[4])

    -- removeAllConditions: clears the ArrDep array, keeps conditions.type=ArrDep
    tt.setTimetableObject({
        ["100"] = { stations = { [1] = { conditions = { type = "ArrDep", ArrDep = { {1,0,2,0}, {3,0,4,0} } } } } },
    })
    tt.removeAllConditions(100, 1, "ArrDep")
    local conds = tt.getConditions(100, 1, "ArrDep")
    assert(type(conds) == "table" and #conds == 0, "ArrDep array cleared")
    assert(tt.getConditionType(100, 1) == "ArrDep", "condition type preserved after clear")
    print("  OK: shiftTime / shiftSlot / removeAllConditions (auto-interval helpers)")
end

-- Per-line vehicle control switch regression (2026-08-16 feature, following 3625975189): depart on time / minimum dwell time / maximum dwell time.
--   * getter defaults: no entry / old save missing fields -> force=true, min/max=false;
--   * setter round trip + persisted to timetableObject[line];
--   * force=true (default): release within delay tolerance = forced departure (forceDeparture called), and min/max are ignored even if ticked;
--   * force=false: same scenario releases normally (forceDeparture not called, the engine leaves when loading is done);
--   * force=false + Min: arrival+minWaitingTime not reached -> keep holding; reached -> normal release;
--   * force=false + Max: at arrival+maxWaitingTime -> forced departure even when late beyond tolerance (max overrides "hold until the next run");
--   * force=false + no min/max + late beyond tolerance -> still held until the next run (force=false ~= always release).
timetableTests[#timetableTests + 1] = function()
    local mockTime = 3600 * 13 + 300         -- 13:05 (baseline, overwritten before each case)
    local mockLine = 100
    local mockStop = 1
    local mockDoorsArrival = 3600 * 13 + 60  -- vehicle arrival time (doorsTime, microseconds), reference for min/max checks
    local dwellMin = 0
    local dwellMax = 0
    local forceCalls = 0
    package.loaded["celmi/timetables/timetable_helper"] = {
        getTime = function() return mockTime end,
        getCurrentLine = function() return mockLine end,
        getCurrentStation = function() return mockStop end,
        getTimeUntilDeparture = function() return 3 end,  -- door-closing countdown <5s: the gate doesn't release early
        getStationID = function() return 1001 end,
        forceDeparture = function() forceCalls = forceCalls + 1 end,
    }
    local prevApi = _G.api
    _G.api = {
        engine = {
            entityExists = function() return true end,
            getComponent = function(id, ctype)
                if ctype == 60 then  -- LINE: the engine's native Line.Stop dwell limits
                    return { stops = { [1] = { minWaitingTime = dwellMin, maxWaitingTime = dwellMax } } }
                elseif ctype == 70 then  -- TRANSPORT_VEHICLE: doorsTime (microseconds)
                    return { doorsTime = mockDoorsArrival * 1000000 }
                end
                return nil
            end,
        },
        type = { ComponentType = { LINE = 60, TRANSPORT_VEHICLE = 70 } },
    }
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"
    tt.setDelayTolerance(300)  -- explicitly 5 minutes, guards against leftovers in _G

    -- 1) getter defaults (no entry / old save missing fields)
    tt.setTimetableObject({})
    assert(tt.getForceDepartureEnabled(100) == true, "default forceDeparture must be true")
    assert(tt.getMinWaitEnabled(100) == false, "default minWait must be false")
    assert(tt.getMaxWaitEnabled(100) == false, "default maxWait must be false")
    tt.setTimetableObject({ ["100"] = { hasTimetable = true, stations = {} } })
    assert(tt.getForceDepartureEnabled(100) == true, "old save (no field): forceDeparture default true")
    assert(tt.getMinWaitEnabled(100) == false, "old save (no field): minWait default false")

    -- 2) setter round trip + persistence
    tt.setForceDepartureEnabled(100, false)
    tt.setMinWaitEnabled(100, true)
    tt.setMaxWaitEnabled(100, true)
    assert(tt.getForceDepartureEnabled(100) == false, "forceDeparture=false round trip")
    assert(tt.getMinWaitEnabled(100) == true, "minWait=true round trip")
    assert(tt.getMaxWaitEnabled(100) == true, "maxWait=true round trip")
    local savedEntry = tt.getTimetableObject()["100"]
    assert(savedEntry.forceDeparture == false and savedEntry.minWaitEnabled == true and savedEntry.maxWaitEnabled == true,
        "line switches must persist in timetableObject[line]")

    -- ===== waitingRequired behavior =====
    -- Time slot {10,0,10,0}: arrival 13:10, departure 13:10 (modulo hour) -> absolute departure 13:10:00 (= 46800+600 = 47400s)
    local function objWith(force, min, max)
        return { ["100"] = { hasTimetable = true, forceDeparture = force, minWaitEnabled = min, maxWaitEnabled = max,
            stations = { [1] = { stationID = 1001,
                conditions = { type = "ArrDep", ArrDep = { {10,0,10,0} } } } } } }
    end
    local function resetWaiting()
        tt.setCurrentlyWaiting({})
        forceCalls = 0
    end

    -- 3) force=true (with min/max also ticked) -> min/max ignored, forced departure on time within delay tolerance
    tt.setTimetableObject(objWith(true, true, true))
    mockTime = 3600 * 13 + 645   -- 13:10:45 (45s late <= tolerance 300)
    resetWaiting()
    assert(tt.waitingRequired("V1") == false, "force=true late-within-tolerance must release")
    assert(forceCalls == 1, "force=true release must forceDeparture (got " .. tostring(forceCalls) .. ")")

    -- 4) force=false (min/max off) -> same scenario releases normally, no forced departure
    tt.setTimetableObject(objWith(false, false, false))
    mockTime = 3600 * 13 + 645
    resetWaiting()
    assert(tt.waitingRequired("V1") == false, "force=false late-within-tolerance must release")
    assert(forceCalls == 0, "force=false release must NOT forceDeparture (engine loads then leaves)")

    -- 5) force=false + Min: arrival 13:10:30 + min 120s = keep holding before 13:12:30 (minimum not reached when loading is done)
    tt.setTimetableObject(objWith(false, true, false))
    mockDoorsArrival = 3600 * 13 + 630   -- 13:10:30 arrival
    dwellMin = 120
    mockTime = 3600 * 13 + 690   -- 13:11:30 (90s late, within tolerance, but min not reached)
    resetWaiting()
    assert(tt.waitingRequired("V1") == true, "min not satisfied must keep holding")
    assert(forceCalls == 0, "min hold must not forceDeparture")

    -- 6) Same config, min reached (13:12:45 >= 13:12:30) -> normal release
    mockTime = 3600 * 13 + 765   -- 13:12:45
    resetWaiting()
    assert(tt.waitingRequired("V1") == false, "min satisfied must release")
    assert(forceCalls == 0, "min satisfied release must be plain (no forceDeparture)")

    -- 7) force=false + Max: arrival 13:10:30 + max 300s = 13:15:30; 13:16:00 (360s late, beyond tolerance)
    --    -> max overrides "hold until the next run", forced departure on time
    tt.setTimetableObject(objWith(false, true, true))
    mockDoorsArrival = 3600 * 13 + 630
    dwellMin = 120
    dwellMax = 300
    mockTime = 3600 * 13 + 960   -- 13:16:00
    resetWaiting()
    assert(tt.waitingRequired("V1") == false, "max reached must release even beyond tolerance")
    assert(forceCalls == 1, "max reached must forceDeparture (got " .. tostring(forceCalls) .. ")")

    -- 8) force=false + no min/max + late beyond tolerance -> still held until the next run (not always released)
    tt.setTimetableObject(objWith(false, false, false))
    mockTime = 3600 * 13 + 960   -- 13:16:00, 360s late > tolerance 300
    resetWaiting()
    assert(tt.waitingRequired("V1") == true, "late beyond tolerance (force=false) must hold to next slot")
    assert(forceCalls == 0, "beyond-tolerance hold must not forceDeparture")

    _G.api = prevApi
    print("  OK: line control switches (force departure / min wait / max wait)")
end

-- Maximum dwell time semantics refinement regression (2026-08-16 player decision): max is not "blindly force departure at arrival+M", but
--   (1) still at the station M after arrival (this run's departure time passed: beyond tolerance waiting for the next run / loading ran past the time) -> forced departure;
--   (2) vehicles that arrived before the departure time and are held until then leave as soon as the time comes -> forced departure (loading cut short on time);
--   departure time not reached -> never force departure early (early vehicles wait for their time, no early departures);
--   late but loading quickly (within tolerance) -> normal release "leave when loaded"; max doesn't cover this.
timetableTests[#timetableTests + 1] = function()
    local mockTime = 3600 * 13 + 300
    local mockLine = 100
    local mockStop = 1
    local mockDoorsArrival = 3600 * 13  -- arrival time (doorsTime, microseconds)
    local dwellMin = 0
    local dwellMax = 0
    local forceCalls = 0
    package.loaded["celmi/timetables/timetable_helper"] = {
        getTime = function() return mockTime end,
        getCurrentLine = function() return mockLine end,
        getCurrentStation = function() return mockStop end,
        getTimeUntilDeparture = function() return 3 end,
        getStationID = function() return 1001 end,
        forceDeparture = function() forceCalls = forceCalls + 1 end,
    }
    local prevApi = _G.api
    _G.api = {
        engine = {
            entityExists = function() return true end,
            getComponent = function(id, ctype)
                if ctype == 60 then
                    return { stops = { [1] = { minWaitingTime = dwellMin, maxWaitingTime = dwellMax } } }
                elseif ctype == 70 then
                    return { doorsTime = mockDoorsArrival * 1000000 }
                end
                return nil
            end,
        },
        type = { ComponentType = { LINE = 60, TRANSPORT_VEHICLE = 70 } },
    }
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"
    tt.setDelayTolerance(300)
    local function objWith(force, min, max)
        return { ["100"] = { hasTimetable = true, forceDeparture = force, minWaitEnabled = min, maxWaitEnabled = max,
            stations = { [1] = { stationID = 1001,
                conditions = { type = "ArrDep", ArrDep = { {10,0,10,0} } } } } } }  -- 13:10 departure (absolute 47400)
    end
    local function resetWaiting()
        tt.setCurrentlyWaiting({})
        forceCalls = 0
    end

    -- A) max ticked + 10 minutes early (arrival 13:00, M=180s): at 13:05:30 arrival+M has passed, but departure time 13:10 not reached
    --    -> never force departure early, keep holding until the departure time (the core fix of "the old implementation forced departure at 13:03")
    tt.setTimetableObject(objWith(false, false, true))
    mockDoorsArrival = 3600 * 13          -- 13:00:00 arrival
    dwellMax = 180
    mockTime = 3600 * 13 + 330            -- 13:05:30
    resetWaiting()
    assert(tt.waitingRequired("V1") == true, "early arrival past arrival+M but before dep point must keep holding")
    assert(forceCalls == 0, "early arrival must NOT be force-departed before its departure point")

    -- B) Same config, 5s after the departure time (13:10:05, delay=5 <= tolerance) -> forced departure on time (loading cut short)
    mockTime = 3600 * 13 + 605
    resetWaiting()
    assert(tt.waitingRequired("V1") == false, "dep point reached (held train) must release")
    assert(forceCalls == 1, "max: at-departure release must forceDeparture (got " .. tostring(forceCalls) .. ")")

    -- C) max ticked + 2 minutes late but loading quickly (arrival 13:12, departure 13:10 passed, within tolerance) -> normal release, no forced departure
    --    (max doesn't cover "late but leaves once loaded", player decision)
    tt.setTimetableObject(objWith(false, false, true))
    mockDoorsArrival = 3600 * 13 + 720    -- 13:12:00 arrival
    mockTime = 3600 * 13 + 750            -- 13:12:30 (door-closing check; arrival+M=13:15 not reached)
    resetWaiting()
    assert(tt.waitingRequired("V1") == false, "late within tolerance + fast loading must release")
    assert(forceCalls == 0, "late-within-tolerance fast loader must NOT be force-departed")

    -- D) max ticked + late beyond tolerance (delay 310s > 300): arrival+M (13:15:00) has passed -> forced departure as a safety net (don't wait for the next run)
    --    arrival+M = 13:12:00 + 180s = 13:15:00; jump to 13:15:10 (47710 >= 47700)
    mockTime = 3600 * 13 + 910            -- 13:15:10
    resetWaiting()
    assert(tt.waitingRequired("V1") == false, "beyond tolerance + max elapsed must release (cap the dead wait)")
    assert(forceCalls == 1, "beyond-tolerance dead wait capped by max must forceDeparture (got " .. tostring(forceCalls) .. ")")

    -- E) Contrast: same beyond-tolerance scenario but max not ticked -> held until the next run (max is the only switch that lets it leave earlier)
    tt.setTimetableObject(objWith(false, false, false))
    mockTime = 3600 * 13 + 910
    resetWaiting()
    assert(tt.waitingRequired("V1") == true, "beyond tolerance without max must hold to next slot")
    assert(forceCalls == 0, "beyond-tolerance hold (no max) must not forceDeparture")

    _G.api = prevApi
    print("  OK: max wait refined semantics (wait-to-point / at-point force / late-fast plain / M cap)")
end

-- Closest-slot matching: the arrival is matched to the slot whose [arr, dep] interval is
-- closest, so early vs. late is decided by the nearer slot boundary.
timetableTests[#timetableTests + 1] = function()
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"
    local slots = { {10,0,11,0}, {20,0,21,0} }
    local h = 3600 * 13
    local function dep(ref) local _, d = tt.assignSlot(slots, ref) return d end

    assert(dep(h + 12 * 60) == h + 11 * 60, "12:00 is late for slot 10/11")
    assert(dep(h + 18 * 60) == h + 21 * 60, "18:00 is early for slot 20/21")
    assert(dep(h + 10 * 60 + 30) == h + 11 * 60, "10:30 is inside slot 10/11")
    assert(dep(h + 15 * 60 + 30) == h + 21 * 60, "tie at the midpoint prefers the later slot")
    assert(dep(h + 40 * 60) == h + 21 * 60, "40:00 is late for slot 20/21")
    assert(dep(h + 46 * 60) == h + 60 * 60 + 11 * 60, "46:00 is early for 10/11 of the next hour")
    -- Slot crossing the hour: arr 58:00, dep 02:00
    local a, d = tt.assignSlot({ {58,0,2,0} }, h + 60)
    assert(a == h - 120 and d == h + 120, "slot across the hour boundary")

    assert(tt.getNextDeparture(slots, h + 12 * 60) == h + 21 * 60, "next departure after 12:00")
    assert(tt.getNextDeparture(slots, h + 21 * 60) == h + 60 * 60 + 11 * 60, "next departure is strictly after")
    print("  OK: assignSlot / getNextDeparture")
end

-- waitingRequired with two slots per hour (10/11 and 20/21), tolerance 5 min.
timetableTests[#timetableTests + 1] = function()
    local h = 3600 * 13
    local mockTime = h
    local mockArrival = nil
    local forceCalls = 0
    package.loaded["celmi/timetables/timetable_helper"] = {
        getTime = function() return mockTime end,
        getCurrentLine = function() return 100 end,
        getCurrentStation = function() return 1 end,
        getTimeUntilDeparture = function() return 3 end,
        getStationID = function() return 1001 end,
        forceDeparture = function() forceCalls = forceCalls + 1 end,
    }
    local prevApi = _G.api
    _G.api = {
        engine = {
            entityExists = function() return true end,
            getComponent = function(id, ctype)
                if ctype == 70 and mockArrival then
                    return { doorsTime = mockArrival * 1000000 }
                end
                return nil
            end,
        },
        type = { ComponentType = { LINE = 60, TRANSPORT_VEHICLE = 70 } },
    }
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"
    tt.setDelayTolerance(300)
    tt.setTimetableObject({ ["100"] = { hasTimetable = true, stations = { [1] = { stationID = 1001,
        conditions = { type = "ArrDep", ArrDep = { {10,0,11,0}, {20,0,21,0} } } } } } })
    local function reset() tt.setCurrentlyWaiting({}) forceCalls = 0 end

    -- Early for slot 20/21 at 19:00 (8 min after 11:00): must wait, was released before.
    reset()
    mockArrival, mockTime = h + 19 * 60, h + 19 * 60
    assert(tt.waitingRequired("V1") == true, "19:00 is early for 20/21 and must wait")
    mockTime = h + 20 * 60 + 59
    assert(tt.waitingRequired("V1") == true, "still waiting before 21:00")
    mockTime = h + 21 * 60
    assert(tt.waitingRequired("V1") == false, "released at 21:00")
    assert(forceCalls == 1, "release at the departure point forces departure")

    -- Late within tolerance for slot 10/11.
    reset()
    mockArrival, mockTime = h + 13 * 60, h + 13 * 60 + 30
    assert(tt.waitingRequired("V1") == false, "13:00 is 2 min late for 10/11 and must leave")

    -- Late beyond tolerance (arrives 11:30, leaves loading at 17:00): held until 21:00,
    -- and the decision stays fixed while waiting.
    reset()
    mockArrival, mockTime = h + 11 * 60 + 30, h + 17 * 60
    assert(tt.waitingRequired("V1") == true, "6 min late must be held to the next slot")
    mockTime = h + 20 * 60
    assert(tt.waitingRequired("V1") == true, "held train keeps waiting for 21:00")
    mockTime = h + 21 * 60 + 1
    assert(tt.waitingRequired("V1") == false, "held train released at the next departure")

    -- Slow loading does not move the train to another slot: arrived 10:30 (on time),
    -- doors close at 16:30 (past the midpoint) -> late for 10/11 by 5:30 -> held to 21:00.
    reset()
    mockArrival, mockTime = h + 10 * 60 + 30, h + 16 * 60 + 30
    assert(tt.waitingRequired("V1") == true, "on-time arrival with slow loading counts against 10/11")
    assert(tt.getCurrentlyWaiting()["100"].stations[1].currentlyWaiting["V1"].dep == h + 21 * 60,
        "held until 21:00")

    -- A hold left over from an earlier visit is ignored on the next arrival.
    reset()
    tt.getCurrentlyWaiting()["100"] = { stations = { [1] = { outboundTime = {}, currentlyWaiting = {
        V1 = { type = "ArrDep", arrivalTime = h - 3600 + 19 * 60, dep = h - 3600 + 21 * 60, late = false } } } } }
    mockArrival, mockTime = h + 19 * 60, h + 19 * 60
    assert(tt.waitingRequired("V1") == true, "stale hold must not release an early train")

    -- Without an arrival time the current time is used as reference.
    reset()
    mockArrival, mockTime = nil, h + 18 * 60
    assert(tt.waitingRequired("V1") == true, "no doorsTime: 18:00 is early for 20/21")

    -- Holding point off: late beyond tolerance departs right away, early still waits.
    assert(tt.getHoldLateEnabled(100, 1) == true, "holding point defaults to on")
    tt.setHoldLateEnabled(100, 1, false)
    assert(tt.getHoldLateEnabled(100, 1) == false, "holding point round trip")
    assert(tt.getTimetableObject()["100"].stations[1].holdLate == false, "stored on the station entry")
    reset()
    mockArrival, mockTime = h + 11 * 60 + 30, h + 17 * 60
    assert(tt.waitingRequired("V1") == false, "not a holding point: 6 min late must depart")
    assert(forceCalls == 1, "release forces departure")
    reset()
    mockArrival, mockTime = h + 19 * 60, h + 19 * 60
    assert(tt.waitingRequired("V1") == true, "not a holding point: early train still waits")
    tt.setHoldLateEnabled(100, 1, true)

    _G.api = prevApi
    print("  OK: waitingRequired closest-slot matching (two slots)")
end

-- Per-vehicle slot tracking: the delay a train leaves a stop with is carried to the next
-- timed stop, so the train is matched to its own slot there even when it is more than half
-- a slot gap late. Slots every 10 min: stop 1 x0/x1, stop 2 x5/x6. Neither stop holds late trains.
timetableTests[#timetableTests + 1] = function()
    local h = 3600 * 13
    local mockTime, mockArrival, mockStop = h, h, 1
    package.loaded["celmi/timetables/timetable_helper"] = {
        getTime = function() return mockTime end,
        getCurrentLine = function() return 100 end,
        getCurrentStation = function() return mockStop end,
        getTimeUntilDeparture = function() return 3 end,
        getStationID = function() return 1001 end,
        forceDeparture = function() end,
    }
    local prevApi = _G.api
    _G.api = {
        engine = {
            entityExists = function() return true end,
            getComponent = function(id, ctype)
                if ctype == 70 then return { doorsTime = mockArrival * 1000000 } end
                return nil
            end,
        },
        type = { ComponentType = { LINE = 60, TRANSPORT_VEHICLE = 70 } },
    }
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"
    tt.setDelayTolerance(300)
    local s1, s2 = {}, {}
    for m = 0, 50, 10 do
        s1[#s1 + 1] = { m, 0, m + 1, 0 }
        s2[#s2 + 1] = { m + 5, 0, m + 6, 0 }
    end
    tt.setTimetableObject({ ["100"] = { hasTimetable = true, stations = {
        [1] = { holdLate = false, conditions = { type = "ArrDep", ArrDep = s1 } },
        [2] = { holdLate = false, conditions = { type = "ArrDep", ArrDep = s2 } },
    } } })
    tt.setCurrentlyWaiting({})
    local function delayOf(v) return tt.getCurrentlyWaiting()["100"].vehicleDelay[v].delay end

    -- Stop 1: arrives 03:00, leaves 03:30 -> 2:30 late for 00/01.
    mockStop, mockArrival, mockTime = 1, h + 180, h + 210
    assert(tt.waitingRequired("V1") == false, "stop 1: late, departs")
    assert(delayOf("V1") == 150, "carries 150 s delay, got " .. tostring(delayOf("V1")))

    -- Stop 2: arrives 11:00. Without tracking this is closer to 15/16 (early, would wait).
    -- With the carried delay it is 08:30 on schedule -> late for 05/06 -> departs.
    mockStop, mockArrival, mockTime = 2, h + 660, h + 690
    assert(tt.waitingRequired("V1") == false, "stop 2: matched to its own slot 05/06, departs")
    assert(delayOf("V1") == 330, "delay grows to 330 s, got " .. tostring(delayOf("V1")))

    -- Re-evaluated at the same stop after the 40 s guard: uses the delay it arrived with.
    mockTime = h + 740
    assert(tt.waitingRequired("V1") == false, "re-evaluation at the same stop still departs")
    assert(tt.getCurrentlyWaiting()["100"].vehicleDelay["V1"].inDelay == 150, "keeps the arrival delay")

    -- Next lap, stop 1: arrives 16:00 (5:30 late for 10/11 on schedule) and departs.
    mockStop, mockArrival, mockTime = 1, h + 960, h + 990
    assert(tt.waitingRequired("V1") == false, "stop 1 next lap: still late, departs")

    -- Catching up: left stop 1 2:30 late for 00/01, arrives at stop 2 at 04:30 = 02:00 on
    -- schedule -> early for 05/06, waits until 06:00 and runs on time again.
    tt.getCurrentlyWaiting()["100"].vehicleDelay["V3"] = { delay = 150, inDelay = 0, time = h + 210 }
    mockStop, mockArrival, mockTime = 2, h + 270, h + 300
    assert(tt.waitingRequired("V3") == true, "stop 2: caught up, early for 05/06")
    mockTime = h + 360
    assert(tt.waitingRequired("V3") == false, "released at 06:00")
    assert(delayOf("V3") == 0, "back on time")

    -- An old record is ignored.
    tt.setCurrentlyWaiting({ ["100"] = { stations = {}, vehicleDelay = {
        V2 = { delay = 330, inDelay = 0, time = h - 4 * 3600 } } } })
    mockStop, mockArrival, mockTime = 2, h + 660, h + 690
    assert(tt.waitingRequired("V2") == true, "stale delay ignored: 11:00 is early for 15/16")

    _G.api = prevApi
    print("  OK: per-vehicle delay carried between stops")
end

-- Slot claims: two bunched vehicles do not run on the same slot. Slots every 10 min (x0/x1),
-- tolerance 5 min.
timetableTests[#timetableTests + 1] = function()
    local h = 3600 * 13
    local mockTime, mockArrival = h, h
    package.loaded["celmi/timetables/timetable_helper"] = {
        getTime = function() return mockTime end,
        getCurrentLine = function() return 100 end,
        getCurrentStation = function() return 1 end,
        getTimeUntilDeparture = function() return 3 end,
        getStationID = function() return 1001 end,
        forceDeparture = function() end,
    }
    local prevApi = _G.api
    _G.api = {
        engine = {
            entityExists = function() return true end,
            getComponent = function(id, ctype)
                if ctype == 70 then return { doorsTime = mockArrival * 1000000 } end
                return nil
            end,
        },
        type = { ComponentType = { LINE = 60, TRANSPORT_VEHICLE = 70 } },
    }
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"
    tt.setDelayTolerance(300)
    local slots = {}
    for m = 0, 50, 10 do slots[#slots + 1] = { m, 0, m + 1, 0 } end
    tt.setTimetableObject({ ["100"] = { hasTimetable = true, stations = {
        [1] = { conditions = { type = "ArrDep", ArrDep = slots } } } } })
    local function waiting(v) return tt.getCurrentlyWaiting()["100"].stations[1].currentlyWaiting[v] end

    -- V1 runs on 00/01.
    tt.setCurrentlyWaiting({})
    mockArrival, mockTime = h, h
    assert(tt.waitingRequired("V1") == true, "V1 early for 00/01")
    mockTime = h + 60
    assert(tt.waitingRequired("V1") == false, "V1 released at 01:00")

    -- V2 follows 30 s behind: 00/01 is taken, so it waits for 11:00 instead of leaving late.
    mockArrival, mockTime = h + 90, h + 90
    assert(tt.waitingRequired("V2") == true, "V2 must not take V1's slot")
    assert(waiting("V2").dep == h + 660, "V2 held for 11:00")
    -- Also with a delay carried from the previous stop on the same slot.
    tt.getCurrentlyWaiting()["100"].stations[1].currentlyWaiting["V2"] = nil
    tt.getCurrentlyWaiting()["100"].vehicleDelay["V2"] = { delay = 30, inDelay = 0, time = h }
    assert(tt.waitingRequired("V2") == true, "V2 with carried delay must not take V1's slot")
    assert(waiting("V2").dep == h + 660, "V2 held for 11:00")
    mockTime = h + 660
    assert(tt.waitingRequired("V2") == false, "V2 released at 11:00")
    assert(tt.getCurrentlyWaiting()["100"].vehicleDelay["V2"].delay == 0, "V2 on time on its new slot")

    -- Both in the station at once: V3 held for 21:00, V4 arriving next goes to 31:00.
    mockArrival, mockTime = h + 1200, h + 1200
    assert(tt.waitingRequired("V3") == true, "V3 early for 20/21")
    mockArrival, mockTime = h + 1220, h + 1220
    assert(tt.waitingRequired("V4") == true, "V4 waits")
    assert(waiting("V4").dep == h + 1860, "V4 held for 31:00, not V3's 21:00")

    -- A claim on a future slot by a vehicle that is no longer held (e.g. sold) is ignored.
    tt.setCurrentlyWaiting({ ["100"] = { stations = { [1] = { currentlyWaiting = {}, outboundTime = {},
        slotClaims = { [tostring(h + 2460)] = "V9" } } } } })
    mockArrival, mockTime = h + 2400, h + 2400
    assert(tt.waitingRequired("V5") == true, "V5 early for 40/41")
    assert(waiting("V5").dep == h + 2460, "stale claim ignored")

    -- Late beyond tolerance: moved to the next free slot and runs on it.
    tt.setCurrentlyWaiting({})
    mockArrival, mockTime = h + 1200, h + 1200
    assert(tt.waitingRequired("V6") == true, "V6 holds 20/21")
    mockArrival, mockTime = h + 420, h + 420
    assert(tt.waitingRequired("V7") == true, "V7 6 min late for 00/01 is held")
    assert(waiting("V7").dep == h + 660, "V7 held for 11:00 (free)")
    assert(waiting("V7").slot == h + 660, "V7 now runs on 10/11")

    _G.api = prevApi
    print("  OK: slot claims spread bunched vehicles")
end

return {
    test = function()
        for k,v in pairs(timetableTests) do
            print("Running test: " .. tostring(k))
            v()
        end
    end
}
