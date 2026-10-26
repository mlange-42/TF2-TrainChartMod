local diagramTrains = require "celmi/timetables/diagram_trains"

local timetableHelper = {}

-- Debug summary logs: controlled by the _G._diagramDebug switch (off by default), to avoid flooding
-- the log and I/O with high-frequency summaries (getAllStops/getAllStationEntities etc.) on every refresh/window open.
local function dbgPrint(msg)
    if _G._diagramDebug then print("[DiagramGUI] " .. msg) end
end

-- ===== Performance optimization group A (2026-08-16, round 21): hoist hot-path pcall targets to module level =====
-- Reason (code-side evidence for player report "stutters for a frame or two every now and then"): this file and the engine coroutine heavily use
--   pcall(function() return api.engine.xxx(...) end)
-- which **creates a new closure object** on every execution; these functions are called dozens to hundreds of times per frame in the engine coroutine,
-- and thousands of times per second in the punctuality scan -> tens of thousands of temporary objects per second -> shorter Lua GC cycles ->
-- shows up as periodic drops of 1-2 frames (in real time, independent of game speed).
-- Changed to pcall(fn, args...) reusing module-level functions: **error protection semantics are unchanged**, just no more closure garbage.
-- Note: these function bodies only access api **when called** (module top level never touches api -- AGENTS hard rule).
local function _entityExists(id) return api.engine.entityExists(id) end
local function _getComponent(id, ctype) return api.engine.getComponent(id, ctype) end
local function _lineVehicles(line) return api.engine.system.transportVehicleSystem.getLineVehicles(line) end
local function _vehiclesWithState(state)
    return api.engine.system.transportVehicleSystem.getVehiclesWithState(state)
end
local function _sendUserStopped(v, m) return api.cmd.sendCommand(api.cmd.make.setUserStopped(v, m)) end
local function _sendManualDeparture(v, m) return api.cmd.sendCommand(api.cmd.make.setVehicleManualDeparture(v, m)) end
local function _sendShouldDepart(v) return api.cmd.sendCommand(api.cmd.make.setVehicleShouldDepart(v)) end
local function _worldGameTime()
    local t = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
    if t then return math.floor(t / 1000) end
    return 0
end
-- Real time in seconds (os.clock). Returns nil if unavailable (caller treats this as "no throttling this time").
local function _realSeconds()
    local ok, t = pcall(os.clock)
    if ok and type(t) == "number" then return t end
    return nil
end

