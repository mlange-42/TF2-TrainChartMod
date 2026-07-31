local timetableHelper = {}

local wpEntityIdCache = {}
local wpEntityIdCounter = 0
local function getWpEntityId(wpRef)
    if wpRef ~= nil and wpEntityIdCache[wpRef] then
        return wpEntityIdCache[wpRef]
    end
    wpEntityIdCounter = wpEntityIdCounter + 1
    local eid = "wpe_" .. wpEntityIdCounter
    if wpRef ~= nil then
        wpEntityIdCache[wpRef] = eid
    end
    return eid
end

local function getWpPersistentKey(wpRef, sgEntity, wpIndex)
    local wpName = "unknown"
    pcall(function()
        local nc = api.engine.getComponent(wpRef, api.type.ComponentType.NAME)
        if nc and nc.name and #nc.name > 0 then wpName = nc.name end
    end)
    return "gwpk_" .. tostring(sgEntity) .. "_" .. tostring(wpIndex) .. "_" .. wpName
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
    local ok, vehicles = pcall(function()
        return api.engine.system.transportVehicleSystem.getLineVehicles(line)
    end)
    if not ok or not vehicles then return res end
    for _,v in pairs(vehicles) do
        local okV, vehicle = pcall(function()
            return api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
        end)
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
    local ok, res = pcall(function()
        return api.engine.system.transportVehicleSystem.getLineVehicles(line)
    end)
    if ok and res then return res end
    return {}
end

