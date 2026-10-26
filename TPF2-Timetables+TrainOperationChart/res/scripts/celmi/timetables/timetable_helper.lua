local diagramTrains = require "celmi/timetables/diagram_trains"

local timetableHelper = {}

-- 调试汇总日志：受 _G._diagramDebug 开关控制（默认关闭），避免每次刷新/打开窗口的
-- 高频汇总日志（getAllStops/getAllStationEntities 等）对玩家造成日志刷屏与 I/O 负担。
local function dbgPrint(msg)
    if _G._diagramDebug then print("[DiagramGUI] " .. msg) end
end

-- ===== 性能优化 A 组（2026-08-16 第 21 轮）：热路径的 pcall 目标提到模块级 =====
-- 原因（玩家反馈"每隔一段时间卡一两帧"的代码侧取证）：本文件与引擎协程里大量使用
--   pcall(function() return api.engine.xxx(...) end)
-- 每次执行都会**新建一个闭包对象**；这些函数在引擎协程里每帧被调用几十~上百次、
-- 在每秒的准点扫描里被调用上千次 → 每秒数万个临时对象 → Lua GC 周期变短 →
-- 表现为周期性掉 1~2 帧（现实时间、与游戏速度无关）。
-- 改为 pcall(fn, args...) 复用模块级函数：**错误保护语义完全不变**，只是不再产生闭包垃圾。
-- 注意：这些函数体只在**调用时**访问 api（模块加载顶层不碰 api —— AGENTS 铁律）。
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
-- 真实时间秒（os.clock）。取不到时返回 nil（调用方按"本次不节流"处理）。
local function _realSeconds()
    local ok, t = pcall(os.clock)
    if ok and type(t) == "number" then return t end
    return nil
end

-- 稳定路径点实体 key。实测（2026-08-05）：v.waypoints[i] 是 SignalId 结构（api.type.SignalId），
-- 暴露数字字段：entity=SignalList 实体号、index=信号列表内序号。
-- 该身份对物理路径点唯一、与线路无关、与改名无关 → _gwNames 严格一实体一名、跨线路全局同步。
-- 注意：路径点不是普通 ECS 实体，getComponent(wpRef, ...) 在其上全部报错（pcall 抓不到值），
-- getEdgeForEdgeObject/MODEL_INSTANCE_LIST 也取不到 —— 只能靠 .entity/.index。
function timetableHelper.getWaypointEntityKey(wpRef, sgEntity, wpIndex)
    local sigEntity, sigIndex = nil, nil
    pcall(function()
        sigEntity = wpRef.entity
        sigIndex = wpRef.index
    end)
    if sigEntity ~= nil then
        return "gws_" .. tostring(sigEntity) .. "_" .. tostring(sigIndex or 0)
    end
    -- 降级（理论路径点都带 .entity，此为防御）：edge + 世界坐标
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
    -- 最后兜底：父站+序号（不含名字，改名不失效）。该情况下跨线路身份无法保证，属可接受降级。
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
    local ok, res = pcall(_lineVehicles, line)
    if ok and res then return res end
    return {}
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
-- returns Null
-- 强制车辆立即发车：仅在"等待→放行"瞬间调用，配合 stopVehicle 的
-- setVehicleManualDeparture(true) 实现在到点后真正启动车辆。
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

local function getEntityPosition(entity)
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

