local timetable = require "celmi/timetables/timetable"
local timetableHelper = require "celmi/timetables/timetable_helper"

-- 交路系统（动车运用计划 / 列车交路）
--
-- 核心概念：
--   交路配置：一组线路的闭环运用顺序，如 线路1 → 线路2 → ... → 线路N → 线路1。
--   换乘站：每条线路的末站（= 下一条线路的首站，同一站组）。真车在换乘站不折返，
--           而是按"下一条线路在该站的发车时刻"换线到下一交路。
--   热备车：被玩家勾选为热备的列车。全程强制停车（setUserStopped(true)，等同手动停止），
--           不跑任何时刻表。部署 = 仅改线路归属（setLine 到要覆盖的线路，车仍停着）；
--           释放 = setLine 回停车线路（回送）。
--
-- 线程模型：
--   引擎线程：update → jiaolu.tick() 每帧（节流 1s）扫描换乘站、执行换线、部署/释放热备。
--   GUI 线程：jiaolu_gui 调 computeOverview()（从 配置 + 车辆组件实时派生展示数据）。
--   共享数据：timetableObject._jrl = { configs, standby, diagramMode }，随存档持久化，
--             经 timetableUpdate 事件从 GUI 同步到引擎线程。
--
-- 乘客防清空不变量：交路配置里的每条线路始终有 ≥1 辆车（真车或热备车）。
-- 换线时先把热备挂到"真车即将离开的线路"，再 setLine 真车到下一线路，任何时刻不出现空窗。
local jiaolu = {}

-- 引擎线程调度运行时状态。模块级 local 不抗模块重载（Lua VM 重载后归 nil），
-- 但重载后下一个 tick 会重新派生全部状态，无副作用。
local runtime = {
    nextTick = 0,
    lineInfo = {},       -- [lineId] = { isConfig, lastStop, nextLine, switchTime }
    lastSwitch = {},     -- [vehicleId] = 上次换线时刻（防同一辆车被反复换线）
    deploySince = {},    -- [standbyId] = 部署开始秒（占用时间显示用）
    lastDeploy = {},     -- [lineId] = 上次部署/滑移热备的时刻（防同一 tick 重复部署）
}-- 车辆名（带 pcall 保护）
local function getVehicleName(veh)
    local name = "Train " .. tostring(veh)
    pcall(function()
        local nc = api.engine.getComponent(veh, api.type.ComponentType.NAME)
        if nc and nc.name and #nc.name > 0 then name = nc.name end
    end)
    return name
end
jiaolu.getVehicleName = getVehicleName

-- 是否为铁路线路（反向过滤：排除明确非铁路的线，空线路保守保留——
-- 空线路无法通过已有车辆判断类型，需要能在交路配置里选到）
function jiaolu.isRailLine(lineId)
    local isNonRail = timetableHelper.lineHasType(lineId, "ROAD")
        or timetableHelper.lineHasType(lineId, "TRAM")
        or timetableHelper.lineHasType(lineId, "WATER")
        or timetableHelper.lineHasType(lineId, "AIR")
    return not isNonRail
end

