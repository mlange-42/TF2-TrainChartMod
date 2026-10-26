-- 路径点全局命名 key 回归测试：同一物理路径点在多线路中必须得到同一个 key，
-- 且改名不能改变 key（保证 _gwNames 一实体一名、跨线路全局同步）。
-- 实测（2026-08-05）：v.waypoints[i] 是 SignalId 结构，暴露数字字段 entity（SignalList 实体号）
-- + index（信号列表内序号），key 用 gws_<entity>_<index>。
_G = _G
_ = function(s) return s end

-- 清除 timetable_tests 写入的 helper 桩，加载真实模块
package.loaded["celmi/timetables/timetable_helper"] = nil

-- 模拟"旧式"路径点（无 .entity/.index，走 edge+pos 降级链）需要的 API 桩
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
    -- 同一物理路径点（相同 entity+index）在两条不同线路（不同父站/序号）里 key 必须一致
    local wpA = { entity = 7154, index = 0, name = "A" }
    local k1 = th.getWaypointEntityKey(wpA, 500, 3)
    local k2 = th.getWaypointEntityKey(wpA, 700, 1)
    assert(k1 == k2, "same waypoint in different lines got different keys: " .. tostring(k1) .. " vs " .. tostring(k2))
    assert(k1 == "gws_7154_0", "unexpected key format: " .. tostring(k1))
end)

addTest(function()
    -- 改名不能改变 key
    local wpA = { entity = 7154, index = 0, name = "A" }
    local before = th.getWaypointEntityKey(wpA, 500, 3)
    wpA.name = "Renamed"
    local after = th.getWaypointEntityKey(wpA, 500, 3)
    assert(before == after, "rename changed the key: " .. tostring(before) .. " -> " .. tostring(after))
end)

addTest(function()
    -- 不同实体（不同 SignalList 实体号）key 必须不同
    local wpA = { entity = 7154, index = 0, name = "A" }
    local wpB = { entity = 7155, index = 0, name = "B" }
    assert(th.getWaypointEntityKey(wpA, 500, 3) ~= th.getWaypointEntityKey(wpB, 500, 3), "distinct waypoints share a key")
end)

addTest(function()
    -- 同一 SignalList 实体上不同序号的路径点 key 必须不同（区分同一条边多个路径点）
    local wpA = { entity = 7154, index = 0, name = "A" }
    local wpC = { entity = 7154, index = 3, name = "C" }
    assert(th.getWaypointEntityKey(wpA, 500, 3) ~= th.getWaypointEntityKey(wpC, 500, 3), "same-entity diff-index waypoints share a key")
end)

addTest(function()
    -- 无 .entity 的旧式路径点：edge+坐标降级，仍与线路无关
    local wpD = makeOldWaypoint(9001, 12.34, 56.78, "D")
    local k1 = th.getWaypointEntityKey(wpD, 111, 2)
    local k2 = th.getWaypointEntityKey(wpD, 222, 5)
    assert(k1 == k2, "edge+pos fallback not line-independent: " .. tostring(k1) .. " vs " .. tostring(k2))
    assert(k1 == "gwp_9001_12.34_56.78", "unexpected fallback key: " .. tostring(k1))
end)