---@param vehicle number | string
-- returns stationIndex : Number
function timetableHelper.getCurrentStation(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return -1 end
    if not vehicle then return -1 end
    local ok, res = pcall(function()
        return api.engine.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
    end)
    if not ok or not res then return -1 end
    return res.stopIndex + 1

end

---@param vehicle number | string
-- returns lineID : Number
function timetableHelper.getCurrentLine(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return -1 end
    if not vehicle then return -1 end

    local ok, res = pcall(function()
        return api.engine.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
    end)
    if not ok or not res then return -1 end
    if res and res.line then return res.line else return -1 end
end


---@param vehicle number | string
-- returns Bool
function timetableHelper.isInStation(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return false end

    local okV, v = pcall(function()
        return api.engine.getComponent(tonumber(vehicle), api.type.ComponentType.TRANSPORT_VEHICLE)
    end)
    if not okV then return false end
    return v and v.state == 2
end

---@param vehicle number | string
-- returns Null
function timetableHelper.startVehicle(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return false end

    pcall(function() api.cmd.sendCommand(api.cmd.make.setUserStopped(vehicle,false)) end)
    pcall(function() api.cmd.sendCommand(api.cmd.make.setVehicleManualDeparture(vehicle,false)) end)
    return nil
end

---@param vehicle number | string
-- returns Null
function timetableHelper.stopVehicle(vehicle)
    if type(vehicle) == "string" then vehicle = tonumber(vehicle) end
    if not(type(vehicle) == "number") then print("Expected String or Number") return false end

    pcall(function() api.cmd.sendCommand(api.cmd.make.setVehicleManualDeparture(vehicle,true)) end)
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
    local ok1, compontent = pcall(function()
        return api.engine.getComponent(vehicle, 70)
    end)
    if not ok1 or not compontent or not compontent.stopIndex then return -1 end
    local currentStopIndex = compontent.stopIndex
    for _,v in pairs(vehicleLineMap[line]) do
        local ok2, vc = pcall(function()
            return api.engine.getComponent(v, 70)
        end)
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

    local okV, v = pcall(function()
        return api.engine.getComponent(vehicle, 70)
    end)
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

    -- 优先从 Line 组件的 vehicleInfo.transportModes 判断（不依赖线路已有车辆，新建空线路也可判断）。
    -- transportModes 是 TransportMode 位字段/数组/userdata: PERSON=0 CARGO=1 CAR=2 BUS=3 TRUCK=4
    --   TRAM=5 ELECTRIC_TRAM=6 TRAIN=7 ELECTRIC_TRAIN=8 AIRCRAFT=9 SHIP=10
    -- 注意：整个字段读取链必须包在 pcall 内——lineObject 是 userdata，若没有 vehicleInfo 字段，
    -- 直接访问 lineObject.vehicleInfo 会抛 Sol2 错误且可能无法被外层捕获，导致崩溃。
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
        -- transportModes 可能是数组/位掩码数字。
        -- userdata：不做 #/索引操作（对 userdata 的 # 可能触发 C++ 异常，pcall 无法捕获），
        -- 直接跳过 transportModes 判断，回退到车辆 carrier 判断（原版可靠方式）。
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

    -- 回退：通过线路已有车辆的 carrier 判断（原版行为）
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
    -- 注意：返回所有线路（不过滤）。时刻表需要展示全部线路（公交/铁路/汽车/电车等）。
    -- 运行图（diagram_gui）需要铁路线时自行用 lineHasType(l,"RAIL") 过滤。
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

---@param line number | string
-- returns [time: Number] Array indexed by station index in sec starting with index 1
function timetableHelper.getLegTimes(line)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then return "ERROR" end
    local vehicleLineMap = api.engine.system.transportVehicleSystem.getLine2VehicleMap()
    if vehicleLineMap[line] == nil or vehicleLineMap[line][1] == nil then return {}end
    local vehicle = vehicleLineMap[line][1]
    local okVO, vehicleObject = pcall(function()
        return api.engine.getComponent(vehicle, 70)
    end)
    if not okVO then return {} end
    if vehicleObject and vehicleObject.sectionTimes then
        return vehicleObject.sectionTimes
    else
        return {}
    end
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


-- 判断 stationEntity 是否为铁路站（有铁轨连接）。
-- 依据1：getStation2edgesMap 返回该站连接的边（EdgeId，TRANSPORT_NETWORK 内索引），
--         通过 TRANSPORT_NETWORK 组件的 edges[index] 拿到 TransportEdge，再检查其 base edge 是否有 BASE_EDGE_TRACK。
-- 依据2：回退检查站组是否有铁路线路停靠。
local stationEdgesCache = nil
local railStationGroupCache = nil -- {[sgEntity]=true} 铁路线停靠的站组
local function getRailStationGroupCache()
    if railStationGroupCache ~= nil then return railStationGroupCache end
    railStationGroupCache = {}
    pcall(function()
        local ls = api.engine.system.lineSystem.getLines()
        for _, l in pairs(ls) do
            -- 只收集"明确是铁路"的线路停站（正向判断）：这里宁可漏判（站再由铁轨边判断兜底），
            -- 不能把公交空线路误收进来导致公交站被误判为铁路站。
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

local nonRailStationGroupCache = nil -- {[sgEntity]=true} 明确非铁路线（公交/电车等）停靠的站组
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

    -- 获取 stationGroup
    local okSG0, sgEntity = pcall(function()
        return api.engine.system.stationGroupSystem.getStationGroup(stationEntity)
    end)
    if not (okSG0 and sgEntity and type(sgEntity) == "number" and sgEntity > 0) then
        return false
    end

    -- 0) 站组在任何铁路线停站中 -> 铁路站（最可靠）
    if getRailStationGroupCache()[sgEntity] then
        return true
    end

    -- 0.5) 站组在非铁路线（公交/电车等）停站中 -> 非铁路站
    if getNonRailStationGroupCache()[sgEntity] then
        return false
    end

    -- 1) 检查连接的边是否铁轨（边实体有 BASE_EDGE_TRACK 组件 = 铁轨）
    if stationEdgesCache == nil then
        pcall(function()
            stationEdgesCache = api.engine.system.stationSystem.getStation2edgesMap()
        end)
        if stationEdgesCache == nil then stationEdgesCache = false end
    end
    local edges = stationEdgesCache
    -- 尝试两种 key：stationEntity 与 stationGroup
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
                        -- edge 可能是 TransportEdge（含 base edge 实体引用）或直接是 base edge 实体
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

    -- 2) 回退：检查站停靠的线路。用反向过滤（与 getAllRailLines 一致）：
    --    若有明确非铁路线路（公交/电车/水路/航空）且没有任何铁路线路，则该站为非铁路站。
    --    无法判断（空线路等）时保守保留为铁路站，避免误删。
    -- 优先 getLineStopsForStation（station 直接停靠），回退 getLineStops（站组停靠）。
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
                -- 提取线路实体：兼容多种结构 {line,int} / {int,line} / {line=...,stop=...} / line
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
                    -- 先判断 isRail 再标记 seen：同一站组可能含多个站台，
                    -- 若首个站台 isRail 判定失败，后续站台仍有机会判定成功（防止共享站组被误过滤）。
                    -- 单个站判断包 pcall：内部任何 Lua 错误不中断整个 forEach 遍历。
                    local okRail, isRail = pcall(function()
                        return timetableHelper.isRailStation(stationEntity)
                    end)
                    if not okRail then
                        isRail = true -- 判断失败时保守保留
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
    print("[timetableHelper] getAllStationEntities stations=" .. #list .. " filteredBus=" .. filteredBus)
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
            print("[DiagramGUI] getAllStops line=" .. tostring(line) .. " stopIdx=" .. tostring(k) .. " stationGroup=" .. tostring(v.stationGroup) .. " type=" .. sgType .. " -> classified as WAYPOINT")
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
            }

            if v.waypoints then
                local wpCount = 0
                if type(v.waypoints) == "userdata" then
                    local ok, len = pcall(function() return #v.waypoints end)
                    if ok and len then wpCount = len end
                elseif type(v.waypoints) == "table" then
                    wpCount = #v.waypoints
                end
                for i = 1, wpCount do
                    local ok, wpRef = pcall(function() return v.waypoints[i] end)
                    if ok and wpRef ~= nil then
                        flatIdx = flatIdx + 1
                        local wpName = UIStrings.waypoint .. flatIdx
                        pcall(function()
                            local nc = api.engine.getComponent(wpRef, api.type.ComponentType.NAME)
                            if nc and nc.name then wpName = nc.name end
                        end)
            local gwKey = getWpPersistentKey(wpRef, sgEntity, i)
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
                    end
                end
            end
        end
    end

    print("[DiagramGUI] getAllStops line=" .. tostring(line) .. " rawStops=" .. rawStops .. " stations=" .. stClassified .. " waypoints=" .. wpClassified)
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
    -- 构建连续数组再排序：arr 可能是稀疏哈希表（key 不连续），直接 table.sort 会遇到 nil 崩溃
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


-- returns [{vehicleID: lineID}]
function timetableHelper.getAllTimetableRailVehicles()
    return api.engine.system.transportVehicleSystem.getVehiclesWithState(api.type.enum.TransportVehicleState.AT_TERMINAL)
    --[[local res = {}
    local vehicleMap = api.engine.system.transportVehicleSystem.getLine2VehicleMap()
    for k,v in pairs(vehicleMap) do
        if (hasTimetable(k)) then
            for _,v2 in pairs(v) do
                res[tostring(v2)] = k
            end
        end
    end
    return res]]--
end


-- returns Number, current GameTime in seconds
function timetableHelper.getTime()
    local okT, time = pcall(function()
        return api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
    end)
    if not okT then return 0 end
    if time then
        time = math.floor(time/ 1000)
        return time
    else
        return 0
    end
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


return timetableHelper