-- 所有铁路线路 [{id, name, count}]，按线路上车辆数降序（车最多的排最上面）
function jiaolu.getRailLines()
    local ls = {}
    for _, info in pairs(timetableHelper.getAllRailLines()) do
        if jiaolu.isRailLine(info.id) then
            local count = #timetableHelper.getVehiclesOnLine(info.id)
            ls[#ls + 1] = { id = info.id, name = info.name, count = count }
        end
    end
    table.sort(ls, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return string.lower(tostring(a.name)) < string.lower(tostring(b.name))
    end)
    return ls
end

------------------------------------------------------------
-- 数据存取（timetableObject._jrl）
------------------------------------------------------------

function jiaolu.getData()
    local to = timetable.getTimetableObject()
    if not to then to = {}; timetable.setTimetableObject(to) end
    if not to._jrl then
        to._jrl = { configs = {}, standby = {}, diagramMode = false }
    end
    return to._jrl
end

function jiaolu.getDiagramMode()
    return jiaolu.getData().diagramMode == true
end

function jiaolu.setDiagramMode(b)
    jiaolu.getData().diagramMode = (b == true)
end

-- 车辆是否为热备车
function jiaolu.isStandby(vehicleId)
    return timetable.isStandby(vehicleId)
end

-- 设置/取消热备（GUI 线程调用）。勾选时记录停车线路/停站，并立即强制停车；
-- 取消勾选时归还控制权。
function jiaolu.setStandby(vehicleId, isStandby)
    local jrl = jiaolu.getData()
    local key = tostring(vehicleId)
    if isStandby then
        if not jrl.standby then jrl.standby = {} end
        if not jrl.standby[key] then
            local line = timetableHelper.getCurrentLine(vehicleId)
            local stop = timetableHelper.getCurrentStation(vehicleId)
            if not (line and line > 0) then return end
            jrl.standby[key] = {
                parkingLine = line,
                parkingStop = stop,
                name = getVehicleName(vehicleId),
            }
        end
        -- 强制停车（等同手动停止按钮）
        pcall(function()
            api.cmd.sendCommand(api.cmd.make.setUserStopped(tonumber(vehicleId), true))
        end)
    else
        if jrl.standby then jrl.standby[key] = nil end
        -- 归还控制权
        pcall(function()
            api.cmd.sendCommand(api.cmd.make.setUserStopped(tonumber(vehicleId), false))
        end)
    end
end

------------------------------------------------------------
-- 配置辅助
------------------------------------------------------------

-- 返回有序线路列表 [{line, order}]
function jiaolu.getOrderedLines(cfg)
    local ordered = {}
    if not cfg or not cfg.lines then return ordered end
    for lid, ord in pairs(cfg.lines) do
        ordered[#ordered + 1] = { line = tonumber(lid) or 0, order = tonumber(ord) or 999 }
    end
    table.sort(ordered, function(a, b) return a.order < b.order end)
    return ordered
end

-- 线路是否属于任一交路配置
function jiaolu.isConfigLine(lineId)
    local jrl = jiaolu.getData()
    for _, cfg in ipairs(jrl.configs or {}) do
        if cfg.lines and cfg.lines[tostring(lineId)] then return true end
    end
    return false
end

-- 线路所属的交路配置（无则 nil）
function jiaolu.getConfigForLine(lineId)
    local jrl = jiaolu.getData()
    for _, cfg in ipairs(jrl.configs or {}) do
        if cfg.lines and cfg.lines[tostring(lineId)] then return cfg end
    end
    return nil
end

-- 线路在配置中的下一线路（闭环，无则 nil）
function jiaolu.getNextLine(cfg, lineId)
    if not cfg or not cfg.lines then return nil end
    local ordered = jiaolu.getOrderedLines(cfg)
    if #ordered < 2 then return nil end
    for idx, e in ipairs(ordered) do
        if e.line == tonumber(lineId) then
            return ordered[(idx % #ordered) + 1].line
        end
    end
    return nil
end

------------------------------------------------------------
-- 站点/时刻辅助
------------------------------------------------------------

-- 线路最后一个"车站"停站的原始停站索引（1-based raw stop index；用于对照
-- TRANSPORT_VEHICLE.stopIndex + 1）。带模块级缓存（线路停站结构一般不常变）。
local lastStopCache = {}
local lastStopCacheTime = {}
function jiaolu.getLastStationStopIndex(lineId)
    local key = tostring(lineId)
    local now = timetableHelper.getTime()
    if lastStopCache[key] ~= nil and lastStopCacheTime[key] and now - lastStopCacheTime[key] < 3600 then
        return lastStopCache[key]
    end
    local last = nil
    local stops = timetableHelper.getAllStops(lineId)
    for _, st in ipairs(stops) do
        if st.type == "station" then last = st.stopIndex end
    end
    lastStopCache[key] = last
    lastStopCacheTime[key] = now
    return last
end

-- 线路首站 stationGroup
function jiaolu.getFirstStopStationGroup(lineId)
    local okL, lineObject = pcall(function()
        return api.engine.getComponent(lineId, api.type.ComponentType.LINE)
    end)
    if okL and lineObject and lineObject.stops and lineObject.stops[1] then
        return lineObject.stops[1].stationGroup
    end
    return nil
end

-- 线路末站（最后一个车站）的 stationGroup
function jiaolu.getLastStopStationGroup(lineId)
    local stops = timetableHelper.getAllStops(lineId)
    for i = #stops, 1, -1 do
        if stops[i].type == "station" then return stops[i].id end
    end
    return nil
end

-- 某线路在给定停站（stopNumber 1-based）的 ArrDep 槽位中，离 now 最近到达的那一趟的
-- 绝对发车秒（> now 表示需等待，<= now 表示已到/已过、可立即执行）。无 ArrDep 返回 nil。
-- 与 waitingRequired 的槽位对齐一致（AGENTS.md 多套时刻表经验）。
function jiaolu.getSlotDeparture(lineId, stopNumber, now)
    if not (lineId and stopNumber) then return nil end
    local ct = timetable.getConditionType(lineId, stopNumber)
    if ct ~= "ArrDep" then return nil end
    local conds = timetable.getConditions(lineId, stopNumber, "ArrDep")
    if not conds or #conds == 0 then return nil end
    local best = nil
    local bestDist = math.huge
    for _, c in ipairs(conds) do
        local arr = (c[1] * 60 + c[2]) % 3600
        local dep = (c[3] * 60 + c[4]) % 3600
        local k = math.floor((now - arr + 1800) / 3600)
        local absArr = arr + 3600 * k
        local absDep = dep + 3600 * k
        if absDep < absArr then absDep = absDep + 3600 end
        local dist = math.abs(now - absArr)
        if dist < bestDist then
            bestDist = dist
            best = absDep
        end
    end
    return best
end

-- 换乘时刻：优先下一线路首站（= 换乘站）的 ArrDep 发车时刻；没有则退回当前线路末站发车时刻。
function jiaolu.getSwitchTime(curLine, nextLine, now)
    local d1 = jiaolu.getSlotDeparture(nextLine, 1, now)
    if d1 then return d1 end
    local lastIdx = jiaolu.getLastStationStopIndex(curLine)
    if lastIdx then
        local d2 = jiaolu.getSlotDeparture(curLine, lastIdx, now)
        if d2 then return d2 end
    end
    return nil
end

-- 覆盖线路 X 的热备占用窗口：最近已发生 / 下一班 的该线路换乘站发车班次（显示用）
function jiaolu.getDeployWindow(lineId, now)
    local lastIdx = jiaolu.getLastStationStopIndex(lineId)
    if not lastIdx then return nil, nil end
    local ct = timetable.getConditionType(lineId, lastIdx)
    if ct ~= "ArrDep" then return nil, nil end
    local conds = timetable.getConditions(lineId, lastIdx, "ArrDep")
    if not conds or #conds == 0 then return nil, nil end
    local before, after = nil, nil
    for _, c in ipairs(conds) do
        local dep = (c[3] * 60 + c[4]) % 3600
        local k = math.floor((now - dep) / 3600)
        local absDep = dep + 3600 * k
        if absDep <= now then
            if not before or absDep > before then before = absDep end
        end
        if absDep > now then
            if not after or absDep < after then after = absDep end
        end
        local nxtDep = absDep + 3600
        if not after or nxtDep < after then after = nxtDep end
    end
    return before, after
end

------------------------------------------------------------
-- 热备管理
------------------------------------------------------------

-- 指定线路上的热备车（comp.line == lineId）
function jiaolu.getStandbyOnLine(lineId)
    local jrl = jiaolu.getData()
    if not jrl.standby then return nil end
    for vid in pairs(jrl.standby) do
        local v = tonumber(vid)
        if v and v > 0 then
            local cur = timetableHelper.getCurrentLine(v)
            if cur == tonumber(lineId) then return v end
        end
    end
    return nil
end

-- 空闲热备：当前所在线路 == 停车线路（在动车所待命）
function jiaolu.getFreeStandby()
    local jrl = jiaolu.getData()
    if not jrl.standby then return nil end
    for vid, info in pairs(jrl.standby) do
        local v = tonumber(vid)
        if v and v > 0 then
            local cur = timetableHelper.getCurrentLine(v)
            if cur == (tonumber(info.parkingLine) or -1) then return v end
        end
    end
    return nil
end

-- 释放热备：回送停车线路（全程强制停车，仅改线路归属）
function jiaolu.releaseStandby(veh)
    local jrl = jiaolu.getData()
    local info = jrl.standby and jrl.standby[tostring(veh)]
    if not info then return end
    local v = tonumber(veh)
    local parkLine = tonumber(info.parkingLine)
    local parkStop = tonumber(info.parkingStop)
    pcall(function()
        if parkLine and parkLine > 0 then
            api.cmd.sendCommand(api.cmd.make.setLine(v, parkLine, (parkStop and parkStop > 0) and (parkStop - 1) or 0))
        end
    end)
    pcall(function()
        api.cmd.sendCommand(api.cmd.make.setUserStopped(v, true))
    end)
    runtime.deploySince[tostring(veh)] = nil
end

------------------------------------------------------------
-- 调度（引擎线程）
------------------------------------------------------------

-- 车辆当前是否由交路系统接管（真车位于换乘站，按交路时刻扣车，不走时刻表 waitingRequired）。
-- 供 timetableCoroutine 在调用 waitingRequired/startVehicle 前判断，避免把换乘站的真车误放行。
function jiaolu.managesVehicle(vehicleId)
    if timetable.isStandby(vehicleId) then return false end
    local lineId = timetableHelper.getCurrentLine(vehicleId)
    if not (lineId and lineId > 0) then return false end
    local info = runtime.lineInfo[tostring(lineId)]
    if not info or not info.isConfig then return false end
    if not info.lastStop or not info.switchTime then return false end
    local okC, vc = pcall(function()
        return api.engine.getComponent(tonumber(vehicleId), api.type.ComponentType.TRANSPORT_VEHICLE)
    end)
    if not (okC and vc) then return false end
    if vc.state ~= 2 then return false end
    if (vc.stopIndex + 1) ~= info.lastStop then return false end
    return true
end

-- 每帧调用（内部节流 1s 游戏时间）：热备常停 + 逐配置逐线处理换乘
function jiaolu.tick()
    local jrl = jiaolu.getData()
    if not jrl.configs or #jrl.configs == 0 then return end
    local now = timetableHelper.getTime()
    if runtime.nextTick and now < runtime.nextTick then return end
    runtime.nextTick = now + 1

    -- 1) 热备车常停（防御：任何时刻都强制停车）
    for vid in pairs(jrl.standby or {}) do
        local v = tonumber(vid)
        if v and v > 0 then
            pcall(function()
                api.cmd.sendCommand(api.cmd.make.setUserStopped(v, true))
            end)
        end
    end

    -- 2) 预计算配置线路信息（换乘站末站索引、下一线路、换乘时刻）
    runtime.lineInfo = {}
    for _, cfg in ipairs(jrl.configs) do
        local ordered = jiaolu.getOrderedLines(cfg)
        if #ordered >= 2 then
            for idx, entry in ipairs(ordered) do
                local curLine = entry.line
                local nxtLine = ordered[(idx % #ordered) + 1].line
                local lastIdx = jiaolu.getLastStationStopIndex(curLine)
                local switchTime = nil
                if lastIdx then
                    switchTime = jiaolu.getSwitchTime(curLine, nxtLine, now)
                end
                runtime.lineInfo[tostring(curLine)] = {
                    isConfig = true,
                    lastStop = lastIdx,
                    nextLine = nxtLine,
                    switchTime = switchTime,
                }
            end
        end
    end

    -- 3) 清理：有真车的交路线，其上的热备释放（真车已覆盖，热备回池）
    for lineIdStr, info in pairs(runtime.lineInfo) do
        local lineId = tonumber(lineIdStr)
        local vehs = timetableHelper.getVehiclesOnLine(lineId)
        local hasReal = false
        local standby = nil
        for _, veh in ipairs(vehs) do
            if timetable.isStandby(veh) then
                standby = veh
            else
                hasReal = true
            end
        end
        if hasReal and standby then
            jiaolu.releaseStandby(standby)
        end
    end

    -- 4) 逐线处理换乘
    for lineIdStr, info in pairs(runtime.lineInfo) do
        jiaolu.tickLine(tonumber(lineIdStr), info, now)
    end
end

function jiaolu.tickLine(curLine, info, now)
    local vehs = timetableHelper.getVehiclesOnLine(curLine)
    local realTrains = {}
    for _, veh in ipairs(vehs) do
        if not timetable.isStandby(veh) then realTrains[#realTrains + 1] = veh end
    end

    -- 安排失败/交换失败由 GUI（computeOverview）从车辆状态派生：一条交路线 >1 辆真车 → 安排失败；
    -- 换乘节点出现两车 → 不执行换线并强制停车。此处不记录运行时状态。
    local lastIdx = info.lastStop
    local switchTime = info.switchTime
    local nxtLine = info.nextLine
    if not (lastIdx and switchTime and nxtLine) then return end

    for _, veh in ipairs(realTrains) do
        local okC, vc = pcall(function()
            return api.engine.getComponent(veh, api.type.ComponentType.TRANSPORT_VEHICLE)
        end)
        if okC and vc and vc.state == 2 and (vc.stopIndex + 1) == lastIdx then
            -- 真车已到达换乘站（本线末站）
            if #realTrains > 1 then
                -- 交换失败：两列真车同到换乘节点 → 交换前强制停车
                pcall(function()
                    api.cmd.sendCommand(api.cmd.make.setVehicleManualDeparture(veh, true))
                end)
            else
                local vehStr = tostring(veh)
                local last = runtime.lastSwitch[vehStr]
                if last and now - last < 60 then
                    -- 刚换过线（防御重复）
                    return
                end
                if now >= switchTime then
                    jiaolu.doSwitch(curLine, nxtLine, veh, now)
                    runtime.lastSwitch[vehStr] = now
                else
                    -- 未到换乘时刻：扣车等待
                    pcall(function()
                        api.cmd.sendCommand(api.cmd.make.setVehicleManualDeparture(veh, true))
                    end)
                end
            end
        end
    end
end

-- 执行换线：
--   1) 确保"真车即将离开的线路"有热备覆盖（先补位，防乘客清空）
--      a. 若下一线路有热备 → 把它滑到本线（接力，不回池）
--      b. 否则从空闲池调一辆 → 部署到本线
--      c. 否则 → 热备车不足（照常换线，提示玩家）
--   2) setLine 真车 → 下一线路首站（换乘站），引擎寻路立即发车
--   3) 多余热备由下一轮 tick 的"清理"步骤释放（有真车的线路不留热备）
function jiaolu.doSwitch(curLine, nxtLine, veh, now)
    local curKey = tostring(curLine)

    local standbyOnCur = jiaolu.getStandbyOnLine(curLine)
    if not standbyOnCur then
        local lastDeploy = runtime.lastDeploy[curKey]
        if not lastDeploy or now - lastDeploy >= 10 then
            local standbyOnNxt = jiaolu.getStandbyOnLine(nxtLine)
            local deployTarget = standbyOnNxt or jiaolu.getFreeStandby()
            if deployTarget then
                pcall(function()
                    api.cmd.sendCommand(api.cmd.make.setLine(deployTarget, tonumber(curLine), 0))
                end)
                pcall(function()
                    api.cmd.sendCommand(api.cmd.make.setUserStopped(deployTarget, true))
                end)
                runtime.deploySince[tostring(deployTarget)] = now
                runtime.lastDeploy[curKey] = now
            end
        end
    end

    -- 真车换线到下一线路首站（换乘站）
    pcall(function()
        api.cmd.sendCommand(api.cmd.make.setLine(veh, tonumber(nxtLine), 0))
    end)
