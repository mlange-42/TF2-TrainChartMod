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
    -- 构造旧存档格式的 currentlyWaiting：
    --   停站条目 outboundTime 是旧版"整站共享时间戳"的标量数字
    --   停站条目缺失 outboundTime
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

-- waitingRequired 回归测试：已过发车时刻、晚点在容差内 → 必须放行（forceDeparture 被调用）
timetableTests[#timetableTests + 1] = function()
    -- 用桩替换 timetable_helper（原桩是空表，waitingRequired 需要 getTime 等）
    local mockTime = 3600 * 13 + 720   -- 13:12
    local mockLine = 100
    local mockStop = 1
    local forceCalls = 0
    package.loaded["celmi/timetables/timetable_helper"] = {
        getTime = function() return mockTime end,
        getCurrentLine = function() return mockLine end,
        getCurrentStation = function() return mockStop end,
        getTimeUntilDeparture = function() return 3 end,  -- 关门倒计时 <5，进入 ArrDep 判定
        forceDeparture = function() forceCalls = forceCalls + 1 end,
    }
    -- 需重载 timetable 模块（模块级 currentlyWaiting/timetableObject 重置）
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"
    -- 构造时刻表对象：线路100（已勾选遵循时刻表）站1 ArrDep 0:00到 0:10发
    tt.setTimetableObject({
        ["100"] = { hasTimetable = true, stations = { [1] = { conditions = { type = "ArrDep", ArrDep = { {0,0,10,0} } } } } },
    })
    tt.setCurrentlyWaiting({})
    tt.setDelayTolerance(300)  -- 5分钟容差

    -- 场景1：车 13:12 到站（发车 13:10 已过2分钟，晚点在容差内）→ 应放行且 forceDeparture
    assert(tt.waitingRequired("V1") == false, "late within tolerance should release")
    assert(forceCalls >= 1, "forceDeparture must be called when releasing a late train")
    print("  OK: late-within-tolerance release triggers forceDeparture (" .. forceCalls .. " calls)")

    -- 场景2：车 13:16 到站（发车 13:10 已过6分钟，超过容差）→ 应扣车
    forceCalls = 0
    mockTime = 3600 * 13 + 960
    tt.setCurrentlyWaiting({})
    assert(tt.waitingRequired("V2") == true, "late beyond tolerance should be held to next cycle")
    assert(forceCalls == 0, "no forceDeparture when holding")
    print("  OK: late-beyond-tolerance holds to next cycle")
end

-- 发车检测守卫回归测试（2026-08-05，用户场景：多套时刻表线路出现假"早24:28"）：
-- 用户线路始发站两套时刻表：第一套 22:30/23:30、第二套 46:30/48:00。
-- 列车本周期 46:30 正点到站（选定第二套），但 lineStopDepartures 还留着上一周期
-- 23:32 从本站发车的旧记录。旧代码把 d>0 当成"本次发车"→ 拿 1412s(23:32) 减第二套
-- 计划发车 2880s(48:00) → 假"早 24:28"（1468s）。
-- 修复：timetable.isValidDepartureRecord 只认"本次到站之后(>=arrTime)、不晚于当前(<=now)"的记录。
timetableTests[#timetableTests + 1] = function()
    -- 需重载 timetable 模块（模块级 currentlyWaiting/timetableObject 重置）
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"

    -- 场景1（用户反馈的核心）：列车 46:30(2790s) 到站，现在是 47:29(2849s)，
    -- lineStopDepartures 残留上一周期 23:32 的旧记录(1412s) → 必须拒绝，不得当"本次发车"
    assert(tt.isValidDepartureRecord(1412 * 1000, 2849, 2790) == false,
        "stale departure record from previous cycle must be rejected")

    -- 场景2：真实发车 48:00(2880s)，到站 46:30(2790s)，现在刚好 48:00 → 接受
    assert(tt.isValidDepartureRecord(2880 * 1000, 2880, 2790) == true,
        "real departure after this visit's arrival must be accepted")

    -- 场景3：记录不晚于当前扫描时刻（未来值拒绝——扫描瞬间不可能拿到未来的发车记录）
    assert(tt.isValidDepartureRecord(2990 * 1000, 2880, 2790) == false,
        "future departure record must be rejected")

    -- 场景4：d 为 nil / 0 → 非发车（站内等待中）
    assert(tt.isValidDepartureRecord(nil, 2880, 2790) == false, "nil record rejected")
    assert(tt.isValidDepartureRecord(0, 2880, 2790) == false, "zero record rejected")

    -- 场景5：到站事件漏拍（arrTime=nil）时仅按 <= now 兜底，不误杀真实发车
    assert(tt.isValidDepartureRecord(2880 * 1000, 2880, nil) == true,
        "arrival-missed fallback accepts a real departure")
    assert(tt.isValidDepartureRecord(1412 * 1000, 2880, nil) == true,
        "arrival-missed fallback cannot distinguish stale (best effort), value <= now accepted")

    -- 场景6：同周期内先到站（10:00=600s），紧接 10:01(601s) 发车 → 接受
    assert(tt.isValidDepartureRecord(601 * 1000, 601, 600) == true,
        "short-dwell real departure accepted")
    print("  OK: departure record guard rejects stale / accepts real")
end

-- 多套时刻表"选套"回归测试（用户场景）：列车 46:30 到站必须选中第二套(46:30/48:00)，
-- 不选中第一套(22:30/23:30)；且 47:29 时刻仍在第二套（不会跳去别的套）。
timetableTests[#timetableTests + 1] = function()
    package.loaded["celmi/timetables/timetable_helper"] = {}
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"
    tt.setTimetableObject({
        ["100"] = { stations = { [1] = { conditions = { type = "ArrDep", ArrDep = { {22,30,23,30}, {46,30,48,0} } } } } },
    })

    -- 选套逻辑在 timetable_gui 的 getPlannedArrDep，这里复刻其算法验证"最近到达"选套对用户场景正确：
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

    local a, d = pickSet(2790)   -- 46:30 到站
    assert(a == 2790 and d == 2880, "arrival 46:30 must pick set2 (46:30/48:00), got arr=" .. tostring(a) .. " dep=" .. tostring(d))
    a, d = pickSet(2849)         -- 47:29（站内等待中）
    assert(a == 2790 and d == 2880, "at 47:29 must still be set2, got arr=" .. tostring(a) .. " dep=" .. tostring(d))
    print("  OK: multi-set selection picks set2 for 46:30 arrival")
end

-- 孤儿线路过滤回归测试（用户场景）：删除已安排时刻的线路后，timetableObject 里的孤儿条目
-- （线路实体已不存在）不应出现在车站 Tab（getAllConditionsOfAllStations），并应被 cleanupOrphanLines 清理。
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
        ["999"] = { stations = { [1] = { stationID = 9991, conditions = { type = "ArrDep", ArrDep = { {5,0,6,0} } } } } }, -- 孤儿：线路已删除
        ["_gwNames"] = { ["gws_x"] = "test" }, -- 非线路条目：保留（不作为线路处理）
    })

    -- getAllConditionsOfAllStations 必须过滤孤儿线路 999（车站 Tab 不再显示 "ERROR" 行）
    local all = tt.getAllConditionsOfAllStations()
    assert(all[1001] and all[1001]["100"], "existing line 100 must appear by station")
    assert(all[2001] and all[2001]["200"], "existing line 200 must appear by station")
    assert(all[9991] == nil, "orphan line 999 must be filtered out from station view")
    assert(all[1001]["999"] == nil, "orphan line 999 must not be listed under station 1001/9991")

    -- getAllWaypointData 同样过滤孤儿线路
    local wp = tt.getAllWaypointData()
    -- 999 无 waypointTimes，此处仅确认不崩；主要断言覆盖在上面

    -- cleanupOrphanLines 应删除孤儿条目 999，保留 100/200 与非数字 key（_gwNames）
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
    -- 运行图设置持久化 getter/setter（时间刻度 / 准点判定阈值 / 自动刷新）
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

    -- 设置必须写入 timetableObject（随存档持久化）；清空 _G 后（模拟读档/模块重载）仍能恢复
    local to = timetable.getTimetableObject()
    assert(to._diagramTimeScale == 2 and to._diagramPunctThreshold == 30 and to._diagramAutoRefresh == true,
        "settings must be stored in timetableObject for persistence")
    _G._diagramTimeScale = nil
    _G._diagramPunctThreshold = nil
    _G._diagramAutoRefresh = nil
    assert(timetable.getTimeScale() == 2, "time scale must survive _G reset (read from timetableObject)")
    assert(timetable.getPunctThreshold() == 30, "punct threshold must survive _G reset")
    assert(timetable.getDiagramAutoRefresh() == true, "auto refresh must survive _G reset")

    -- 非法值收拢
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
    -- 运行方向筛选 getter/setter（_diagramPolylineFilter，all/up/down）
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
    -- 跨线程同步安全防御：hasLineEntries 判定"表里是否有线路条目"
    -- 数字/字符串线路 key 命中；设置键（_diagram*）、_gwNames、空表都不命中。
    assert(timetable.hasLineEntries({ ["35110"] = {} }) == true, "string line key must count as line entry")
    assert(timetable.hasLineEntries({ [35110] = {} }) == true, "number line key must count as line entry")
    assert(timetable.hasLineEntries({ ["_diagramTimeScale"] = 5, ["_diagramAutoRefresh"] = false }) == false,
        "settings-only table must NOT count as line entries")
    assert(timetable.hasLineEntries({ ["_gwNames"] = {} }) == false, "_gwNames-only table must NOT count as line entries")
    assert(timetable.hasLineEntries({}) == false, "empty table must NOT count as line entries")
    assert(timetable.hasLineEntries(nil) == false, "nil must NOT count as line entries")

    -- hasAnyPreset：任一线路带 dp.presetList 非空才命中；空/无 dp/预设空都不命中
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
    -- 数据同步（number→string 迁移）回归测试：旧版 mod 用数字 key 存线路时刻，
    -- migrateNumberLineKeys 应迁移到字符串 key，且追加不覆盖（多套时刻全保留），
    -- 非线路字符串 key（_gwNames 等）原样保留，报告里每站"新增套数"正确。
    -- 场景1：纯 number 存档 → 迁移后 string 可读、number 清空、报告计数正确
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

    -- 场景2：number+string 并存 → 追加不覆盖，string 原有数据保留，_gwNames 原样保留
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

    -- 场景3：无 number → 幂等，totalSlots == 0，纯 string 表不变
    timetable.setTimetableObject({
        ["200"] = { stations = { [1] = { conditions = { type = "ArrDep", ArrDep = { {1,0,2,0} } } } } },
    })
    local r3 = timetable.migrateNumberLineKeys()
    assert(r3.totalSlots == 0, "no number keys → totalSlots 0")
    assert(timetable.getTimetableObject()["200"] ~= nil, "string-only table unchanged")
    print("  OK: migrateNumberLineKeys (number→string append migration + report)")
end

-- 控车开关回归测试（用户反馈）：线路未勾选"遵循时刻表"（hasTimetable=false）时，
-- waitingRequired 必须返回 false（不扣车），即使该线路残留车站时刻数据。
-- 此前没有 hasTimetable 判定 → 未勾选线路的列车到站后被 setVehicleManualDeparture(true)
-- 硬扣、永远不发车（只有勾选再取消勾选瞬间 startAllLineVehicles 才放行 → 玩家看到
-- "取消勾选才发车"）。用户定稿：不打勾就按游戏默认装卸车后正常发车，打勾才控车。
timetableTests[#timetableTests + 1] = function()
    local mockTime = 3600 * 13 + 300   -- 13:05（发车 13:10 未到 → 旧逻辑会扣车等发车时刻）
    local forceCalls = 0
    package.loaded["celmi/timetables/timetable_helper"] = {
        getTime = function() return mockTime end,
        getCurrentLine = function() return 100 end,
        getCurrentStation = function() return 1 end,
        getTimeUntilDeparture = function() return 3 end,  -- 关门倒计时 <5，进入 ArrDep 判定
        forceDeparture = function() forceCalls = forceCalls + 1 end,
    }
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"

    -- 场景1：线路存在但未勾选（hasTimetable=false），站内有 ArrDep 残留数据 → 不扣车、不强制发车
    tt.setTimetableObject({
        ["100"] = { hasTimetable = false, stations = { [1] = { conditions = { type = "ArrDep", ArrDep = { {0,0,10,0} } } } } },
    })
    tt.setCurrentlyWaiting({})
    assert(tt.waitingRequired("V1") == false, "unchecked line must not hold the train")
    assert(forceCalls == 0, "unchecked line must not forceDeparture either")

    -- 场景2：线路没有时刻表条目（从未安排过时刻）→ 不扣车
    tt.setTimetableObject({})
    tt.setCurrentlyWaiting({})
    assert(tt.waitingRequired("V1") == false, "line without timetable entry must not hold the train")

    -- 场景3：勾选（hasTimetable=true）+ 发车时刻未到 → 正常扣车（对照：勾选才控车）
    tt.setTimetableObject({
        ["100"] = { hasTimetable = true, stations = { [1] = { conditions = { type = "ArrDep", ArrDep = { {0,0,10,0} } } } } },
    })
    tt.setCurrentlyWaiting({})
    assert(tt.waitingRequired("V1") == true, "checked line must hold until departure time")
    print("  OK: unchecked line not controlled (hasTimetable gate)")
end

-- 残留扣车清理回归（2026-08-16 诊断）：旧版 mod 设置的 manualDeparture 标志随存档持久化，
-- 未勾选但有条目的线路车辆 autoDeparture=false → clearStaleHolds 必须清掉；
-- 勾选线路 / 无条目线路 / 已 autoDeparture=true 的车辆一律不动。
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
                    -- 性能优化 A 组（2026-08-16 第 21 轮）：clearStaleHolds 已改成"候选驱动"——
                    -- 先纯 Lua 找"有条目但未勾选"的线路，再按线路取车；不再扫全世界停站车辆。
                    getLineVehicles = function(line)
                        if line == 100 then return { 10, 11 } end
                        if line == 200 then return { 20, 21 } end
                        return { 30 }   -- 线路300 无条目 → 无候选，不该被查到
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
        ["100"] = { hasTimetable = true, stations = {} },   -- 勾选：不动（协程正常控车）
        ["200"] = { hasTimetable = false, stations = {} },  -- 未勾选+有条目：清
        -- 300 无条目：不清（本 mod 从未扣过它）
    })
    local n = tt.clearStaleHolds()
    -- 10: 线路100 勾选 → 不清；11: 线路100 勾选 → 不清（autoDeparture=true 也不清）
    -- 20: 线路200 未勾选 + autoDeparture=false → 清；21: 同线但 autoDeparture=true → 不清
    -- 30: 线路300 无条目 → 不清
    assert(n == 1, "exactly 1 stale hold cleared, got " .. tostring(n))
    assert(#cmdCalls == 1 and cmdCalls[1][1] == 20 and cmdCalls[1][2] == false,
        "clearStaleHolds must send setVehicleManualDeparture(20, false)")
    assert(fleetScanCalls == 0, "candidate-driven clearStaleHolds must not scan the whole fleet, got "
        .. tostring(fleetScanCalls))
    -- 无候选时零成本：把所有条目改成已勾选 → 不该有任何 getLineVehicles / 车队扫描
    tt.setTimetableObject({ ["100"] = { hasTimetable = true, stations = {} } })
    local n2 = tt.clearStaleHolds()
    assert(n2 == 0 and fleetScanCalls == 0, "no candidate lines → no scan at all")
    print("  OK: clearStaleHolds (candidate-driven stale manualDeparture cleanup)")
    _G.api = prevApi
