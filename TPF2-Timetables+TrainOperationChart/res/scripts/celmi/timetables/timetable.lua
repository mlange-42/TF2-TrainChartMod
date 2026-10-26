local timetableHelper = require "celmi/timetables/timetable_helper"

--[[
timetable = {
    line = {
        stations = { stationinfo }
        hasTimetable = true
    }
}

stationInfo = {
    conditions = {condition :: Condition},
    inboundTime = 1 :: int
}

conditions = {
    type = "None"| "ArrDep" | "minWait" | "debounce" | "moreFancey"
    ArrDep = {}
    minWait = {}
    debaunce  = {}
    moreFancey = {}
}
--]]
local timetable = { }
local timetableObject = { }
local currentlyWaiting = { }
local diagramConfig = { }

-- ===== Performance optimization group A (2026-08-16, round 21): hoist hot-path pcall targets to module level =====
-- Same optimization as in timetable_helper.lua: the old pcall(function() ... end) created a new closure on every execution,
-- and this file's hot functions (waitingRequired every frame per vehicle, cleanupOrphanLines/reconcileStationData every 5s,
-- clearStaleHolds) produced thousands of temporary closures per second -> shorter Lua GC cycles -> periodic frame drops noticeable to players.
-- Changed to pcall(fn, args...) reusing module-level functions: error protection semantics unchanged, just no garbage.
-- (Function bodies only access api when called -- module top level never touches api, per the AGENTS hard rule.)
local function _entityExists(id) return api.engine.entityExists(id) end
local function _getComponent(id, ctype) return api.engine.getComponent(id, ctype) end
local function _getLines() return api.engine.system.lineSystem.getLines() end
local function _lineVehicles(line) return api.engine.system.transportVehicleSystem.getLineVehicles(line) end
local function _vehiclesWithState(state)
    return api.engine.system.transportVehicleSystem.getVehiclesWithState(state)
end
local function _sendManualDeparture(v, m) return api.cmd.sendCommand(api.cmd.make.setVehicleManualDeparture(v, m)) end
local function _realSeconds()
    local ok, t = pcall(os.clock)
    if ok and type(t) == "number" then return t end
    return nil
end


function timetable.getTimetableObject()
    return timetableObject
end

function timetable.setTimetableObject(t)
    if t then
        timetableObject = t
    end
end

-- Get a station's ArrDep time array ({ {arrMin,arrSec,depMin,depSec}, ... }); returns nil if there is none.
local function getStationArrDep(stationInfo)
    if type(stationInfo) ~= "table" then return nil end
    local cond = stationInfo.conditions
    if type(cond) ~= "table" then return nil end
    local arr = cond.ArrDep
    if type(arr) ~= "table" or #arr == 0 then return nil end
    return arr
end