---@param line number | string
-- returns [seconds] travel time estimate of the leg leaving each stop, indexed by stop index.
-- Uses the median of the measured sectionTimes of all vehicles on the line; legs no vehicle has
-- driven yet get a share of the round trip estimated from the line frequency, split by distance.
-- Entries may be nil where no estimate is possible.
function timetableHelper.getLegTimeEstimates(line)
    if type(line) == "string" then line = tonumber(line) end
    if not(type(line) == "number") then return {} end
    local okL, lineObject = pcall(function()
        return api.engine.getComponent(line, api.type.ComponentType.LINE)
    end)
    if not (okL and lineObject and lineObject.stops) then return {} end
    local stationGroups = {}
    local n = 0
    for k, v in pairs(lineObject.stops) do
        stationGroups[k] = v.stationGroup
        if k > n then n = k end
    end
    if n == 0 then return {} end

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
            local x, y = getEntityPosition(sg)
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

    return diagramTrains.estimateLegTimes(samples, distances, roundTrip, n)
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
            }

            if v.waypoints then
                local wpCount = 0
                if type(v.waypoints) == "userdata" then
                    local ok, len = pcall(function() return #v.waypoints end)
                    if ok and len then wpCount = len end
                elseif type(v.waypoints) == "table" then
                    wpCount = #v.waypoints
                end
                -- 逐条验证、遇到无效/越界实体即截断：Line.Stop.waypoints 是 userdata，
                -- 其 # 可能返回虚高（无路径点的车站概率性多出几个"路径点"即此原因），
                -- 实体也可能已被删除。越界索引会返回 nil 或抛错（pcall 捕获），以此截断。
                -- 注意：不能用"是否有 NAME 组件"判断有效——未命名路径点可能没有 NAME 组件，
                -- 一旦第一个 waypoint 校验失败就 break，会导致路径点全部消失。
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


-- 返回车辆 ID 数组（list）：仅包含"勾选了遵循时刻表（hasTimetable == true）"的线路、
-- 且当前停在站内的车辆（TransportVehicleState.AT_TERMINAL）。
-- 用户定稿：未勾选"遵循时刻表"的线路完全不受 mod 控车——按游戏默认装卸车后正常发车，
-- 也不得干预其它未安排时刻表的线路（含公共汽车/电车/船/飞机）。
-- 注意（三条血泪）：
-- 1) 调用方传入 hasTimetable 过滤函数。此前改为 getVehiclesWithState 时把过滤漏掉了，
--    → 协程对全地图所有站内车辆逐帧 stopVehicle/startVehicle，未勾选线路被误扣车；
-- 2) 返回值必须是"车辆 ID 数组"（值=车辆 ID）。若返回 {车辆ID: 线路ID} 映射表，
--    协程 for _,v in pairs() 取到的是线路 ID，waitingRequired(线路ID) 内
--    getComponent(线路, TRANSPORT_VEHICLE) 触发 C++ assert（GetComponentDataIndex，
--    pcall 抓不住）→ 协程卡死 → 每帧刷 "cannot resume non-suspended coroutine"；
-- 3) getVehiclesWithState 快照可能含刚删除的失效 ID：必须先 entityExists 校验再
--    getComponent（AGENTS.md：getComponent 对无效实体 = C++ assert，pcall 无效）。
--
-- ===== 性能优化 A 组（2026-08-16 第 21 轮）：本函数有两个口径 =====
--   · scanByComponent（原口径，保留作**回退**与**自检基准**）：全世界停站车辆 → 逐辆
--     entityExists + getComponent(TRANSPORT_VEHICLE) 取线路 → hasTimetable 过滤。
--     开销 = 1 + 2×F 次引擎调用（F = 全世界停站车辆数），每次还各带一个闭包。
--   · scanByLineIndex（本版本默认）：先取"勾选了遵循时刻表的线路"的车辆集合
--     （每线一次 getLineVehicles，勾选线路通常个位数），再与全世界停站车辆集合求交
--     → **逐辆引擎调用降为 0**（只对命中的车做一次 entityExists 保护）。
--   自检（每 60s 一次）：两个口径的结果集合必须完全一致；一旦不一致 → 永久退回原口径
--   并打印一次提示（宁可慢也不改变控车行为）。这样即使某版本引擎的车辆 ID 类型/线路
--   归属与假设不符，也不会出现"该控的车不控了"。
local scanFastPathOk = true      -- 反查口径是否可用（自检失败 → false）
local scanNextCheckAt = nil      -- 下次自检的真实时间秒（os.clock）

-- 原口径（稳妥回退 / 自检基准）
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

-- 反查口径（勾选线路的车辆 ∩ 停站车辆）
local function scanByLineIndex(tickedLines)
    local res = {}
    if type(tickedLines) ~= "table" then return res end
    local allowed = {}
    local any = false
    for _, line in ipairs(tickedLines) do
        local okL, vehs = pcall(_lineVehicles, line)
        if okL and vehs then
            for _, v in pairs(vehs) do
                -- 同时登记原值与字符串两种键：两套引擎接口的 ID 类型若不统一也能命中
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

-- 两套口径结果是否等价（按字符串键比较集合）
local function sameVehicleSet(a, b)
    if #a ~= #b then return false end
    local seen = {}
    for _, v in ipairs(a) do seen[tostring(v)] = true end
    for _, v in ipairs(b) do
        if not seen[tostring(v)] then return false end
    end
    return true
end

---@param hasTimetable function 线路是否"遵循时刻表"的判定函数
---@param tickedLines table|nil 勾选线路的 ID 数组（调用方从 timetableObject 纯 Lua 取；给了才走反查口径）
function timetableHelper.getAllTimetableRailVehicles(hasTimetable, tickedLines)
    if not (scanFastPathOk and tickedLines) then
        return scanByComponent(hasTimetable)
    end
    local res = scanByLineIndex(tickedLines)
    -- 周期性自检：真实时间每 60s 比对一次两套口径（各一次全量扫描，开销可忽略）
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

-- Liang-Barsky 线段矩形裁剪（纯函数，可单测）。运行图放大（2026-08-16 功能）用：
-- 折线各段先按小时切段（drawWrappedSegment），再按可视时间窗口/站区窗口裁剪。
-- 输入：线段端点 (x1,y1)-(x2,y2)，矩形 [xMin,xMax]×[yMin,yMax]。
-- 线段完全在矩形外 → 返回 nil；否则返回裁剪后的 (cx1, cy1, cx2, cy2)。
function timetableHelper.clipSegmentToRect(x1, y1, x2, y2, xMin, xMax, yMin, yMax)
    local dx, dy = x2 - x1, y2 - y1
    local t0, t1 = 0, 1
    local function clipAxis(p, q)
        if p == 0 then
            -- 平行于该轴：q < 0 表示整段在矩形外侧 → 丢弃
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