end

-- 5s 维护合并回归（性能优化 A 组）：maintainTimetableData 必须
--   * 只取一次 getLines()；
--   * 用它同时完成孤儿清理与车站对账（对账不再逐线 entityExists）；
--   * 返回值语义与原来两次调用一致（removed 数 + 对账 stats）。
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
                    getLines = function() getLinesCalls = getLinesCalls + 1 return { 100 } end,  -- 999 是孤儿
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
            [2] = { stationID = 1002, conditions = { type = "ArrDep", ArrDep = { {3,0,4,0} } } },  -- 挪到 2
            [5] = { stationID = 1001, conditions = { type = "ArrDep", ArrDep = { {1,0,2,0} } } },  -- 挪到 1
        } },
        ["999"] = { hasTimetable = true, stations = {} },   -- 线路已删 → 孤儿，应清掉
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

-- 车站/线路结构对账回归（2026-08-16 方案定稿）：拆站后游戏把线路停站重新编号，
-- 时刻数据按位置存储会错位。reconcileStationData 必须：
--   * 幸存站（stationID 还在线路上）数据归位到新位置（时刻内容不变）；
--   * 被拆站（stationID 不在线路上）数据删除；
--   * 无 stationID 的老数据删除；
--   * 环线同站组多次出现按顺序配对；
--   * 被删位置的 currentlyWaiting 残留清掉。
timetableTests[#timetableTests + 1] = function()
    local prevApi = _G.api
    _G.api = {
        engine = {
            entityExists = function(id) return id == 100 or id == 200 end,
            getComponent = function(id, ctype)
                if ctype == 60 then  -- LINE
                    if id == 100 then
                        -- 原 A B C D E，C(1003) 被拆 → 现 A B D E
                        return { stops = { [1] = { stationGroup = 1001 }, [2] = { stationGroup = 1002 },
                                           [3] = { stationGroup = 1004 }, [4] = { stationGroup = 1005 } } }
                    elseif id == 200 then
                        -- 环线：同站组 2001 出现两次（位置1/2），2002 一次
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
            [3] = { stationID = 1003, conditions = { type = "ArrDep", ArrDep = { {5,0,6,0} } } },  -- 被拆
            [4] = { stationID = 1004, conditions = { type = "ArrDep", ArrDep = { {7,0,8,0} } } },  -- 挪到 3
            [5] = { stationID = 1005, conditions = { type = "ArrDep", ArrDep = { {9,0,10,0} } } }, -- 挪到 4
            [6] = { noSid = true },  -- 无 stationID 老数据 → 删
        } },
        ["200"] = { hasTimetable = true, stations = {
            [2] = { stationID = 2001, conditions = { type = "ArrDep", ArrDep = { {11,0,12,0} } } },
            [5] = { stationID = 2001, conditions = { type = "ArrDep", ArrDep = { {13,0,14,0} } } },
            [7] = { stationID = 2004, conditions = { type = "ArrDep", ArrDep = { {15,0,16,0} } } }, -- 已不在环线 → 删
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
    -- 线路100
    assert(obj["100"].stations[1].stationID == 1001, "A stays at 1")
    assert(obj["100"].stations[2].stationID == 1002, "B stays at 2")
    assert(obj["100"].stations[3] and obj["100"].stations[3].stationID == 1004, "D rekeyed to 3")
    assert(obj["100"].stations[4] and obj["100"].stations[4].stationID == 1005, "E rekeyed to 4")
    assert(obj["100"].stations[3].conditions.ArrDep[1][1] == 7, "D's times preserved")
    assert(obj["100"].stations[4].conditions.ArrDep[1][1] == 9, "E's times preserved")
    assert(obj["100"].stations[5] == nil and obj["100"].stations[6] == nil, "C and noSid removed")
    -- 线路200 环线配对
    assert(obj["200"].stations[1] and obj["200"].stations[1].stationID == 2001, "2001 first → 1")
    assert(obj["200"].stations[2] and obj["200"].stations[2].stationID == 2001, "2001 second → 2")
    assert(obj["200"].stations[1].conditions.ArrDep[1][1] == 11, "first 2001 times preserved")
    assert(obj["200"].stations[2].conditions.ArrDep[1][1] == 13, "second 2001 times preserved")
    assert(obj["200"].stations[7] == nil, "2004 (off line) removed")
    -- currentlyWaiting 残留：被删位置 3 清掉
    local cw = tt.getCurrentlyWaiting()
    assert(cw["100"].stations[3] == nil, "currentlyWaiting for removed pos 3 cleared")
    _G.api = prevApi
    print("  OK: reconcileStationData (rekey / drop deleted / noSid / loop pairing)")
end

-- 读取校验回归（2026-08-16 方案定稿）：拆/建站后两次对账之间的窗口期，
-- waitingRequired 必须拒绝"位置错位"的数据（存档 stationID ≠ 当前位置真实车站 → 不扣车）。
timetableTests[#timetableTests + 1] = function()
    local mockTime = 3600 * 13 + 300   -- 13:05（发车 13:10 未到 → 正常会扣车）
    local mockLine = 100
    local mockStop = 1
    local forceCalls = 0
    local mockLiveSid = 1002  -- 当前位置真实车站（与存档 stationID=1001 不符 → 应拒绝）
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

    -- 场景1：存档 stationID=1001 ≠ 当前位置 1002 → 拒绝（不扣车、不强制发车）
    assert(tt.waitingRequired("V1") == false, "mismatched stationID must not hold the train")
    assert(forceCalls == 0, "mismatched stationID must not forceDeparture")

    -- 场景2：一致 → 正常扣车到发车时刻
    mockLiveSid = 1001
    tt.setCurrentlyWaiting({})
    assert(tt.waitingRequired("V1") == true, "matched stationID must hold until departure")
    print("  OK: waitingRequired rejects position-mismatched station data")
end

-- 自动时刻间隔生成辅助回归（2026-08-16 功能）：
-- shiftTime 平移（模1小时/绕小时）、shiftSlot 整槽平移、removeAllConditions 清空保留 type。
timetableTests[#timetableTests + 1] = function()
    package.loaded["celmi/timetables/timetable_helper"] = {}
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"

    -- shiftTime：平移 + 跨小时回绕（0-59 分）
    local a = tt.shiftTime({0, 0}, 60)
    assert(a[1] == 1 and a[2] == 0, "0:00 + 1m = 1:00")
    local b = tt.shiftTime({59, 30}, 60)
    assert(b[1] == 0 and b[2] == 30, "59:30 + 1m wraps to 0:30, got " .. b[1] .. ":" .. b[2])
    local c = tt.shiftTime({28, 45}, 60 * 30)
    assert(c[1] == 58 and c[2] == 45, "28:45 + 30m = 58:45")

    -- shiftSlot：{0,0,10,0} + 10min → {10,0,20,0}
    local s = tt.shiftSlot({0, 0, 10, 0}, 10 * 60)
    assert(s[1] == 10 and s[2] == 0 and s[3] == 20 and s[4] == 0,
        "shiftSlot +10min: " .. s[1] .. ":" .. s[2] .. "-" .. s[3] .. ":" .. s[4])

    -- removeAllConditions：清空 ArrDep 数组，保留 conditions.type=ArrDep
    tt.setTimetableObject({
        ["100"] = { stations = { [1] = { conditions = { type = "ArrDep", ArrDep = { {1,0,2,0}, {3,0,4,0} } } } } },
    })
    tt.removeAllConditions(100, 1, "ArrDep")
    local conds = tt.getConditions(100, 1, "ArrDep")
    assert(type(conds) == "table" and #conds == 0, "ArrDep array cleared")
    assert(tt.getConditionType(100, 1) == "ArrDep", "condition type preserved after clear")
    print("  OK: shiftTime / shiftSlot / removeAllConditions (auto-interval helpers)")
end

-- 线路控车开关回归（2026-08-16 功能，跟进 3625975189）：到点发车 / 最小停站时间 / 最大停站时间。
--   * getter 默认：无条目 / 旧档缺字段 → force=true、min/max=false；
--   * setter 往返 + 持久化到 timetableObject[line]；
--   * force=true（默认）：晚点容差内放行 = 强发（forceDeparture 被调），且 min/max 即使勾选也被忽略；
--   * force=false：同一场景放行 = 普通放行（forceDeparture 不被调，引擎装完才走）；
--   * force=false + Min：到站+minWaitingTime 未满 → 继续扣；满 → 普通放行；
--   * force=false + Max：到站+maxWaitingTime → 晚点超容差也强发（max 覆盖"扣到下一趟"）；
--   * force=false + 无 min/max + 晚点超容差 → 仍扣到下一趟（force=false ≠ 一律放行）。
timetableTests[#timetableTests + 1] = function()
    local mockTime = 3600 * 13 + 300         -- 13:05（基准，每场景前覆写）
    local mockLine = 100
    local mockStop = 1
    local mockDoorsArrival = 3600 * 13 + 60  -- 车辆到站时刻（doorsTime 微秒），min/max 判点基准
    local dwellMin = 0
    local dwellMax = 0
    local forceCalls = 0
    package.loaded["celmi/timetables/timetable_helper"] = {
        getTime = function() return mockTime end,
        getCurrentLine = function() return mockLine end,
        getCurrentStation = function() return mockStop end,
        getTimeUntilDeparture = function() return 3 end,  -- 关门倒计时 <5s：门控不提前放行
        getStationID = function() return 1001 end,
        forceDeparture = function() forceCalls = forceCalls + 1 end,
    }
    local prevApi = _G.api
    _G.api = {
        engine = {
            entityExists = function() return true end,
            getComponent = function(id, ctype)
                if ctype == 60 then  -- LINE：引擎 Line.Stop 原生驻留上下限
                    return { stops = { [1] = { minWaitingTime = dwellMin, maxWaitingTime = dwellMax } } }
                elseif ctype == 70 then  -- TRANSPORT_VEHICLE：doorsTime（微秒）
                    return { doorsTime = mockDoorsArrival * 1000000 }
                end
                return nil
            end,
        },
        type = { ComponentType = { LINE = 60, TRANSPORT_VEHICLE = 70 } },
    }
    package.loaded[".res.scripts.celmi.timetables.timetable"] = nil
    local tt = require ".res.scripts.celmi.timetables.timetable"
    tt.setDelayTolerance(300)  -- 显式 5 分钟，防 _G 残留干扰

    -- 1) getter 默认（无条目 / 旧档缺字段）
    tt.setTimetableObject({})
    assert(tt.getForceDepartureEnabled(100) == true, "default forceDeparture must be true")
    assert(tt.getMinWaitEnabled(100) == false, "default minWait must be false")
    assert(tt.getMaxWaitEnabled(100) == false, "default maxWait must be false")
    tt.setTimetableObject({ ["100"] = { hasTimetable = true, stations = {} } })
    assert(tt.getForceDepartureEnabled(100) == true, "old save (no field): forceDeparture default true")
    assert(tt.getMinWaitEnabled(100) == false, "old save (no field): minWait default false")

    -- 2) setter 往返 + 持久化
    tt.setForceDepartureEnabled(100, false)
    tt.setMinWaitEnabled(100, true)
    tt.setMaxWaitEnabled(100, true)
    assert(tt.getForceDepartureEnabled(100) == false, "forceDeparture=false round trip")
    assert(tt.getMinWaitEnabled(100) == true, "minWait=true round trip")
    assert(tt.getMaxWaitEnabled(100) == true, "maxWait=true round trip")
    local savedEntry = tt.getTimetableObject()["100"]
    assert(savedEntry.forceDeparture == false and savedEntry.minWaitEnabled == true and savedEntry.maxWaitEnabled == true,
        "line switches must persist in timetableObject[line]")

    -- ===== waitingRequired 行为 =====
    -- 时刻槽 {10,0,10,0}：13:10 到、13:10 发（模小时）→ 绝对发车 13:10:00（= 46800+600 = 47400s）
    local function objWith(force, min, max)
        return { ["100"] = { hasTimetable = true, forceDeparture = force, minWaitEnabled = min, maxWaitEnabled = max,
            stations = { [1] = { stationID = 1001,
                conditions = { type = "ArrDep", ArrDep = { {10,0,10,0} } } } } } }
    end
    local function resetWaiting()
        tt.setCurrentlyWaiting({})
        forceCalls = 0
    end

    -- 3) force=true（且 min/max 也勾着）→ min/max 被忽略，晚点容差内到点强发
    tt.setTimetableObject(objWith(true, true, true))
    mockTime = 3600 * 13 + 645   -- 13:10:45（晚点 45s ≤ 容差 300）
    resetWaiting()
    assert(tt.waitingRequired("V1") == false, "force=true late-within-tolerance must release")
    assert(forceCalls == 1, "force=true release must forceDeparture (got " .. tostring(forceCalls) .. ")")

    -- 4) force=false（min/max 关）→ 同一场景普通放行，不强发
    tt.setTimetableObject(objWith(false, false, false))
    mockTime = 3600 * 13 + 645
    resetWaiting()
    assert(tt.waitingRequired("V1") == false, "force=false late-within-tolerance must release")
    assert(forceCalls == 0, "force=false release must NOT forceDeparture (engine loads then leaves)")

    -- 5) force=false + Min：到站 13:10:30 + min 120s = 13:12:30 前继续扣（装完判点未满）
    tt.setTimetableObject(objWith(false, true, false))
    mockDoorsArrival = 3600 * 13 + 630   -- 13:10:30 到站
    dwellMin = 120
    mockTime = 3600 * 13 + 690   -- 13:11:30（晚点 90s 容差内，但 min 未满）
    resetWaiting()
    assert(tt.waitingRequired("V1") == true, "min not satisfied must keep holding")
    assert(forceCalls == 0, "min hold must not forceDeparture")

    -- 6) 同配置 min 已满（13:12:45 ≥ 13:12:30）→ 普通放行
    mockTime = 3600 * 13 + 765   -- 13:12:45
    resetWaiting()
    assert(tt.waitingRequired("V1") == false, "min satisfied must release")
    assert(forceCalls == 0, "min satisfied release must be plain (no forceDeparture)")

    -- 7) force=false + Max：到站 13:10:30 + max 300s = 13:15:30；13:16:00（晚点 360s 超容差）
    --    → max 覆盖"扣到下一趟"，到点强发
    tt.setTimetableObject(objWith(false, true, true))
    mockDoorsArrival = 3600 * 13 + 630
    dwellMin = 120
    dwellMax = 300
    mockTime = 3600 * 13 + 960   -- 13:16:00
    resetWaiting()
    assert(tt.waitingRequired("V1") == false, "max reached must release even beyond tolerance")
    assert(forceCalls == 1, "max reached must forceDeparture (got " .. tostring(forceCalls) .. ")")

    -- 8) force=false + 无 min/max + 晚点超容差 → 仍扣到下一趟（不是一律放行）
    tt.setTimetableObject(objWith(false, false, false))
    mockTime = 3600 * 13 + 960   -- 13:16:00，晚点 360s > 容差 300
    resetWaiting()
    assert(tt.waitingRequired("V1") == true, "late beyond tolerance (force=false) must hold to next slot")
    assert(forceCalls == 0, "beyond-tolerance hold must not forceDeparture")

    _G.api = prevApi
    print("  OK: line control switches (force departure / min wait / max wait)")
