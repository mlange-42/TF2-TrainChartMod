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


function timetable.getTimetableObject()
    return timetableObject
end

function timetable.setTimetableObject(t)
    if t then
        timetableObject = t
    end
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


function timetable.getAllConditionsOfStaion(stationID)
    local res = { }
    for k,v in pairs(timetableObject) do
        if type(v) == "table" and v.stations then
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
    for k,v in pairs(timetableObject) do
        if type(v) == "table" and v.stations then
        for _,v2 in pairs(v.stations) do
            if v2.stationID and v2.conditions and  v2.conditions.type and not (v2.conditions.type == "None")  then
                if not res[v2.stationID] then res[v2.stationID] = {} end
                res[v2.stationID][k] = {
                    conditions = v2.conditions
                }
            end
        end
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

function timetable.hasTimetable(line)
    if timetableObject[tostring(line)] then
        return timetableObject[tostring(line)].hasTimetable
    else
        return false
    end
end

function timetable.waitingRequired(vehicle)
    local time = timetableHelper.getTime()
    local currentLine = timetableHelper.getCurrentLine(vehicle)
    local currentStop = timetableHelper.getCurrentStation(vehicle)
    local currentLineString = tostring(currentLine)
    if not timetableObject[currentLineString] then return false end
    if not timetableObject[currentLineString].stations[currentStop] then return false end
    if not timetableObject[currentLineString].stations[currentStop].conditions then return false end
    if not timetableObject[currentLineString].stations[currentStop].conditions.type then return false end

    if not currentlyWaiting[currentLineString] then currentlyWaiting[currentLineString] = {stations = {}} end
    if not currentlyWaiting[currentLineString].stations[currentStop] then
          currentlyWaiting[currentLineString].stations[currentStop] = { currentlyWaiting = {}, outboundTime = {} }
    end
    local stopData = currentlyWaiting[currentLineString].stations[currentStop]

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

        -- 逐槽位计算：周期取"到达时刻离当前时刻最近"的那一趟（早到时取下一趟，
        -- 避免把早到误判成对上一趟晚点）。统计：
        --   nextDep       = 下一趟发车时刻（绝对秒，未错过槽位的发车）
        --   smallestDelay = 距最近一趟"已错过"发车的晚点秒数
        local nextDep = nil
        local smallestDelay = nil
        for _, c in ipairs(constraints) do
            local arrTime = (c[1] * 60 + c[2]) % 3600
            local depTime = (c[3] * 60 + c[4]) % 3600
            local k = math.floor((time - arrTime + 1800) / 3600)
            local absArr = arrTime + 3600 * k
            local absDep = depTime + 3600 * k
            if absDep < absArr then absDep = absDep + 3600 end
            if time < absDep then
                -- 未到该槽位发车（早到/正点）→ 作为等待候选
                if not nextDep or absDep < nextDep then nextDep = absDep end
            else
                -- 已过该槽位发车（晚点）→ 记录晚点秒数
                local delay = time - absDep
                if not smallestDelay or delay < smallestDelay then smallestDelay = delay end
            end
        end

        local wasWaiting = stopData.currentlyWaiting[vehicle] ~= nil

        if smallestDelay then
            -- 已错过某趟发车（晚点）
            if tolerance > 0 and smallestDelay > tolerance then
                -- 晚点超过判定标准：扣车到下一趟/下一周期
                stopData.currentlyWaiting[vehicle] = { type = "ArrDep", arrivalTime = time }
                return true
            end
            -- 未设判定标准（无）或晚点在容差内：立即放行发车（晚点1秒也不再被扣）
            stopData.currentlyWaiting[vehicle] = nil
            stopData.outboundTime[vehicle] = time
            if wasWaiting then timetableHelper.forceDeparture(vehicle) end
            return false
        end

        -- 未错过任何槽位（早到/正点）：等待下一趟发车
        if nextDep then
            stopData.currentlyWaiting[vehicle] = { type = "ArrDep", arrivalTime = time }
            return true
        end
        stopData.currentlyWaiting[vehicle] = nil
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
    if not st or not st.currentlyWaiting then return false end
    return st.currentlyWaiting[vehicle] ~= nil
end

-- 晚点判定标准（秒）。0 = 无（无论晚点多久都立即放行发车）。
-- 存 timetableObject._delayTolerance（随 state.timetable 持久化，跨关窗/重进保留；
-- 且经 sendScriptEvent 从 GUI 线程同步到引擎线程，waitingRequired 在引擎线程读取）。
function timetable.getDelayTolerance()
    -- 先读 _G 缓存（模块重载后仍存活），再读 timetableObject（跨线程同步后的权威值）
    if type(_G._delayTolerance) == "number" then return _G._delayTolerance end
    local v = timetableObject._delayTolerance
    if type(v) ~= "number" then return 0 end
    return v
end

function timetable.setDelayTolerance(v)
    if type(v) ~= "number" or v < 0 then v = 0 end
    timetableObject._delayTolerance = v
    _G._delayTolerance = v
end

-- 时间标签位置（运行图窗口）："top" 时间标签在上方 / "bottom" 在下方。默认 "bottom"。
-- 与晚点容差同样持久化：存 timetableObject（随 state.timetable 存档）+ _G（模块重载存活）。
function timetable.getTimeLabelPos()
    if _G._diagramTimeLabelPos == "top" then return "top" end
    if _G._diagramTimeLabelPos == "bottom" then return "bottom" end
    local v = timetableObject._diagramTimeLabelPos
    if v == "top" then return "top" end
    return "bottom"
end

function timetable.setTimeLabelPos(v)
    if v ~= "top" then v = "bottom" end
    timetableObject._diagramTimeLabelPos = v
    _G._diagramTimeLabelPos = v
end

function timetable.setHasTimetable(line, bool)
    if timetableObject[tostring(line)] then
        timetableObject[tostring(line)].hasTimetable = bool
    else
        timetableObject[tostring(line)] = {stations = {} , hasTimetable = bool, dp = {}}
    end
    return bool
end

--- Start all vehicles of given line.
---@param line table line id
function timetable.startAllLineVehicles(line)
    for _, vehicle in pairs(timetableHelper.getVehiclesOnLine(line)) do
        if timetableHelper.isInStation(vehicle) then
            local currentLine = tostring(timetableHelper.getCurrentLine(vehicle))
            local currentStop = timetableHelper.getCurrentStation(vehicle)
            if currentlyWaiting[currentLine] and currentlyWaiting[currentLine].stations[currentStop] then
                currentlyWaiting[currentLine].stations[currentStop].currentlyWaiting = {}
            end
            timetableHelper.startVehicle(vehicle)
        end
    end
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
        if lineID and lineID > 0 and type(v) == "table" and v.waypointTimes then
            local ok, stops = pcall(timetableHelper.getAllStops, lineID)
            if ok and stops then
                for _, st in ipairs(stops) do
                    if st.type == "waypoint" and st.gwKey then
                        local times = v.waypointTimes[st.id]
                        if times and #times > 0 then
                            if not res[st.gwKey] then
                                res[st.gwKey] = {
                                    gwKey = st.gwKey,
                                    name = st.name,
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