-- Append all times of src to the end of dst (dst is extended in place).
local function appendSlots(dst, src)
    for _, slot in pairs(src) do
        dst[#dst + 1] = slot
    end
end

-- Data sync: migrate line timetables stored with numeric keys by the old mod (2918585390 / 1.5) to this mod's string keys.
-- Semantics: append, never overwrite -- if the target string key doesn't exist, the whole entry is moved; otherwise the numeric key's ArrDep times
-- are appended per station to the end of the string key's ArrDep list (all slot sets are kept; the user removes duplicates).
-- Only top-level numeric keys (line IDs) are processed; string keys like _gwNames / _diagram* are kept as is.
-- Triggered explicitly by the "Data sync" button in the timetable settings tab (no automatic migration on load, so the user is aware).
-- Returns a report { lines = { [lineKey] = { [stationNumber] = number of added ArrDep sets } }, totalSlots = N }.
function timetable.migrateNumberLineKeys()
    local report = { lines = {}, totalSlots = 0 }
    local numericKeys = {}
    for k in pairs(timetableObject) do
        if type(k) == "number" and k > 0 then
            numericKeys[#numericKeys + 1] = k
        end
    end
    for _, k in ipairs(numericKeys) do
        local numEntry = timetableObject[k]
        local sk = tostring(k)
        local strEntry = timetableObject[sk]
        local lineReport = {}
        local lineAdded = 0

        if strEntry == nil then
            -- Target string key doesn't exist: move the whole entry
            timetableObject[k] = nil
            timetableObject[sk] = numEntry
            if type(numEntry) == "table" and type(numEntry.stations) == "table" then
                for sn, sInfo in pairs(numEntry.stations) do
                    local arr = getStationArrDep(sInfo)
                    if arr then
                        lineReport[sn] = #arr
                        lineAdded = lineAdded + #arr
                    end
                end
            end
        elseif type(numEntry) == "table" then
            -- Target string key exists: append per station, don't overwrite
            if type(strEntry.stations) ~= "table" then strEntry.stations = {} end
            if type(numEntry.stations) == "table" then
                for sn, numStation in pairs(numEntry.stations) do
                    local numArr = getStationArrDep(numStation)
                    if numArr then
                        local strStation = strEntry.stations[sn]
                        if type(strStation) ~= "table" then
                            strEntry.stations[sn] = numStation
                        else
                            local strCond = strStation.conditions
                            if type(strCond) ~= "table" then
                                strCond = {}
                                strStation.conditions = strCond
                            end
                            local strArr = strCond.ArrDep
                            if type(strArr) ~= "table" then strArr = {} end
                            appendSlots(strArr, numArr)
                            strCond.ArrDep = strArr
                            if strCond.type == nil or strCond.type == "None" then
                                strCond.type = "ArrDep"
                            end
                        end
                        lineReport[sn] = #numArr
                        lineAdded = lineAdded + #numArr
                    end
                end
            end
            if lineAdded > 0 and strEntry.hasTimetable ~= true then
                strEntry.hasTimetable = true
            end
            timetableObject[k] = nil
        else
            -- Numeric key but value is not a table (defensive, shouldn't happen): move as is to the string key
            timetableObject[k] = nil
            timetableObject[sk] = numEntry
        end

        if lineAdded > 0 then
            report.lines[sk] = lineReport
            report.totalSlots = report.totalSlots + lineAdded
        end
    end
    return report
end

-- Sync revision: bumped by the GUI thread each time it sends timetableObject to the engine.
-- The GUI thread rejects engine snapshots with an older revision (they predate its own edits).
function timetable.getRevision(t)
    t = t or timetableObject
    return (type(t) == "table" and type(t._rev) == "number") and t._rev or 0
end

function timetable.bumpRevision()
    timetableObject._rev = timetable.getRevision() + 1
    return timetableObject._rev
end

function timetable.getCurrentlyWaiting()
    return currentlyWaiting
end

function timetable.setCurrentlyWaiting(t)
    if t then
        currentlyWaiting = t
    end
end

function timetable.setConditionType(line, stationNumber, type)
    local stationID = timetableHelper.getStationID(line, stationNumber)
    if not(line and stationNumber) then return -1 end
    if timetableObject[tostring(line)] and timetableObject[tostring(line)].stations[stationNumber] then
        timetableObject[tostring(line)].stations[stationNumber].conditions.type = type
        local conditionObject = timetableObject[tostring(line)].stations[stationNumber].conditions[type]
        if not conditionObject then  timetableObject[tostring(line)].stations[stationNumber].conditions[type] = {} end
        timetableObject[tostring(line)].stations[stationNumber].stationID = stationID
    else
        if not timetableObject[tostring(line)] then
            timetableObject[tostring(line)] = { hasTimetable = false, stations = {}, dp = {}}
        end

        timetableObject[tostring(line)].stations[stationNumber] = {
            inboundTime = 0,
            stationID = stationID,
            conditions = {type = type}
        }
        local conditionObject = timetableObject[tostring(line)].stations[stationNumber].conditions[type]
        if not conditionObject then  timetableObject[tostring(line)].stations[stationNumber].conditions[type] = {} end
    end
end

function timetable.getConditionType(line, stationNumber)
    if not(line and stationNumber) then return "ERROR" end
    if timetableObject[tostring(line)] and timetableObject[tostring(line)].stations[stationNumber] then
        if timetableObject[tostring(line)].stations[stationNumber].conditions.type then
            return timetableObject[tostring(line)].stations[stationNumber].conditions.type
        else
            timetableObject[tostring(line)].stations[stationNumber].conditions.type = "None"
            return "None"
        end
    else
        return "None"
    end
end


-- Whether table t contains line entries (numeric keys or string keys convertible to a number, > 0).
-- Used as a safeguard for cross-thread sync: if the GUI thread only has settings keys (_diagram*) or an empty table left due to a module reload/load failure,
-- the engine thread refuses to overwrite the fully loaded line data with it, preventing the save from being wiped.
function timetable.hasLineEntries(t)
    if type(t) ~= "table" then return false end
    for k in pairs(t) do
        local n = tonumber(k)
        if n and n > 0 then return true end
    end
    return false
end

-- Whether any line in table t carries diagram presets (dp.presetList non-empty).
-- Works together with hasLineEntries: prevents the GUI thread sync from overwriting/losing presets (dp) already loaded by the engine.
function timetable.hasAnyPreset(t)
    if type(t) ~= "table" then return false end
    for _, v in pairs(t) do
        if type(v) == "table" and type(v.dp) == "table" and type(v.dp.presetList) == "table" and #v.dp.presetList > 0 then
            return true
        end
    end
    return false
end

-- Whether the line entity still exists (players may delete lines; orphaned data in timetableObject should be filtered/cleaned up).
-- Criterion: the set of lines currently returned by lineSystem.getLines() -- lines deleted by the player are never in it;
-- more reliable than api.engine.entityExists (verified: entityExists may still return true for deleted lines, breaking both filtering and cleanup).
-- Note: never probe with getComponent (on invalid entities it triggers a C++ assert that pcall can't catch -> crash).
-- If getLines fails, fall back to entityExists (conservative: returning true counts as existing; the display layer catches ERROR as a last resort).
function timetable.lineExists(lineID)
    local n = tonumber(lineID)
    if not n then return false end
    local okL, lines = pcall(_getLines)
    if okL and lines then
        for _, l in pairs(lines) do
            if tostring(l) == tostring(n) then return true end
        end
        return false
    end
    local ok, exists = pcall(_entityExists, n)
    return ok and exists == true
end

function timetable.getAllConditionsOfStaion(stationID)
    local res = { }
    for k,v in pairs(timetableObject) do
        if type(v) == "table" and v.stations and timetable.lineExists(k) then
        for _,v2 in pairs(v.stations) do
            if v2.stationID
               and v2.conditions
               and  v2.conditions.type
               and not (v2.conditions.type == "None")
               and tostring(v2.stationID) == tostring(stationID+1) then
                res[k] = {
                    stationID = v2.stationID,
                    conditions = v2.conditions
                }
            end
        end
        end
    end
    return res
end

function timetable.getAllConditionsOfAllStations()
    local res = { }
    local skipped = {}
    for k,v in pairs(timetableObject) do
        local okLine = false
        if type(v) == "table" and v.stations then
            okLine = timetable.lineExists(k)
            if okLine then
                for _,v2 in pairs(v.stations) do
                    if v2.stationID and v2.conditions and  v2.conditions.type and not (v2.conditions.type == "None")  then
                        if not res[v2.stationID] then res[v2.stationID] = {} end
                        res[v2.stationID][k] = {
                            conditions = v2.conditions
                        }
                    end
                end
            else
                -- Diagnostics: orphaned line (has stations but lineExists=false)
                skipped[#skipped + 1] = k
            end
        end
    end
    if #skipped > 0 and _G._diagramDebug then
        print("[Timetable] getAllConditionsOfAllStations skipped orphan lines: " .. table.concat(skipped, ","))
    end
    -- Filter out empty stations: when a station only has times of deleted lines (no lines left after orphan filtering),
    -- res[stationID] is an empty table and must not appear in the station tab list (it would open empty/with leftovers).
    for sid, lines in pairs(res) do
        if type(lines) ~= "table" or next(lines) == nil then
            res[sid] = nil
        end
    end
    return res
end

function timetable.getConditions(line, stationNumber, type)
    if not(line and stationNumber) then return nil end
    if timetableObject[tostring(line)]
       and timetableObject[tostring(line)].stations[stationNumber]
       and timetableObject[tostring(line)].stations[stationNumber].conditions[type] then
        return timetableObject[tostring(line)].stations[stationNumber].conditions[type]
    else
        return nil
    end
end


-- TEST: timetable.addCondition(1,1,{type = "ArrDep", ArrDep = {{12,14,14,14}}})
function timetable.addCondition(line, stationNumber, condition)
    local stationID = timetableHelper.getStationID(line, stationNumber)
    if not(line and stationNumber and condition) then return -1 end

    if timetableObject[tostring(line)] and timetableObject[tostring(line)].stations[stationNumber] then
        if condition.type == "ArrDep" then
            timetable.setConditionType(line, stationNumber, condition.type)
            local arrDepCond = timetableObject[tostring(line)].stations[stationNumber].conditions.ArrDep
            local mergedArrays = timetableHelper.mergeArray(arrDepCond, condition.ArrDep)
            timetableObject[tostring(line)].stations[stationNumber].conditions.ArrDep = mergedArrays
        elseif condition.type == "minWait" then
            timetableObject[tostring(line)].stations[stationNumber].conditions.type = "minWait"
            timetableObject[tostring(line)].stations[stationNumber].conditions.minWait = condition.minWait
        elseif condition.type == "debounce" then
            timetableObject[tostring(line)].stations[stationNumber].conditions.type = "debounce"
            timetableObject[tostring(line)].stations[stationNumber].conditions.debounce = condition.debounce
        elseif condition.type == "moreFancey" then
            timetableObject[tostring(line)].stations[stationNumber].conditions.type = "moreFancey"
            timetableObject[tostring(line)].stations[stationNumber].conditions.moreFancey = condition.moreFancey
        end
        timetableObject[tostring(line)].stations[stationNumber].stationID = stationID

    else
        if not timetableObject[tostring(line)] then
            timetableObject[tostring(line)] = {hasTimetable = false, stations = {}}
        end
        timetableObject[tostring(line)].stations[stationNumber] = {
            inboundTime = 0,
            stationID = stationID,
            conditions = condition
        }
    end
end

function timetable.updateArrDep(line, station, indexKey, indexValue, value)
    if line == nil or station == nil or indexKey == nil or indexValue == nil or value == nil then return -1 end
    if timetableObject[tostring(line)] and
       timetableObject[tostring(line)].stations[station] and
       timetableObject[tostring(line)].stations[station].conditions and
       timetableObject[tostring(line)].stations[station].conditions.ArrDep and
       timetableObject[tostring(line)].stations[station].conditions.ArrDep[indexKey] and
       timetableObject[tostring(line)].stations[station].conditions.ArrDep[indexKey][indexValue] then
       timetableObject[tostring(line)].stations[station].conditions.ArrDep[indexKey][indexValue] = value
        return 0
    else
        return -2
    end
end

function timetable.updateDebounce(line, station, indexKey, value)
    if line == nil or station == nil or indexKey == nil or value == nil then return -1 end
    if timetableObject[tostring(line)] and
       timetableObject[tostring(line)].stations[station] and
       timetableObject[tostring(line)].stations[station].conditions and
       timetableObject[tostring(line)].stations[station].conditions.debounce then
       timetableObject[tostring(line)].stations[station].conditions.debounce[indexKey] = value
        return 0
    else
        return -2
    end
end

function timetable.getWaypointPassingTime(line, wpEntity)
    if not (line and wpEntity) then return nil end
    local lineData = timetableObject[tostring(line)]
    if not (lineData and lineData.waypointTimes) then return nil end
    local raw = lineData.waypointTimes[tostring(wpEntity)]
    if not raw then return nil end
    -- Compatibility with the old format {min, sec} -> convert to {{min, sec}}
    if raw[1] ~= nil and type(raw[1]) ~= "table" then
        raw = {{raw[1], raw[2] or 0}}
        lineData.waypointTimes[tostring(wpEntity)] = raw
    end
    return raw
end

function timetable.addWaypointPassingTime(line, wpEntity, min, sec)
    if not (line and wpEntity) then return -1 end
    if not timetableObject[tostring(line)] then
            timetableObject[tostring(line)] = {stations = {}, hasTimetable = false, waypointTimes = {}, dp = {}}
    end
    if not timetableObject[tostring(line)].waypointTimes then
        timetableObject[tostring(line)].waypointTimes = {}
    end
    local key = tostring(wpEntity)
    if not timetableObject[tostring(line)].waypointTimes[key] then
        timetableObject[tostring(line)].waypointTimes[key] = {}
    end
    table.insert(timetableObject[tostring(line)].waypointTimes[key], {min or 0, sec or 0})
    return 0
end

function timetable.removeWaypointPassingTime(line, wpEntity, index)
    if not (line and wpEntity and index) then return -1 end
    local key = tostring(wpEntity)
    local lineData = timetableObject[tostring(line)]
    if lineData and lineData.waypointTimes and lineData.waypointTimes[key] then
        table.remove(lineData.waypointTimes[key], index)
        if #lineData.waypointTimes[key] == 0 then
            lineData.waypointTimes[key] = nil
        end
        return 0
    end
    return -1
end

function timetable.removeAllWaypointPassingTimes(line, wpEntity)
    if not (line and wpEntity) then return -1 end
    local lineData = timetableObject[tostring(line)]
    if lineData and lineData.waypointTimes then
        lineData.waypointTimes[tostring(wpEntity)] = nil
    end
    return 0
end

function timetable.updateWaypointPassingTimeEntry(line, wpEntity, index, subIndex, value)
    if line == nil or wpEntity == nil or index == nil or subIndex == nil or value == nil then return -1 end
    local key = tostring(wpEntity)
    local lineData = timetableObject[tostring(line)]
    if lineData and lineData.waypointTimes and lineData.waypointTimes[key] and lineData.waypointTimes[key][index] then
        lineData.waypointTimes[key][index][subIndex] = value
        return 0
    end
    return -1
end

function timetable.getWaypointName(line, wpKey)
    if not (line and wpKey) then return nil end
    local lineData = timetableObject[tostring(line)]
    if lineData and lineData.waypointNames then
        return lineData.waypointNames[tostring(wpKey)]
    end
    return nil
end

function timetable.setWaypointName(line, wpKey, name)
    if not (line and wpKey) then return end
    if not timetableObject[tostring(line)] then
            timetableObject[tostring(line)] = {stations = {}, hasTimetable = false, waypointTimes = {}, dp = {}}
    end
    if not timetableObject[tostring(line)].waypointNames then
        timetableObject[tostring(line)].waypointNames = {}
    end
    if name and #name > 0 then
        timetableObject[tostring(line)].waypointNames[tostring(wpKey)] = name
    else
        timetableObject[tostring(line)].waypointNames[tostring(wpKey)] = nil
    end
end

function timetable.setGlobalWaypointName(gwKey, name)
    if not gwKey then return end
    if not _G._gwNames then _G._gwNames = {} end
    if not timetableObject._gwNames then timetableObject._gwNames = {} end
    if name and #name > 0 then
        _G._gwNames[gwKey] = name
        timetableObject._gwNames[gwKey] = name
    else
        _G._gwNames[gwKey] = nil
        timetableObject._gwNames[gwKey] = nil
    end
end

function timetable.getGlobalWaypointName(gwKey)
    if not gwKey then return nil end
    if _G._gwNames then
        local r = _G._gwNames[gwKey]
        if r then return r end
    end
    if timetableObject and timetableObject._gwNames then
        return timetableObject._gwNames[gwKey]
    end
    return nil
end

function timetable.removeCondition(line, station, type, index)
    if not(line and station and index) or (not (timetableObject[tostring(line)]
       and timetableObject[tostring(line)].stations[station])) then
        return -1
    end

    if type == "ArrDep" then
        local tmpTable = timetableObject[tostring(line)].stations[station].conditions.ArrDep
        if tmpTable and tmpTable[index] then return table.remove(tmpTable, index) end
    else
        -- just remove the whole condition
        local tmpTable = timetableObject[tostring(line)].stations[station].conditions[type]
        if tmpTable and tmpTable[index] then timetableObject[tostring(line)].stations[station].conditions[type] = {} end
        return 0
    end
    return -1
end

-- Clear all condition entries of a station for a type (ArrDep/debounce...) (keeps conditions.type, so the type stays unchanged).
-- Used by "auto-generate slots by interval" (2026-08-16 feature): keep the first entry as template, clear the rest, then regenerate.
function timetable.removeAllConditions(line, station, type)
    if timetableObject[tostring(line)]
       and timetableObject[tostring(line)].stations[station]
       and timetableObject[tostring(line)].stations[station].conditions then
        timetableObject[tostring(line)].stations[station].conditions[type] = {}
        return 0
    end
    return -1
end

-- Shift a {min, sec} time by offset seconds (modulo 1 hour). Pure function, used by "auto-generate slots by interval".
---@param time table {min, sec}
---@param offset number seconds
function timetable.shiftTime(time, offset)
    local total = ((time[1] * 60 + time[2]) + offset) % 3600
    return { math.floor(total / 60), total % 60 }
end

-- Shift a whole ArrDep slot {arrMin, arrSec, depMin, depSec} by offset seconds (modulo 1 hour).
function timetable.shiftSlot(slot, offset)
    local arr = timetable.shiftTime({slot[1], slot[2]}, offset)
    local dep = timetable.shiftTime({slot[3], slot[4]}, offset)
    return { arr[1], arr[2], dep[1], dep[2] }
end

function timetable.hasTimetable(line)
    if timetableObject[tostring(line)] then
        return timetableObject[tostring(line)].hasTimetable
    else
        return false
    end
end

-- Normalize the stop entries of currentlyWaiting (defensive: currentlyWaiting is persisted with the save;
-- stop entries from old saves may lack outboundTime, or outboundTime may be the old scalar "timestamp shared by the whole station" --
-- then writing/reading stopData.outboundTime[vehicle] crashes ("attempt to index field 'outboundTime' (a nil value)")).
-- A carried delay older than this is ignored (vehicle stood in a depot, line was edited, ...).
local VEHICLE_DELAY_MAX_AGE = 3 * 3600

-- Slot claims older than this are dropped.
local SLOT_CLAIM_MAX_AGE = 2 * 3600

local function normalizeStopData(stopData)
    if type(stopData.currentlyWaiting) ~= "table" then stopData.currentlyWaiting = {} end
    if type(stopData.outboundTime) ~= "table" then stopData.outboundTime = {} end
    if type(stopData.slotClaims) ~= "table" then stopData.slotClaims = {} end
end

-- All occurrences of the slots from the hour before to two hours after the given time,
-- sorted by departure.
local function slotOccurrences(constraints, time)
    local list = {}
    local base = math.floor(time / 3600)
    for _, c in ipairs(constraints) do
        local arrTime = (c[1] * 60 + c[2]) % 3600
        local depTime = (c[3] * 60 + c[4]) % 3600
        local dwell = (depTime - arrTime) % 3600
        for k = base - 1, base + 2 do
            local absArr = arrTime + 3600 * k
            list[#list + 1] = { arr = absArr, dep = absArr + dwell }
        end
    end
    table.sort(list, function(a, b) return a.dep < b.dep end)
    return list
end

-- Matches a reference time (usually the vehicle's arrival) to the slot whose [arr, dep]
-- interval is closest to it (distance 0 if inside). Before the departure the train counts
-- as early/on time, after it as late. Ties prefer the later slot (wait rather than leave early).
-- If isTaken is given and the matched slot is taken by another vehicle, the next free slot
-- after it is used instead, so that two vehicles never run on the same slot.
---@param constraints table in format like: {{30,0,59,0},{9,0,59,0},...}
---@param ref number absolute time in seconds
---@param isTaken function|nil isTaken(absDep) -> boolean
---@return number|nil absArr absolute arrival time of the matched slot
---@return number|nil absDep absolute departure time of the matched slot
function timetable.assignSlot(constraints, ref, isTaken)
    local occ = slotOccurrences(constraints, ref)
    local best, bestDist = nil, math.huge
    for i, o in ipairs(occ) do
        local dist = 0
        if ref < o.arr then
            dist = o.arr - ref
        elseif ref > o.dep then
            dist = ref - o.dep
        end
        -- Sorted by departure, so "<=" lets the later slot win ties.
        if dist <= bestDist then
            best, bestDist = i, dist
        end
    end
    if not best then return nil, nil end
    if isTaken then
        for i = best, #occ do
            if not isTaken(occ[i].dep) then return occ[i].arr, occ[i].dep end
        end
    end
    -- All taken (more vehicles than slots): share the closest one.
    return occ[best].arr, occ[best].dep
end

-- First departure of any slot strictly after the given time.
-- With isTaken, slots taken by another vehicle are skipped (unless all are taken).
---@param constraints table in format like: {{30,0,59,0},{9,0,59,0},...}
---@param time number absolute time in seconds
---@param isTaken function|nil isTaken(absDep) -> boolean
---@return number|nil absDep
function timetable.getNextDeparture(constraints, time, isTaken)
    if isTaken then
        for _, o in ipairs(slotOccurrences(constraints, time)) do
            if o.dep > time and not isTaken(o.dep) then return o.dep end
        end
    end
    local best = nil
    for _, c in ipairs(constraints) do
        local depTime = (c[3] * 60 + c[4]) % 3600
        local absDep = depTime + 3600 * math.floor(time / 3600)
        if absDep <= time then absDep = absDep + 3600 end
        if not best or absDep < best then best = absDep end
    end
    return best
end

function timetable.waitingRequired(vehicle)
    -- The vehicle may have been deleted (after the player sells it, the coroutine's AT_TERMINAL snapshot may contain invalid IDs):
    -- getComponent inside getCurrentLine/getCurrentStation/getTimeUntilDeparture triggers a
    -- C++ assert on invalid entities (GetComponentDataIndex, not catchable by pcall). Check entityExists first and skip invalid ones.
    local okEv, exists = pcall(_entityExists, tonumber(vehicle))
    if okEv and exists ~= true then return false end

    local time = timetableHelper.getTime()
    local currentLine = timetableHelper.getCurrentLine(vehicle)
    local currentStop = timetableHelper.getCurrentStation(vehicle)
    local currentLineString = tostring(currentLine)
    if not timetableObject[currentLineString] then return false end
    -- Line doesn't have "follow timetable" ticked (hasTimetable ~= true): no vehicle control at all.
    -- Final user decision: unticked lines load/unload and depart as the game does by default; even if the line has leftover station time data
    -- (e.g. configured earlier, unticked later) vehicles must not be held/interfered with. The coroutine has its own hasTimetable filter;
    -- this is the safety net (against direct calls or leftover data).
    if timetableObject[currentLineString].hasTimetable ~= true then return false end
    if not timetableObject[currentLineString].stations[currentStop] then return false end
    -- Read validation (2026-08-16 final design): time data is stored by "position in the line"; after removing/building stations the positions shift
    -- (reconcileStationData puts them back every 5s; this covers the window between two reconciliations).
    -- If the saved stationID at this position doesn't match the actual current station -> treat as "no data" (release, don't hold),
    -- rejecting stale data rather than using it. Old data without a stationID is removed by reconciliation and not blocked here
    -- (reconciliation runs within <=5s; entries without sid keep the old behavior while waiting for it).
    local curEntrySid = timetableObject[currentLineString].stations[currentStop].stationID
    if curEntrySid ~= nil then
        local okSid, liveSid = pcall(timetableHelper.getStationID, currentLine, currentStop)
        if okSid and liveSid and liveSid > 0 and tostring(curEntrySid) ~= tostring(liveSid) then
            return false
        end
    end
    if not timetableObject[currentLineString].stations[currentStop].conditions then return false end
    if not timetableObject[currentLineString].stations[currentStop].conditions.type then return false end

    if not currentlyWaiting[currentLineString] then currentlyWaiting[currentLineString] = {stations = {}} end
    if not currentlyWaiting[currentLineString].stations[currentStop] then
          currentlyWaiting[currentLineString].stations[currentStop] = { currentlyWaiting = {}, outboundTime = {} }
    end
    local stopData = currentlyWaiting[currentLineString].stations[currentStop]
    normalizeStopData(stopData)

    -- Gate (only for vehicles "not yet held"): don't interfere while the door-closing countdown is >=5s, keeping the conservative behavior of
    -- "not interfering during the engine's default stopping procedure after arrival". Held vehicles must skip this gate -- otherwise, when the engine
    -- resets/keeps the door-closing timer at >=5 while the vehicle is held, this function wrongly returns false -> startVehicle releases the hold ->
    -- the train "stops briefly and departs immediately" instead of waiting for the timetable departure time.
    if stopData.currentlyWaiting[vehicle] == nil
       and timetableHelper.getTimeUntilDeparture(vehicle) >= 5 then
        return false
    end

    if timetableObject[currentLineString].stations[currentStop].conditions.type == "ArrDep" then
        local constraints = timetableObject[currentLineString].stations[currentStop].conditions.ArrDep
        if not constraints or #constraints == 0 then
            stopData.currentlyWaiting = {}
            return false
        end

        -- Don't interfere within 40s after departure (prevents being held again due to a lagging departure check).
        -- outboundTime must be recorded per vehicle: if the whole station shared one timestamp, a late vehicle released first at the station
        -- would also release other vehicles that should wait for their departure time within those 40s -> the other vehicle "stops briefly and departs immediately".
        local ob = stopData.outboundTime and stopData.outboundTime[vehicle]
        if ob and (ob + 40) > time then
            return false
        end

        -- Delay tolerance (seconds): 0 = none (always release immediately, however late)
        local tolerance = timetable.getDelayTolerance()

        -- Per-line vehicle control switch (2026-08-16 feature): with depart-on-time=true (default), min/max have no effect (greyed out in the UI, ignored by the logic);
        -- with =false, the min lower bound / max upper bound apply, and "release" becomes a normal release (no forced departure, the engine leaves when loading is done).
        local forceDep = timetable.getForceDepartureEnabled(currentLine)
        local minEn = (not forceDep) and timetable.getMinWaitEnabled(currentLine)
        local maxEn = (not forceDep) and timetable.getMaxWaitEnabled(currentLine)
        -- The min/max values = the engine's native Line.Stop dwell limits (api.type Line.Stop.minWaitingTime/maxWaitingTime);
        -- vehicle arrival time = TRANSPORT_VEHICLE.doorsTime (microseconds -> seconds, read the same way as in 3625975189).
        -- The arrival time is always read: it is the reference for matching the train to a slot.
        local dwellMin, dwellMax, arrivalSec = nil, nil, nil
        pcall(function()
            if minEn or maxEn then
                local okEv2, exists2 = pcall(function() return api.engine.entityExists(currentLine) end)
                if okEv2 and exists2 == true then
                    local okLS2, lineObj2 = pcall(function()
                        return api.engine.getComponent(currentLine, api.type.ComponentType.LINE)
                    end)
                    if okLS2 and lineObj2 and lineObj2.stops and lineObj2.stops[currentStop] then
                        local stInfo = lineObj2.stops[currentStop]
                        dwellMin = stInfo.minWaitingTime
                        dwellMax = stInfo.maxWaitingTime
                    end
                end
            end
            local okEv3, exists3 = pcall(function() return api.engine.entityExists(tonumber(vehicle)) end)
            if okEv3 and exists3 == true then
                local okVC, vc2 = pcall(function()
                    return api.engine.getComponent(tonumber(vehicle), api.type.ComponentType.TRANSPORT_VEHICLE)
                end)
                if okVC and vc2 and vc2.doorsTime then
                    arrivalSec = math.floor(vc2.doorsTime / 1000000)
                end
            end
        end)
        -- Delay the vehicle carried out of its previous timed stop on this line. Subtracting it
        -- from the arrival gives the arrival "on schedule", so a delayed train is matched to its
        -- own slot instead of being mistaken for an early train of a later slot.
        local lineWaiting = currentlyWaiting[currentLineString]
        if type(lineWaiting.vehicleDelay) ~= "table" then lineWaiting.vehicleDelay = {} end
        local carriedDelay = 0
        local delayRec = lineWaiting.vehicleDelay[vehicle]
        if type(delayRec) == "table" and type(delayRec.delay) == "number" and type(delayRec.time) == "number"
           and time - delayRec.time < VEHICLE_DELAY_MAX_AGE then
            if arrivalSec and delayRec.time >= arrivalSec then
                -- Recorded during this visit (re-evaluated after release): use the delay it arrived with.
                carriedDelay = delayRec.inDelay or 0
            else
                carriedDelay = delayRec.delay
            end
        end

        -- Slot claims: which vehicle runs on which departure at this stop (key = tostring(absDep)).
        -- A slot claimed by another vehicle is skipped when matching, so that vehicles which are
        -- bunched (e.g. after adding vehicles and slots to a line) spread out over the free slots
        -- instead of chasing the same one.
        local claims = stopData.slotClaims
        for k in pairs(claims) do
            local t = tonumber(k)
            if not t or t < time - SLOT_CLAIM_MAX_AGE then claims[k] = nil end
        end
        local function slotTaken(dep)
            local owner = claims[tostring(dep)]
            if owner == nil or owner == vehicle then return false end
            -- Already departed on it.
            if dep <= time then return true end
            -- Future slot: only while the owner is still held for it here.
            local w = stopData.currentlyWaiting[owner]
            return type(w) == "table" and w.dep == dep
        end

        -- Single exit point for release: depart-on-time=true -> forced departure; false -> normal release only (the engine leaves after loading and closing doors, loading is not cut short).
        -- refDep: the departure the train runs on; the delay against it is carried to the next stop.
        local function releaseNow(forceIt, refDep)
            stopData.currentlyWaiting[vehicle] = nil
            stopData.outboundTime[vehicle] = time
            if refDep then
                lineWaiting.vehicleDelay[vehicle] = {
                    delay = math.max(0, time - refDep), inDelay = carriedDelay, time = time,
                }
                claims[tostring(refDep)] = vehicle
            end
            if forceIt then timetableHelper.forceDeparture(vehicle) end
        end
        -- Holds the train until the given departure. The target is stored so that the decision
        -- stays fixed while the train waits (it is not re-matched on every tick).
        -- slot = departure of the slot the train runs on (only differs from dep in old saves).
        local function holdNow(dep, late, slot)
            local prev = stopData.currentlyWaiting[vehicle]
            stopData.currentlyWaiting[vehicle] = {
                type = "ArrDep",
                arrivalTime = (prev and prev.arrivalTime) or time,
                dep = dep,
                late = late,
                slot = slot,
            }
            if dep then claims[tostring(dep)] = vehicle end
        end

        -- missDep    = the departure that has been reached or missed (absolute seconds)
        -- checkDelay = whether the delay tolerance still applies (not for a stored target)
        -- isLate     = the train was held after missing its slot (for the max dwell cap)
        local entry = stopData.currentlyWaiting[vehicle]
        if entry and arrivalSec and entry.arrivalTime and arrivalSec > entry.arrivalTime then
            -- Left over from an earlier visit (train left without being released here).
            entry = nil
        end
        local missDep, checkDelay, isLate
        if entry and entry.dep then
            -- Already held: wait for the stored departure.
            isLate = entry.late == true
            if time < entry.dep then
                if isLate and not forceDep and maxEn and arrivalSec and dwellMax
                   and time >= arrivalSec + dwellMax then
                    releaseNow(true, entry.slot)
                    return false
                end
                return true
            end
            missDep = entry.dep
            checkDelay = false
        else
            -- Match the arrival, minus the carried delay, to the closest slot. Falls back to the
            -- current time if the arrival time is unavailable or implausible.
            local ref = time
            if arrivalSec and arrivalSec <= time and time - arrivalSec < 3600 then
                ref = arrivalSec
            elseif entry and entry.arrivalTime then
                ref = entry.arrivalTime
            end
            local _, slotDep = timetable.assignSlot(constraints, ref - carriedDelay, slotTaken)
            if not slotDep then
                releaseNow(false)
                return false
            end
            if time < slotDep then
                -- Early or on time: wait for the departure (with max dwell, released by ② at the point).
                holdNow(slotDep, false, slotDep)
                return true
            end
            missDep = slotDep
            checkDelay = true
            isLate = true
        end

        -- ===== Maximum dwell time (maxEn, only with depart-on-time off) -- final user decision 2026-08-16 =====
        -- max is not "blindly force departure at arrival+M" (that would make early vehicles leave early); it only covers cases where "this run's departure time has passed":
        --   (1) still at the station M seconds after arrival (this run's departure time has passed: beyond tolerance waiting for the next run / loading ran past the time) -> force departure;
        --   (2) the vehicle "arrived before the departure time and is held until then"; leave as soon as the time comes -> force departure (don't wait for loading, cut it short);
        --   departure time not reached -> never force departure early (early vehicles wait for their time as usual; punctual, no early departures).
        --   Late but loading quickly (departure time passed, within tolerance) -> normal release "leave when loaded"; max doesn't cover this (player's decision).
        if not forceDep and maxEn and arrivalSec and dwellMax
           and time >= arrivalSec + dwellMax then
            -- (1) Still at the station M seconds after arrival: force departure regardless of tolerance or loading state (prevents waiting forever / endless loading)
            releaseNow(true, missDep)
            return false
        end
        if checkDelay and tolerance > 0 and time - missDep > tolerance
           and timetable.getHoldLateEnabled(currentLine, currentStop) then
            -- Late beyond the tolerance: hold until the next run/next cycle (with max ticked, (1) forces departure at "arrival+M")
            -- The train moves to the next free slot and runs on it from now on (its delay is
            -- measured against that slot), leaving the missed slot to nobody.
            local nextDep = timetable.getNextDeparture(constraints, time, slotTaken)
            holdNow(nextDep, true, nextDep)
            return true
        end
        -- No tolerance set (none) or delay within tolerance:
        -- depart-on-time off + minimum dwell time not reached -> keep holding until arrival+minWaitingTime, then release
        if not forceDep and minEn and arrivalSec and dwellMin and time < arrivalSec + dwellMin then
            holdNow(missDep, isLate, (entry and entry.slot) or missDep)
            return true
        end
        -- (2) Forced departure on time: vehicle arrived before this run's departure time (a vehicle "waiting for its time", not one "arriving late") -> force departure if max is ticked;
        --    vehicles arriving late that leave once loaded -> use the normal release below (max doesn't cover this case)
        if not forceDep and maxEn and arrivalSec and arrivalSec < missDep then
            releaseNow(true, missDep)
            return false
        end
        -- Depart on time (default) -> forced departure (forceDeparture must be unconditional: when a vehicle arrives for the first time and was never held,
        -- startVehicle alone doesn't make it depart immediately, it stays at the station -- AGENTS.md lesson from 2026-08-04);
        -- depart-on-time off -> normal release (the engine leaves after loading and closing doors, loading is not cut short).
        releaseNow(forceDep, missDep)
        return false


    --------------------------------------------------------------------------------------------------------------------
    --------------------------------------- DEBOUNCE -------------------------------------------------------------------
    --------------------------------------------------------------------------------------------------------------------
    elseif timetableObject[currentLineString].stations[currentStop].conditions.type == "debounce" then
        local previousDepartureTime = timetableHelper.getPreviousDepartureTime(tonumber(vehicle))
        local condition = timetable.getConditions(currentLine, currentStop, "debounce")
        if not condition then return false end
        if not condition[1] then condition[1] = 0 end
        if not condition[2] then condition[2] = 0 end
        if time > previousDepartureTime + ((condition[1] * 60)  + condition[2]) then
            currentlyWaiting[currentLineString].stations[currentStop].currentlyWaiting = {}
            return false
        else
            return true
        end
    else
        currentlyWaiting[currentLineString].stations[currentStop].currentlyWaiting = {}
        return false
    end
end

-- Whether the vehicle is currently "held waiting" (lets timetableCoroutine detect the moment of waiting -> released,
-- so that setVehicleShouldDepart can be called at the actual departure time to force the vehicle to start)
function timetable.isVehicleWaiting(vehicle)
    local currentLine = timetableHelper.getCurrentLine(vehicle)
    local currentStop = timetableHelper.getCurrentStation(vehicle)
    local lineStr = tostring(currentLine)
    local s = currentlyWaiting[lineStr]
    if not s or not s.stations then return false end
    local st = s.stations[currentStop]
    if not st or type(st.currentlyWaiting) ~= "table" then return false end
    return st.currentlyWaiting[vehicle] ~= nil
end

-- Whether a raw lineStopDepartures record (milliseconds) is a valid departure record "after this arrival".
-- (2026-08-05) The field records "the most recent departure from this station" and isn't reset between cycles: after a train departed from this station
-- in the previous cycle (e.g. 23:32) and returns in this cycle, the field still holds the old value. On lines with multiple slot sets, using the
-- old value directly as "this departure" would subtract this cycle's chosen planned departure from the previous cycle's departure -> a bogus "24 minutes early".
-- So only records "later than this arrival (>= arrTime) and not later than the current scan time (<= now)" are accepted; leftovers from the previous cycle
-- are necessarily earlier than this arrival and are excluded naturally. If arrTime is nil (missed arrival event), only <= now is checked as a fallback.
-- @param d number|nil lineStopDepartures raw value (milliseconds)
-- @param now number current game time in seconds
-- @param arrTime number|nil time of this arrival (game seconds)
-- @return boolean whether it is a valid departure record
function timetable.isValidDepartureRecord(d, now, arrTime)
    if not (d and d > 0) then return false end
    local candidate = math.floor(d / 1000)
    if candidate <= now and (not arrTime or candidate >= arrTime) then
        return true
    end
    return false
end

-- Clean up stop entries in currentlyWaiting of old saves (missing outboundTime / old scalar),
-- preventing waitingRequired from crashing when writing outboundTime[vehicle]. Called once after loading.
function timetable.sanitizeCurrentlyWaiting()
    for _, lineData in pairs(currentlyWaiting) do
        if type(lineData) == "table" and type(lineData.stations) == "table" then
            for _, st in pairs(lineData.stations) do
                if type(st) == "table" then
                    if type(st.currentlyWaiting) ~= "table" then st.currentlyWaiting = {} end
                    if type(st.outboundTime) ~= "table" then st.outboundTime = {} end
                    if type(st.slotClaims) ~= "table" then st.slotClaims = {} end
                end
            end
        end
    end
end

-- Clean up orphaned data of deleted lines in timetableObject (after the player deletes a line, the line tab disappears immediately,
-- but the station tab iterates timetableObject and reads orphaned entries -> shows "ERROR + arrival/departure times").
-- Called periodically (throttled) by the GUI/engine threads; removes orphaned entries at the source so reads don't need filtering every time.
-- Only removes entries "with a numeric key that is not in the current line set of lineSystem.getLines()"; non-numeric keys (global config like _gwNames) are kept.
-- Returns the number of removed entries (for logging/throttling).
---@param validSetIn table|nil optional "current line set" (tostring(lineId)=true). If given it is reused,
---        instead of calling getLines() again (performance optimization group A: the 5s maintenance of engine/GUI is merged into one fetch).
function timetable.cleanupOrphanLines(validSetIn)
    local validSet = validSetIn
    local haveLiveSet = validSetIn ~= nil
    if not validSet then
        validSet = {}
        local okL, lines = pcall(_getLines)
        if okL and lines then
            haveLiveSet = true
            for _, l in pairs(lines) do
                validSet[tostring(l)] = true
            end
        end
    end
    local removed = 0
    for k in pairs(timetableObject) do
        local n = tonumber(k)
        if n and n > 0 then
            local exists = validSet[tostring(n)]
            -- If the line set can't be obtained (getLines failed): don't clean up this round (conservative, avoids wrong deletions); rely on read filtering + the display layer
            if exists == nil and not haveLiveSet then
                -- skip cleanup this round
            elseif not exists then
                timetableObject[k] = nil
                removed = removed + 1
            end
        end
    end
    if removed > 0 and _G._diagramDebug then
        print("[Timetable] cleanupOrphanLines removed " .. removed .. " orphan line(s)")
    end
    return removed
end

-- Station/line structure reconciliation (2026-08-16 final design):
-- After removing/building stations, the game renumbers the line's stops (the stops array shrinks/grows), while timetable data is stored by
-- "position in the line" (stations[position]) -- when positions change the data is misaligned (trains read the wrong station's times at the old position -> line chaos).
-- Reconciliation (realigns by "the line's current stop list", independent of entityExists -- entity recycling/reuse doesn't matter):
--   * stationID still on the line: move the data to its actual current position (time content kept as is, the player's times are not lost);
--   * stationID no longer on the line (removed/taken off the line): delete the whole entry (no longer saved);
--   * old data without stationID: delete (can't be validated; "resolve stale data rather than use it").
-- The same station group appearing several times on a line (loop/reversal): paired by order of appearance (old 1st -> new 1st).
-- currentlyWaiting leftovers of deleted positions are cleared as well.
-- Diagram presets use a different structure (stored by entity key "s_<stationID>") and are not handled here (diagram_gui cleans them up separately).
-- Returns { rekeyed = n, removed = n }.
---@param validSet table|nil optional "current line set" (tostring(lineId)=true). If given, line existence is checked against the set,
---        saving one entityExists engine call per line (performance optimization group A); if omitted, the original entityExists method is kept.
function timetable.reconcileStationData(validSet)
    local stats = { rekeyed = 0, removed = 0 }
    for lineKey, lineData in pairs(timetableObject) do
        local lineID = tonumber(lineKey)
        if lineID and lineID > 0 and type(lineData) == "table" and type(lineData.stations) == "table" then
            -- Whether the line exists: prefer the set given by the caller (same getLines method as cleanupOrphanLines);
            -- otherwise fall back to entityExists (check before getComponent -- getComponent on an invalid entity = C++ assert).
            local exists = nil
            if validSet then
                exists = validSet[tostring(lineID)] == true
            else
                local okEv, ex = pcall(_entityExists, lineID)
                exists = (okEv and ex == true)
            end
            if not exists then goto continueLine end
            -- Read the current stop list: position -> stationGroup
            local liveStops = {}
            local okLS, lineObject = pcall(_getComponent, lineID, api.type.ComponentType.LINE)
            if okLS and lineObject and lineObject.stops then
                for pos, stop in pairs(lineObject.stops) do
                    if stop and stop.stationGroup and type(stop.stationGroup) == "number" then
                        liveStops[pos] = stop.stationGroup
                    end
                end
            end
            if next(liveStops) == nil then
                -- Can't read the stop list (line in a bad state): skip this round (line deletion is handled by cleanupOrphanLines)
                goto continueLine
            end

            -- Collect first, modify later (modifying a table during pairs traversal is undefined behavior in Lua 5.1)
            local byStation = {}   -- [stationID string] = { {pos, entry}, ... } (sorted by pos ascending)
            local noSid = {}       -- { pos, ... } old entries without stationID
            for oldPos, entry in pairs(lineData.stations) do
                if type(entry) == "table" then
                    local sid = entry.stationID
                    if sid == nil then
                        noSid[#noSid + 1] = oldPos
                    else
                        local k = tostring(sid)
                        if not byStation[k] then byStation[k] = {} end
                        byStation[k][#byStation[k] + 1] = { pos = oldPos, entry = entry }
                    end
                end
            end
            for _, lst in pairs(byStation) do
                table.sort(lst, function(a, b) return a.pos < b.pos end)
            end
            -- Group current positions by stationID (ascending)
            local liveByStation = {}
            for pos, sid in pairs(liveStops) do
                local k = tostring(sid)
                if not liveByStation[k] then liveByStation[k] = {} end
                liveByStation[k][#liveByStation[k] + 1] = pos
            end
            for _, lst in pairs(liveByStation) do
                table.sort(lst)
            end

            local newStations = {}
            -- Entries without stationID: delete
            for _, pos in ipairs(noSid) do
                stats.removed = stats.removed + 1
                local cwLine = currentlyWaiting[lineKey]
                if cwLine and cwLine.stations then cwLine.stations[pos] = nil end
            end
            -- Pair and realign in stationID order
            for sidStr, lst in pairs(byStation) do
                local livePositions = liveByStation[sidStr] or {}
                for i, item in ipairs(lst) do
                    local newPos = livePositions[i]
                    if newPos then
                        newStations[newPos] = item.entry
                        if newPos ~= item.pos then stats.rekeyed = stats.rekeyed + 1 end
                    else
                        -- The station is no longer on the line (removed/taken off): delete the data
                        stats.removed = stats.removed + 1
                        local cwLine = currentlyWaiting[lineKey]
                        if cwLine and cwLine.stations then cwLine.stations[item.pos] = nil end
                    end
                end
            end
            lineData.stations = newStations
        end
        ::continueLine::
    end
    return stats
end

-- Delay tolerance (seconds). 0 = none (always release immediately, however late). Default 5 minutes (300s).
-- Stored in timetableObject._delayTolerance (persisted with state.timetable, survives closing windows/reloading;
-- and synced from the GUI thread to the engine thread via sendScriptEvent; waitingRequired reads it on the engine thread).
function timetable.getDelayTolerance()
    -- Read the _G cache first (survives module reloads), then timetableObject (authoritative value after cross-thread sync)
    if type(_G._delayTolerance) == "number" then return _G._delayTolerance end
    local v = timetableObject._delayTolerance
    if type(v) ~= "number" then return 300 end
    return v
end

function timetable.setDelayTolerance(v)
    if type(v) ~= "number" or v < 0 then v = 0 end
    timetableObject._delayTolerance = v
    _G._delayTolerance = v
end

-- Time label position (diagram window): "top" / "bottom" (default) / "both" (top and bottom).
-- Persisted like the delay tolerance: stored in timetableObject (saved with state.timetable) + _G (survives module reloads).
function timetable.getTimeLabelPos()
    if _G._diagramTimeLabelPos == "top" then return "top" end
    if _G._diagramTimeLabelPos == "both" then return "both" end
    if _G._diagramTimeLabelPos == "bottom" then return "bottom" end
    local v = timetableObject._diagramTimeLabelPos
    if v == "top" then return "top" end
    if v == "both" then return "both" end
    return "bottom"
end

function timetable.setTimeLabelPos(v)
    if v ~= "top" and v ~= "both" then v = "bottom" end
    timetableObject._diagramTimeLabelPos = v
    _G._diagramTimeLabelPos = v
end

-- Diagram refresh rate (ticked on the GUI thread): true = auto refresh every 10s / false = manual refresh. Default false.
-- Persistence: stored in timetableObject (saved with state.timetable) + _G (survives module reloads).
function timetable.getDiagramAutoRefresh()
    if _G._diagramAutoRefresh ~= nil then return _G._diagramAutoRefresh == true end
    return timetableObject._diagramAutoRefresh == true
end

function timetable.setDiagramAutoRefresh(v)
    timetableObject._diagramAutoRefresh = v == true
    _G._diagramAutoRefresh = v == true
end

-- Diagram time scale (interval of vertical grid lines, minutes): 2 / 5 / 10. Default 5.
-- Persistence: stored in timetableObject (saved with state.timetable) + _G (survives module reloads).
function timetable.getTimeScale()
    if type(_G._diagramTimeScale) == "number" and (_G._diagramTimeScale == 2 or _G._diagramTimeScale == 5 or _G._diagramTimeScale == 10) then
        return _G._diagramTimeScale
    end
    local v = timetableObject._diagramTimeScale
    if v == 2 or v == 10 then return v end
    return 5
end

function timetable.setTimeScale(v)
    if v ~= 2 and v ~= 10 then v = 5 end
    timetableObject._diagramTimeScale = v
    _G._diagramTimeScale = v
end

-- Punctuality threshold (late/on time/early classification in the diagram's punctuality display, seconds): 0/5/10/20/30/40/50/60. Default 10.
-- Not to be confused with the "delay tolerance" (timetable._delayTolerance, minutes, controls holding vehicles).
-- Persistence: stored in timetableObject (saved with state.timetable) + _G (survives module reloads).
function timetable.getPunctThreshold()
    if type(_G._diagramPunctThreshold) == "number" then return _G._diagramPunctThreshold end
    local v = timetableObject._diagramPunctThreshold
    if type(v) == "number" and v >= 0 and v <= 60 then return v end
    return 10
end

function timetable.setPunctThreshold(v)
    if type(v) ~= "number" or v < 0 then v = 0 end
    if v > 60 then v = 60 end
    timetableObject._diagramPunctThreshold = v
    _G._diagramPunctThreshold = v
end

-- Diagram polyline direction filter: "all" / "up" (only draw upward) / "down" (only draw downward). Default "all".
-- Classification: segment end y < start y = upward (direction of increasing sort number, top of the chart); y > start = downward; equal y = horizontal dwell segment.
-- Persistence: stored in timetableObject (saved with state.timetable) + _G (survives module reloads).
function timetable.getPolylineFilter()
    local g = _G._diagramPolylineFilter
    if g == "up" or g == "down" then return g end
    local v = timetableObject._diagramPolylineFilter
    if v == "up" or v == "down" then return v end
    return "all"
end

function timetable.setPolylineFilter(v)
    if v ~= "up" and v ~= "down" then v = "all" end
    timetableObject._diagramPolylineFilter = v
    _G._diagramPolylineFilter = v
end

-- Train rotation system: whether a vehicle is a hot standby (standbys are force-stopped by the TrainRoute mod's dispatcher and bypass the timetable logic).
-- The data moved with _jrl to TrainRoute's separate save; this delegates to _G._trainRouteHooks (registered by the engine/GUI threads separately).
function timetable.isStandby(vehicleId)
    local hooks = _G._trainRouteHooks
    if hooks and hooks.isStandby then
        local ok, r = pcall(hooks.isStandby, tostring(vehicleId))
        if ok then return r == true end
    end
    return false
end

-- Vertical station spacing of the chart: "equal" / "distance" (along lines) / "time" (travel time). Default "distance".
-- Persisted like the time label position: stored in timetableObject (saved with the game) + _G (survives module reloads).
local rowSpacingModes = { equal = true, distance = true, time = true }

function timetable.getRowSpacing()
    if rowSpacingModes[_G._diagramRowSpacing] then return _G._diagramRowSpacing end
    local v = timetableObject._diagramRowSpacing
    if rowSpacingModes[v] then return v end
    return "distance"
end

function timetable.setRowSpacing(v)
    if not rowSpacingModes[v] then v = "distance" end
    timetableObject._diagramRowSpacing = v
    _G._diagramRowSpacing = v
end

-- Chart: show platform numbers above the dwell segments. Default on.
-- Persisted in timetableObject (saved with the game) + _G (survives module reloads).
function timetable.getShowPlatforms()
    if _G._diagramShowPlatforms ~= nil then return _G._diagramShowPlatforms == true end
    return timetableObject._diagramShowPlatforms ~= false
end

function timetable.setShowPlatforms(v)
    timetableObject._diagramShowPlatforms = v == true
    _G._diagramShowPlatforms = v == true
end

-- Chart: overlay of the vehicles' current positions and delays. Default on.
-- Persisted like the platform numbers setting.
function timetable.getShowVehicles()
    if _G._diagramShowVehicles ~= nil then return _G._diagramShowVehicles == true end
    return timetableObject._diagramShowVehicles ~= false
end

function timetable.setShowVehicles(v)
    timetableObject._diagramShowVehicles = v == true
    _G._diagramShowVehicles = v == true
end

function timetable.setHasTimetable(line, bool)
    if timetableObject[tostring(line)] then
        timetableObject[tostring(line)].hasTimetable = bool
    else
        timetableObject[tostring(line)] = {stations = {} , hasTimetable = bool, dp = {}}
    end
    return bool
end

-- ===== Per-line vehicle control switch (2026-08-16 feature, following 3625975189) =====
-- Stored in timetableObject[line] (persisted with the save, synced across threads via sendScriptEvent).
--   Depart on time (forceDeparture): default true -- always force departure on time (current behavior); false = normal release (the engine leaves when loading is done)
--   Minimum dwell time (minWaitEnabled) / maximum dwell time (maxWaitEnabled): default false; only effective when depart-on-time = false
--     (greyed out in the UI, also ignored by the logic when force=true). Values are read from the engine's Line.Stop.minWaitingTime/maxWaitingTime.
function timetable.getForceDepartureEnabled(line)
    local entry = timetableObject[tostring(line)]
    if not entry then return true end
    local v = entry.forceDeparture
    if v == nil then return true end
    return v == true
end

function timetable.setForceDepartureEnabled(line, value)
    if timetableObject[tostring(line)] then
        timetableObject[tostring(line)].forceDeparture = value == true
    end
end

-- Per-stop holding point: whether trains later than the delay tolerance are held at this stop
-- until the next slot. Default true (old behaviour). When false, late trains depart right away;
-- early trains still wait for their departure. Stored on the station entry, so it moves along
-- with it in reconcileStationData.
function timetable.getHoldLateEnabled(line, stationNumber)
    local entry = timetableObject[tostring(line)]
    local st = entry and entry.stations and entry.stations[stationNumber]
    if not st or st.holdLate == nil then return true end
    return st.holdLate == true
end

function timetable.setHoldLateEnabled(line, stationNumber, value)
    local entry = timetableObject[tostring(line)]
    local st = entry and entry.stations and entry.stations[stationNumber]
    if st then
        st.holdLate = value == true
    end
end

function timetable.getMinWaitEnabled(line)
    local entry = timetableObject[tostring(line)]
    if not entry then return false end
    return entry.minWaitEnabled == true
end

function timetable.setMinWaitEnabled(line, value)
    if timetableObject[tostring(line)] then
        timetableObject[tostring(line)].minWaitEnabled = value == true
    end
end

function timetable.getMaxWaitEnabled(line)
    local entry = timetableObject[tostring(line)]
    if not entry then return false end
    return entry.maxWaitEnabled == true
end

function timetable.setMaxWaitEnabled(line, value)
    if timetableObject[tostring(line)] then
        timetableObject[tostring(line)].maxWaitEnabled = value == true
    end
end

--- Start all vehicles of given line.
---@param line table line id
function timetable.startAllLineVehicles(line)
    for _, vehicle in pairs(timetableHelper.getVehiclesOnLine(line)) do
        -- Hot standbys are force-stopped by the train rotation system and don't take part in timetable start/stop
        if timetable.isStandby(vehicle) then goto continueStart end
        if timetableHelper.isInStation(vehicle) then
            local currentLine = tostring(timetableHelper.getCurrentLine(vehicle))
            local currentStop = timetableHelper.getCurrentStation(vehicle)
            if currentlyWaiting[currentLine] and currentlyWaiting[currentLine].stations[currentStop] then
                currentlyWaiting[currentLine].stations[currentStop].currentlyWaiting = {}
            end
            timetableHelper.startVehicle(vehicle)
        end
        ::continueStart::
    end
end

-- Clean up "vehicle holds left over by old mod versions" (2026-08-16 diagnosis, confirmed by player testing):
-- Old versions called setVehicleManualDeparture(true) on lines that were "unticked but had leftover time data"; this flag is persisted
-- with the save. The new coroutine no longer touches unticked lines, but the leftover flag kept vehicles at the station forever (confirmed: autoDeparture=false,
-- timeUntilDeparture frozen, daysAtTerminal growing; only ticking and unticking let startAllLineVehicles
-- clear it by chance; and "normal from the next station on" proves it was a one-off leftover). For vehicles of lines "with timetable entries but unticked
-- (hasTimetable ~= true)", this clears manualDeparture (autoDeparture back to true) ->
-- restoring the game's default behavior of departing normally after loading/unloading.
-- Boundaries:
--   * only clears manualDeparture, doesn't touch userStopped (that belongs to TrainRoute standbys / manual stops by the player; avoids conflicts);
--   * only clears "unticked lines with entries" -- this mod never held vehicles of lines without entries, so departure modes set manually by the player are unaffected;
--   * ticked lines (hasTimetable==true) are left alone (controlled normally by the coroutine).
-- Returns the number of cleared vehicles.
--
-- ===== Performance optimization group A (2026-08-16, round 21): changed to "candidate driven" =====
-- The original implementation scanned **all vehicles at stations worldwide** every 30s (os.clock) with getComponent per vehicle to get its line -- this was the spike
-- in the player report "with many mods it stutters about every 30s": cost proportional to the whole map's fleet size, regardless of "whether the player uses timetables".
-- Now candidate lines are first found by iterating timetableObject in plain Lua (same criterion as before: entry exists and
-- hasTimetable ~= true); **if there are no candidates, return immediately** (the path taken in normal play, zero engine calls);
-- only with candidates are vehicles fetched per line (one getLineVehicles per line).
-- The only difference from the old behavior: vehicles are no longer required to "currently be at a station" (AT_TERMINAL snapshot) -- the flag being cleared
-- (leftover holds with manualDeparture=false) can only occur on vehicles of these lines anyway, and "at a station" was just a
-- by-product of the original scan; vehicles not at a station are not cleared (they can't be in a held-waiting state).
function timetable.clearStaleHolds()
    local candidates = {}
    for lineKey, entry in pairs(timetableObject) do
        local lineID = tonumber(lineKey)
        if lineID and lineID > 0 and type(entry) == "table" and entry.hasTimetable ~= true then
            candidates[#candidates + 1] = lineID
        end
    end
    if #candidates == 0 then return 0 end
    local cleared = 0
    for _, lineID in ipairs(candidates) do
        local okL, vehs = pcall(_lineVehicles, lineID)
        if okL and vehs then
            for _, v in pairs(vehs) do
                local okEv, exists = pcall(_entityExists, tonumber(v))
                if okEv and exists == true then
                    local okC, vc = pcall(_getComponent, v, api.type.ComponentType.TRANSPORT_VEHICLE)
                    if okC and vc and vc.autoDeparture == false then
                        pcall(_sendManualDeparture, v, false)
                        cleared = cleared + 1
                    end
                end
            end
        end
    end
    return cleared
end

-- ===== Performance optimization group A: merged 5s maintenance entry point =====
-- Previously the engine/GUI threads each made two calls every 5s: cleanupOrphanLines() (getLines internally) +
-- reconcileStationData() (entityExists per line internally). Now merged into a single fetch:
-- getLines() once -> orphan cleanup -> surviving lines are reconciled with the same set (no more entityExists per line).
-- Semantics are identical to two separate calls (reconciliation's "does the line exist" now uses the getLines set, which is equivalent to the original entityExists method
-- for "line IDs", and getLines is more reliable for deleted lines -- AGENTS has verified results).
-- Returns: removed (number of orphaned lines removed), stats (reconciliation stats { rekeyed, removed }).
function timetable.maintainTimetableData()
    local validSet = {}
    local haveLiveSet = false
    local okL, lines = pcall(_getLines)
    if okL and lines then
        haveLiveSet = true
        for _, l in pairs(lines) do
            validSet[tostring(l)] = true
        end
    end
    local removed = 0
    local stats = { rekeyed = 0, removed = 0 }
    if haveLiveSet then
        removed = timetable.cleanupOrphanLines(validSet)
        local okR, st = pcall(timetable.reconcileStationData, validSet)
        if okR and type(st) == "table" then stats = st end
    else
        -- getLines failed: keep the original conservative behavior (no orphan cleanup; reconciliation falls back to entityExists)
        local okR, st = pcall(timetable.reconcileStationData)
        if okR and type(st) == "table" then stats = st end
    end
    return removed, stats
end


-------------- UTILS FUNCTIONS ----------

-- This function returns true if the train is before its departure time
---@param constraint table in format like: {9,0,59,0}
---@param time number in seconds
---@param allConstraints number table in format like: {{30,0,59,0},{9,0,59,0},...}
function timetable.beforeDepature(constraint, time, allConstraints)
    local arrTime = (constraint[1] * 60 + constraint[2]) % 3600
    local depTime = (constraint[3] * 60 + constraint[4]) % 3600
    local normalisedTime = time % (60 * 60)
    -- Single slot (only one run per cycle, the most common case): before departure = the departure time hasn't been reached in the current cycle.
    -- The old implementation's arrivalTimeSec wrongly used the departure fields [3][4], so nextArrival == departure,
    -- the dead zone was empty and it always decided to wait (even 1 second late was held until the next cycle).
    if allConstraints == nil or #allConstraints <= 1 then
        return normalisedTime < depTime
    end
    -- Multiple slots: before departure = not inside the dead zone [dep, nextArr) of "departed, waiting for arrival at the next station"
    local nextArrivalTime = (timetable.getTimeUntilNextConstraint(constraint, allConstraints) + arrTime) % (60 * 60)
    local inDeadZone
    if depTime <= nextArrivalTime then
        inDeadZone = normalisedTime >= depTime and normalisedTime < nextArrivalTime
    else
        inDeadZone = normalisedTime >= depTime or normalisedTime < nextArrivalTime
    end
    return not inDeadZone
end

-- This function calcualtes the time from a given constraint to its closest next constraint
---@param constraint table in format like: {9,0,59,0}
---@param allConstraints number table in format like: {{30,0,59,0},{9,0,59,0},...}
---@return number timeUntilNextContraint: {30,0,59,0}
function timetable.getTimeUntilNextConstraint(constraint, allConstraints)
    local res = 60*60
    local constraintSec =((constraint[1] * 60) + constraint[2])
    for _,v in pairs(allConstraints) do
        local toCheckSec = ((v[1] * 60) + v[2])
        if constraintSec > toCheckSec then
            toCheckSec =  toCheckSec + (60*60)
        end
        local difference = toCheckSec - constraintSec
        if difference > 0 and difference < res then
            res = difference
        end
    end
    return res
end

---Find the next valid constraint for given constraints and time
---@param constraints table in format like: {{30,0,59,0},{9,0,59,0}
---@param time number in seconds
---@return table closestConstraint example: {30,0,59,0}
function timetable.getNextConstraint(constraints, time)
    local res = {diff = 40000, value = nil}
    for _, constraint in pairs(constraints) do
        local arrMin = constraint[1]
        local arrSec = constraint[2]
        local arrTime = arrMin * 60 + arrSec

        local diff = timetable.getTimeDifference(arrTime, time % 3600)
        if (diff < res.diff) then
            res = {diff = diff, value = constraint}
        end
    end

    return res.value
end

---Calculates the time difference between two timestamps in seconds.
---Considers that 59 mins is close to 0 mins.
---@param a number in seconds between in range of 0-3599 (inclusive)
---@param b number in seconds between in range of 0-3599 (inclusive)
---@return number
function timetable.getTimeDifference(a, b)
    local absDiff = math.abs(a - b)
    if absDiff > 1800 then
        return 3600 - absDiff
    else
        return absDiff
    end
end


function timetable.getDiagramConfig()
    return diagramConfig
end

function timetable.getAllWaypointData()
    local res = {}
    for k, v in pairs(timetableObject) do
        local lineID = tonumber(k)
        if lineID and lineID > 0 and type(v) == "table" and v.waypointTimes and timetable.lineExists(k) then
            local ok, stops = pcall(timetableHelper.getAllStops, lineID)
            if ok and stops then
                for _, st in ipairs(stops) do
                    if st.type == "waypoint" and st.gwKey then
                        local times = v.waypointTimes[st.id]
                        if times and #times > 0 then
                            if not res[st.gwKey] then
                                res[st.gwKey] = {
                                    gwKey = st.gwKey,
                                    name = timetable.getGlobalWaypointName(st.gwKey) or st.name,
                                    lines = {}
                                }
                            end
                            res[st.gwKey].lines[k] = { times = times }
                        end
                    end
                end
            end
        end
    end
    return res
end

function timetable.setDiagramConfig(config)
    diagramConfig = config or {}
end


return timetable