end

-- 最大停站时间语义精化回归（2026-08-16 玩家拍板）：max 不是"到站+M 无脑强发"，而是
--   ① 到站满 M 仍滞留（该趟发车时刻已过：超容差等下一趟/装卸拖过点）→ 强发；
--   ② 发车点前到达、扣着等到点的车，点到即走 → 强发（到点掐装卸）；
--   发车时刻没到 → 绝不提前强发（早到等到点，不早发）；
--   晚点但装得快（容差内）→ 普通放行"装完就走"，max 不兜底。
timetableTests[#timetableTests + 1] = function()
    local mockTime = 3600 * 13 + 300
    local mockLine = 100
    local mockStop = 1
    local mockDoorsArrival = 3600 * 13  -- 到站时刻（doorsTime 微秒）
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
                conditions = { type = "ArrDep", ArrDep = { {10,0,10,0} } } } } } }  -- 13:10 发（绝对 47400）
    end
    local function resetWaiting()
        tt.setCurrentlyWaiting({})
        forceCalls = 0
    end

    -- A) max✓ + 早到 10 分钟（13:00 到，M=180s）：13:05:30 已到站+M，但发车时刻 13:10 未到
    --    → 绝不提前强发，继续扣到发车时刻（这是对"旧实现 13:03 就强发"的核心修正）
    tt.setTimetableObject(objWith(false, false, true))
    mockDoorsArrival = 3600 * 13          -- 13:00:00 到站
    dwellMax = 180
    mockTime = 3600 * 13 + 330            -- 13:05:30
    resetWaiting()
    assert(tt.waitingRequired("V1") == true, "early arrival past arrival+M but before dep point must keep holding")
    assert(forceCalls == 0, "early arrival must NOT be force-departed before its departure point")

    -- B) 同配置，到发车时刻后 5s（13:10:05，delay=5 ≤ 容差）→ 到点强发（掐装卸）
    mockTime = 3600 * 13 + 605
    resetWaiting()
    assert(tt.waitingRequired("V1") == false, "dep point reached (held train) must release")
    assert(forceCalls == 1, "max: at-departure release must forceDeparture (got " .. tostring(forceCalls) .. ")")

    -- C) max✓ + 晚点 2 分钟但装得快（13:12 到，发车点 13:10 已过，容差内）→ 普通放行不强发
    --    （max 不兜"晚点但装完即走"，玩家拍板）
    tt.setTimetableObject(objWith(false, false, true))
    mockDoorsArrival = 3600 * 13 + 720    -- 13:12:00 到站
    mockTime = 3600 * 13 + 750            -- 13:12:30（关门判点；到站+M=13:15 未到）
    resetWaiting()
    assert(tt.waitingRequired("V1") == false, "late within tolerance + fast loading must release")
    assert(forceCalls == 0, "late-within-tolerance fast loader must NOT be force-departed")

    -- D) max✓ + 晚点超容差（delay 310s > 300）：到站+M（13:15:00）已过 → 强发兜底（不等下一趟）
    --    到站+M = 13:12:00 + 180s = 13:15:00；跳到 13:15:10（47710 ≥ 47700）
    mockTime = 3600 * 13 + 910            -- 13:15:10
    resetWaiting()
    assert(tt.waitingRequired("V1") == false, "beyond tolerance + max elapsed must release (cap the dead wait)")
    assert(forceCalls == 1, "beyond-tolerance dead wait capped by max must forceDeparture (got " .. tostring(forceCalls) .. ")")

    -- E) 对照：同样超容差场景但 max✗ → 扣到下一趟（max 是唯一让它提前走的开关）
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

return {
    test = function()
        for k,v in pairs(timetableTests) do
            print("Running test: " .. tostring(k))
            v()
        end
    end
}