addTest(function()
    -- getAllTimetableRailVehicles 必须按 hasTimetable 过滤（控车开关回归，用户反馈）：
    -- 只返回"勾选了遵循时刻表"的线路车辆；未勾选线路 / 无时刻表条目线路的车辆一律排除，
    -- 保证引擎协程不会对它们调用 stopVehicle/startVehicle（此前过滤丢失 → 未勾选线路
    -- 列车到站后被硬扣、永远不发车；勾选再取消才被放行）。
    -- 回归1：返回值必须是"车辆 ID 数组"（协程 for _,v in pairs() 取值当车辆 ID 用）——
    -- 若返回 {车辆ID:线路ID} 映射表，协程拿到线路 ID，waitingRequired(线路ID) 内
    -- getComponent(线路, TRANSPORT_VEHICLE) 触发 C++ assert（GetComponentDataIndex）。
    -- 回归2：getVehiclesWithState 快照可能含刚删除的失效 ID，必须先 entityExists 校验
    -- 再 getComponent（AGENTS.md：getComponent 对无效实体 = C++ assert，pcall 抓不住）。
    local savedGetComponent = api.engine.getComponent
    local savedTransportSystem = api.engine.system.transportVehicleSystem
    local savedEntityExists = api.engine.entityExists
    api.engine.system.transportVehicleSystem = {
        getVehiclesWithState = function(state)
            return { 10, 20, 30, 40, 99 }  -- 99 = 刚被删除的失效 ID（快照残留）
        end,
    }
    api.engine.entityExists = function(id)
        return id ~= 99   -- 99 已删除，其余存在
    end
    api.engine.getComponent = function(v, ctype)
        local lineOf = { [10] = 100, [20] = 100, [30] = 200, [40] = 300 }
        if ctype == 70 then return { line = lineOf[v] } end
        return nil
    end
    api.type.enum = api.type.enum or {}
    api.type.enum.TransportVehicleState = api.type.enum.TransportVehicleState or { AT_TERMINAL = "AT_TERMINAL" }
    api.type.ComponentType.TRANSPORT_VEHICLE = 70
    local hasTT = function(line) return line == 100 end  -- 只有线路100勾选了遵循时刻表
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
    -- Liang-Barsky 线段裁剪回归（运行图放大功能用）：窗口 [0,6]×[0,100]
    -- 场景1：完全在窗口内 → 原样返回
    local x1, y1, x2, y2 = th.clipSegmentToRect(1, 10, 5, 90, 0, 6, 0, 100)
    assert(x1 == 1 and y1 == 10 and x2 == 5 and y2 == 90, "inside segment unchanged")

    -- 场景2：横穿右边界（时间窗口）→ 在 x=6 处截断，y 插值
    x1, y1, x2, y2 = th.clipSegmentToRect(4, 20, 10, 80, 0, 6, 0, 100)
    assert(x1 == 4 and x2 == 6, "right edge clipped: " .. tostring(x1) .. "," .. tostring(x2))
    assert(math.abs(y2 - (20 + (80-20) * (6-4)/(10-4))) < 0.001, "right edge y interpolated: " .. tostring(y2))

    -- 场景3：整段在窗口右侧外 → nil
    assert(th.clipSegmentToRect(8, 10, 12, 90, 0, 6, 0, 100) == nil, "fully right → nil")

    -- 场景4：横穿左边界
    x1, y1, x2, y2 = th.clipSegmentToRect(-2, 30, 3, 60, 0, 6, 0, 100)
    assert(x1 == 0 and x2 == 3, "left edge clipped: " .. tostring(x1) .. "," .. tostring(x2))
    assert(math.abs(y1 - (30 + (60-30) * (0-(-2))/(3-(-2)))) < 0.001, "left edge y interpolated: " .. tostring(y1))

    -- 场景5：横穿上下边界（车站窗口，理论上不发生，防御）
    x1, y1, x2, y2 = th.clipSegmentToRect(1, 80, 5, 150, 0, 6, 0, 100)
    assert(y2 == 100, "top edge clipped: " .. tostring(y2))

    -- 场景6：跨窗口全程（左外→右外）
    x1, y1, x2, y2 = th.clipSegmentToRect(-5, 10, 20, 90, 0, 6, 0, 100)
    assert(x1 == 0 and x2 == 6, "crossing both edges: " .. tostring(x1) .. "," .. tostring(x2))
    assert(math.abs(y1 - (10 + (90-10) * (0-(-5))/(20-(-5)))) < 0.001, "crossing y1 interpolated")
    assert(math.abs(y2 - (10 + (90-10) * (6-(-5))/(20-(-5)))) < 0.001, "crossing y2 interpolated")

    -- 场景7：垂直线段（dx==0，防退化）
    x1, y1, x2, y2 = th.clipSegmentToRect(3, -10, 3, 110, 0, 6, 0, 100)
    assert(x1 == 3 and x2 == 3 and y1 == 0 and y2 == 100, "vertical segment clipped: " .. tostring(y1) .. "," .. tostring(y2))
    print("  OK: helper test #7 (clipSegmentToRect Liang-Barsky)")
end)

addTest(function()
    -- 性能优化 A 组回归：getAllTimetableRailVehicles 的"反查口径"（传入勾选线路清单）必须与
    -- 原口径（逐辆 getComponent 取线路）得到**同一个集合**——这是本次优化的正确性前提。
    -- 场景：线路100 勾选（车 10/11 在站）、线路200 未勾选（车 20）、线路300 无条目（车 30）；
    -- 车辆 99 是快照残留的失效 ID。
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
        -- 反查口径：只有线路100 在勾选清单里 → 它的车 = {10, 11}
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

    -- 自检回归：反查口径与真实归属不一致（getLineVehicles 漏车）时，必须自动退回原口径并给出
    -- 正确结果（宁可慢也不能少控车）。
    api.engine.system.transportVehicleSystem.getLineVehicles = function(line) return {} end
    -- 注：自检每 60s 才有一次机会，这里直接再调一次——上次调用已把 nextCheckAt 设为 now+60，
    -- 故用 os.clock 桩把时间推远，确保本次触发自检。
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
