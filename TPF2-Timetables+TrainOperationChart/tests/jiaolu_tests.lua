-- 交路系统单元测试：用桩替换 timetable / timetable_helper / api，
-- 验证配置辅助、槽位对齐、校验、以及"单真车 + 多热备"闭环换乘调度序列。
-- 运行：lua ./tests/main_tests.lua（与 timetable_tests 一致）

-- 测试用共享状态
local mockTO = { _jrl = { configs = {}, standby = {}, diagramMode = false } }
local mockNow = 0
local vehLine = {}   -- [vehicleId] = lineId
local vehStop = {}   -- [vehicleId] = 1-based stop index
local vehState = {}  -- [vehicleId] = 2 (AT_TERMINAL) 或 1
local lineVehicles = {} -- [lineId] = {vehicleId,...}
local mockStops = {}  -- [lineId] = flat stop list
local condType = {}   -- [lineId][stopNumber] = "ArrDep" | "None"
local conds = {}      -- [lineId][stopNumber]["ArrDep"] = {...}
local commands = {}   -- 记录 api.cmd.sendCommand 的调用
local mockFirstSG = {} -- [lineId] = first stop stationGroup
local mockLastSG = {}  -- [lineId] = last station stationGroup
local mockLineName = {}

local api = {
    engine = {
        getComponent = function(entity, compType)
            if compType == 70 then
                return { state = vehState[entity] or 1, stopIndex = (vehStop[entity] or 1) - 1 }
            end
            if compType == 63 then return { stops = { { stationGroup = mockFirstSG[entity] or 0 } } } end
            if compType == 2 then return { name = "Vehicle " .. tostring(entity) } end
            return nil
        end,
        system = {
            transportVehicleSystem = {
                getLine2VehicleMap = function()
                    local m = {}
                    for l, vehs in pairs(lineVehicles) do m[l] = vehs end
                    return m
                end,
            },
            lineSystem = { getLines = function() return {} end },
            stationGroupSystem = {},
            stationSystem = {},
        },
    },
    cmd = {
        sendCommand = function(cmd) commands[#commands + 1] = cmd end,
        make = {
            setLine = function(v, l, s) return { type = "setLine", v = v, l = l, s = s } end,
            setUserStopped = function(v, b) return { type = "userStopped", v = v, b = b } end,
            setVehicleManualDeparture = function(v, b) return { type = "manualDeparture", v = v, b = b } end,
        },
    },
    type = {
        ComponentType = { TRANSPORT_VEHICLE = 70, LINE = 63, NAME = 2, COLOR = 1 },
        enum = { Carrier = { RAIL = 1 } },
    },
}

_G.api = api

package.loaded["celmi/timetables/timetable_helper"] = {
    getTime = function() return mockNow end,
    getCurrentLine = function(v) return vehLine[v] or -1 end,
    getCurrentStation = function(v) return vehStop[v] or 1 end,
    getVehiclesOnLine = function(l) return lineVehicles[l] or {} end,
    getAllStops = function(l) return mockStops[l] or {} end,
    getLineName = function(l) return mockLineName[l] or ("Line" .. tostring(l)) end,
    getAllRailLines = function() return {} end,
    lineHasType = function(l, t) return t == "RAIL" end,
}

package.loaded["celmi/timetables/timetable"] = {
    getTimetableObject = function() return mockTO end,
    setTimetableObject = function(t) mockTO = t end,
    getConditionType = function(l, s) return (condType[l] and condType[l][s]) or "None" end,
    getConditions = function(l, s, t) return (conds[l] and conds[l][s] and conds[l][s][t]) end,
    isStandby = function(v) return mockTO._jrl and mockTO._jrl.standby and mockTO._jrl.standby[tostring(v)] ~= nil end,
}

local jiaolu = nil
local function loadJiaolu()
    package.loaded["celmi/timetables/jiaolu"] = nil
    jiaolu = require "celmi/timetables/jiaolu"
end
loadJiaolu()

local tests = {}

-- 建一条 5 站线路的 mock（lastStation index = 5）
local function setupLine(lineId, firstSG, lastSG)
    local stops = {}
    for i = 1, 5 do
        stops[i] = { type = "station", stopIndex = i, id = (i == 1) and firstSG or (i == 5) and lastSG or (100 + i) }
    end
    mockStops[lineId] = stops
    mockFirstSG[lineId] = firstSG
    mockLastSG[lineId] = lastSG
    mockLineName[lineId] = "L" .. lineId
    lineVehicles[lineId] = lineVehicles[lineId] or {}
end

local function clearState()
    mockTO = { _jrl = { configs = {}, standby = {}, diagramMode = false } }
    vehLine = {}
    vehStop = {}
    vehState = {}
    lineVehicles = {}
    condType = {}
    conds = {}
    commands = {}
    mockNow = 0
    loadJiaolu() -- 重置模块级 runtime（lastSwitch/lastDeploy 等跨测试隔离）
end

-- 给某线路某站设 ArrDep（arrMin,arrSec,depMin,depSec）
local function setArrDep(lineId, stopNumber, list)
    if not condType[lineId] then condType[lineId] = {} end
    if not conds[lineId] then conds[lineId] = {} end
    condType[lineId][stopNumber] = "ArrDep"
    conds[lineId][stopNumber] = conds[lineId][stopNumber] or {}
    conds[lineId][stopNumber].ArrDep = list
end

local function lastCommandOfType(t)
    for i = #commands, 1, -1 do
        if commands[i].type == t then return commands[i] end
    end
    return nil
end

local function countCommand(t)
    local c = 0
    for _, cmd in ipairs(commands) do
        if cmd.type == t then c = c + 1 end
    end
    return c
end

--------------------------------------------------------------
-- 测试1：getOrderedLines 按序号排序 + getNextLine 闭环
--------------------------------------------------------------
tests[#tests + 1] = function()
    clearState()
    mockTO._jrl.configs = { { id = "1", name = "cfg1", lines = { ["20"] = 2, ["10"] = 1, ["30"] = 3 } } }
    local cfg = mockTO._jrl.configs[1]
    local ordered = jiaolu.getOrderedLines(cfg)
    assert(ordered[1].line == 10 and ordered[2].line == 20 and ordered[3].line == 30, "order wrong")
    assert(jiaolu.getNextLine(cfg, 10) == 20, "next of 10 should be 20")
    assert(jiaolu.getNextLine(cfg, 20) == 30, "next of 20 should be 30")
    assert(jiaolu.getNextLine(cfg, 30) == 10, "next of 30 should wrap to 10")
    assert(jiaolu.isConfigLine(20) == true, "20 should be config line")
    assert(jiaolu.isConfigLine(99) == false, "99 should not be config line")
    print("  OK: ordered lines / next line wrap")
end

--------------------------------------------------------------
-- 测试2：getSlotDeparture 槽位对齐（多套时刻表取最近到达）
--------------------------------------------------------------
-- ArrDep 格式为 {arrMin, arrSec, depMin, depSec}（一小时内的分:秒）。
-- 绝对发车秒 = dep*60+sec + 3600*k。测试取 13:00（780s）与 27:00（1620s）两个对齐点。
tests[#tests + 1] = function()
    clearState()
    -- 站1 两套：13:00 和 27:00
    setArrDep(10, 1, { { 12, 50, 13, 0 }, { 26, 0, 27, 0 } })
    -- now=780（13:00）应选中第一套（absArr 770 dist 10 < 第二套 1560 dist 780）
    local dep = jiaolu.getSlotDeparture(10, 1, 780)
    assert(dep == 780, "expected 780 got " .. tostring(dep))
    -- now=1620（27:00）应选中第二套（absArr 1560 dist 60）
    dep = jiaolu.getSlotDeparture(10, 1, 1620)
    assert(dep == 1620, "expected 1620 got " .. tostring(dep))
    -- 无 ArrDep → nil
    assert(jiaolu.getSlotDeparture(11, 1, 780) == nil, "no ArrDep should be nil")
    print("  OK: slot departure alignment")
end

--------------------------------------------------------------
-- 测试3：getSwitchTime 优先下一线首站，退回当前线末站
--------------------------------------------------------------
tests[#tests + 1] = function()
    clearState()
    setupLine(10, 1, 5)
    setupLine(20, 5, 9)
    -- 下一线（20）首站有 ArrDep → 用它（13:00）
    setArrDep(20, 1, { { 12, 50, 13, 0 } })
    local st = jiaolu.getSwitchTime(10, 20, 780)
    assert(st == 780, "switch time from next line first stop, got " .. tostring(st))
    -- 下一线首站无 ArrDep → 退回当前线末站（10 的 5 站，12:50）
    setArrDep(10, 5, { { 12, 40, 12, 50 } })
    local st2 = jiaolu.getSwitchTime(10, 30, 780)
    assert(st2 == 770, "switch time fallback to cur line terminal, got " .. tostring(st2))
    print("  OK: switch time precedence/fallback")
end

--------------------------------------------------------------
-- 测试4：validateConfigs —— 站台不匹配 / 时间不合理
--------------------------------------------------------------
tests[#tests + 1] = function()
    clearState()
    setupLine(10, 1, 5)   -- L10 末站 5
    setupLine(20, 6, 9)   -- L20 首站 6 ≠ 5 → 站台不匹配
    mockTO._jrl.configs = { { id = "1", name = "cfg1", lines = { ["10"] = 1, ["20"] = 2 } } }
    local res = jiaolu.validateConfigs()
    assert(res.ok == false, "should fail on station mismatch")
    local hasStationErr = false
    for _, e in ipairs(res.errors) do if e.reason == "station" then hasStationErr = true end end
    assert(hasStationErr, "expected station mismatch error")

    -- 时间不合理：L10 末站到达 13:10，L20 首站发车 13:00 → 发车早于到达
    clearState()
    setupLine(10, 1, 5)
    setupLine(20, 5, 9)
    setArrDep(10, 5, { { 13, 10, 13, 20 } })
    setArrDep(20, 1, { { 13, 0, 13, 0 } })
    mockTO._jrl.configs = { { id = "1", name = "cfg1", lines = { ["10"] = 1, ["20"] = 2 } } }
    res = jiaolu.validateConfigs()
    assert(res.ok == false, "should fail on time mismatch")
    local hasTimeErr = false
    for _, e in ipairs(res.errors) do if e.reason == "time" then hasTimeErr = true end end
    assert(hasTimeErr, "expected time mismatch error")

    -- 序号不连续
    clearState()
    setupLine(10, 1, 5)
    setupLine(20, 5, 9)
    mockTO._jrl.configs = { { id = "1", name = "cfg1", lines = { ["10"] = 2, ["20"] = 3 } } }
    res = jiaolu.validateConfigs()
    local hasOrderErr = false
    for _, e in ipairs(res.errors) do if e.reason == "order" then hasOrderErr = true end end
    assert(hasOrderErr, "expected order error")
    print("  OK: validation (station/time/order)")
end

--------------------------------------------------------------
-- 测试5：单真车 + 3 热备 的 4 线闭环换乘调度序列
--------------------------------------------------------------
tests[#tests + 1] = function()
    clearState()
    -- 4 条线：L10(1-2-3-4-5) L20(5-6-7-8-9) L30(9-10-11-12-13) L40(13-14-15-16-17)
    setupLine(10, 1, 5)
    setupLine(20, 5, 9)
    setupLine(30, 9, 13)
    setupLine(40, 13, 1)
    -- 每线换乘站（末站）ArrDep 13:00 发车；下一线首站也有 ArrDep（测试优先用下一线首站）
    for _, l in ipairs({ 10, 20, 30, 40 }) do
        setArrDep(l, 1, { { 12, 50, 13, 0 } })  -- 首站（换入站）
        setArrDep(l, 5, { { 12, 50, 13, 0 } })  -- 末站（换出站）
    end
    -- 热备 S20/S30/S40 + 真车 T10
    mockTO._jrl.configs = { { id = "1", name = "cfg1", lines = { ["10"] = 1, ["20"] = 2, ["30"] = 3, ["40"] = 4 } } }
    mockTO._jrl.standby = {
        ["101"] = { parkingLine = 99, parkingStop = 1 },
        ["102"] = { parkingLine = 99, parkingStop = 1 },
        ["103"] = { parkingLine = 99, parkingStop = 1 },
    }
    -- 初始：T10 在线 10 末站；热备分别覆盖 20/30/40（模拟已经部署）
    lineVehicles[10] = { 100 }
    lineVehicles[20] = { 101 }
    lineVehicles[30] = { 102 }
    lineVehicles[40] = { 103 }
    vehLine = { [100] = 10, [101] = 20, [102] = 30, [103] = 40 }
    vehStop = { [100] = 5, [101] = 1, [102] = 1, [103] = 1 }
    vehState = { [100] = 2, [101] = 2, [102] = 2, [103] = 2 }
    mockNow = 780  -- 13:00

    -- 第一次换线：L10 → L20
    jiaolu.tick()
    local sl = lastCommandOfType("setLine")
    assert(sl and sl.v == 100 and sl.l == 20 and sl.s == 0, "T10 should setLine to L20 stop0, got " .. tostring(sl and sl.v))
    -- 必须先部署热备到 L10 再换真车：找 setLine(101 → 10)
    local found101to10 = false
    local found100to20 = false
    for _, cmd in ipairs(commands) do
        if cmd.type == "setLine" and cmd.v == 101 and cmd.l == 10 then found101to10 = true end
        if cmd.type == "setLine" and cmd.v == 100 and cmd.l == 20 then found100to20 = true end
    end
    assert(found101to10, "standby 101 should be deployed to L10")
    assert(found100to20, "real train 100 should switch to L20")

    -- 推进状态：101 滑到 L10、T10 到 L20 末站（60 分钟后的下一个槽位）
    lineVehicles[10] = { 101 }
    lineVehicles[20] = { 100 }
    vehLine[101] = 10
    vehLine[100] = 20
    vehStop[100] = 5
    commands = {}
    mockNow = mockNow + 3600  -- 14:00

    -- 第二次换线：L20 → L30（102 应滑到 L20，100 换到 L30）
    jiaolu.tick()
    local f102to20 = false
    local f100to30 = false
    for _, cmd in ipairs(commands) do
        if cmd.type == "setLine" and cmd.v == 102 and cmd.l == 20 then f102to20 = true end
        if cmd.type == "setLine" and cmd.v == 100 and cmd.l == 30 then f100to30 = true end
    end
    assert(f102to20, "standby 102 should deploy to L20")
    assert(f100to30, "real train 100 should switch to L30")

    -- 推进：103 滑到 L30、100 到 L40
    lineVehicles[20] = { 102 }
    lineVehicles[30] = { 100 }
    vehLine[102] = 20
    vehLine[100] = 30
    vehStop[100] = 5
    commands = {}
    mockNow = mockNow + 3600
    jiaolu.tick()
    local f103to30 = false
    local f100to40 = false
    for _, cmd in ipairs(commands) do
        if cmd.type == "setLine" and cmd.v == 103 and cmd.l == 30 then f103to30 = true end
        if cmd.type == "setLine" and cmd.v == 100 and cmd.l == 40 then f100to40 = true end
    end
    assert(f103to30, "standby 103 should deploy to L30")
    assert(f100to40, "real train 100 should switch to L40")

    -- 推进：101 从 L10 滑到 L40、100 回 L10（闭环）
    lineVehicles[30] = { 103 }
    lineVehicles[40] = { 100 }
    vehLine[103] = 30
    vehLine[100] = 40
    vehStop[100] = 5
    commands = {}
    mockNow = mockNow + 3600
    jiaolu.tick()
    local f101to40 = false
    local f100to10 = false
    for _, cmd in ipairs(commands) do
        if cmd.type == "setLine" and cmd.v == 101 and cmd.l == 40 then f101to40 = true end
        if cmd.type == "setLine" and cmd.v == 100 and cmd.l == 10 then f100to10 = true end
    end
    assert(f101to40, "standby 101 should slide L10->L40")
    assert(f100to10, "real train 100 should return to L10 (loop closed)")

    print("  OK: 4-line rotation with 1 real train + 3 standbys")
end

--------------------------------------------------------------
-- 测试6：热备车不足（standby 覆盖的线路没热备可滑移，也不可回池）
--------------------------------------------------------------
tests[#tests + 1] = function()
    clearState()
    setupLine(10, 1, 5)
    setupLine(20, 5, 9)
    setArrDep(10, 5, { { 12, 50, 13, 0 } })
    setArrDep(20, 1, { { 12, 50, 13, 0 } })
    mockTO._jrl.configs = { { id = "1", name = "cfg1", lines = { ["10"] = 1, ["20"] = 2 } } }
    -- 只有 1 辆热备，且它在停车线上（空闲池），真车在线 10 末站
    mockTO._jrl.standby = { ["101"] = { parkingLine = 99, parkingStop = 1 } }
    lineVehicles[10] = { 100 }
    lineVehicles[99] = { 101 }   -- 热备在停车线上（空闲）
    vehLine = { [100] = 10, [101] = 99 }
    vehStop = { [100] = 5, [101] = 1 }
    vehState = { [100] = 2, [101] = 2 }
    mockNow = 780

    -- L10 真车要换到 L20。L20 无热备 → 从空闲池调 101 到 L10。
    jiaolu.tick()
    local f101to10 = false
    for _, cmd in ipairs(commands) do
        if cmd.type == "setLine" and cmd.v == 101 and cmd.l == 10 then f101to10 = true end
    end
    assert(f101to10, "free standby 101 should deploy to L10")
    print("  OK: free standby pool deployment")
end

--------------------------------------------------------------
-- 测试7：一条线 >1 真车 → 交换前强制停车（交换失败）
--------------------------------------------------------------
tests[#tests + 1] = function()
    clearState()
    setupLine(10, 1, 5)
    setupLine(20, 5, 9)
    setArrDep(10, 5, { { 12, 50, 13, 0 } })
    setArrDep(20, 1, { { 12, 50, 13, 0 } })
    mockTO._jrl.configs = { { id = "1", name = "cfg1", lines = { ["10"] = 1, ["20"] = 2 } } }
    lineVehicles[10] = { 100, 200 }   -- 两辆真车在同一条线
    vehLine = { [100] = 10, [200] = 10 }
    vehStop = { [100] = 5, [200] = 5 }
    vehState = { [100] = 2, [200] = 2 }
    mockNow = 780

    jiaolu.tick()
    -- 不应有真车换线命令
    local switched = false
    for _, cmd in ipairs(commands) do
        if cmd.type == "setLine" and (cmd.v == 100 or cmd.v == 200) then switched = true end
    end
    assert(not switched, "no real train should switch when 2 trains on line")
    -- 应强制停车（manualDeparture true）
    local heldCount = countCommand("manualDeparture")
    assert(heldCount >= 1, "should force-stop before switch fail")
    print("  OK: switch fail forces hold")
end

return {
    test = function()
        for k, v in pairs(tests) do
            print("Running jiaolu test: " .. tostring(k))
            v()
        end
    end
}