end

-- 当前配置校验结果是否可用（供 GUI 在"确定"时调用，给出全部不合理项）
-- 返回 { ok = bool, errors = { {cfgName, lineA, lineB, reason}, ... } }
function jiaolu.validateConfigs()
    local jrl = jiaolu.getData()
    local errors = {}
    for _, cfg in ipairs(jrl.configs or {}) do
        local ordered = jiaolu.getOrderedLines(cfg)
        if #ordered >= 2 then
            -- 序号必须 1..N 连续
            for i, e in ipairs(ordered) do
                if e.order ~= i then
                    table.insert(errors, { cfgName = cfg.name, lineA = timetableHelper.getLineName(e.line), lineB = "", reason = "order" })
                    break
                end
            end
            -- 相邻换乘站检查（含闭环首尾）
            for i, e in ipairs(ordered) do
                local nxt = ordered[(i % #ordered) + 1]
                local aSG = jiaolu.getLastStopStationGroup(e.line)
                local bSG = jiaolu.getFirstStopStationGroup(nxt.line)
                if aSG == nil or bSG == nil or aSG ~= bSG then
                    table.insert(errors, {
                        cfgName = cfg.name,
                        lineA = timetableHelper.getLineName(e.line),
                        lineB = timetableHelper.getLineName(nxt.line),
                        reason = "station",
                    })
                else
                    -- 时间校验：下一线路在该站计划发车 < 当前线路在该站计划到达 → 不合理
                    local lastIdx = jiaolu.getLastStationStopIndex(e.line)
                    local now = 0
                    local arrOfCur = jiaolu.getSlotArrival(e.line, lastIdx, now)
                    local depOfNxt = jiaolu.getSlotDeparture(nxt.line, 1, now)
                    if arrOfCur and depOfNxt and depOfNxt < arrOfCur then
                        table.insert(errors, {
                            cfgName = cfg.name,
                            lineA = timetableHelper.getLineName(e.line),
                            lineB = timetableHelper.getLineName(nxt.line),
                            reason = "time",
                        })
                    end
                end
            end
        end
    end
    -- 一条线路只能属于一个配置
    local seen = {}
    for _, cfg in ipairs(jrl.configs or {}) do
        for lid in pairs(cfg.lines or {}) do
            if seen[lid] then
                table.insert(errors, { cfgName = cfg.name, lineA = timetableHelper.getLineName(lid), lineB = "", reason = "dup" })
            end
            seen[lid] = true
        end
    end
    return { ok = (#errors == 0), errors = errors }
end

-- 某线路在给定停站中最近到达槽位的绝对到达秒（校验用）
function jiaolu.getSlotArrival(lineId, stopNumber, now)
    if not (lineId and stopNumber) then return nil end
    local ct = timetable.getConditionType(lineId, stopNumber)
    if ct ~= "ArrDep" then return nil end
    local conds = timetable.getConditions(lineId, stopNumber, "ArrDep")
    if not conds or #conds == 0 then return nil end
    local best = nil
    local bestDist = math.huge
    for _, c in ipairs(conds) do
        local arr = (c[1] * 60 + c[2]) % 3600
        local k = math.floor((now - arr + 1800) / 3600)
        local absArr = arr + 3600 * k
        local dist = math.abs(now - absArr)
        if dist < bestDist then
            bestDist = dist
            best = absArr
        end
    end
    return best
end

------------------------------------------------------------
-- GUI 展示数据（从 配置 + 车辆组件实时派生）
------------------------------------------------------------

-- 返回 {
--   trains    = { { id, name, lineId, lineName, isConfig, nextLineId, nextLineName, switchTime, standbyAlloc }, ... }
--   standbys  = { { id, name, curLineId, curLineName, idle, nextLineName, occupyFrom, occupyTo, occupyDur }, ... }
--   shortage  = { [lineId] = true }   -- 配置线路缺车且无热备可补
--   assignFail= { [lineId] = true }   -- 一条线 >1 真车
-- }
function jiaolu.computeOverview()
    local jrl = jiaolu.getData()
    local now = timetableHelper.getTime()
    local res = { trains = {}, standbys = {}, shortage = {}, assignFail = {} }

    local vehicleMap = {}
    pcall(function()
        vehicleMap = api.engine.system.transportVehicleSystem.getLine2VehicleMap()
    end)

    -- 预计算：配置线路映射
    local cfgOfLine, nextOfLine = {}, {}
    for _, cfg in ipairs(jrl.configs or {}) do
        local ordered = jiaolu.getOrderedLines(cfg)
        if #ordered >= 2 then
            for idx, e in ipairs(ordered) do
                cfgOfLine[e.line] = cfg
                nextOfLine[e.line] = ordered[(idx % #ordered) + 1].line
            end
        end
    end

    -- 收集车辆：按线路
    local standbyOnLine = {}
    local realCount = {}
    local allTrains = {}   -- 非热备车辆
    local allStandbyVehs = {}
    for lineId, vehs in pairs(vehicleMap) do
        if timetableHelper.lineHasType(lineId, "RAIL") then
            for _, veh in ipairs(vehs) do
                if timetable.isStandby(veh) then
                    if not standbyOnLine[lineId] then standbyOnLine[lineId] = veh end
                    allStandbyVehs[#allStandbyVehs + 1] = veh
                else
                    realCount[lineId] = (realCount[lineId] or 0) + 1
                    allTrains[#allTrains + 1] = { veh = veh, lineId = lineId }
                end
            end
        end
    end

    -- 空闲池
    local freeStandbys = {}
    for vid, info in pairs(jrl.standby or {}) do
        local v = tonumber(vid)
        if v and v > 0 then
            local cur = timetableHelper.getCurrentLine(v)
            if cur == (tonumber(info.parkingLine) or -1) then
                freeStandbys[#freeStandbys + 1] = v
            end
        end
    end

    -- 列车列表
    for _, tr in ipairs(allTrains) do
        local lineId = tr.lineId
        local row = {
            id = tr.veh,
            name = getVehicleName(tr.veh),
            lineId = lineId,
            lineName = timetableHelper.getLineName(lineId),
            isConfig = false, nextLineId = nil, nextLineName = nil, switchTime = nil, standbyAlloc = nil,
        }
        if cfgOfLine[lineId] then
            row.isConfig = true
            local nxt = nextOfLine[lineId]
            if nxt then
                row.nextLineId = nxt
                row.nextLineName = timetableHelper.getLineName(nxt)
                row.switchTime = jiaolu.getSwitchTime(lineId, nxt, now)
            end
            if (realCount[lineId] or 0) > 1 then
                res.assignFail[lineId] = true
            end
            if standbyOnLine[lineId] then
                row.standbyAlloc = getVehicleName(standbyOnLine[lineId])
            elseif #freeStandbys > 0 then
                row.standbyAlloc = getVehicleName(freeStandbys[1])
            else
                res.shortage[lineId] = true
            end
        end
        res.trains[#res.trains + 1] = row
    end

    -- 热备车列表
    for _, veh in ipairs(allStandbyVehs) do
        local cur = timetableHelper.getCurrentLine(veh)
        local info = jrl.standby and jrl.standby[tostring(veh)]
        local park = info and (tonumber(info.parkingLine) or -1) or -1
        local idle = (cur == park)
        local row = {
            id = veh,
            name = getVehicleName(veh),
            curLineId = cur,
            curLineName = timetableHelper.getLineName(cur),
            idle = idle,
            nextLineName = nil,
            occupyFrom = nil, occupyTo = nil, occupyDur = nil,
        }
        if idle then
            row.nextLineName = "idle"
        else
            row.nextLineName = timetableHelper.getLineName(cur)
            local from, to = jiaolu.getDeployWindow(cur, now)
            row.occupyFrom = from
            row.occupyTo = to
            if from and to then row.occupyDur = to - from end
        end
        res.standbys[#res.standbys + 1] = row
    end

    return res
end

return jiaolu