-- Stable waypoint entity key. Verified (2026-08-05): v.waypoints[i] is a SignalId struct (api.type.SignalId),
-- exposing numeric fields: entity = SignalList entity id, index = position within the signal list.
-- This identity is unique per physical waypoint, independent of line and of renaming -> _gwNames is strictly one name per entity, synced globally across lines.
-- Note: waypoints are not regular ECS entities; getComponent(wpRef, ...) errors on all of them (pcall yields no value),
-- and getEdgeForEdgeObject/MODEL_INSTANCE_LIST don't work either -- only .entity/.index can be used.
function timetableHelper.getWaypointEntityKey(wpRef, sgEntity, wpIndex)
    local sigEntity, sigIndex = nil, nil
    pcall(function()
        sigEntity = wpRef.entity
        sigIndex = wpRef.index
    end)
    if sigEntity ~= nil then
        return "gws_" .. tostring(sigEntity) .. "_" .. tostring(sigIndex or 0)
    end
    -- Fallback (in theory all waypoints have .entity, this is defensive): edge + world position
    local edge = nil
    pcall(function()
        edge = api.engine.system.streetSystem.getEdgeForEdgeObject(wpRef)
    end)
    local px, py = nil, nil
    pcall(function()
        local ml = api.engine.getComponent(wpRef, api.type.ComponentType.MODEL_INSTANCE_LIST)
        if ml and ml.fatInstances and ml.fatInstances[1] and ml.fatInstances[1].transf then
            local col = ml.fatInstances[1].transf:col(3)
            if col then
                px = string.format("%.2f", tonumber(col.x) or 0)
                py = string.format("%.2f", tonumber(col.y) or 0)
            end
        end
    end)
    if edge then
        if px and py then return "gwp_" .. tostring(edge) .. "_" .. px .. "_" .. py end
        return "gwp_" .. tostring(edge)
    end
    if px and py then return "gwp_p_" .. px .. "_" .. py end
    -- Last resort: parent station + index (no name, so renaming doesn't invalidate it). Cross-line identity is not guaranteed here; acceptable degradation.
    return "gwpk_" .. tostring(sgEntity) .. "_" .. tostring(wpIndex)
end

local UIStrings = {
    arr = _("arr_i18n"),
    dep = _("dep_i18n"),
    unbunchTime = _("unbunch_time_i18n"),
    waypoint = _("diagram_waypoint_i18n"),
    passing = _("diagram_passing_i18n"),
}

-------------------------------------------------------------
---------------------- Vehicle related ----------------------
-------------------------------------------------------------

-- returns [lineID] indext by VehicleID : String
function timetableHelper.getAllRailVehicles()
    local res = {}
    local vehicleMap = api.engine.system.transportVehicleSystem.getLine2VehicleMap()
    for k,v in pairs(vehicleMap) do
        for _,v2 in pairs(v) do
            res[tostring(v2)] = k
        end
    end
    return res
end

---@param line number
-- returns [{stopIndex: Number, vehicle: Number, atTerminal: Bool, countStr: "SINGLE"| "MANY" }]
--         indext by StopIndes : string
function timetableHelper.getTrainLocations(line)
    local res = {}
    local ok, vehicles = pcall(_lineVehicles, line)
    if not ok or not vehicles then return res end
    for _,v in pairs(vehicles) do
        local okV, vehicle = pcall(_getComponent, v, api.type.ComponentType.TRANSPORT_VEHICLE)
        if not okV or not vehicle then goto continueA end
        local atTerminal = vehicle.state == 2
        if res[tostring(vehicle.stopIndex)] then
            local prevAtTerminal = res[tostring(vehicle.stopIndex)].atTerminal
            res[tostring(vehicle.stopIndex)] = {
                stopIndex = vehicle.stopIndex,
                vehicle = v,
                atTerminal = (atTerminal or prevAtTerminal),
                countStr = "MANY"
            }
        else
            res[tostring(vehicle.stopIndex)] = {
                stopIndex = vehicle.stopIndex,
                vehicle = v,
                atTerminal = atTerminal,
                countStr = "SINGLE"
            }
        end
        ::continueA::
    end
    return res
end

---@param line number
-- returns [ vehicle:Number ]
function timetableHelper.getVehiclesOnLine(line)
    local ok, vec = pcall(_lineVehicles, line)
    -- Copy into a Lua table: the engine vector is only referenced by the iterator state of a
    -- `for ... in pairs(getVehiclesOnLine(...))` loop, so the GC can free it mid-loop, and the
    -- iterator then reads freed memory (native crash, not catchable by pcall).
    local res = {}
    if ok and vec then
        for i = 1, #vec do res[i] = vec[i] end
    end
    return res
end

---@param vehicle number | string
-- returns stationIndex : Number
function timetableHelper.getCurrentStation(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return -1 end
    if not vehicle then return -1 end
    local ok, res = pcall(_getComponent, vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
    if not ok or not res then return -1 end
    return res.stopIndex + 1

end

---@param vehicle number | string
-- returns lineID : Number
function timetableHelper.getCurrentLine(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return -1 end
    if not vehicle then return -1 end

    local ok, res = pcall(_getComponent, vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
    if not ok or not res then return -1 end
    if res and res.line then return res.line else return -1 end
end


---@param vehicle number | string
-- returns Bool
function timetableHelper.isInStation(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return false end

    local okV, v = pcall(_getComponent, tonumber(vehicle), api.type.ComponentType.TRANSPORT_VEHICLE)
    if not okV then return false end
    return v and v.state == 2
end

---@param vehicle number | string
-- returns Null
function timetableHelper.startVehicle(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return false end

    pcall(_sendUserStopped, vehicle, false)
    pcall(_sendManualDeparture, vehicle, false)
    return nil
end

---@param vehicle number | string
-- returns Null
function timetableHelper.stopVehicle(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return false end

    pcall(_sendManualDeparture, vehicle, true)
    return nil
end

---@param vehicle number | string
---@param held boolean
-- Holds (like stopVehicle) or releases (like startVehicle) a vehicle, but only sends the
-- commands that change its current state. Called for every stopped vehicle on every frame,
-- where re-sending unchanged commands is costly. Falls back to sending them if the vehicle
-- component can't be read.
function timetableHelper.setVehicleHeld(vehicle, held)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return false end

    local ok, vc = pcall(_getComponent, vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
    if not ok or not vc then
        if held then return timetableHelper.stopVehicle(vehicle) end
        return timetableHelper.startVehicle(vehicle)
    end
    if held then
        if vc.autoDeparture ~= false then pcall(_sendManualDeparture, vehicle, true) end
    else
        if vc.userStopped ~= false then pcall(_sendUserStopped, vehicle, false) end
        if vc.autoDeparture ~= true then pcall(_sendManualDeparture, vehicle, false) end
    end
    return nil
end

---@param vehicle number | string
-- returns Null
-- Force a vehicle to depart immediately: only called at the moment of "waiting -> released"; together with stopVehicle's
-- setVehicleManualDeparture(true) this actually starts the vehicle once its time has come.
function timetableHelper.forceDeparture(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return false end

    pcall(_sendShouldDepart, vehicle)
    return nil
end

---@param vehicle number | string
-- returns time in seconds from game start
function timetableHelper.getPreviousDepartureTime(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return false end

    local vehicleLineMap = api.engine.system.transportVehicleSystem.getLine2VehicleMap()
    local line = timetableHelper.getCurrentLine(vehicle)
    local departureTimes = {}
    local ok1, compontent = pcall(_getComponent, vehicle, 70)
    if not ok1 or not compontent or not compontent.stopIndex then return -1 end
    local currentStopIndex = compontent.stopIndex
    for _,v in pairs(vehicleLineMap[line]) do
        local ok2, vc = pcall(_getComponent, v, 70)
        if ok2 and vc and vc.lineStopDepartures then
            departureTimes[#departureTimes + 1] = vc.lineStopDepartures[currentStopIndex + 1]
        end
    end
    return (timetableHelper.maximumArray(departureTimes))/1000
end

---@param vehicle number | string
-- returns Time in seconds and -1 in case of an error
function timetableHelper.getTimeUntilDeparture(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return -1 end

    local okV, v = pcall(_getComponent, vehicle, 70)
    if not okV then return -1 end
    if v and v.timeUntilCloseDoors then return v.timeUntilCloseDoors else return -1 end
end

-------------------------------------------------------------
---------------------- Line related -------------------------
-------------------------------------------------------------

---@param lineType string, eg "RAIL", "ROAD", "TRAM", "WATER", "AIR"
-- returns Bool
function timetableHelper.isLineOfType(lineType)
    local lines = api.engine.system.lineSystem.getLines()
    local res = {}
    for k,l in pairs(lines) do
        res[k] = timetableHelper.lineHasType(l, lineType)
    end
    return res
end

---@param line  number | string
---@param lineType string, eg "RAIL", "ROAD", "TRAM", "WATER", "AIR"
-- returns Bool
function timetableHelper.lineHasType(line, lineType)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then print("Expected String or Number") return -1 end

    -- Prefer the Line component's vehicleInfo.transportModes (doesn't depend on the line having vehicles; works for new empty lines too).
    -- transportModes is a TransportMode bit field/array/userdata: PERSON=0 CARGO=1 CAR=2 BUS=3 TRUCK=4
    --   TRAM=5 ELECTRIC_TRAM=6 TRAIN=7 ELECTRIC_TRAIN=8 AIRCRAFT=9 SHIP=10
    -- Note: the whole field access chain must be inside pcall -- lineObject is userdata; if it has no vehicleInfo field,
    -- accessing lineObject.vehicleInfo directly throws a Sol2 error that may not be caught by the outer handler, causing a crash.
    local okModes, modesFound = pcall(function()
        local okL, lineObject = pcall(function()
            return api.engine.getComponent(line, api.type.ComponentType.LINE)
        end)
        if not (okL and lineObject) then return nil end
        local vi = lineObject.vehicleInfo
        if not vi then return nil end
        return vi.transportModes
    end)
    if okModes and modesFound then
        local want
        if lineType == "RAIL" then
            want = {7, 8} -- TRAIN, ELECTRIC_TRAIN
        elseif lineType == "ROAD" then
            want = {2, 3, 4} -- CAR, BUS, TRUCK
        elseif lineType == "TRAM" then
            want = {5, 6} -- TRAM, ELECTRIC_TRAM
        elseif lineType == "WATER" then
            want = {10, 12} -- SHIP, SMALL_SHIP
        elseif lineType == "AIR" then
            want = {9, 11} -- AIRCRAFT, SMALL_AIRCRAFT
        else
            return false
        end
        local modes = modesFound
        -- transportModes may be an array/bitmask number.
        -- userdata: no #/indexing (# on userdata may trigger a C++ exception that pcall cannot catch);
        -- skip the transportModes check and fall back to the vehicle carrier check (the original, reliable way).
        local matched = false
        if type(modes) == "table" then
            for _, m in ipairs(modes) do
                for _, w in ipairs(want) do
                    if m == w then matched = true; break end
                end
                if matched then break end
            end
        elseif type(modes) == "number" then
            for _, w in ipairs(want) do
                local bit = math.floor(modes / (2 ^ w)) % 2
                if bit == 1 then matched = true; break end
            end
        end
        if matched then return true end
    end

    -- Fallback: determine via the carrier of the line's existing vehicles (original behavior)
    local okCarrier, carrierVal = pcall(function()
        local okV, vehicles = pcall(function()
            return api.engine.system.transportVehicleSystem.getLineVehicles(line)
        end)
        if not (okV and vehicles and vehicles[1]) then return nil end
        local okC, component = pcall(function()
            return api.engine.getComponent(vehicles[1], api.type.ComponentType.TRANSPORT_VEHICLE)
        end)
        if okC and component then
            return component.carrier
        end
        return nil
    end)
    if okCarrier and carrierVal then
        return carrierVal == api.type.enum.Carrier[lineType]
    end
    return false
end

-- similar function in timetable_colors.lua stylesheet, import is not possible
-- if you change it here, also change it there!
local function getColorString(r, g, b)
    local x = string.format("%03.0f", (r * 100))
    local y = string.format("%03.0f", (g * 100))
    local z = string.format("%03.0f", (b * 100))
    return x .. y .. z
end

---@param line number | string
-- returns String, RGB value string eg: "204060" with Red 20, Green 40, Blue 60
function timetableHelper.getLineColour(line)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then return "default" end
    local err, colour = pcall(function()
        return api.engine.getComponent(line, api.type.ComponentType.COLOR)
    end)
    if err and colour and colour.color then
        return getColorString(colour.color.x, colour.color.y, colour.color.z)
    else
        return "default"
    end
end

function timetableHelper.getLineColourVec4(line)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then return nil end
    local ok, colour = pcall(function()
        return api.engine.getComponent(line, api.type.ComponentType.COLOR)
    end)
    if ok and colour and colour.color then
        local c = colour.color
        return api.type.Vec4f.new(c.x, c.y, c.z, 1.0)
    end
    return nil
end

---@param line number | string
-- returns lineName : String
function timetableHelper.getLineName(line)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then return "ERROR" end

    local err, res = pcall(function()
        return api.engine.getComponent(line, api.type.ComponentType.NAME)
    end)
    local component = res
    if err and component and component.name then
        return component.name
    else
        return "ERROR"
    end
end

---@param line number | string
-- returns lineFrequency : String, formatted '%M:%S'
function timetableHelper.getFrequency(line)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then return "ERROR" end

    local ok, lineEntity = pcall(function() return game.interface.getEntity(line) end)
    if ok and lineEntity and lineEntity.frequency then
        if lineEntity.frequency == 0 then return "--" end
        local x = 1 / lineEntity.frequency
        return math.floor(x / 60) .. ":" .. os.date('%S', x)
    else
        return "--"
    end
end

-- returns [{id : number, name : String}]
function timetableHelper.getAllRailLines()
    -- Note: returns all lines (unfiltered). The timetable needs to show all lines (bus/rail/road/tram etc.).
    -- The diagram (diagram_gui) filters for rail lines itself via lineHasType(l,"RAIL") when needed.
    local res = {}
    local ls = api.engine.system.lineSystem.getLines()
    for k,l in pairs(ls) do
        local okLN, lineName = pcall(function()
            return api.engine.getComponent(l, 63)
        end)
        if okLN and lineName and lineName.name then
            res[k] = {id = l, name = lineName.name}
        else
            res[k] = {id = l, name = "ERROR"}
        end
    end
    return res
end

---@param entity number station group or station
-- returns x, y of the entity (station group: its first station), or nil
function timetableHelper.getEntityPosition(entity)
    local ok, e = pcall(function() return game.interface.getEntity(entity) end)
    if not (ok and e) then return nil end
    local p = e.position
    if not p and e.stations and e.stations[1] then
        local ok2, s = pcall(function() return game.interface.getEntity(e.stations[1]) end)
        if ok2 and s then p = s.position end
    end
    if not p then return nil end
    local x, y = p[1] or p.x, p[2] or p.y
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    return x, y
end

-- Midpoint of a track/street edge, from its two nodes.
local function edgeMidpoint(edge)
    local be = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE)
    local n0 = api.engine.getComponent(be.node0, api.type.ComponentType.BASE_NODE)
    local n1 = api.engine.getComponent(be.node1, api.type.ComponentType.BASE_NODE)
    return (n0.position.x + n1.position.x) / 2, (n0.position.y + n1.position.y) / 2
end

---World position of a line waypoint (signal or waypoint, a SignalId {entity, index}):
---the midpoint of the track edge it is placed on (verified in-game).
---@param wpRef userdata SignalId from Line.Stop.waypoints
---@return number|nil x
---@return number|nil y
function timetableHelper.getWaypointPosition(wpRef)
    local ok, x, y = pcall(function()
        return edgeMidpoint(api.engine.system.streetSystem.getEdgeForEdgeObject(wpRef.entity))
    end)
    if ok and type(x) == "number" and type(y) == "number" then return x, y end
    return nil
end

---@param line number | string
-- returns [seconds] travel time estimate of the leg leaving each stop, indexed by stop index,
-- and [distance] straight-line distance of each leg (leg i: stop i -> stop i+1, last -> first).
-- Uses the median of the measured sectionTimes of all vehicles on the line; legs no vehicle has
-- driven yet get a share of the round trip estimated from the line frequency, split by distance.
-- Entries may be nil where no estimate is possible.
-- Third return value: [stopIndex] = true for legs whose estimate is a measured median.
function timetableHelper.getLegEstimates(line)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then return {}, {} end
    local okL, lineObject = pcall(function()
        return api.engine.getComponent(line, api.type.ComponentType.LINE)
    end)
    if not (okL and lineObject and lineObject.stops) then return {}, {} end
    local stationGroups = {}
    local n = 0
    for k, v in pairs(lineObject.stops) do
        stationGroups[k] = v.stationGroup
        if k > n then n = k end
    end
    if n == 0 then return {}, {} end

    local vehicles = timetableHelper.getVehiclesOnLine(line)
    local samples = {}
    local vehicleCount = 0
    for _, v in pairs(vehicles) do
        vehicleCount = vehicleCount + 1
        local okV, vc = pcall(function()
            return api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
        end)
        if okV and vc and vc.sectionTimes then
            for i = 1, n do
                local okT, t = pcall(function() return vc.sectionTimes[i] end)
                if okT and type(t) == "number" and t > 0 then
                    samples[i] = samples[i] or {}
                    table.insert(samples[i], t)
                end
            end
        end
    end

    local roundTrip = nil
    local okE, lineEntity = pcall(function() return game.interface.getEntity(line) end)
    if okE and lineEntity and type(lineEntity.frequency) == "number" and lineEntity.frequency > 0 and vehicleCount > 0 then
        roundTrip = vehicleCount / lineEntity.frequency
    end

    local positions = {}
    for i = 1, n do
        local sg = stationGroups[i]
        if type(sg) == "number" and sg > 0 then
            local x, y = timetableHelper.getEntityPosition(sg)
            if x then positions[i] = {x, y} end
        end
    end
    local distances = {}
    for i = 1, n do
        local a, b = positions[i], positions[i % n + 1]
        if a and b then
            distances[i] = math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2)
        end
    end

    local measured = {}
    for i in pairs(samples) do measured[i] = true end
    return diagramTrains.estimateLegTimes(samples, distances, roundTrip, n), distances, measured
end

-------------------------------------------------------------
---------------------- Station related ----------------------
-------------------------------------------------------------

---@param station number | string
-- returns {name : String}
function timetableHelper.getStation(station)
    if type(station) == "string" then station = tonumber(station) end
    if not(type(station) == "number") then return "ERROR" end

    local okSO, stationObject = pcall(function()
        return api.engine.getComponent(station, api.type.ComponentType.NAME)
    end)
    if okSO and stationObject and stationObject.name then
        return { name = stationObject.name }
    else
        return {name = "ERROR"}
    end
end


-- Determine whether stationEntity is a rail station (has track connections).
-- Criterion 1: getStation2edgesMap returns the edges connected to the station (EdgeId, index within TRANSPORT_NETWORK);
--         get the TransportEdge via edges[index] of the TRANSPORT_NETWORK component, then check whether its base edge has BASE_EDGE_TRACK.
-- Criterion 2: fall back to checking whether rail lines stop at the station group.
local stationEdgesCache = nil
local railStationGroupCache = nil -- {[sgEntity]=true} station groups served by rail lines
local function getRailStationGroupCache()
    if railStationGroupCache ~= nil then return railStationGroupCache end
    railStationGroupCache = {}
    pcall(function()
        local ls = api.engine.system.lineSystem.getLines()
        for _, l in pairs(ls) do
            -- Only collect stops of lines that are "definitely rail" (positive check): better to miss some here (the track edge check is the backup)
            -- than to include empty bus lines and misclassify bus stops as rail stations.
            if timetableHelper.lineHasType(l, "RAIL") then
                local okL, lineObject = pcall(function()
                    return api.engine.getComponent(l, api.type.ComponentType.LINE)
                end)
                if okL and lineObject and lineObject.stops then
                    for _, stop in pairs(lineObject.stops) do
                        if stop and stop.stationGroup and type(stop.stationGroup) == "number" then
                            railStationGroupCache[stop.stationGroup] = true
                        end
                    end
                end
            end
        end
    end)
    return railStationGroupCache
end

local nonRailStationGroupCache = nil -- {[sgEntity]=true} station groups served by definitely non-rail lines (bus/tram etc.)
local function getNonRailStationGroupCache()
    if nonRailStationGroupCache ~= nil then return nonRailStationGroupCache end
    nonRailStationGroupCache = {}
    pcall(function()
        local ls = api.engine.system.lineSystem.getLines()
        for _, l in pairs(ls) do
            local isNonRail = timetableHelper.lineHasType(l, "ROAD")
                or timetableHelper.lineHasType(l, "TRAM")
                or timetableHelper.lineHasType(l, "WATER")
                or timetableHelper.lineHasType(l, "AIR")
            if isNonRail then
                local okL, lineObject = pcall(function()
                    return api.engine.getComponent(l, api.type.ComponentType.LINE)
                end)
                if okL and lineObject and lineObject.stops then
                    for _, stop in pairs(lineObject.stops) do
                        if stop and stop.stationGroup and type(stop.stationGroup) == "number" then
                            nonRailStationGroupCache[stop.stationGroup] = true
                        end
                    end
                end
            end
        end
    end)
    return nonRailStationGroupCache
end

function timetableHelper.isRailStation(stationEntity)
    if not (type(stationEntity) == "number") then return false end

    -- Get stationGroup
    local okSG0, sgEntity = pcall(function()
        return api.engine.system.stationGroupSystem.getStationGroup(stationEntity)
    end)
    if not (okSG0 and sgEntity and type(sgEntity) == "number" and sgEntity > 0) then
        return false
    end

    -- 0) Station group is a stop of any rail line -> rail station (most reliable)
    if getRailStationGroupCache()[sgEntity] then
        return true
    end

    -- 0.5) Station group is a stop of a non-rail line (bus/tram etc.) -> non-rail station
    if getNonRailStationGroupCache()[sgEntity] then
        return false
    end

    -- 1) Check whether connected edges are tracks (edge entity has a BASE_EDGE_TRACK component = track)
    if stationEdgesCache == nil then
        pcall(function()
            stationEdgesCache = api.engine.system.stationSystem.getStation2edgesMap()
        end)
        if stationEdgesCache == nil then stationEdgesCache = false end
    end
    local edges = stationEdgesCache
    -- Try both keys: stationEntity and stationGroup
    local edgeEntry = nil
    if edges then
        edgeEntry = edges[stationEntity]
        if edgeEntry == nil then edgeEntry = edges[sgEntity] end
    end
    if edgeEntry then
        local trackFound = false
        pcall(function()
            for _, entry in ipairs(edgeEntry) do
                local edgeId = entry and entry[1]
                if edgeId and edgeId.edgeId then
                    local tnEntity = edgeId.edgeId
                    local idx = edgeId.index or 0
                    local okN, tn = pcall(function()
                        return api.engine.getComponent(tnEntity, api.type.ComponentType.TRANSPORT_NETWORK)
                    end)
                    if okN and tn and tn.edges and tn.edges[idx] then
                        local edge = tn.edges[idx]
                        -- edge may be a TransportEdge (with a base edge entity reference) or directly a base edge entity
                        local baseEntity = type(edge) == "number" and edge or (edge and (edge.edge or edge.entity or edge.baseEdge))
                        if baseEntity then
                            local okT, trackComp = pcall(function()
                                return api.engine.getComponent(baseEntity, api.type.ComponentType.BASE_EDGE_TRACK)
                            end)
                            if okT and trackComp then
                                trackFound = true
                                break
                            end
                        end
                    end
                end
            end
        end)
        if trackFound then
            return true
        end
    end

    -- 2) Fallback: check the lines stopping at the station. Uses reverse filtering (consistent with getAllRailLines):
    --    if there are definitely non-rail lines (bus/tram/water/air) and no rail lines at all, the station is non-rail.
    --    If undecidable (empty lines etc.), conservatively keep it as a rail station to avoid wrongly removing it.
    -- Prefer getLineStopsForStation (lines stopping directly at the station), fall back to getLineStops (station group stops).
    local lineStops = nil
    pcall(function()
        lineStops = api.engine.system.lineSystem.getLineStopsForStation(stationEntity)
    end)
    local lineCount = 0
    if lineStops then
        for _ in pairs(lineStops) do lineCount = lineCount + 1 end
    end
    if lineCount == 0 then
        lineStops = nil
        pcall(function()
            lineStops = api.engine.system.lineSystem.getLineStops(sgEntity)
        end)
        lineCount = 0
        if lineStops then
            for _ in pairs(lineStops) do lineCount = lineCount + 1 end
        end
    end
    if lineStops and lineCount > 0 then
        local hasRail = false
        local hasNonRail = false
        pcall(function()
            for _, entry in pairs(lineStops) do
                -- Extract the line entity: supports several structures {line,int} / {int,line} / {line=...,stop=...} / line
                local line = nil
                local et = type(entry)
                if et == "number" then
                    line = entry
                elseif et == "table" then
                    if entry[1] and (type(entry[1]) == "number" or type(entry[1]) == "userdata") then
                        line = entry[1]
                    elseif entry[2] and (type(entry[2]) == "number" or type(entry[2]) == "userdata") then
                        line = entry[2]
                    elseif entry.line then
                        line = entry.line
                    end
                end
                if line then
                    if timetableHelper.lineHasType(line, "RAIL") then
                        hasRail = true
                    end
                    if timetableHelper.lineHasType(line, "ROAD")
                        or timetableHelper.lineHasType(line, "TRAM")
                        or timetableHelper.lineHasType(line, "WATER")
                        or timetableHelper.lineHasType(line, "AIR") then
                        hasNonRail = true
                    end
                end
            end
        end)
        if hasRail then
            return true
        end
        if hasNonRail then
            return false
        end
        return true
    end
    return true
end

function timetableHelper.getAllStationEntities()
    local list = {}
    local seen = {}
    local filteredBus = 0
    local ok, err = pcall(function()
        api.engine.system.stationSystem.forEach(function(stationEntity)
            local okSG, sgEntity = pcall(function()
                return api.engine.system.stationGroupSystem.getStationGroup(stationEntity)
            end)
            if okSG and sgEntity and type(sgEntity) == "number" and sgEntity > 0 then
                local sgKey = tostring(sgEntity)
                if not seen[sgKey] then
                    -- Check isRail before marking as seen: a station group may contain several platforms;
                    -- if the first platform fails the isRail check, later platforms still get a chance (prevents shared station groups from being filtered out wrongly).
                    -- Each station check is wrapped in pcall: any Lua error inside doesn't abort the whole forEach traversal.
                    local okRail, isRail = pcall(function()
                        return timetableHelper.isRailStation(stationEntity)
                    end)
                    if not okRail then
                        isRail = true -- keep conservatively if the check fails
                    end
                    if not isRail then
                        filteredBus = filteredBus + 1
                        return
                    end
                    seen[sgKey] = true
                    local name = "Station " .. sgKey
                    local okN, nameComp = pcall(function()
                        return api.engine.getComponent(sgEntity, api.type.ComponentType.NAME)
                    end)
                    if okN and nameComp and nameComp.name then
                        name = nameComp.name
                    end
                    list[#list + 1] = { id = sgEntity, name = name }
                end
            end
        end)
    end)
    dbgPrint("[timetableHelper] getAllStationEntities stations=" .. #list .. " filteredBus=" .. filteredBus)
    if not ok then
        print("[timetableHelper] getAllStationEntities error: " .. tostring(err))
    end
    return list
end

---@param line number | string
-- returns [id : Number] Array of stationIds
function timetableHelper.getAllStations(line)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then return "ERROR" end

    local okL, lineObject = pcall(function()
        return api.engine.getComponent(line, api.type.ComponentType.LINE)
    end)
    if okL and lineObject and lineObject.stops then
        local res = {}
        for k, v in pairs(lineObject.stops) do
            res[k] = v.stationGroup
        end
        return res
    else
        return {}
    end
end

-- Platform number(s) of a line stop as shown to the player (terminal index + 1), e.g. "2",
-- or "2/3" if the stop has alternative terminals. nil if the stop has no terminal.
---@param stop userdata Line.Stop
---@return string|nil
function timetableHelper.getStopPlatformString(stop)
    local ok, terminal = pcall(function() return stop.terminal end)
    if not (ok and type(terminal) == "number") then return nil end
    local res = tostring(terminal + 1)
    pcall(function()
        local alts = stop.alternativeTerminals
        if not alts then return end
        for i = 1, #alts do
            local alt = alts[i]
            if alt and type(alt.terminal) == "number" and alt.terminal ~= terminal then
                res = res .. "/" .. tostring(alt.terminal + 1)
            end
        end
    end)
    return res
end

---@param line number | string
-- returns [{id, name, type, stopIndex, flatIndex}] Array in sequential order.
-- Stations and their attached waypoints are flattened into one sequential list:
--   Station1, Waypoint1a, Waypoint1b, Station2, Station3, Waypoint3a, ...
-- type is "station" or "waypoint"
function timetableHelper.getAllStops(line)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then return {} end

    local ok, lineObject = pcall(function()
        return api.engine.getComponent(line, api.type.ComponentType.LINE)
    end)
    if not (ok and lineObject and lineObject.stops) then return {} end

    local res = {}
    local flatIdx = 0
    local rawStops = 0
    local stClassified = 0
    local wpClassified = 0

    for k, v in pairs(lineObject.stops) do
        rawStops = rawStops + 1
        local sgEntity = v.stationGroup
        local sgType = type(sgEntity)
        if sgEntity == nil or type(sgEntity) ~= "number" then
            sgEntity = 0
            dbgPrint("[DiagramGUI] getAllStops line=" .. tostring(line) .. " stopIdx=" .. tostring(k) .. " stationGroup=" .. tostring(v.stationGroup) .. " type=" .. sgType .. " -> classified as WAYPOINT")
        end
        if sgEntity == 0 then
            wpClassified = wpClassified + 1
            flatIdx = flatIdx + 1
            local okNC, nameComp = pcall(function()
                return api.engine.getComponent(tostring(k), api.type.ComponentType.NAME)
            end)
            local wpName = (okNC and nameComp and nameComp.name) or ("Waypoint " .. k)
            res[flatIdx] = {
                id = "wp_" .. k,
                entityId = "wps_" .. tostring(k),
                name = wpName,
                type = "waypoint",
                stopIndex = k,
                flatIndex = flatIdx,
                gwKey = "gwps_" .. tostring(k),
            }
        else
            stClassified = stClassified + 1
            flatIdx = flatIdx + 1
            local stationName = timetableHelper.getStationName(sgEntity)
            res[flatIdx] = {
                id = sgEntity,
                name = stationName,
                type = "station",
                stopIndex = k,
                flatIndex = flatIdx,
                platform = timetableHelper.getStopPlatformString(v),
            }

            if v.waypoints then
                local wpCount = 0
                if type(v.waypoints) == "userdata" then
                    local ok, len = pcall(function() return #v.waypoints end)
                    if ok and len then wpCount = len end
                elseif type(v.waypoints) == "table" then
                    wpCount = #v.waypoints
                end
                -- Validate one by one and truncate at the first invalid/out-of-range entity: Line.Stop.waypoints is userdata,
                -- its # may be inflated (this is why stations without waypoints randomly get a few extra "waypoints"),
                -- and entities may have been deleted. Out-of-range indices return nil or throw (caught by pcall), which is used to truncate.
                -- Note: "has a NAME component" cannot be used as the validity check -- unnamed waypoints may have no NAME component,
                -- and breaking as soon as the first waypoint fails validation would make all waypoints disappear.
                for i = 1, wpCount do
                    local ok, wpRef = pcall(function() return v.waypoints[i] end)
                    if not (ok and wpRef ~= nil) then break end
                    flatIdx = flatIdx + 1
                    wpClassified = wpClassified + 1
                    local wpName = nil
                    pcall(function()
                        local nc = api.engine.getComponent(wpRef, api.type.ComponentType.NAME)
                        if nc and nc.name then wpName = nc.name end
                    end)
                    if not wpName then wpName = UIStrings.waypoint .. wpClassified end
                    local gwKey = timetableHelper.getWaypointEntityKey(wpRef, sgEntity, i)
                    res[flatIdx] = {
                        id = "wp_" .. k .. "_" .. i,
                        entityId = gwKey,
                        name = wpName,
                        type = "waypoint",
                        stopIndex = k,
                        flatIndex = flatIdx,
                        parentStationGroup = sgEntity,
                        gwKey = gwKey,
                    }
                    local px, py = timetableHelper.getWaypointPosition(wpRef)
                    if px then res[flatIdx].pos = { px, py } end
                end
            end
        end
    end

    dbgPrint("[DiagramGUI] getAllStops line=" .. tostring(line) .. " rawStops=" .. rawStops .. " stations=" .. stClassified .. " waypoints=" .. wpClassified)
    return res
end

---@param station number | string
-- returns stationName : String
function timetableHelper.getStationName(station)
    if type(station) == "string" then station = tonumber(station) end
    if not(type(station) == "number") then return "ERROR" end

    local err, res = pcall(function()
        return api.engine.getComponent(station, api.type.ComponentType.NAME)
    end)
    if err and res then return res.name else return "ERROR" end
end


---@param line number | string
---@param stationNumber number
-- returns stationID : Number and -1 in Error Case
function timetableHelper.getStationID(line, stationNumber)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then return -1 end

    local okLS, lineObject = pcall(function()
        return api.engine.getComponent(line, api.type.ComponentType.LINE)
    end)
    if okLS and lineObject and lineObject.stops and lineObject.stops[stationNumber] then
        return lineObject.stops[stationNumber].stationGroup
    else
        return -1
    end
end

-------------------------------------------------------------
---------------------- Array Functions ----------------------
-------------------------------------------------------------

---@param arr table
-- returns [Number], an Array where the index it the source element and the number is the target position
function timetableHelper.getOrderOfArray(arr)
    if not arr then return {} end
    -- Build a contiguous array before sorting: arr may be a sparse hash table (non-contiguous keys); table.sort on it would crash on nil
    local toSort = {}
    for k, v in pairs(arr) do
        toSort[#toSort + 1] = {key = k, value = v}
    end
    table.sort(toSort, function(a,b)
        if a == nil then return false end
        if b == nil then return false end
        return string.lower(tostring(a.value)) < string.lower(tostring(b.value))
    end)
    local res = {}
    for k, v in ipairs(toSort) do
        res[k-1] = v.key - 1
    end
    return res
end

---@param a table
---@param b table
-- returns Array, the merged arrays a,b
function timetableHelper.mergeArray(a,b)
    if a == nil then return b end
    if b == nil then return a end
    local ab = {}
    for _, v in pairs(a) do
        table.insert(ab, v)
    end
    for _, v in pairs(b) do
        table.insert(ab, v)
    end
    return ab
end


-- Returns an array (list) of vehicle IDs: only vehicles of lines with "follow timetable" ticked (hasTimetable == true)
-- that are currently stopped at a station (TransportVehicleState.AT_TERMINAL).
-- Final user decision: lines without "follow timetable" ticked are not controlled by the mod at all -- they load/unload and depart as the game does by default,
-- and other lines without a timetable (including buses/trams/ships/aircraft) must not be interfered with either.
-- Note (three hard-learned lessons):
-- 1) The caller passes a hasTimetable filter function. When this was changed to getVehiclesWithState the filter was lost,
--    -> the coroutine called stopVehicle/startVehicle every frame on all vehicles at stations on the whole map, holding vehicles of unticked lines;
-- 2) The return value must be an "array of vehicle IDs" (value = vehicle ID). If it returned a {vehicleID: lineID} map,
--    the coroutine's for _,v in pairs() would get line IDs, and inside waitingRequired(lineID)
--    getComponent(line, TRANSPORT_VEHICLE) triggers a C++ assert (GetComponentDataIndex,
--    not catchable by pcall) -> coroutine hangs -> "cannot resume non-suspended coroutine" spammed every frame;
-- 3) The getVehiclesWithState snapshot may contain just-deleted, invalid IDs: must check entityExists before
--    getComponent (AGENTS.md: getComponent on an invalid entity = C++ assert, pcall doesn't help).
--
-- ===== Performance optimization group A (2026-08-16, round 21): this function has two methods =====
--   - scanByComponent (original method, kept as **fallback** and **self-check baseline**): all vehicles at stations worldwide -> per vehicle
--     entityExists + getComponent(TRANSPORT_VEHICLE) to get the line -> hasTimetable filter.
--     Cost = 1 + 2xF engine calls (F = number of vehicles at stations worldwide), each with its own closure.
--   - scanByLineIndex (default in this version): first get the vehicles of lines with "follow timetable" ticked
--     (one getLineVehicles per line; usually only a handful of ticked lines), then intersect with all vehicles at stations
--     -> **per-vehicle engine calls drop to 0** (only one entityExists guard for each matching vehicle).
--   Self-check (every 60s): both methods must yield exactly the same set; on any mismatch -> permanently fall back to the original method
--   and print a notice once (better slow than changing vehicle control behavior). That way, even if some engine version's vehicle ID types/line
--   ownership don't match the assumptions, we never end up "not controlling vehicles that should be controlled".
local scanFastPathOk = true      -- whether the reverse lookup method is usable (self-check failed -> false)
local scanNextCheckAt = nil      -- real time in seconds (os.clock) of the next self-check

-- Original method (safe fallback / self-check baseline)
local function scanByComponent(hasTimetable)
    local res = {}
    local okS, vehicles = pcall(_vehiclesWithState, api.type.enum.TransportVehicleState.AT_TERMINAL)
    if not okS or not vehicles then return res end
    for _, v in pairs(vehicles) do
        local okEv, exists = pcall(_entityExists, tonumber(v))
        if okEv and exists == true then
            local ok, comp = pcall(_getComponent, v, api.type.ComponentType.TRANSPORT_VEHICLE)
            if ok and comp and comp.line and hasTimetable and hasTimetable(comp.line) == true then
                res[#res + 1] = v
            end
        end
    end
    return res
end

-- Reverse lookup method (vehicles of ticked lines ∩ vehicles at stations)
local function scanByLineIndex(tickedLines)
    local res = {}
    if type(tickedLines) ~= "table" then return res end
    local allowed = {}
    local any = false
    for _, line in ipairs(tickedLines) do
        local okL, vehs = pcall(_lineVehicles, line)
        if okL and vehs then
            for _, v in pairs(vehs) do
                -- Register both the raw value and its string as keys: matches even if the two engine APIs use different ID types
                allowed[v] = true
                allowed[tostring(v)] = true
                any = true
            end
        end
    end
    if not any then return res end
    local okS, vehicles = pcall(_vehiclesWithState, api.type.enum.TransportVehicleState.AT_TERMINAL)
    if not okS or not vehicles then return res end
    for _, v in pairs(vehicles) do
        if allowed[v] or allowed[tostring(v)] then
            local okEv, exists = pcall(_entityExists, tonumber(v))
            if okEv and exists == true then res[#res + 1] = v end
        end
    end
    return res
end

-- Whether the results of both methods are equivalent (set comparison by string keys)
local function sameVehicleSet(a, b)
    if #a ~= #b then return false end
    local seen = {}
    for _, v in ipairs(a) do seen[tostring(v)] = true end
    for _, v in ipairs(b) do
        if not seen[tostring(v)] then return false end
    end
    return true
end

---@param hasTimetable function whether a line "follows the timetable" (predicate)
---@param tickedLines table|nil array of ticked line IDs (caller reads it as plain Lua from timetableObject; the reverse lookup method is only used if given)
function timetableHelper.getAllTimetableRailVehicles(hasTimetable, tickedLines)
    if not (scanFastPathOk and tickedLines) then
        return scanByComponent(hasTimetable)
    end
    local res = scanByLineIndex(tickedLines)
    -- Periodic self-check: compare both methods every 60s of real time (one full scan each, negligible cost)
    local now = _realSeconds()
    if now and (scanNextCheckAt == nil or now >= scanNextCheckAt) then
        scanNextCheckAt = now + 60
        local ref = scanByComponent(hasTimetable)
        if not sameVehicleSet(res, ref) then
            scanFastPathOk = false
            print("[Timetable] perf: line-index scan mismatch (fast=" .. tostring(#res)
                .. " ref=" .. tostring(#ref) .. ") -> fallback to component scan")
            return ref
        end
    end
    return res
end


-- returns Number, current GameTime in seconds
function timetableHelper.getTime()
    local okT, time = pcall(_worldGameTime)
    if not okT or type(time) ~= "number" then return 0 end
    return time
end

---@param tab table
---@param val any
-- returns Bool,
function timetableHelper.hasValue(tab, val)
    for _, v in pairs(tab) do
        if v == val then
            return true
        end
    end

    return false
end

---@param arr table
-- returns a, the maximum element of the array
function timetableHelper.maximumArray(arr)
    local max = arr[1]
    for k,_ in pairs(arr) do
        if max < arr[k] then
            max = arr[k]
        end
    end
    return max
end


-------------------------------------------------------------
---------------------- Other --------------------------------
-------------------------------------------------------------

---@param cond table : TimetableCondition,
---@param type string, "ArrDep" |"debounce"
-- returns String, ready to display in the UI
function timetableHelper.conditionToString(cond, type)
    if (not cond) or (not type) then return "" end
    if type =="ArrDep" then
        local arr = UIStrings.arr
        local dep = UIStrings.dep
        for _,v in pairs(cond) do
            arr = arr .. string.format("%02d", v[1]) .. ":" .. string.format("%02d", v[2])  .. "|"
            dep = dep .. string.format("%02d", v[3]) .. ":" .. string.format("%02d", v[4])  .. "|"
        end
        local res = arr .. "\n"  .. dep
        return res
    elseif type == "debounce" then
        if not cond[1] then cond[1] = 0 end
        if not cond[2] then cond[2] = 0 end
        return UIStrings.unbunchTime .. ": " .. string.format("%02d", cond[1]) .. ":" .. string.format("%02d", cond[2])
    elseif type == "Passing" then
        if not cond[1] then cond[1] = 0 end
        if not cond[2] then cond[2] = 0 end
        return UIStrings.passing .. ": " .. string.format("%02d", cond[1]) .. ":" .. string.format("%02d", cond[2])
    else
        return type
    end
end

---@param i number Index of Combobox,
-- returns String, ready to display in the UI
function timetableHelper.constraintIntToString(i)
    if i == 0 then return "None"
    elseif i == 1 then return "ArrDep"
    elseif i == 2 then return "debounce"
    elseif i == 3 then return "Passing"
    else return "ERROR"
    end
end

---@param i string, "ArrDep" |"debounce" | "Passing"
-- returns Number, index of combobox
function timetableHelper.constraintStringToInt(i)
    if i == "None" then return 0
    elseif i == "ArrDep" then return 1
    elseif i == "debounce" then return 2
    elseif i == "Passing" then return 3
    else return 0
    end

end

-- Liang-Barsky segment/rectangle clipping (pure function, unit-testable). Used by diagram zoom (2026-08-16 feature):
-- polyline segments are first split per hour (drawWrappedSegment), then clipped to the visible time window/station window.
-- Input: segment endpoints (x1,y1)-(x2,y2), rectangle [xMin,xMax]x[yMin,yMax].
-- Segment fully outside the rectangle -> returns nil; otherwise returns the clipped (cx1, cy1, cx2, cy2).
function timetableHelper.clipSegmentToRect(x1, y1, x2, y2, xMin, xMax, yMin, yMax)
    local dx, dy = x2 - x1, y2 - y1
    local t0, t1 = 0, 1
    local function clipAxis(p, q)
        if p == 0 then
            -- Parallel to this axis: q < 0 means the whole segment is outside -> discard
            return q >= 0
        end
        local r = q / p
        if p < 0 then
            if r > t1 then return false end
            if r > t0 then t0 = r end
        else
            if r < t0 then return false end
            if r < t1 then t1 = r end
        end
        return true
    end
    if not (clipAxis(-dx, x1 - xMin) and clipAxis(dx, xMax - x1)
        and clipAxis(-dy, y1 - yMin) and clipAxis(dy, yMax - y1)) then
        return nil
    end
    return x1 + t0 * dx, y1 + t0 * dy, x1 + t1 * dx, y1 + t1 * dy
end

return timetableHelper
