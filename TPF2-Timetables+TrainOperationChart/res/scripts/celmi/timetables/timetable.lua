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

-- ===== 性能优化 A 组（2026-08-16 第 21 轮）：热路径 pcall 目标提到模块级 =====
-- 与 timetable_helper.lua 同一处优化：原写法 pcall(function() … end) 每次执行都新建闭包，
-- 而本文件的热函数（waitingRequired 每帧每车、cleanupOrphanLines/reconcileStationData 每 5s、
-- clearStaleHolds）每秒会产生成千上万个临时闭包 → Lua GC 周期变短 → 玩家可感的周期性掉帧。
-- 改成 pcall(fn, args…) 复用模块级函数：错误保护语义不变，只去掉垃圾。
-- （函数体只在调用时访问 api —— 模块顶层不碰 api，遵守 AGENTS 铁律。）
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

-- 取某站的 ArrDep 到发时刻数组（{ {arrMin,arrSec,depMin,depSec}, ... }），无则返回 nil。
local function getStationArrDep(stationInfo)
    if type(stationInfo) ~= "table" then return nil end
    local cond = stationInfo.conditions
    if type(cond) ~= "table" then return nil end
    local arr = cond.ArrDep
    if type(arr) ~= "table" or #arr == 0 then return nil end
    return arr
end

-- 把 src 的所有时刻追加到 dst 末尾（dst 原地扩展）。
local function appendSlots(dst, src)
    for _, slot in pairs(src) do
        dst[#dst + 1] = slot
    end
end

-- 数据同步：把旧版 mod（2918585390 / 1.5）用数字 key 存的线路时刻迁移到本 mod 的字符串 key。
-- 语义：追加不覆盖——目标 string key 不存在则整条搬过去；已存在则按站把 number 的 ArrDep 时刻
-- 追加到 string 对应站的 ArrDep 列表末尾（多套时刻全部保留，重复的由用户自行删除）。
-- 只处理顶层数字 key（线路 ID）；_gwNames / _diagram* 等字符串 key 原样保留。
-- 由时刻表设置 Tab 的"数据同步"按钮显式触发（不做读档自动迁移，保证用户知情）。
-- 返回报告 { lines = { [lineKey] = { [stationNumber] = 新增ArrDep套数 } }, totalSlots = N }。
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
            -- 目标 string 不存在：整条搬过去
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
            -- 目标 string 已存在：按站追加，不覆盖
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
            -- 数字 key 但值不是表（防御，不应发生）：原样搬到 string key
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


-- 表 t 是否含线路条目（数字 key 或可转数字的字符串 key，>0）。
-- 用于跨线程同步安全防御：GUI 线程若因模块重载/加载失败只剩设置键（_diagram*）或空表，
-- 引擎线程据此拒绝用它覆盖已加载的完整线路数据，防止存档被清空。
function timetable.hasLineEntries(t)
    if type(t) ~= "table" then return false end
    for k in pairs(t) do
        local n = tonumber(k)
        if n and n > 0 then return true end
    end
    return false
end

-- 表 t 里是否有任一线路携带运行图预设（dp.presetList 非空）。
-- 与 hasLineEntries 配合：防止 GUI 线程同步时把引擎已加载的预设（dp）覆盖丢失。
function timetable.hasAnyPreset(t)
    if type(t) ~= "table" then return false end
    for _, v in pairs(t) do
        if type(v) == "table" and type(v.dp) == "table" and type(v.dp.presetList) == "table" and #v.dp.presetList > 0 then
            return true
        end
    end
    return false
end

-- 线路实体是否仍存在（玩家可能删除线路，timetableObject 里的孤儿数据应被过滤/清理）。
-- 判断标准：用 lineSystem.getLines() 当前实际存在的线路集合——玩家删除的线路绝不在其中，
-- 比 api.engine.entityExists 可靠（entityExists 对已删线路实测可能仍返回 true，导致过滤/清理双双失效）。
-- 注意：绝不调 getComponent 探测（对无效实体触发 C++ assert，pcall 抓不住，会崩）。
-- getLines 调用失败时回退 entityExists（保守：返回 true 视为存在，靠显示层兜底拦 ERROR）。
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
                -- 诊断：孤儿线路（带 stations 但 lineExists=false）
                skipped[#skipped + 1] = k
            end
        end
    end
    if #skipped > 0 and _G._diagramDebug then
        print("[Timetable] getAllConditionsOfAllStations skipped orphan lines: " .. table.concat(skipped, ","))
    end
    -- 过滤空站：某站只有已删除线路的时刻时（孤儿过滤后该站无任何线路），
    -- res[stationID] 是空表，不应出现在车站 Tab 列表里（否则点开是空的/残留）。
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
    -- 兼容旧格式 {min, sec} → 转为 {{min, sec}}
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

-- 清空某站某类型（ArrDep/debounce…）的全部条件条目（保留 conditions.type，保持类型不变）。
-- "自动时刻间隔生成"（2026-08-16 功能）用：保留第一条作模板、清空其余后重新生成。
function timetable.removeAllConditions(line, station, type)
    if timetableObject[tostring(line)]
       and timetableObject[tostring(line)].stations[station]
       and timetableObject[tostring(line)].stations[station].conditions then
        timetableObject[tostring(line)].stations[station].conditions[type] = {}
        return 0
    end
    return -1
end

-- 把 {分, 秒} 时刻平移 offset 秒（模 1 小时）。纯函数，供"自动时刻间隔生成"用。
---@param time table {min, sec}
---@param offset number 秒
function timetable.shiftTime(time, offset)
    local total = ((time[1] * 60 + time[2]) + offset) % 3600
    return { math.floor(total / 60), total % 60 }
end

-- 把整条 ArrDep 槽位 {arrMin, arrSec, depMin, depSec} 平移 offset 秒（模 1 小时）。
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

-- 归一化 currentlyWaiting 的停站条目（防御性：currentlyWaiting 会随存档持久化，
-- 旧存档的停站条目可能缺失 outboundTime，或 outboundTime 是旧版"整站共享时间戳"的标量数字——
-- 此时 stopData.outboundTime[vehicle] 写/读会崩溃（"attempt to index field 'outboundTime' (a nil value)"））。
-- A carried delay older than this is ignored (vehicle stood in a depot, line was edited, ...).
local VEHICLE_DELAY_MAX_AGE = 3 * 3600

local function normalizeStopData(stopData)
    if type(stopData.currentlyWaiting) ~= "table" then stopData.currentlyWaiting = {} end
    if type(stopData.outboundTime) ~= "table" then stopData.outboundTime = {} end
end

-- Matches a reference time (usually the vehicle's arrival) to the slot whose [arr, dep]
-- interval is closest to it (distance 0 if inside). Before the departure the train counts
-- as early/on time, after it as late. Ties prefer the later slot (wait rather than leave early).
---@param constraints table in format like: {{30,0,59,0},{9,0,59,0},...}
---@param ref number absolute time in seconds
---@return number|nil absArr absolute arrival time of the matched slot
---@return number|nil absDep absolute departure time of the matched slot
function timetable.assignSlot(constraints, ref)
    local bestArr, bestDep, bestDist = nil, nil, math.huge
    local base = math.floor(ref / 3600)
    for _, c in ipairs(constraints) do
        local arrTime = (c[1] * 60 + c[2]) % 3600
        local depTime = (c[3] * 60 + c[4]) % 3600
        local dwell = (depTime - arrTime) % 3600
        for k = base - 1, base + 1 do
            local absArr = arrTime + 3600 * k
            local absDep = absArr + dwell
            local dist = 0
            if ref < absArr then
                dist = absArr - ref
            elseif ref > absDep then
                dist = ref - absDep
            end
            if dist < bestDist or (dist == bestDist and absDep > bestDep) then
                bestArr, bestDep, bestDist = absArr, absDep, dist
            end
        end
    end
    return bestArr, bestDep
end

-- First departure of any slot strictly after the given time.
---@param constraints table in format like: {{30,0,59,0},{9,0,59,0},...}
---@param time number absolute time in seconds
---@return number|nil absDep
function timetable.getNextDeparture(constraints, time)
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
    -- 车辆可能已删除（玩家卖车后，协程遍历的 AT_TERMINAL 快照可能含失效 ID）：
    -- getCurrentLine/getCurrentStation/getTimeUntilDeparture 内 getComponent 对失效实体触发
    -- C++ assert（GetComponentDataIndex，pcall 抓不住）。先 entityExists 校验，无效直接跳过。
    local okEv, exists = pcall(_entityExists, tonumber(vehicle))
    if okEv and exists ~= true then return false end

    local time = timetableHelper.getTime()
    local currentLine = timetableHelper.getCurrentLine(vehicle)
    local currentStop = timetableHelper.getCurrentStation(vehicle)
    local currentLineString = tostring(currentLine)
    if not timetableObject[currentLineString] then return false end
    -- 线路未勾选"遵循时刻表"（hasTimetable ~= true）：不做任何控车。
    -- 用户定稿：不打勾的线路按游戏默认装卸车后正常发车，即使该线路残留了车站时刻数据
    -- （如以前配置过、后来取消勾选）也不得扣车/干预。协程侧另有 hasTimetable 过滤，
    -- 这里是兜底（防御直接调用或数据残留）。
    if timetableObject[currentLineString].hasTimetable ~= true then return false end
    if not timetableObject[currentLineString].stations[currentStop] then return false end
    -- 读取校验（2026-08-16 方案定稿）：时刻数据按"线路位置"存储，拆/建站后位置会错位
    -- （reconcileStationData 每 5s 归位，这里兜住两次对账之间的窗口期）。
    -- 若该位置的存档 stationID 与当前真实车站不一致 → 按"无数据"处理（放行不扣车），
    -- 拒绝旧数据而不是利用旧数据。stationID 缺失的老数据由对账删除，此处不拦截
    -- （对账 ≤5s 内执行；缺 sid 的条目在等待对账期间保持旧行为）。
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

    -- 门控（仅对"未被扣车"的车辆生效）：关门倒计时 >=5s 时不干预，保留"到站后引擎默认
    -- 停靠流程内先不干预"的保守行为。已被扣车的车辆必须跳过此门控——否则引擎在扣车状态下
    -- 把关门计时重置/保持为 >=5 时，本函数会错误返回 false → startVehicle 释放扣车 →
    -- 列车"停一下车立马就发车"，不再等到时刻表发车时刻。
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

        -- 发车后 40s 内不干预（防止发车判定滞后导致再次被扣）。
        -- outboundTime 必须按车辆分别记录：若整站共享一个时间戳，同站先被放行的晚点车
        -- 会在 40s 内把其它应该等待到发车时刻的车也一起放行 → 另一辆车"停一下车立马就发车"。
        local ob = stopData.outboundTime and stopData.outboundTime[vehicle]
        if ob and (ob + 40) > time then
            return false
        end

        -- 晚点判定标准（秒）：0 = 无（无论晚点多久都立即放行发车）
        local tolerance = timetable.getDelayTolerance()

        -- 线路控车开关（2026-08-16 功能）：到点发车=true（默认）时 min/max 不生效（UI 置灰、逻辑忽略）；
        -- =false 时 min 下限 / max 上限生效，且"放行"改为普通放行（不强发，引擎装完才走）。
        local forceDep = timetable.getForceDepartureEnabled(currentLine)
        local minEn = (not forceDep) and timetable.getMinWaitEnabled(currentLine)
        local maxEn = (not forceDep) and timetable.getMaxWaitEnabled(currentLine)
        -- min/max 的数值 = 引擎 Line.Stop 原生驻留上下限（api.type Line.Stop.minWaitingTime/maxWaitingTime）；
        -- 车辆到站时刻 = TRANSPORT_VEHICLE.doorsTime（微秒→秒，3625975189 同款取值）。
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

        -- 释放动作统一出口：到点发车=true → 强发；false → 仅普通放行（引擎装完关门才走，不掐装卸）。
        -- refDep: the departure the train runs on; the delay against it is carried to the next stop.
        local function releaseNow(forceIt, refDep)
            stopData.currentlyWaiting[vehicle] = nil
            stopData.outboundTime[vehicle] = time
            if refDep then
                lineWaiting.vehicleDelay[vehicle] = {
                    delay = math.max(0, time - refDep), inDelay = carriedDelay, time = time,
                }
            end
            if forceIt then timetableHelper.forceDeparture(vehicle) end
        end
        -- Holds the train until the given departure. The target is stored so that the decision
        -- stays fixed while the train waits (it is not re-matched on every tick).
        -- slot = departure of the slot the train was matched to (differs from dep when it is
        -- held for a later slot).
        local function holdNow(dep, late, slot)
            local prev = stopData.currentlyWaiting[vehicle]
            stopData.currentlyWaiting[vehicle] = {
                type = "ArrDep",
                arrivalTime = (prev and prev.arrivalTime) or time,
                dep = dep,
                late = late,
                slot = slot,
            }
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
            local _, slotDep = timetable.assignSlot(constraints, ref - carriedDelay)
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

        -- ===== 最大停站时间（maxEn，仅到点发车关闭时）——用户定稿 2026-08-16 =====
        -- max 不是"到站+M 无脑强发"（那会让早到的车提前发车），而是只兜"该趟发车时刻已过"的场合：
        --   ① 到站满 M 秒仍滞留（该趟发车时刻已过：超容差等下一趟 / 装卸拖过点）→ 强发；
        --   ② 车是"发车点前到达、被扣着等到点"的，点到即走 → 强发（不等装卸完，掐装卸）；
        --   发车时刻没到 → 绝不提前强发（早到照常等到点，保准点不早发）。
        --   晚点但装得快（发车时刻已过、容差内）→ 普通放行"装完就走"，max 不在此兜底（玩家拍板）。
        if not forceDep and maxEn and arrivalSec and dwellMax
           and time >= arrivalSec + dwellMax then
            -- ① 到站已满 M 秒仍滞留：无论超不超容差、装没装完，强发兜底（防死等/防无限装卸）
            releaseNow(true, missDep)
            return false
        end
        if checkDelay and tolerance > 0 and time - missDep > tolerance
           and timetable.getHoldLateEnabled(currentLine, currentStop) then
            -- 晚点超过判定标准：扣车到下一趟/下一周期（勾了 max 则到"到站+M"被 ① 强发）
            holdNow(timetable.getNextDeparture(constraints, time), true, missDep)
            return true
        end
        -- 未设判定标准（无）或晚点在容差内：
        -- 到点发车关闭 + 最小停站时间未满 → 继续扣到 arrival+minWaitingTime 再放行
        if not forceDep and minEn and arrivalSec and dwellMin and time < arrivalSec + dwellMin then
            holdNow(missDep, isLate, (entry and entry.slot) or missDep)
            return true
        end
        -- ② 到点强发：车到站早于该趟发车点（是"等点到"的车，不是"晚点到"的车）→ 勾了 max 强发；
        --    晚点到达、装完即走的车 → 走下面的普通放行（max 不兜此情形）
        if not forceDep and maxEn and arrivalSec and arrivalSec < missDep then
            releaseNow(true, missDep)
            return false
        end
        -- 到点发车（默认）→ 强发（必须无条件 forceDeparture：车首次到站从未被扣时
        -- 只 startVehicle 不会立即发车，会停在站里——AGENTS.md 2026-08-04 教训）；
        -- 到点发车关闭 → 普通放行（引擎装完关门才走，不掐装卸）。
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

-- 车辆当前是否处于"被扣车等待"状态（供 timetableCoroutine 检测 等待→放行 瞬间，
-- 以便在真正发车时刻调用 setVehicleShouldDepart 强制启动车辆）
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

-- 判断 lineStopDepartures 的原始记录（毫秒）是否为"本次到站后"的有效发车记录。
-- (2026-08-05) 该字段记录的是"该站最近一次发车"，跨周期不清零：列车上一周期从本站
-- 发车（如 23:32）后、本周期再回到本站，字段仍留着旧值。多套时刻表线路中，若直接把
-- 旧值当"本次发车"，会拿上一周期的发车时刻去减本周期选定那套时刻表的计划发车 → 假"早24分钟"。
-- 故只认"晚于本次到站（>= arrTime）、且不晚于当前扫描时刻（<= now）"的记录；上一周期的
-- 残留值必然早于本次到站，被自然排除。arrTime 为 nil（到站事件漏拍）时仅按 <= now 兜底。
-- @param d number|nil lineStopDepartures 原始值（毫秒）
-- @param now number 当前游戏秒
-- @param arrTime number|nil 本次到站时刻（游戏秒）
-- @return boolean 是否为有效发车记录
function timetable.isValidDepartureRecord(d, now, arrTime)
    if not (d and d > 0) then return false end
    local candidate = math.floor(d / 1000)
    if candidate <= now and (not arrTime or candidate >= arrTime) then
        return true
    end
    return false
end

-- 清理旧存档 currentlyWaiting 里的停站条目（缺失 outboundTime / 旧版标量），
-- 防止 waitingRequired 在写入 outboundTime[vehicle] 时崩溃。读档后调用一次。
function timetable.sanitizeCurrentlyWaiting()
    for _, lineData in pairs(currentlyWaiting) do
        if type(lineData) == "table" and type(lineData.stations) == "table" then
            for _, st in pairs(lineData.stations) do
                if type(st) == "table" then
                    if type(st.currentlyWaiting) ~= "table" then st.currentlyWaiting = {} end
                    if type(st.outboundTime) ~= "table" then st.outboundTime = {} end
                end
            end
        end
    end
end

-- 清理 timetableObject 中已删除线路的孤儿数据（玩家删除线路后，线路 Tab 立即消失，
-- 但车站 Tab 遍历 timetableObject 会读到孤儿条目 → 显示 "ERROR + 到发时间"）。
-- GUI/引擎线程定期调用（节流），从源头删除孤儿条目，避免每次读取都要过滤。
-- 只清理"数字 key 且不在 lineSystem.getLines() 当前线路集合中"的条目；保留非数字 key（_gwNames 等全局配置）。
-- 返回清理数量（供日志/节流判断）。
---@param validSetIn table|nil 可选的"当前线路集合"（tostring(lineId)=true）。给了就复用，
---        不再自己调一次 getLines()（性能优化 A 组：engine/GUI 的 5s 维护合并为一次取数）。
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
            -- 取不到线路集合时（getLines 失败）：本轮不清理（保守，避免误删），靠读取过滤+显示层兜底
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

-- 车站/线路结构对账（2026-08-16 方案定稿）：
-- 拆站/建站后，游戏的线路停站会重新编号（stops 数组收缩/扩张），而时刻表数据按
-- "线路位置序号"存储（stations[位置]）——位置变了数据就错位（列车按旧位置读到错站时刻 → 线路混乱）。
-- 对账逻辑（按"线路当前停站表"归位，不依赖 entityExists——实体回收/复用都不影响）：
--   * stationID 还在线路上的站：数据挪到它当前的真实位置（保持时刻内容原样，玩家的时刻不丢）；
--   * stationID 已不在线路上（被拆/被移出线路）：整条数据删除（不再进存档）；
--   * stationID 缺失的老数据：删除（无法验证，按"解决旧数据而不是利用旧数据"处理）。
-- 同一站组在线路上出现多次（环线折返）：按出现顺序配对（旧第1次 → 新第1次）。
-- 被删除位置的 currentlyWaiting 残留一并清掉。
-- 运行图预设是另一套结构（按实体键 "s_<stationID>" 存），不在这里处理（diagram_gui 单独清理）。
-- 返回 { rekeyed = n, removed = n }。
---@param validSet table|nil 可选的"当前线路集合"（tostring(lineId)=true）。给了就按集合判断线路是否存在，
---        省掉每条线路一次 entityExists 引擎调用（性能优化 A 组）；不传则维持原 entityExists 口径。
function timetable.reconcileStationData(validSet)
    local stats = { rekeyed = 0, removed = 0 }
    for lineKey, lineData in pairs(timetableObject) do
        local lineID = tonumber(lineKey)
        if lineID and lineID > 0 and type(lineData) == "table" and type(lineData.stations) == "table" then
            -- 线路是否存在：优先用调用方给的集合（同 cleanupOrphanLines 的 getLines 口径）；
            -- 否则回退 entityExists（先判断再 getComponent —— getComponent 对无效实体 = C++ assert）。
            local exists = nil
            if validSet then
                exists = validSet[tostring(lineID)] == true
            else
                local okEv, ex = pcall(_entityExists, lineID)
                exists = (okEv and ex == true)
            end
            if not exists then goto continueLine end
            -- 读当前停站表：位置 → stationGroup
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
                -- 读不到停站表（线路异常）：本轮跳过（线路删除由 cleanupOrphanLines 负责）
                goto continueLine
            end

            -- 先收集、后修改（不能在 pairs 遍历里改表，Lua 5.1 未定义行为）
            local byStation = {}   -- [stationID字符串] = { {pos, entry}, ... }（按 pos 升序）
            local noSid = {}       -- { pos, ... } 无 stationID 的旧条目
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
            -- 当前位置按 stationID 分组（升序）
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
            -- 无 stationID 条目：删除
            for _, pos in ipairs(noSid) do
                stats.removed = stats.removed + 1
                local cwLine = currentlyWaiting[lineKey]
                if cwLine and cwLine.stations then cwLine.stations[pos] = nil end
            end
            -- 按 stationID 顺序配对归位
            for sidStr, lst in pairs(byStation) do
                local livePositions = liveByStation[sidStr] or {}
                for i, item in ipairs(lst) do
                    local newPos = livePositions[i]
                    if newPos then
                        newStations[newPos] = item.entry
                        if newPos ~= item.pos then stats.rekeyed = stats.rekeyed + 1 end
                    else
                        -- 该站已不在线路上（被拆/被移出）：删除数据
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

-- 晚点判定标准（秒）。0 = 无（无论晚点多久都立即放行发车）。默认 5 分钟（300s）。
-- 存 timetableObject._delayTolerance（随 state.timetable 持久化，跨关窗/重进保留；
-- 且经 sendScriptEvent 从 GUI 线程同步到引擎线程，waitingRequired 在引擎线程读取）。
function timetable.getDelayTolerance()
    -- 先读 _G 缓存（模块重载后仍存活），再读 timetableObject（跨线程同步后的权威值）
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

-- 时间标签位置（运行图窗口）："top" 上方 / "bottom" 下方（默认）/ "both" 上下同时显示。
-- 与晚点容差同样持久化：存 timetableObject（随 state.timetable 存档）+ _G（模块重载存活）。
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

-- 运行图刷新频率（GUI 线程勾选）：true=10s 自动刷新 / false=手动刷新。默认 false。
-- 持久化：存 timetableObject（随 state.timetable 存档）+ _G（模块重载存活）。
function timetable.getDiagramAutoRefresh()
    if _G._diagramAutoRefresh ~= nil then return _G._diagramAutoRefresh == true end
    return timetableObject._diagramAutoRefresh == true
end

function timetable.setDiagramAutoRefresh(v)
    timetableObject._diagramAutoRefresh = v == true
    _G._diagramAutoRefresh = v == true
end

-- 运行图时间刻度（网格竖线间隔，分钟）：2 / 5 / 10。默认 5。
-- 持久化：存 timetableObject（随 state.timetable 存档）+ _G（模块重载存活）。
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

-- 准点判定阈值（运行图准点显示的晚点/正点/早点判定，秒）：0/5/10/20/30/40/50/60。默认 10。
-- 注意与"晚点判定标准"（timetable._delayTolerance，分钟，控制扣车）区分。
-- 持久化：存 timetableObject（随 state.timetable 存档）+ _G（模块重载存活）。
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

-- 运行图折线方向筛选："all" 全部 / "up" 只画往上走 / "down" 只画往下走。默认 "all"。
-- 判定：线段终点 y < 起点 y = 往上（sort 号增大方向，图上端）；y > 起点 = 往下；y 相等 = 停站水平段。
-- 持久化：存 timetableObject（随 state.timetable 存档）+ _G（模块重载存活）。
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

-- 交路系统：车辆是否为热备车（热备车由 TrainRoute mod 的调度强制停车管理，不走时刻表逻辑）。
-- 数据已随 _jrl 迁到 TrainRoute 的独立存档，这里委托给 _G._trainRouteHooks（引擎/GUI 线程各自注册）。
function timetable.isStandby(vehicleId)
    local hooks = _G._trainRouteHooks
    if hooks and hooks.isStandby then
        local ok, r = pcall(hooks.isStandby, tostring(vehicleId))
        if ok then return r == true end
    end
    return false
end

-- Vertical station spacing of the chart: "equal" / "distance" (along lines) / "time" (travel time). Default "distance".
-- 与时间标签位置同样持久化：存 timetableObject（随存档）+ _G（模块重载存活）。
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

-- ===== 线路控车开关（2026-08-16 功能，跟进 3625975189）=====
-- 存 timetableObject[line]（随存档持久化，经 sendScriptEvent 跨线程同步）。
--   到点发车（forceDeparture）：默认 true——到点无论如何强发（现状）；false=普通放行（引擎装完才走）
--   最小停站时间（minWaitEnabled）/ 最大停站时间（maxWaitEnabled）：默认 false；仅在 到点发车=false 时生效
--     （UI 置灰，逻辑层 force=true 时也忽略）。数值读引擎 Line.Stop.minWaitingTime/maxWaitingTime。
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
        -- 热备车由交路系统强制停车管理，不参与时刻表启停
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

-- 清理"旧版 mod 扣车残留"（2026-08-16 诊断结论，玩家实测确认）：
-- 老版本对"未勾选但残留时刻数据"的线路调用过 setVehicleManualDeparture(true)，该标志随存档
-- 持久化；新版协程不再触碰未勾选线路，但残留标志让车辆永远停在站内（实锤：autoDeparture=false、
-- timeUntilDeparture 冻结、daysAtTerminal 持续增长，只有勾选再取消才被 startAllLineVehicles
-- 碰巧清掉；且"下一站开始就正常"证实是一次性残留）。这里对"有时刻表条目但未勾选
-- （hasTimetable ~= true）"的线路车辆，清除 manualDeparture（autoDeparture 恢复 true）→
-- 恢复游戏默认装卸车后正常发车。
-- 边界：
--   * 只清 manualDeparture，不动 userStopped（那是 TrainRoute 热备车 / 玩家手动停止的领域，避免打架）；
--   * 只清"有条目的未勾选线路"——无条目线路本 mod 从未扣过车，玩家手动设置的发车模式不受影响；
--   * 勾选线路（hasTimetable==true）不动（由协程正常控车）。
-- 返回清理数量。
--
-- ===== 性能优化 A 组（2026-08-16 第 21 轮）：改为"候选驱动" =====
-- 原实现每 30s（os.clock）扫**全世界停站车辆**并逐辆 getComponent 取线路 —— 这就是玩家反馈
-- "mod 多的时候大概 30s 卡一下"里那一下尖峰：开销 ∝ 全地图车队规模，且与"玩家有没有用时刻表"无关。
-- 现在先纯 Lua 遍历 timetableObject 找出候选线路（判定条件与原来完全一致：条目存在且
-- hasTimetable ~= true），**没有候选就直接返回**（正常玩法下就是这条路径，零引擎调用）；
-- 有候选才按线路取车（每线一次 getLineVehicles）。
-- 与旧行为的唯一差别：不再要求"车辆当前在站"（AT_TERMINAL 快照）——因为要清的标志
-- （manualDeparture=false 的残留扣车）本来就只可能出现在这些线路的车辆上，而"在站"只是
-- 原扫描口径的副产品；非在站车辆不会被清（它们不可能处于扣车等待状态）。
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

-- ===== 性能优化 A 组：5s 维护合并入口 =====
-- 原来 engine/GUI 线程每 5s 各调两次：cleanupOrphanLines()（内部 getLines）+
-- reconcileStationData()（内部每线 entityExists）。现在合并为一次取数：
-- getLines() 一次 → 孤儿清理 → 幸存的线路用同一份集合对账（不再逐线 entityExists）。
-- 语义与两次单独调用完全一致（对账的"线路是否存在"改用 getLines 集合，与原 entityExists 口径
-- 对"线路 ID"本就等价，且 getLines 对已删线路更可靠 —— AGENTS 已有实测结论）。
-- 返回：removed（删掉的孤儿线路数）、stats（对账统计 { rekeyed, removed }）。
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
        -- getLines 失败：保持原保守行为（不清理孤儿；对账退回 entityExists 口径）
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
    -- 单槽位（每周期仅一趟，最常见）：发车前 = 当前周期内还没到发车时刻。
    -- 旧实现 arrivalTimeSec 误用了发车字段[3][4]，导致 nextArrival == departure、
    -- 死区为空、永远判定等待（晚点1秒也被扣到下一周期）。
    if allConstraints == nil or #allConstraints <= 1 then
        return normalisedTime < depTime
    end
    -- 多槽位：发车前 = 不在"已发车、等待下一站到达"的死区 [dep, nextArr) 内
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

