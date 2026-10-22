local timetable = require "celmi/timetables/timetable"
local timetableHelper = require "celmi/timetables/timetable_helper"
local diagramTrains = require "celmi/timetables/diagram_trains"
local diagramLayout = require "celmi/timetables/diagram_layout"
-- 交路系统已独立为 TrainRoute mod：这里通过 _G._trainRouteDiagramHook 读取它的
-- getDiagramMode()/isConfigLine() 来决定"交路运行图模式"绘制；未安装 TrainRoute 时钩子为 nil，
-- 运行图按普通模式绘制（与无交路系统时一致）。

local diagramGUI = {}

-- 交路运行图模式接口（由 TrainRoute mod 注册）：该线路是否为交路配置线且交路运行图开关打开
local function isRotationLine(lineId)
    local hook = _G._trainRouteDiagramHook
    if not hook then return false end
    local okMode, mode = pcall(hook.getDiagramMode)
    if not (okMode and mode) then return false end
    local okCfg, isCfg = pcall(hook.isConfigLine, lineId)
    if okCfg then return isCfg == true end
    return false
end

local menu = {
    window = nil, lineRenderViews = {}, stationLabels = {}, timeLabels = {},
    timeBarTop = nil, timeBarBottom = nil, chartH = nil, daComponent = nil,
    stationLabelViews = {}, timeLabelViews = {},
    lineListLayout = nil, lineScrollArea = nil,
    presetScrollArea = nil,
    -- live vehicle overlay: its line views (topmost) and the chart geometry of the last refresh
    liveViews = {}, liveCtx = nil,
}

local allStations = {}
local allLines = {}
local displayedLines = {}
local expandedPresetId = nil
local currentPresetRef = nil
local stationRowGroups = {}
local localPresets = {}  -- {id = {id, name, stationData}, ...}, runtime source of truth
local stationFilterText = ""
-- 新增预设后要把列表滚动到新预设表头（从视口顶部开始展示），rebuildPresetList 记录对应行
local pendingScrollPresetId = nil
local pendingScrollPresetRow = nil

-- 前向声明：以下函数以赋值形式定义（xxx = function ... end），且可能在声明之前被
-- 其它函数的闭包引用。Lua 局部变量只在声明之后可见，不加前向声明会导致引用解析为全局 nil
-- （"attempt to call global 'xxx' (a nil value)"）。
local rebuildPresetList
local saveCurrentPreset

-- 组件名计数器：必须跨刷新周期唯一（AGENTS.md: removeItem 移除的组件名可能未被
-- 引擎即时释放，同名重建会冲突）。每次刷新创建站名/时间标签时递增，永不重复。
-- 存 _G 而非 local：模块级 local 不抗 Lua VM 重载，_G 可跨模块重载存活。
local function nextLabelName()
    if not _G._diagramLabelCounter then _G._diagramLabelCounter = 0 end
    _G._diagramLabelCounter = _G._diagramLabelCounter + 1
    return _G._diagramLabelCounter
end

local WINDOW_WIDTH = 1200
local WINDOW_HEIGHT = 780
-- 标题栏实际高约 36px（2026-08-16 玩家日志实测：da 渲染高 930px / 1.25 = 744 = 780 - 36；
-- 旧值 30 会让 da/ca 高度按 750 估算，实际只有 744 → ca 与时间条重叠）
local TITLE_BAR_H = 36
local STATION_PANEL_WIDTH = 220
local TIME_LABEL_HEIGHT = 22
local STATION_LABEL_WIDTH = 110

local LINE_COLORS = {
    {1.0, 0.2, 0.2, 1.0}, {0.2, 0.6, 1.0, 1.0},
    {0.2, 1.0, 0.4, 1.0}, {1.0, 0.8, 0.2, 1.0},
    {0.8, 0.2, 1.0, 1.0}, {1.0, 0.6, 0.2, 1.0},
    {0.6, 0.8, 0.2, 1.0}, {0.2, 0.8, 0.8, 1.0},
    {0.8, 0.6, 0.8, 1.0}, {0.6, 0.6, 0.6, 1.0},
    {1.0, 0.5, 0.5, 1.0}, {0.5, 0.8, 0.5, 1.0},
}

local function getColor(index)
    local c = LINE_COLORS[(index - 1) % #LINE_COLORS + 1]
    return api.type.Vec4f.new(c[1], c[2], c[3], c[4])
end

-- 错误日志：始终输出（仅出错时触发，性能无负担）
local function debugPrint(msg) print("[DiagramGUI] " .. msg) end
-- 调试汇总日志：受 _G._diagramDebug 开关控制（默认关闭），避免每次刷新/保存的
-- 高频汇总日志对玩家造成日志刷屏与 I/O 负担。排查问题时在控制台 `_G._diagramDebug=true`。
local function dbgPrint(msg)
    if _G._diagramDebug then print("[DiagramGUI] " .. msg) end
end

local D = {
    title = _("diagram_title_i18n"),
    title_short = _("diagram_title_short_i18n"),
    refresh = _("diagram_refresh_i18n"),
    color = _("diagram_color_i18n"),
    choose_color = _("diagram_choose_color_i18n"),
    no_presets = _("diagram_no_presets_i18n"),
    confirm_delete = _("diagram_confirm_delete_i18n"),
    warning = _("diagram_warning_i18n"),
    confirm = _("diagram_confirm_i18n"),
    cancel = _("diagram_cancel_i18n"),
    sort = _("diagram_sort_i18n"),
    preset = _("diagram_preset_i18n"),
    railway_lines = _("diagram_railway_lines_i18n"),
    train_list = _("diagram_train_list_i18n"),
    station_search = _("diagram_station_search_i18n"),
    settings = _("diagram_settings_i18n"),
    settings_auto = _("diagram_settings_auto_i18n"),
    settings_manual = _("diagram_settings_manual_i18n"),
    settings_refresh_rate = _("diagram_settings_refresh_rate_i18n"),
    settings_time_label = _("diagram_settings_time_label_i18n"),
    settings_top = _("diagram_settings_top_i18n"),
    settings_bottom = _("diagram_settings_bottom_i18n"),
    settings_both = _("diagram_settings_both_i18n"),
    settings_position = _("diagram_settings_position_i18n"),
    settings_time_scale = _("diagram_settings_time_scale_i18n"),
    settings_scale_2 = _("diagram_settings_scale_2_i18n"),
    settings_scale_5 = _("diagram_settings_scale_5_i18n"),
    settings_scale_10 = _("diagram_settings_scale_10_i18n"),
    settings_punct_threshold = _("diagram_settings_punct_threshold_i18n"),
    settings_polyline_filter = _("diagram_settings_polyline_filter_i18n"),
    settings_polyline_all = _("diagram_settings_polyline_all_i18n"),
    settings_polyline_up = _("diagram_settings_polyline_up_i18n"),
    settings_polyline_down = _("diagram_settings_polyline_down_i18n"),
    zoom = _("diagram_zoom_i18n") or "Zoom",
    zoom_time_interval = _("diagram_zoom_time_interval_i18n") or "Time Interval:",
    zoom_station_interval = _("diagram_zoom_station_interval_i18n") or "Station Interval:",
    zoom_restore = _("diagram_zoom_restore_i18n") or "Restore Default",
    settings_spacing = _("diagram_settings_spacing_i18n"),
    settings_spacing_equal = _("diagram_settings_spacing_equal_i18n"),
    settings_spacing_distance = _("diagram_settings_spacing_distance_i18n"),
    settings_spacing_time = _("diagram_settings_spacing_time_i18n"),
    settings_platforms = _("diagram_settings_platforms_i18n"),
    settings_platforms_show = _("diagram_settings_platforms_show_i18n"),
    settings_vehicles = _("diagram_settings_vehicles_i18n"),
    settings_vehicles_show = _("diagram_settings_vehicles_show_i18n"),
    punctuality = _("diagram_punctuality_i18n"),
    punct_ontime = _("diagram_punct_ontime_i18n"),
    punct_early = _("diagram_punct_early_i18n"),
    punct_late = _("diagram_punct_late_i18n"),
}

local function getConfig()
    local cfg = timetable.getDiagramConfig()
    if not cfg then cfg = {}; timetable.setDiagramConfig(cfg) end
    return cfg
end

local function saveConfig(cfg) timetable.setDiagramConfig(cfg or {}) end

-- The line's color in the game. The color button of the line list sets the game color too,
-- so the colors saved in the config are not read anymore (they were saved for every line,
-- so the fallback palette overrode the game colors).
local function getLineColor(lineID)
    return timetableHelper.getLineColourVec4(lineID)
end

local function saveLineColor(lineID, color)
    local cfg = getConfig()
    if not cfg.lineColors then cfg.lineColors = {} end
    cfg.lineColors[tostring(lineID)] = {color.x, color.y, color.z, color.w}
    saveConfig(cfg)
end

local function getHostLineKey(to)
    local cfg = getConfig()
    local stored = cfg._hostLineId
    if stored and to[stored] and to[stored].dp and to[stored].dp.presetList and #to[stored].dp.presetList > 0 then
        return stored
    end
    local keys = {}
    for k, v in pairs(to) do
        local n = tonumber(k)
        if n and n > 0 and type(v) == "table" and v.dp and v.dp.presetList and #v.dp.presetList > 0 then
            table.insert(keys, n)
        end
    end
    table.sort(keys)
    if #keys > 0 then
        local chosen = tostring(keys[1])
        cfg._hostLineId = chosen; saveConfig(cfg)
        return chosen
    end
    if stored and to[stored] then return stored end
    for k, v in pairs(to) do
        if tonumber(k) and tonumber(k) > 0 then
            cfg._hostLineId = k; saveConfig(cfg)
            return k
        end
    end
    return nil
end

-- Runtime: localPresets is source of truth. Persistence via timetableObject.
local function getPresetList() return localPresets end
local function setPresetList(list) localPresets = list or {} end

local function getActivePresetId() return getConfig()._activePresetId or "" end
local function setActivePresetId(id)
    local cfg = getConfig(); cfg._activePresetId = id or ""; saveConfig(cfg)
end

local function loadPresetsFromTimetableObject()
    localPresets = {}
    local to = timetable.getTimetableObject()
    local host = getHostLineKey(to)
    if host and to[host].dp then
        local dp = to[host].dp
        if dp.presetList then
            for i, p in ipairs(dp.presetList) do
                local sdCopy = {}
                if p.stationData then
                    for k, v in pairs(p.stationData) do
                        sdCopy[k] = {selected = v.selected or false, sort = (type(v.sort) == "number" and v.sort > 0 and v.sort <= 255) and v.sort or 256}
                    end
                end
                local ldCopy = {}
                if p.lineData then
                    for k, v in pairs(p.lineData) do ldCopy[k] = v end
                end
                table.insert(localPresets, {id = tostring(i), name = p.name, stationData = sdCopy, lineData = ldCopy})
            end
        end
        getConfig()._activePresetId = dp.activePresetId or ""
        if dp.colorList then
            local cfg = getConfig()
            if not cfg.lineColors then cfg.lineColors = {} end
            for _, entry in pairs(dp.colorList) do
                cfg.lineColors[entry.i] = {entry.r, entry.g, entry.b, entry.a}
            end
        end
        dbgPrint("loadPresets: " .. #localPresets .. " from line " .. host .. ".dp")
    else
        dbgPrint("loadPresets: no host line with dp")
    end
end

local function savePresetsToTimetableObject()
    local to = timetable.getTimetableObject()
    if not to then return end
    local host = getHostLineKey(to)
    if not host then
        dbgPrint("savePresets: no host line found")
        return
    end
    local dp = to[host].dp
    if not dp then dp = {}; to[host].dp = dp end
    -- 数据安全防御（2026-08-09 补）：内存中预设为空但存档已有预设（loadPresets 失败/模块重载等），
    -- 拒绝写入空列表覆盖已保存配置，避免"存档铁路线配置被清空"。
    if #localPresets == 0 and dp.presetList and #dp.presetList > 0 then
        dbgPrint("savePresets: localPresets empty but save has presets, refusing to overwrite")
        return
    end
        dp.presetList = {}
    for _, p in pairs(localPresets) do
        local sdCount = 0
        local sdCopy = {}
        if p.stationData then
            for k, v in pairs(p.stationData) do
                sdCount = sdCount + 1
                sdCopy[k] = {selected = v.selected or false, sort = (type(v.sort) == "number" and v.sort > 0 and v.sort <= 255) and v.sort or 256}
            end
        end
        local ldCopy = {}
        if p.lineData then
            for k, v in pairs(p.lineData) do ldCopy[k] = v end
        end
        dbgPrint("savePresets: preset " .. p.id .. "=" .. p.name .. " stationData entries=" .. sdCount)
        table.insert(dp.presetList, {id = p.id, name = p.name, stationData = sdCopy, lineData = ldCopy})
    end
    dp.activePresetId = getActivePresetId()
    dp.colorList = {}
    for _, ld in pairs(allLines) do
        if ld.color then
            local c = ld.color
            table.insert(dp.colorList, {i = tostring(ld.id), r = c.x, g = c.y, b = c.z, a = c.w})
        end
    end
    dbgPrint("savePresets: saved " .. #localPresets .. " to line " .. host .. ".dp")

    for k, v in pairs(to) do
        if k ~= host and type(v) == "table" and v.dp and v.dp.presetList then
            v.dp.presetList = nil
        end
    end

    local cfg = getConfig()
    cfg._activePresetId = getActivePresetId()
    saveConfig(cfg)
    _G._diagramForceSync = true
end

-- 预设车站清理（2026-08-16 方案定稿）：拆站后，预设 stationData 里该站的勾选/序号条目删除，
-- 其余站的条目原样保留、序号不动（预设按实体键 "s_<stationID>" 存储，与线路位置无关）。
-- 有效性判断用 entityExists（保守：实体暂未回收时保留——被删站不在 allStations 里本就不会被
-- 应用，无害；重建车站若复用实体 ID → entityExists true → 条目保留，同一位置视为同一站）。
-- 路径点条目（"wp_" 前缀）不在此清理范围。
-- 有删除时立即 savePresetsToTimetableObject() 写回存档（dp.presetList）+ 触发跨线程同步。
-- 返回清理条数。
local function purgeDeletedStationsFromPresets()
    local removedTotal = 0
    for _, p in pairs(localPresets) do
        if type(p) == "table" and type(p.stationData) == "table" then
            local toDrop = {}
            for key, _ in pairs(p.stationData) do
                if type(key) == "string" and key:sub(1, 2) == "s_" then
                    local sid = tonumber(key:sub(3))
                    if sid then
                        local okEv, exists = pcall(function() return api.engine.entityExists(sid) end)
                        if okEv and exists ~= true then
                            toDrop[#toDrop + 1] = key
                        end
                    end
                end
            end
            for _, key in ipairs(toDrop) do
                p.stationData[key] = nil
                removedTotal = removedTotal + 1
            end
        end
    end
    if removedTotal > 0 then
        dbgPrint("purgeDeletedStationsFromPresets removed " .. removedTotal .. " stale station entry(ies)")
        pcall(function() savePresetsToTimetableObject() end)
    end
    return removedTotal
end

local function findPresetById(id)
    for _, p in pairs(localPresets) do
        if p.id == id then return p end
    end
    return nil
end

local function getActivePreset()
    local id = getActivePresetId()
    if id and #id > 0 then return findPresetById(id) end
    return nil
end

local function getActivePresetName()
    local p = getActivePreset()
    return p and p.name or ""
end

local function sortAllStations()
    table.sort(allStations, function(a, b)
        if a.selected ~= b.selected then return a.selected end
        if a.selected then
            local sa = a.sort or 1
            local sb = b.sort or 1
            if sa ~= sb then return sa < sb end
        end
        return string.lower(a.name) < string.lower(b.name)
    end)
end

-- Station positions (station group entity -> {x, y}), cached: they hardly ever change
local stationPosCache = {}
local function getStationPos(id)
    local key = tostring(id)
    if stationPosCache[key] == nil then
        local x, y = timetableHelper.getEntityPosition(tonumber(id))
        stationPosCache[key] = x and {x, y} or false
    end
    return stationPosCache[key] or nil
end

local function getAllTimetableData()
    local data = {}
    for _, lineInfo in pairs(timetableHelper.getAllRailLines()) do
        local lineID = lineInfo.id
        -- 运行图只显示铁路线（时刻表显示所有线路，故筛选只在运行图侧做）。
        -- 用反向过滤：排除明确非铁路（公交/电车/水路/航空）的线；空线路保守保留，避免误删。
        local isNonRail = timetableHelper.lineHasType(lineID, "ROAD")
            or timetableHelper.lineHasType(lineID, "TRAM")
            or timetableHelper.lineHasType(lineID, "WATER")
            or timetableHelper.lineHasType(lineID, "AIR")
        if isNonRail then
            goto continueLine
        end
        local stops = timetableHelper.getAllStops(lineID)
        local stCount = 0
        local wpCount = 0
        for _, si in ipairs(stops) do
            if si.type == "station" then stCount = stCount + 1
            elseif si.type == "waypoint" then wpCount = wpCount + 1 end
        end
        if stCount > 0 or wpCount > 0 then
            dbgPrint("LINE " .. tostring(lineID) .. " '" .. lineInfo.name .. "' stops=" .. #stops .. " stations=" .. stCount .. " waypoints=" .. wpCount)
        end
        local lineData = {
            id = lineID, name = lineInfo.name, stations = {},
            color = getLineColor(lineID) or getColor(#data + 1),
            selected = false, bold = false, checked = true,
        }
        lineData.legTimes, lineData.legDistances = timetableHelper.getLegEstimates(lineID)
        for flatIdx, stopInfo in ipairs(stops) do
            local displayName = stopInfo.name
            local gk = stopInfo.gwKey
            if stopInfo.type == "waypoint" then
                if gk then
                    local gn = timetable.getGlobalWaypointName(gk)
                    if gn then displayName = gn end
                end
                if not gk or not timetable.getGlobalWaypointName(gk) then
                    local cn = timetable.getWaypointName(lineID, stopInfo.id)
                    if cn then displayName = cn end
                end
            end
            local uk = tostring(stopInfo.id) .. "_" .. tostring(lineID)
            local entry = { id = stopInfo.id, entityId = stopInfo.entityId, uniqueKey = uk,
                name = displayName, stopType = stopInfo.type, times = {},
                gwKey = gk, stopIndex = stopInfo.stopIndex, platform = stopInfo.platform,
                isLineStop = stopInfo.type == "station" or stopInfo.parentStationGroup == nil }
            if stopInfo.type == "station" then
                local ct = timetable.getConditionType(lineID, stopInfo.stopIndex)
                if ct == "ArrDep" then
                    entry.times = timetable.getConditions(lineID, stopInfo.stopIndex, "ArrDep") or {}
                end
            else
                local wt = timetable.getWaypointPassingTime(lineID, stopInfo.id)
                if wt and #wt > 0 then
                    for _, t in ipairs(wt) do
                        entry.times[#entry.times + 1] = {t[1], t[2], t[1], t[2]}
                    end
                end
            end
            if stopInfo.type == "station" then
                entry.pos = getStationPos(stopInfo.id)
            else
                entry.pos = stopInfo.pos
            end
            lineData.stations[flatIdx] = entry
        end
        diagramTrains.assignLegFractions(lineData.stations)
        table.insert(data, lineData)
        ::continueLine::
    end
    return data
end

local function stableKey(stopType, id, uniqueKey, entityId)
    if stopType == "station" then return "s_" .. tostring(id) end
    return "wp_" .. tostring(entityId or id)
end

local function getAllStationsFlat(lineDataList)
    local list = {}
    local seen = {}
    local totalStations = 0
    local totalWaypoints = 0
    for _, ld in pairs(lineDataList) do
        for _, st in pairs(ld.stations) do
            local key = stableKey(st.stopType, st.id, st.uniqueKey, st.entityId)
            if not seen[key] then
                seen[key] = true
                local dn = st.name
                if st.stopType == "waypoint" then
                    dn = "▶ " .. dn; totalWaypoints = totalWaypoints + 1
                else
                    totalStations = totalStations + 1
                end
                table.insert(list, {
                    id = st.id, entityId = st.entityId, uniqueKey = st.uniqueKey, name = dn,
                    selected = false, sort = 256, stopType = st.stopType,
                    sourceLineID = ld.id, sourceLineName = ld.name, pos = st.pos,
                })
            end
        end
    end
    local mapAdded = 0
    local allMapStations = timetableHelper.getAllStationEntities()
    for _, ms in ipairs(allMapStations) do
        local key = "s_" .. tostring(ms.id)
        if not seen[key] then
            seen[key] = true
            mapAdded = mapAdded + 1
            totalStations = totalStations + 1
            table.insert(list, {
                id = ms.id, entityId = nil, uniqueKey = "map_" .. tostring(ms.id),
                name = ms.name, selected = false, sort = 256, stopType = "station",
                sourceLineID = nil, sourceLineName = nil,
            })
        end
    end
    dbgPrint("getAllStationsFlat: totalLines=" .. #lineDataList .. " uniqueStations=" .. totalStations .. " uniqueWaypoints=" .. totalWaypoints .. " mapOnlyAdded=" .. mapAdded)
    return list
end

local function getSelectedStationList()
    local r = {}
    for _, s in pairs(allStations) do if s.selected then table.insert(r, s) end end
    return r
end

local function getRelevantLines(selList)
    local keys = {}
    local entityIds = {}
    local wpEntityIds = {}
    for _, s in pairs(selList) do
        keys[s.uniqueKey] = true
        if s.stopType == "station" then
            entityIds[tostring(s.id)] = true
        end
        if s.stopType == "waypoint" and s.entityId then
            wpEntityIds[s.entityId] = true
        end
    end
    local r = {}
    for _, ld in pairs(allLines) do
        for _, st in pairs(ld.stations) do
            local match = keys[st.uniqueKey]
            if not match and st.stopType == "station" then
                match = entityIds[tostring(st.id)]
            end
            if not match and st.stopType == "waypoint" and st.entityId then
                match = wpEntityIds[st.entityId]
            end
            if match then
                table.insert(r, ld); break
            end
        end
    end
    -- 车次排序：勾选置顶 + 线路名自然排序。
    -- 1) 勾选的线路排最上面（用户需求：勾选后刷新全部上移）
    -- 2) 线路名含"字母+数字"前缀（如 G123/G34）按 (字母, 数值) 比较 → G1,G2,G10,G21,G111
    -- 3) 其余（含中文）按 UTF-8 码点稳定排序。中文按拼音首字母需内置数千字的拼音对照表，
    --    TPF2 无此库，不做（这是"有难度只上移"里放弃的那部分）。
    local function lineSortKey(name)
        name = tostring(name or "")
        local prefix, num = name:match("^(%a+)(%d+)")
        if prefix and num then return {p = prefix, n = tonumber(num)} end
        local numOnly = name:match("^(%d+)")
        if numOnly then return {p = "", n = tonumber(numOnly)} end
        return {s = name}
    end
    local function compareLines(a, b)
        if a.checked ~= b.checked then return a.checked end
        local ka, kb = lineSortKey(a.name), lineSortKey(b.name)
        if ka.p and kb.p then
            if ka.p ~= kb.p then return ka.p < kb.p end
            if ka.n ~= kb.n then return ka.n < kb.n end
        elseif ka.p or kb.p then
            -- 一个有字母/数字前缀、一个没有：有前缀的排前
            return ka.p ~= nil
        else
            if tostring(ka.s) ~= tostring(kb.s) then return tostring(ka.s) < tostring(kb.s) end
        end
        -- 同名/同 key 兜底：按线路 ID 稳定
        local na, nb = tonumber(a.id), tonumber(b.id)
        if na and nb then return na < nb end
        return tostring(a.id) < tostring(b.id)
    end
    table.sort(r, compareLines)
    return r
end

local function createColorChooserButton(lineData, onSelected)
    local btn = api.gui.comp.Button.new(api.gui.comp.TextView.new(D.color), true)
    btn:setStyleClassList({"timetable-avtivateTimetableButton"})
    btn:setEnabled(lineData.selected)
    lineData.colorButton = btn
    btn:onClick(function()
        local cp = api.gui.comp.ColorPicker.new()
        cp:onColorChanged(function(c)
            lineData.color = api.type.Vec4f.new(c.x, c.y, c.z, 1.0)
            saveLineColor(lineData.id, lineData.color)
            local to = timetable.getTimetableObject()
            local host = getHostLineKey(to)
            if host and to[host].dp then
                if not to[host].dp.colorList then to[host].dp.colorList = {} end
                local found = false
                for _, entry in pairs(to[host].dp.colorList) do
                    if entry.i == tostring(lineData.id) then
                        entry.r = c.x; entry.g = c.y; entry.b = c.z; entry.a = 1.0
                        found = true; break
                    end
                end
                if not found then
                    table.insert(to[host].dp.colorList, {i = tostring(lineData.id), r = c.x, g = c.y, b = c.z, a = 1.0})
                end
            end
            _G._diagramForceSync = true
            onSelected()
        end)
        local okW, w = pcall(function() return api.gui.comp.Window.new(D.choose_color, cp) end)
        if okW and w then w:addHideOnCloseHandler(); w:setMovable(true); w:setPosition(300, 200) end
    end)
    return btn
end

-- 按设置计算各行（排序组）的纵坐标：
--   equal    等距
--   distance 沿线路的站间直线距离（各线路、双向取平均），无线路经过的相邻行用两行车站的直线距离补
--   time     沿线路的区间运行时间估算（各线路、双向取平均），缺失的按距离换算补
local function computeRowYs(keyRow, sorts, labelGroups, h)
    local nRows = #sorts
    local mode = timetable.getRowSpacing()
    if mode == "equal" or nRows <= 1 then
        return diagramLayout.rowYs(nil, nRows, h)
    end
    local direct = {}
    local prevPos = nil
    for i, sv in ipairs(sorts) do
        -- a station of the row, else a waypoint
        local pos = nil
        for _, s in pairs(labelGroups[sv]) do
            if s.stopType == "station" then
                pos = getStationPos(s.id)
                if pos then break end
            elseif not pos then
                pos = s.pos
            end
        end
        if pos and prevPos then
            direct[i - 1] = math.sqrt((pos[1] - prevPos[1]) ^ 2 + (pos[2] - prevPos[2]) ^ 2)
        end
        prevPos = pos
    end
    local function linesWith(metricKey)
        local r = {}
        for _, ld in pairs(displayedLines) do
            r[#r + 1] = { stations = ld.stations, metric = ld[metricKey] or {} }
        end
        return r
    end
    local gaps = diagramLayout.fillGaps(
        diagramLayout.lineGaps(linesWith("legDistances"), keyRow, nRows), direct, nRows - 1)
    if mode == "time" then
        gaps = diagramLayout.fillGaps(
            diagramLayout.lineGaps(linesWith("legTimes"), keyRow, nRows), gaps, nRows - 1)
    end
    return diagramLayout.rowYs(gaps, nRows, h)
end

-- 缩放窗口：把整图的行位置（rowFracs，首行 1、末行 0）映射为纵坐标，使窗口首行 y = h、
-- 窗口末行 y = 0；窗口外的行按同一刻度外推（可能超出 [0,h]，由绘制时裁剪）。
local function windowRowYs(rowFracs, rWin0, rWinLen, h)
    local ys = {}
    local fLo, fHi = rowFracs[rWin0], rowFracs[rWin0 + rWinLen - 1]
    for i, f in ipairs(rowFracs) do
        if rWinLen <= 1 or not fLo or not fHi or fLo == fHi then
            ys[i] = h / 2
        else
            ys[i] = (f - fHi) / (fLo - fHi) * h
        end
    end
    return ys
end

-- 运行图放大（2026-08-16 功能）：保持画布大小不变，改变绘制范围来放大运行图。
--   tStart/tLen = 时间窗口（分钟，0-60 内）；rStart/rLen = 车站行窗口（1-based 行排名）。
--   active=false → 完整视图（0-60 分、全部行）。关窗即重置（临时查看辅助，不持久化）。
local zoomState = {
    active = false,
    tStart = 0,
    tLen = 60,
    rStart = 1,
    rLen = 0,
}

-- 各时间刻度对应的"时间区间"（窗口长度，分钟）下拉选项（用户定稿）
local ZOOM_INTERVAL_OPTIONS = {
    [2] = {60, 30, 20, 10, 6},
    [5] = {60, 30, 20, 10},
    [10] = {60, 40, 30, 20},
}

-- 设置/放大弹窗单例引用：重复点击只置顶/重显已打开的窗口，不重复创建（2026-08-16 反馈）。
-- isAttached() 检测窗口是否已被销毁（如重开运行图时被引擎清理）；setVisible(true,true) 重显/置顶。
local settingsWinRef = nil
local zoomWinRef = nil
local function reshowOrReset(winRef)
    if not winRef then return false end
    local okAtt, attached = pcall(function() return winRef:isAttached() end)
    if not (okAtt and attached) then return false end
    local okVis = pcall(function() winRef:setVisible(true, true) end)
    if not okVis then return false end
    return true
end

-- 当前选择（展开线路合并去重后的车站+路径点行）的唯一排序序号列表（升序）
local function computeSortRanks(selList)
    local labelGroups = {}
    local labelDedup = {}
    for _, s in pairs(selList) do
        local sort = s.sort or 1
        if not labelGroups[sort] then labelGroups[sort] = {}; labelDedup[sort] = {} end
        local dk = stableKey(s.stopType, s.id, s.uniqueKey, s.entityId)
        if not labelDedup[sort][dk] then
            labelDedup[sort][dk] = true
            table.insert(labelGroups[sort], s)
        end
    end
    local sorts = {}
    for k, _ in pairs(labelGroups) do table.insert(sorts, tonumber(k)) end
    table.sort(sorts)
    return sorts, labelGroups
end

-- 缩放窗口钳制（选择变化/越界时）：窗口必须落在有效范围内；没有实际放大（全宽全行）则视为未激活。
local function clampZoom(totalRanks)
    if not zoomState.active then return end
    local tLen = zoomState.tLen
    if tLen < 2 then tLen = 2 end
    if tLen > 60 then tLen = 60 end
    zoomState.tLen = tLen
    if zoomState.tStart < 0 then zoomState.tStart = 0 end
    if zoomState.tStart + tLen > 60 then zoomState.tStart = 60 - tLen end
    local rLen = zoomState.rLen
    if rLen < 1 then rLen = 1 end
    if rLen > totalRanks then rLen = totalRanks end
    zoomState.rLen = rLen
    if zoomState.rStart < 1 then zoomState.rStart = 1 end
    if zoomState.rStart + rLen - 1 > totalRanks then
        zoomState.rStart = math.max(1, totalRanks - rLen + 1)
    end
    if tLen >= 60 and rLen >= totalRanks then
        zoomState.active = false
    end
end

-- 构建 Y 轴映射：所有选中行都有 Y 值（2026-08-16 放大功能）。
-- 行位置按"车站间距"设置计算（computeRowYs），再按缩放窗口映射（windowRowYs）；
-- 窗口外的行用同一窗口刻度外推，可能超出 [0,h]——
-- 折线段跨越车站窗口边界时由 drawClippedSegment 按窗口 Y 范围 [0,dh] 裁剪（横向截断点正常绘制，
-- 不再因窗口外站无 Y 值而整段断线）。非选中的跨线车站（uniqueKey 不在 map 里）仍断线（原行为）。
local function buildYMap(selList, groups, sorts, rWin0, rWinLen, h)
    local keyRow = {}
    for i, sv in ipairs(sorts) do
        for _, s in pairs(groups[sv]) do
            if s.stopType == "station" then
                local eid = tostring(s.id)
                for _, ld in pairs(allLines) do
                    for _, st in pairs(ld.stations) do
                        if st.stopType == "station" and tostring(st.id) == eid then
                            keyRow[st.uniqueKey] = i
                        end
                    end
                end
            else
                if s.entityId then
                    for _, ld in pairs(allLines) do
                        for _, st in pairs(ld.stations) do
                            if st.stopType == "waypoint" and st.entityId == s.entityId then
                                keyRow[st.uniqueKey] = i
                            end
                        end
                    end
                else
                    keyRow[s.uniqueKey] = i
                end
            end
        end
    end
    local rowYs = windowRowYs(computeRowYs(keyRow, sorts, groups, 1), rWin0, rWinLen, h)
    local map = {}
    for k, i in pairs(keyRow) do map[k] = rowYs[i] end
    return map, rowYs
end

local function clearLiveViews()
    if menu.renderLayout then
        for _, v in ipairs(menu.liveViews) do
            pcall(function() menu.renderLayout:removeItem(v) end)
        end
    end
    menu.liveViews = {}
end

-- Position and delay of one vehicle on the chart, or nil if it cannot be placed.
-- At a stop: the stop's row, delay measured to the planned dwell. Between stops: on the planned
-- leg, shifted by the delay the vehicle departed with (diagramTrains.trainOnLeg).
-- Needs a timetabled stop: the current one, or the one the vehicle departed from.
local function locateVehicle(ld, vehicle, now, yMap, keepSeg)
    local okEv, exists = pcall(function() return api.engine.entityExists(tonumber(vehicle)) end)
    if not (okEv and exists == true) then return nil end
    local okC, vc = pcall(function()
        return api.engine.getComponent(tonumber(vehicle), api.type.ComponentType.TRANSPORT_VEHICLE)
    end)
    if not (okC and vc and vc.stopIndex) then return nil end
    local stations = ld.stations
    local stopFlat, nStops = {}, 0
    for f, st in ipairs(stations) do
        if st.isLineStop and st.stopIndex then
            stopFlat[st.stopIndex] = f
            if st.stopIndex > nStops then nStops = st.stopIndex end
        end
    end
    if nStops == 0 then return nil end

    if vc.state == 2 then
        local s = vc.stopIndex + 1
        local f = stopFlat[s]
        local st = f and stations[f]
        local y = st and yMap[st.uniqueKey]
        if not (y and #st.times > 0) then return nil end
        -- arrival: from the punctuality scanner if it saw this stop, else the doors time
        local arrival = nil
        local pv = _G._punctuality and _G._punctuality[tostring(vehicle)]
        if pv and pv.thisStopIndex == vc.stopIndex and pv.arrTime then arrival = pv.arrTime end
        if not arrival and vc.doorsTime and vc.doorsTime > 0 then arrival = math.floor(vc.doorsTime / 1000000) end
        local plArr, plDep = timetable.assignSlot(st.times, arrival or now)
        if not plArr then return nil end
        return { y = y, delay = diagramTrains.dwellDelay(plArr, plDep, now) }
    elseif vc.state == 1 then
        -- en route: stopIndex is the next stop, the leg starts at the previous one
        local s = (vc.stopIndex - 1) % nStops + 1
        local f = stopFlat[s]
        local st = f and stations[f]
        if not (st and #st.times > 0 and ld.runs) then return nil end
        local d = vc.lineStopDepartures and vc.lineStopDepartures[s]
        if not (d and d > 0) then return nil end
        local dep = math.floor(d / 1000)
        if dep > now or now - dep > 3600 then return nil end
        local _, plDep = timetable.assignSlot(st.times, dep)
        if not plDep then return nil end
        local visits = diagramTrains.legVisits(ld.runs, stations, f, plDep)
        if not visits then return nil end
        local pts = {}
        for vi, v in ipairs(visits) do
            local vs = stations[v.flatIdx]
            local y = yMap[vs.uniqueKey]
            if not y then
                -- waypoints off the axis are skipped like in the planned lines; stations break the leg
                if vs.stopType == "station" then return nil end
            elseif vi == 1 then
                pts[#pts + 1] = { t = v.dep, y = y }
            elseif v.arr then
                pts[#pts + 1] = { t = v.arr, y = y }
                if vi < #visits and v.dep then pts[#pts + 1] = { t = v.dep, y = y } end
            end
        end
        local lastV = visits[#visits]
        if #pts < 2 or not lastV.arr or pts[#pts].t ~= lastV.arr then return nil end
        if not keepSeg(pts[1].y, pts[#pts].y) then return nil end
        local y, delay = diagramTrains.trainOnLeg(pts, now, dep - plDep)
        return { y = y, delay = delay }
    end
    return nil
end

-- Live vehicle overlay: a "now" line and, for every vehicle of the displayed lines, a square at
-- (now, position) plus a whisker back to where the timetable has it now (length = delay),
-- colored like the punctuality dots. Rebuilt every game second; drawn on top of the chart.
local function drawLiveOverlay()
    clearLiveViews()
    local ctx = menu.liveCtx
    if not (ctx and menu.renderLayout and timetable.getShowVehicles()) then return end
    local now = timetableHelper.getTime()
    local nowM = (now % 3600) / 60
    local tol = timetable.getPunctThreshold()

    local byClass = { ontime = {}, early = {}, late = {} }
    local any = false
    for _, ld in pairs(displayedLines) do
        if ld.checked and ld.runs then
            for _, vehicle in pairs(timetableHelper.getVehiclesOnLine(ld.id)) do
                local okL, m = pcall(locateVehicle, ld, vehicle, now, ctx.yMap, ctx.keepSeg)
                if okL and m and m.y >= 0 and m.y <= ctx.dh then
                    local cls = (m.delay > tol and "late") or (m.delay < -tol and "early") or "ontime"
                    table.insert(byClass[cls], m)
                    any = true
                end
            end
        end
    end

    local function makeView(r, g, b, a, width)
        local v = api.gui.comp.LineRenderView.new()
        v:setMinimumSize(api.gui.util.Size.new(ctx.lw, ctx.lh))
        v:setMaximumSize(api.gui.util.Size.new(ctx.lw, ctx.lh))
        menu.renderLayout:addItem(v, 0.5, 0)
        table.insert(menu.liveViews, v)
        v:setColor(api.type.Vec4f.new(r, g, b, a))
        v:setWidth(width)
        return v
    end

    local nowVisible = nowM >= ctx.tWin0 and nowM <= ctx.tWin1
    if nowVisible then
        local x = ctx.timeX(nowM)
        makeView(1, 1, 1, 0.35, 1):addLine(api.type.Vec2f.new(x, 0), api.type.Vec2f.new(x, ctx.dh))
    end
    if not any then return end

    -- same colors as the punctuality dots of the line list
    local COLORS = { ontime = {1, 1, 1}, early = {0, 1, 0}, late = {1, 0, 0} }
    local half = 4 * ctx.scale
    for cls, markers in pairs(byClass) do
        if #markers > 0 then
            local c = COLORS[cls]
            local wv = makeView(c[1], c[2], c[3], 0.9, 2)
            for _, m in ipairs(markers) do
                if math.abs(m.delay) >= 1 then
                    local t1, t2 = math.min(now, now - m.delay), math.max(now, now - m.delay)
                    ctx.drawWrapped(wv, t1, m.y, t2, m.y)
                end
            end
            if nowVisible then
                -- a filled square: one short, wide stroke
                local sv = makeView(c[1], c[2], c[3], 1, 2 * half)
                local x = ctx.timeX(nowM)
                for _, m in ipairs(markers) do
                    sv:addLine(api.type.Vec2f.new(x - half, m.y), api.type.Vec2f.new(x + half, m.y))
                end
            end
        end
    end
end

-- 清除运行图渲染区（折线视图 + 站名标签 + 时间标签），全部 pcall 保护。
local function clearDiagramViews()
    if menu.renderLayout then
        for _, v in pairs(menu.lineRenderViews) do
            pcall(function() menu.renderLayout:removeItem(v) end)
        end
    end
    menu.lineRenderViews = {}
    clearLiveViews()
    menu.liveCtx = nil
    if menu.stationLabels and menu.stationLabels.layout then
        for _, oldCont in ipairs(menu.stationLabelViews) do
            pcall(function() menu.stationLabels.layout:removeItem(oldCont) end)
        end
    end
    menu.stationLabelViews = {}
    -- 时间标签条可能是顶部/底部两条（上下同时显示时都画）；各自清理
    for _, bar in ipairs({ menu.timeBarTop, menu.timeBarBottom }) do
        if bar and bar.layout then
            for _, oldCont in ipairs(bar.views or {}) do
                pcall(function() bar.layout:removeItem(oldCont) end)
            end
            bar.views = {}
        end
    end
    menu.timeLabelViews = {}
end

local function refreshDiagram()
    dbgPrint("refreshDiagram start")
    if not menu.renderLayout then dbgPrint("refreshDiagram: no renderLayout"); return end
    local selList = getSelectedStationList()
    if #selList == 0 then
        -- 勾选车站少于1个：不绘制，并清除残留的上一次运行图（含上一预设的折线/标签），
        -- 避免展开空预设后仍显示过期图形造成误导。
        clearDiagramViews()
        dbgPrint("refreshDiagram: no stations selected, cleared")
        return
    end

    -- LineRenderView 组件逻辑尺寸（会被引擎按 UI 缩放因子放大显示），
    -- 但 addLine 用的是组件实际渲染像素坐标（受缩放影响），故绘制坐标需乘缩放因子：
    -- 实际像素 = 逻辑像素 × scale，scale = renderArea实际尺寸 / 逻辑尺寸。
    local lw_logical = WINDOW_WIDTH - STATION_PANEL_WIDTH - STATION_LABEL_WIDTH
    -- 逻辑高随"时间标签位置"联动：上下同显时图表让出两条标签（menu.chartH 由 applyTimeLabelPosition 维护）
    local lh_logical = menu.chartH or (WINDOW_HEIGHT - TITLE_BAR_H - TIME_LABEL_HEIGHT)
    local dw = lw_logical
    local dh = lh_logical
    local scale = 1
    pcall(function()
        local rr = menu.renderArea and menu.renderArea:getContentRect()
        if rr and rr.w > 0 and rr.h > 0 then
            scale = rr.w / lw_logical
            dw = rr.w
            dh = rr.h
            -- renderArea 可能因布局偏移超出窗口右缘/下缘被裁（右侧实测超 14px）。
            -- 计算"窗口可见右边界 - renderArea 左缘"把 dw 收缩到窗口内，保证边框/
            -- 折线/网格最右端都画在可见区域内、右下角四线对齐。
            -- 时间标签切到"上"时 renderArea 下移，底部也可能超出窗口下缘（下边框消失），
            -- 用同样的方法把 dh 收缩进窗口，并额外留底部安全边距（整体上移）。
            local winRect = menu.window and menu.window:getContentRect()
            if winRect and winRect.w > 0 and winRect.x + winRect.w > rr.x then
                local visW = (winRect.x + winRect.w) - rr.x - 2
                if visW > 0 and visW < dw then dw = visW end
            end
            local visH = nil
            if winRect and winRect.h > 0 and winRect.y + winRect.h > rr.y then
                visH = (winRect.y + winRect.h) - rr.y - 2
                if visH > 0 and visH < dh then dh = visH end
            end
            -- 时间标签在上方时，renderArea 下移、底部可能被窗口裁掉（下边框消失）。
            -- 兜底：dh 再收缩一个底部安全边距（整体上移），让下边框远离组件底缘。
            -- 时间标签在下方时保持 dh = rr.h 原样（底边框贴合组件底缘是正常状态）。
            if timetable.getTimeLabelPos() == "top" then
                local bottomPad = 16
                if dh > rr.h - bottomPad then dh = rr.h - bottomPad end
            end
        end
    end)
    local sorts, groups = computeSortRanks(selList)
    local totalRanks = #sorts
    clampZoom(totalRanks)
    -- 缩放窗口参数（未激活时 = 完整视图，与旧公式一致）
    local tWin0 = zoomState.active and zoomState.tStart or 0
    local tWin1 = zoomState.active and (zoomState.tStart + zoomState.tLen) or 60
    local rWin0 = zoomState.active and zoomState.rStart or 1
    local rWinLen = zoomState.active and zoomState.rLen or totalRanks
    local function timeX(m)  -- m = 分钟
        return (m - tWin0) / (tWin1 - tWin0) * dw
    end
    local yMap, rowYs = buildYMap(selList, groups, sorts, rWin0, rWinLen, dh)

    for _, v in pairs(menu.lineRenderViews) do
        if menu.renderLayout then pcall(function() menu.renderLayout:removeItem(v) end) end
    end
    menu.lineRenderViews = {}

    local function makeLRV()
        local v = api.gui.comp.LineRenderView.new()
        v:setMinimumSize(api.gui.util.Size.new(lw_logical, lh_logical))
        v:setMaximumSize(api.gui.util.Size.new(lw_logical, lh_logical))
        menu.renderLayout:addItem(v, 0.5, 0)
        table.insert(menu.lineRenderViews, v)
        return v
    end

    -- 边框视图 bv 最后创建（叠在最上层），否则折线的十字标记会把边框线盖住。
    -- 创建顺序：rv(网格,最底) → 折线(中层) → bv(边框,最顶)。
    local rv = makeLRV()
    rv:setColor(api.type.Vec4f.new(0.5, 0.5, 0.5, 0.3))
    rv:setWidth(1)
    -- 竖向时间参考线间隔 = 时间刻度设置（2/5/10 分钟，默认5）；窗口边界（0/60 或 tWin0/tWin1）由边框线覆盖。
    local gridStep = timetable.getTimeScale()
    if gridStep ~= 2 and gridStep ~= 10 then gridStep = 5 end
    for m = math.ceil(tWin0 / gridStep) * gridStep, math.floor(tWin1 / gridStep) * gridStep, gridStep do
        if m > tWin0 and m < tWin1 then
            local x = timeX(m)
            rv:addLine(api.type.Vec2f.new(x, 0), api.type.Vec2f.new(x, dh))
        end
    end
    for i = rWin0, rWin0 + rWinLen - 1 do
        local y = rowYs[i]
        rv:addLine(api.type.Vec2f.new(0, y), api.type.Vec2f.new(dw, y))
    end

    if menu.stationLabels and menu.stationLabels.layout then
        local sll = menu.stationLabels.layout
        for _, oldCont in ipairs(menu.stationLabelViews) do
            pcall(function() sll:removeItem(oldCont) end)
        end
        menu.stationLabelViews = {}
        local labelH = 18
        -- 顶部留白：最上面的车站 y=0，rectY 若 clamp 到 0 会贴住组件顶部、
        -- 文字上半部分被标题栏/组件边界遮挡。整体下移留白让所有标签可见。
        local topPad = labelH / 2
        for idx = rWin0 + rWinLen - 1, rWin0, -1 do
            local sv = sorts[idx]
            local groupStations = groups[sv]
            -- 该行的标签文本（用户定稿 2026-08-16）：有站 → 只显示站名；无站（纯路径点行）
            -- → 显示路径点名（1~2 个全显示分多行、≥3 只显示第 1 个——稳定不随机）。
            -- 路径点名去掉列表界面用的 "▶ " 前缀。
            local rows = {}
            if groupStations then
                local stName = nil
                local wpNames = {}
                for _, s in pairs(groupStations) do
                    if s.stopType == "station" and not stName then
                        stName = s.name
                    elseif s.stopType == "waypoint" and s.name then
                        wpNames[#wpNames + 1] = (s.name:gsub("^▶%s*", ""))
                    end
                end
                if stName then
                    rows = { stName }
                elseif #wpNames > 0 then
                    -- 纯路径点行：只显示第 1 个路径点（用户 2026-08-16：两行标签在等距行距下
                    -- 显示困难，改"只显示第一个"，稳定不随机）
                    rows = { wpNames[1] }
                end
            end
            if #rows > 0 then
                local nameTag = nextLabelName()
                local ok2, result = pcall(function()
                    local y = rowYs[idx]
                    local contH = #rows * labelH
                    local cont = api.gui.comp.Component.new("stCont_" .. sv .. "_" .. nameTag)
                    cont:setMinimumSize(api.gui.util.Size.new(STATION_LABEL_WIDTH, contH))
                    cont:setMaximumSize(api.gui.util.Size.new(STATION_LABEL_WIDTH, contH))
                    cont:setLayout(api.gui.layout.BoxLayout.new("VERTICAL"))
                    for _, txt in ipairs(rows) do
                        local label = api.gui.comp.TextView.new(txt)
                        label:setStyleClassList({"timetable-mono-sc"})
                        label:setGravity(1, 0.5)
                        label:setMinimumSize(api.gui.util.Size.new(STATION_LABEL_WIDTH, labelH))
                        label:setMaximumSize(api.gui.util.Size.new(STATION_LABEL_WIDTH, labelH))
                        cont:getLayout():addItem(label)
                    end
                    local rectY = math.max(topPad, math.min(dh - contH - topPad, math.floor(y - contH / 2 + topPad)))
                    local rect = api.gui.util.Rect.new(0, rectY, STATION_LABEL_WIDTH, contH)
                    sll:addItem(cont, rect)
                    table.insert(menu.stationLabelViews, cont)
                end)
                if not ok2 then debugPrint("stationLabel add failed: " .. tostring(result)) end
            end
        end
        dbgPrint("stationLabels: " .. #menu.stationLabelViews .. " items, sorts=" .. #sorts)
    end

    -- 时间标签条刷新（顶部/底部条通用；isTop 决定文字垂直居中还是贴底）
    local function updateTimeBar(bar, isTop)
        if not bar or not bar.layout or not bar.component then return end
        pcall(function()
            bar.component:invokeLater(function()
                pcall(function()
                    local tll = bar.layout
                    if not tll then return end
                    for _, oldCont in ipairs(bar.views or {}) do
                        pcall(function() tll:removeItem(oldCont) end)
                    end
                    bar.views = {}
                    local raRect = menu.renderArea and menu.renderArea:getContentRect()
                    local tlcRect = bar.component:getContentRect()
                    local labelW = 44
                    if raRect and raRect.w > 0 and tlcRect and tlcRect.w > 0 then
                        local offsetX = raRect.x - tlcRect.x
                        local offsetY = (raRect.y + raRect.h) - tlcRect.y
                        -- 时间刻度设置决定标签步长：完整视图 2分→每4分（0,4,8…）、5分→每5分、10分→每10分；
                        -- 放大时用刻度步长（更密，与参考线一致）。
                        local gridStep = timetable.getTimeScale()
                        if gridStep ~= 2 and gridStep ~= 10 then gridStep = 5 end
                        local labelStep = zoomState.active and gridStep or ((gridStep == 2) and 4 or gridStep)
                        local mStart = zoomState.active and tWin0 or 0
                        local mEnd = zoomState.active and tWin1 or 59
                        for m = mStart, mEnd, labelStep do
                            local fx = (m - tWin0) / (tWin1 - tWin0)
                            local cx = offsetX + fx * dw
                            local label = api.gui.comp.TextView.new(string.format("%02d:00", m))
                            label:setStyleClassList({"timetable-mono-sc"})
                            -- 底部条：文字贴容器底部（gravity 1），从居中位置下移约半字，
                            -- 避免紧贴运行图底边框；顶部条保持垂直居中。
                            -- 注意：label 必须显式占满 TIME_LABEL_HEIGHT 高，gravity 才有效——
                            -- 否则 TextView 按文字高度自适应，gravity 形同虚设。
                            label:setMinimumSize(api.gui.util.Size.new(labelW, TIME_LABEL_HEIGHT))
                            label:setMaximumSize(api.gui.util.Size.new(labelW, TIME_LABEL_HEIGHT))
                            if isTop then
                                label:setGravity(0.5, 0.5)
                            else
                                label:setGravity(0.5, 1)
                            end
                            local nameTag = nextLabelName()
                            local cont = api.gui.comp.Component.new("tmCont_" .. m .. "_" .. nameTag)
                            cont:setMinimumSize(api.gui.util.Size.new(labelW, TIME_LABEL_HEIGHT))
                            cont:setMaximumSize(api.gui.util.Size.new(labelW, TIME_LABEL_HEIGHT))
                            cont:setLayout(api.gui.layout.BoxLayout.new("VERTICAL"))
                            cont:getLayout():addItem(label)
                            local rectX = math.max(0, math.min(tlcRect.w - labelW, math.floor(cx - labelW / 2)))
                            local rectY = math.max(0, math.min(tlcRect.h - TIME_LABEL_HEIGHT, math.floor(offsetY + 14)))
                            local rect = api.gui.util.Rect.new(rectX, rectY, labelW, TIME_LABEL_HEIGHT)
                            tll:addItem(cont, rect)
                            bar.views[#bar.views + 1] = cont
                        end
                    else
                        debugPrint("timeLabels: raRect or tlcRect invalid")
                    end
                    dbgPrint("timeLabels(" .. (isTop and "top" or "bottom") .. "): " .. #bar.views .. " items")
                end)
            end)
        end)
    end
    -- 按当前时间标签位置刷新对应时间条：both = 顶部+底部都画；单条模式只画所在侧
    local tlp = timetable.getTimeLabelPos()
    if tlp ~= "top" and tlp ~= "both" then tlp = "bottom" end
    if tlp == "top" or tlp == "both" then updateTimeBar(menu.timeBarTop, true) end
    if tlp == "bottom" or tlp == "both" then updateTimeBar(menu.timeBarBottom, false) end

    local drawDebug = {}
    -- Platform labels, collected while drawing: {t = absolute seconds, y = px, text}
    local showPlatforms = timetable.getShowPlatforms()
    local platformLabels = {}
    -- 折线单段绘制（放大窗口感知）：先按小时切段，再对每段做窗口裁剪。
    -- 裁剪用 Liang-Barsky（timetableHelper.clipSegmentToRect），窗口 = 可视时间范围 × 画布高
    -- （车站方向天然被窗口限制——窗口外站无 Y 值、折线已断，y 裁剪只是防御）。
    local function drawClippedSegment(lv, m1, y1, m2, y2)
        local c1, cy1, c2, cy2 = timetableHelper.clipSegmentToRect(m1, y1, m2, y2, tWin0, tWin1, 0, dh)
        if c1 == nil then return end
        local x1 = (c1 - tWin0) / (tWin1 - tWin0) * dw
        local x2 = (c2 - tWin0) / (tWin1 - tWin0) * dw
        lv:addLine(api.type.Vec2f.new(x1, cy1), api.type.Vec2f.new(x2, cy2))
    end

    local function drawWrappedSegment(lv, t1, y1, t2, y2)
        local c1 = math.floor(t1 / 3600)
        local c2 = math.floor(t2 / 3600)
        if c1 == c2 then
            drawClippedSegment(lv, (t1 - c1 * 3600) / 60, y1, (t2 - c1 * 3600) / 60, y2)
        else
            local total = t2 - t1
            if total <= 0 then return end
            for c = c1, c2 do
                local s = math.max(t1, c * 3600)
                local e = math.min(t2, (c + 1) * 3600)
                if e > s then
                    local f1 = (s - t1) / total
                    local f2 = (e - t1) / total
                    local cy1 = y1 + f1 * (y2 - y1)
                    local cy2 = y1 + f2 * (y2 - y1)
                    drawClippedSegment(lv, (s - c * 3600) / 60, cy1, (e - c * 3600) / 60, cy2)
                end
            end
        end
    end

    -- Direction filter: only draw legs going up (y2 < y1) / down (y2 > y1); dwells (dy == 0) always
    local filterDir = timetable.getPolylineFilter()
    local function keepSeg(y1, y2)
        if filterDir == "up" then return y2 <= y1 end
        if filterDir == "down" then return y2 >= y1 end
        return true
    end

    if #displayedLines > 0 then
    for _ in pairs(displayedLines) do makeLRV() end

    for li, ld in pairs(displayedLines) do
        if not ld.checked then goto continueLine end
        table.insert(drawDebug, ld.name)
        -- 交路绘制模式：该线路若属于交路配置（TrainRoute mod 钩子），只画到换乘站（末站），不画折返/循环闭合段
        local isJRL = isRotationLine(ld.id)
        local lv = menu.lineRenderViews[li + 1]
        if lv then
            lv:setColor(ld.color)
            local lw = ld.bold and 2 or 1
            lv:setWidth(lw)
            -- The width is a property of the whole view (the last setWidth wins), so the stop
            -- markers, drawn wider, go into a view of their own.
            local cv = makeLRV()
            cv:setColor(ld.color)
            cv:setWidth(lw + 1)
            -- 按行程推算逐车次跟踪：从首个有时刻的停靠站的每个槽位出发，按区间运行时间估算
            -- 到达下一站的时刻并选取最接近的槽位（而非按槽位序号配对）。
            -- 交路线：末站为换乘站，列车到站即换下一交路，不画本线发车，也不折返/循环闭合。
            -- The runs are kept for the live vehicle overlay.
            ld.runs = diagramTrains.buildRuns(ld.stations, ld.legTimes or {}, isJRL)
            for _, run in ipairs(ld.runs) do
                local polylines = {}
                local cur = {}
                for vi, visit in ipairs(run) do
                    local st = ld.stations[visit.flatIdx]
                    local y = yMap[st.uniqueKey]
                    if not y then
                        -- 该停站不在当前运行图纵轴上
                        -- 车站：跨线车次的异线车站 → 方案A断开折线
                        -- 路径点：仅"沿轨道经过"的路径控制点 → 静默跳过（不添加点也不断开）
                        if st.stopType == "station" and #cur > 0 then
                            polylines[#polylines + 1] = cur
                            cur = {}
                        end
                    elseif visit.arr then
                        if vi > 1 then
                            table.insert(cur, {uw = visit.arr, y = y})
                        end
                        if visit.dep then
                            table.insert(cur, {uw = visit.dep, y = y})
                            if showPlatforms and st.platform then
                                platformLabels[#platformLabels + 1] =
                                    { t = (visit.arr + visit.dep) / 2, y = y, text = st.platform }
                            end
                        end
                    end
                end
                if #cur > 0 then
                    polylines[#polylines + 1] = cur
                end

                for _, pl in ipairs(polylines) do
                    for i = 1, #pl - 1 do
                        if keepSeg(pl[i].y, pl[i + 1].y) then
                            drawWrappedSegment(lv, pl[i].uw, pl[i].y, pl[i + 1].uw, pl[i + 1].y)
                        end
                    end
                end
                for _, pl in ipairs(polylines) do
                    for __, p in pairs(pl) do
                        local pm = (p.uw % 3600) / 60
                        local ny = p.y
                        -- 时间窗口 + 车站窗口双重过滤：窗口外（含外推 Y 越界）的十字标记不画
                        if pm >= tWin0 and pm <= tWin1 and ny >= 0 and ny <= dh then
                            local nx = timeX(pm)
                            cv:addLine(api.type.Vec2f.new(nx - 2, ny), api.type.Vec2f.new(nx + 2, ny))
                            cv:addLine(api.type.Vec2f.new(nx, ny - 2), api.type.Vec2f.new(nx, ny + 2))
                        end
                    end
                end
            end
        end
        ::continueLine::
    end
    end  -- if #displayedLines > 0

    -- 边框视图最后创建（叠在折线之上），避免折线的十字标记把边框线盖住。
    -- addLine 用实际渲染像素坐标（dw/dh 已取 renderArea 实际尺寸并收缩到窗口内）
    local bv = makeLRV()
    bv:setColor(api.type.Vec4f.new(0.5, 0.5, 0.5, 0.3))
    bv:setWidth(3)
    bv:addLine(api.type.Vec2f.new(0, 0), api.type.Vec2f.new(dw, 0))
    bv:addLine(api.type.Vec2f.new(0, dh), api.type.Vec2f.new(dw, dh))
    bv:addLine(api.type.Vec2f.new(0, 0), api.type.Vec2f.new(0, dh))
    bv:addLine(api.type.Vec2f.new(dw, 0), api.type.Vec2f.new(dw, dh))

    -- Platform numbers above the dwell segments. Drawn as line strokes in a line view of its
    -- own (TextViews on top of the line views are not displayed); coordinates in rendered pixels.
    if #platformLabels > 0 then
        local pv = makeLRV()
        pv:setColor(api.type.Vec4f.new(0.85, 0.85, 0.85, 1))
        pv:setWidth(1)
        local gh = 10 * scale
        local seen = {}
        for _, pl in ipairs(platformLabels) do
            local m = (pl.t % 3600) / 60
            if m >= tWin0 and m <= tWin1 and pl.y >= 0 and pl.y <= dh then
                local tw = diagramLayout.textWidth(pl.text, gh)
                local x = math.max(0, math.min(dw - tw, timeX(m) - tw / 2))
                local y = pl.y - 3 * scale - gh
                if y < 0 then y = pl.y + 3 * scale end
                local key = math.floor(x) .. "_" .. math.floor(y) .. "_" .. pl.text
                if not seen[key] then
                    seen[key] = true
                    for _, sg in ipairs(diagramLayout.textSegments(pl.text, x, y, gh)) do
                        pv:addLine(api.type.Vec2f.new(sg[1], sg[2]), api.type.Vec2f.new(sg[3], sg[4]))
                    end
                end
            end
        end
    end

    menu.liveCtx = { yMap = yMap, dw = dw, dh = dh, lw = lw_logical, lh = lh_logical, scale = scale,
        tWin0 = tWin0, tWin1 = tWin1, timeX = timeX, drawWrapped = drawWrappedSegment, keepSeg = keepSeg }
    drawLiveOverlay()

    dbgPrint("draw names: " .. table.concat(drawDebug, ", "))
end

local function toggleLineSelection(idx)
    local ld = displayedLines[idx]
    if ld then
        ld.selected = not ld.selected; ld.bold = ld.selected
        if ld.nameView then
            pcall(function()
                ld.nameView:setText(ld.bold and ("[" .. ld.name .. "]") or ld.name, false)
            end)
        end
        pcall(function() refreshDiagram() end)
    end
end

-- setContent 会把内容视图复位到顶部，但可能保留旧的滚动条值，导致"内容在顶、滚动条在底"的错位
-- （setScrollOffset 传相同值不会触发重新同步）。这里先归零再设目标值，强制引擎重新同步；
-- 若初始捕获失败，布局完成后再补捕获。双重 invokeLater 等布局完成。
local function restoreScrollOffset(area, offset)
    if not area then return end
    area:invokeLater(function()
        area:invokeLater(function()
            pcall(function()
                local target = offset
                if not target then
                    local tmp = area:getScrollOffset()
                    if tmp then target = api.type.Vec2i.new(tmp.x, tmp.y) end
                end
                if target then
                    area:setScrollOffset(api.type.Vec2i.new(0, 0))
                    area:setScrollOffset(target)
                end
            end)
        end)
    end)
end

local function updateLineList()
    if not menu.lineScrollArea then return end
    local prevOffset = nil
    pcall(function()
        local tmp = menu.lineScrollArea:getScrollOffset()
        prevOffset = api.type.Vec2i.new(tmp.x, tmp.y)
    end)
    local nc = api.gui.comp.Component.new("lineList")
    local nl = api.gui.layout.BoxLayout.new("VERTICAL")
    nc:setLayout(nl)
    dbgPrint("updateLineList: " .. #displayedLines .. " lines")
    local lineCount = 0
    local totalHeight = 0
    local lineListDebug = {}
    for li, ld in pairs(displayedLines) do
        lineCount = lineCount + 1
        table.insert(lineListDebug, ld.name)
        -- 先统计该线路的准点车辆数，决定行高（准点文本并入线路行内，色块右侧垂直排列）
        local punctRowCount = 0
        local punctData0 = _G._punctuality
        if punctData0 then
            for _, pv in pairs(punctData0) do
                if pv and pv.lineId and tostring(pv.lineId) == tostring(ld.id) then
                    punctRowCount = punctRowCount + 1
                end
            end
        end
        local rowH = math.max(42, punctRowCount * 24)
        totalHeight = totalHeight + rowH
        local ic = api.gui.comp.Component.new("lineItem_" .. li)
        local il = api.gui.layout.BoxLayout.new("HORIZONTAL")
        ic:setLayout(il)
        -- 行宽最小 220（与左栏一致），最大放宽：线路名过长时行自然变宽，
        -- 靠 ScrollArea 横向滚动条把被顶出去的准点信息滚回来（见 showDiagram 中
        -- lineScrollArea 的 setHorizontalScrollBarPolicy）。
        ic:setMinimumSize(api.gui.util.Size.new(STATION_PANEL_WIDTH, rowH))
        ic:setMaximumSize(api.gui.util.Size.new(600, rowH))

        local ckImg = api.gui.comp.ImageView.new(ld.checked and "ui/checkbox1.tga" or "ui/checkbox0.tga")
        local ckBtn = api.gui.comp.Button.new(ckImg, true)
        ckBtn:onClick(function()
            ld.checked = not ld.checked
            pcall(function() ckImg:setImage(ld.checked and "ui/checkbox1.tga" or "ui/checkbox0.tga", false) end)
            pcall(function() refreshDiagram() end)
            -- 勾选/取消勾选线路后立即保存到当前预设（内部会触发 _diagramForceSync 同步），
            -- 避免直接退出游戏/关窗时勾选状态丢失（"保存不上"）。
            if currentPresetRef then
                local okSave, saveErr = pcall(function()
                    saveCurrentPreset()
                    savePresetsToTimetableObject()
                end)
                if not okSave then debugPrint("lineCheck SAVE ERROR: " .. tostring(saveErr)) end
            end
        end)
        il:addItem(ckBtn)

        local displayText = ld.bold and ("[" .. ld.name .. "]") or ld.name
        local nameTv = api.gui.comp.TextView.new(displayText)
        local lb = api.gui.comp.Button.new(nameTv, true)
        lb:setStyleClassList({"timetable-avtivateTimetableButton"})
        lb:onClick(function() toggleLineSelection(li) end)
        ld.nameView = nameTv
        il:addItem(lb)

        local dotCont = api.gui.comp.Component.new("dotCont")
        dotCont:setMinimumSize(api.gui.util.Size.new(14, 14))
        dotCont:setMaximumSize(api.gui.util.Size.new(14, 14))
        local dotLayout = api.gui.layout.FloatingLayout.new(0, 1)
        dotCont:setLayout(dotLayout)
        local dotLrv = api.gui.comp.LineRenderView.new()
        dotLrv:setMinimumSize(api.gui.util.Size.new(10, 10))
        dotLrv:setMaximumSize(api.gui.util.Size.new(10, 10))
        dotLrv:setColor(ld.color)
        dotLrv:setWidth(2)
        for y = 1, 9, 2 do
            dotLrv:addLine(api.type.Vec2f.new(1, y), api.type.Vec2f.new(9, y))
        end
        dotLayout:addItem(dotLrv, 0.5, 0.5)
        il:addItem(dotCont)

        -- 准点信息：圆点（●）与文字合并为一个 TextView（"●正点"），颜色同为准点样式色
        -- （正点白/早点绿/晚点红）。不设固定宽度：TextView 按实际渲染宽度自适应，
        -- pvCont 随之自适应——避免估宽不准导致文字被裁（"跑后面被遮住"）。
        -- 若整行（勾选框+线路名+色块+准点）超出 220，行自然变宽，由横向滚动条带回。
        local pvCont = api.gui.comp.Component.new("pvCont_" .. li)
        local pvl = api.gui.layout.BoxLayout.new("VERTICAL")
        pvCont:setLayout(pvl)
        pvCont:setMinimumSize(api.gui.util.Size.new(0, rowH))
        pvCont:setMaximumSize(api.gui.util.Size.new(600, rowH))
        if punctRowCount > 0 then
            local punctData = _G._punctuality
            for vId, pv in pairs(punctData) do
                if pv and pv.lineId and tostring(pv.lineId) == tostring(ld.id) then
                    local text = D.punct_ontime
                    local punctClass = "timetable-punct-ontime"
                    local diff = nil
                    -- 判定（中国铁路逻辑，两段式）：
                    --   [发车前] 以"停车到站"事件判定到达：早到/正点/晚点都显示，直到发车；
                    --   [发车后] 以"发车"事件修正为准：晚发→晚点，正点发→正点，早发→早点。
                    -- 晚点到站但正点发车 = 追回晚点，发车后应显示"正点"（不能按到达晚点掩盖）。
                    if pv.arrDone then
                        if pv.depPunct == "late" then
                            diff = pv.depDiff
                        elseif pv.depPunct == "early" then
                            diff = pv.depDiff
                        end
                    else
                        if pv.arrPunct == "early" then
                            diff = pv.arrDiff  -- 负值（早到）
                        elseif pv.arrPunct == "late" then
                            diff = pv.arrDiff  -- 正值（晚到）
                        end
                    end
                    if diff then
                        local secs = math.abs(math.floor(diff))
                        local mm = math.floor(secs / 60)
                        local ss = secs % 60
                        local tmStr = string.format("%02d:%02d", mm, ss)
                        if diff > 0 then
                            text = string.format(D.punct_late, tmStr)
                            punctClass = "timetable-punct-late"
                        else
                            text = string.format(D.punct_early, tmStr)
                            punctClass = "timetable-punct-early"
                        end
                    end
                    -- 圆点（●）与准点文本合并为"●正点"一体；颜色由样式类决定
                    local ptv = api.gui.comp.TextView.new("●" .. text)
                    ptv:setStyleClassList({"timetable-mono-sc", punctClass})
                    ptv:setMinimumSize(api.gui.util.Size.new(0, 24))
                    ptv:setMaximumSize(api.gui.util.Size.new(600, 24))
                    ptv:setGravity(0, 0.5)
                    pvl:addItem(ptv)
                end
            end
            il:addItem(pvCont)
        end
        nl:addItem(ic)
    end
    dbgPrint("lineList names: " .. table.concat(lineListDebug, ", "))
    nc:setMinimumSize(api.gui.util.Size.new(STATION_PANEL_WIDTH, totalHeight))
    menu.lineScrollArea:setContent(nc)
    menu.lineListLayout = nl; menu.lineListComponent = nc
    -- 恢复刷新前的滚动位置，避免车次列表回到最上面（影响用户继续改动）
    restoreScrollOffset(menu.lineScrollArea, prevOffset)
end

local function applyPresetToStations(preset)
    if not preset or not preset.stationData then return end
    for _, st in pairs(allStations) do
        local key = stableKey(st.stopType, st.id, st.uniqueKey, st.entityId)
        local d = preset.stationData[key]
        if d then st.selected = d.selected or false; st.sort = (type(d.sort) == "number" and d.sort > 0 and d.sort <= 255) and d.sort or 256
        else st.selected = false; st.sort = 1 end
    end
    -- 线路勾选先整体重置为勾选，再按 preset.lineData 覆盖：
    -- 车站勾选是显式赋值（else st.selected = false），而线路之前只覆盖 lineData 里存在的线路，
    -- 未被覆盖的线路会继承上一预设的勾选状态（残留为全勾选），导致"切换预设回来又全部勾选"。
    -- 重置后再覆盖使线路状态与车站一样确定化。
    for _, ld in pairs(allLines) do ld.checked = true end
    if preset.lineData then
        for _, ld in pairs(allLines) do
            local chk = preset.lineData[tostring(ld.id)]
            if chk ~= nil then ld.checked = chk end
        end
    end
end

saveCurrentPreset = function()
    -- 只允许保存当前展开的预设；不落入 getActivePreset() 回退，
    -- 避免在 allStations 为未加载默认状态时把空配置写回（数据丢失）。
    local p = currentPresetRef
    if not p then dbgPrint("saveCurrentPreset: no current preset, skip"); return end
    local sd = {}
    local asCount = 0
    local selCount = 0
    for _, st in pairs(allStations) do
        asCount = asCount + 1
        local key = stableKey(st.stopType, st.id, st.uniqueKey, st.entityId)
        sd[key] = {selected = st.selected or false, sort = (type(st.sort) == "number" and st.sort > 0 and st.sort <= 255) and st.sort or 256}
        if st.selected then selCount = selCount + 1 end
    end
    dbgPrint("saveCurrentPreset: allStations=" .. asCount .. " selected=" .. selCount .. " sd type=" .. type(sd))
    p.stationData = sd

    local ld = {}
    local ldCount = 0
    -- 线路勾选状态从 allLines 保存（而非 displayedLines）：
    -- displayedLines 只是"当前选中车站相关的线路"子集，且首次打开/未绘制时为空，
    -- 用它会误把已保存的 lineData 清空（即"勾选状态保存不上"）。
    -- allLines 是完整线路集合，与 applyPresetToStations 的应用侧（同样遍历 allLines）一致。
    for _, line in pairs(allLines) do
        if line.id then
            ldCount = ldCount + 1
            ld[tostring(line.id)] = line.checked
        end
    end
    p.lineData = ld
    dbgPrint("saveCurrentPreset: lineData entries=" .. ldCount)
end

local function saveAllLineColors()
    for _, ld in pairs(allLines) do
        if ld.color then saveLineColor(ld.id, ld.color) end
    end
end

local function updateStationVisibility()
    local filterActive = (#stationFilterText > 0)
    for presetId, rows in pairs(stationRowGroups) do
        local visible = (presetId == expandedPresetId)
        for _, rd in pairs(rows) do
            local show = visible
            if visible and filterActive then
                show = string.find(string.lower(rd.st.name), string.lower(stationFilterText), 1, true) ~= nil
            end
            pcall(function() rd.comp:setVisible(show, false) end)
            if show then
                pcall(function() rd.ck:setImage(rd.st.selected and "ui/checkbox1.tga" or "ui/checkbox0.tga", false) end)
                pcall(function() rd.sp:setValue(rd.st.sort, false) end)
            end
        end
    end
end

rebuildPresetList = function()
    if not menu.presetScrollArea then return end
    local prevOffset = nil
    pcall(function()
        local tmp = menu.presetScrollArea:getScrollOffset()
        prevOffset = api.type.Vec2i.new(tmp.x, tmp.y)
    end)
    local nc = api.gui.comp.Component.new("presetList")
    local nl = api.gui.layout.BoxLayout.new("VERTICAL")
    nc:setLayout(nl)
    stationRowGroups = {}
    dbgPrint("rebuildPresetList: " .. #localPresets .. " presets, expanded=" .. tostring(expandedPresetId) .. " allStations=" .. #allStations)

    if #localPresets == 0 then
        local lbl = api.gui.comp.TextView.new(D.no_presets)
        lbl:setStyleClassList({"timetable-mono-sc"})
        nl:addItem(lbl)
        menu.presetScrollArea:setContent(nc)
        restoreScrollOffset(menu.presetScrollArea, prevOffset)
        return
    end

    for __, ps in ipairs(localPresets) do
        local isExpanded = (expandedPresetId == ps.id)

        local row = api.gui.comp.Component.new("pr_" .. ps.id)
        local rl = api.gui.layout.BoxLayout.new("HORIZONTAL")
        row:setLayout(rl)
        if ps.id == pendingScrollPresetId then pendingScrollPresetRow = row end

        local tglIcon = api.gui.comp.TextView.new(isExpanded and "▽" or "▶")
        local tgl = api.gui.comp.Button.new(tglIcon, true)
        tgl:onClick(function()
            if expandedPresetId == ps.id then
                expandedPresetId = nil
                currentPresetRef = nil
                if menu.presetScrollArea then
                    menu.presetScrollArea:invokeLater(function() pcall(function() rebuildPresetList() end) end)
                end
            else
                expandedPresetId = ps.id
                currentPresetRef = ps
                setActivePresetId(ps.id)
                applyPresetToStations(ps)
                sortAllStations()
                -- 展开预设即展开车次列表并立即绘制该预设的运行图。
                -- 勾选车站少于1个时 refreshDiagram 内部会清除旧图而不绘制（新增配置先勾选再点刷新）。
                displayedLines = getRelevantLines(getSelectedStationList())
                updateLineList()
                if menu.renderLayout and menu.stationLabels and menu.timeBarTop then
                    pcall(function() refreshDiagram() end)
                end
                if menu.presetScrollArea then
                    menu.presetScrollArea:invokeLater(function() pcall(function() rebuildPresetList() end) end)
                end
            end
            pcall(function() tglIcon:setText(expandedPresetId == ps.id and "▽" or "▶") end)
        end)

        local inp = nil
        local okTI, tiField = pcall(function() return api.gui.comp.TextInputField.new("") end)
        if okTI and tiField then
            inp = tiField
            tiField:setText(ps.name, false)
            tiField:onChange(function(text)
                if text and #text > 0 then
                    ps.name = text
                end
            end)
        end
        if not inp then
            local nameLabel = api.gui.comp.TextView.new(ps.name)
            nameLabel:setStyleClassList({"timetable-mono-sc"})
            rl:addItem(tgl); rl:addItem(nameLabel)
        else
            rl:addItem(tgl); rl:addItem(inp)
        end
        local delBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new("X"), true)
        delBtn:onClick(function()
            local targetId = ps.id
            local targetName = ps.name
            local cc2 = api.gui.comp.Component.new("confirmContent")
            local cl2 = api.gui.layout.BoxLayout.new("VERTICAL")
            cc2:setLayout(cl2)
            cl2:addItem(api.gui.comp.TextView.new(string.format(D.confirm_delete, targetName)))
            local blc2 = api.gui.comp.Component.new("confirmBtns")
            local bll2 = api.gui.layout.BoxLayout.new("HORIZONTAL")
            blc2:setLayout(bll2)
            local okW, cw2 = pcall(function() return api.gui.comp.Window.new(D.warning, cc2) end)
            if not okW or not cw2 then return end
            cw2:addHideOnCloseHandler()
            cw2:setMovable(true)
            cw2:setSize(api.gui.util.Size.new(350, 120))
            cw2:setPosition(400, 300)
            local ok2 = api.gui.comp.Button.new(api.gui.comp.TextView.new(D.confirm), true)
            ok2:onClick(function()
                -- 删除确认回调整体包 pcall：玩家反馈删除铁路线配置时偶发 Lua exception 崩溃
                -- （如 attempt to index nil）。pcall 捕获后可记录具体错误、阻止崩溃传播。
                local okDel, delErr = pcall(function()
                    pcall(function() cw2:setVisible(false, false) end)
                    for i, p in ipairs(localPresets) do if p.id == targetId then table.remove(localPresets, i); break end end
                    if expandedPresetId == targetId then
                        expandedPresetId = nil
                        currentPresetRef = nil
                        -- 删除正在展开的预设：清空车次列表与运行图，避免残留已删除预设的图形
                        displayedLines = {}
                        updateLineList()
                        clearDiagramViews()
                    end
                    if #localPresets == 0 then setActivePresetId(""); currentPresetRef = nil end
                    savePresetsToTimetableObject()
                    rebuildPresetList()
                end)
                if not okDel then debugPrint("deletePreset ERROR: " .. tostring(delErr)) end
            end)
            local cancel2 = api.gui.comp.Button.new(api.gui.comp.TextView.new(D.cancel), true)
            cancel2:onClick(function() pcall(function() cw2:setVisible(false, false) end) end)
            bll2:addItem(ok2); bll2:addItem(cancel2); cl2:addItem(blc2)
        end)
        rl:addItem(delBtn)
        nl:addItem(row)

        local rows = {}
        if isExpanded then
            for __, st in pairs(allStations) do
                local sr = api.gui.comp.Component.new("sr_" .. st.uniqueKey)
                local sl = api.gui.layout.BoxLayout.new("HORIZONTAL")
                sr:setLayout(sl)

                local ck = api.gui.comp.ImageView.new(st.selected and "ui/checkbox1.tga" or "ui/checkbox0.tga")
                local cb = api.gui.comp.Button.new(ck, true)
                cb:onClick(function()
                    st.selected = not st.selected
                    ck:setImage(st.selected and "ui/checkbox1.tga" or "ui/checkbox0.tga", false)
                    -- 勾选/取消勾选车站后立即保存当前铁路线配置，不再依赖保存按钮
                    if currentPresetRef then
                        local okSave, saveErr = pcall(function()
                            saveCurrentPreset()
                            savePresetsToTimetableObject()
                        end)
                        if not okSave then debugPrint("stationCheck SAVE ERROR: " .. tostring(saveErr)) end
                    end
                end)

                local lb = api.gui.comp.TextView.new(st.name)
                lb:setStyleClassList({"timetable-mono-sc"})
                -- Gravity -1 = left (0 centres the text, see the timetable window's buttons)
                lb:setGravity(-1, 0.5)

                local sp = api.gui.comp.DoubleSpinBox.new()
                pcall(function() sp:setTooltip(D.sort) end)
                -- Fixed width, otherwise the dial stretches to fill the row.
                sp:setMinimumSize(api.gui.util.Size.new(40, 0))
                sp:setMaximumSize(api.gui.util.Size.new(40, 100))
                sp:setMinimum(1, false)
                sp:setMaximum(256, false)
                local sv = (type(st.sort) == "number" and st.sort >= 1 and st.sort <= 256) and st.sort or 256
                pcall(function() sp:setValue(sv, false) end)
                sp:onChange(function(v)
                    st.sort = math.floor(v + 0.5)
                    -- 排序序号改动后立即保存（注意：onChange 逐位触发，这里只写数据不重建 UI，
                    -- 否则会打断输入框焦点/值，见 AGENTS.md 时刻表 SpinBox 丢值经验）
                    if currentPresetRef then
                        local okSave, saveErr = pcall(function()
                            saveCurrentPreset()
                            savePresetsToTimetableObject()
                        end)
                        if not okSave then debugPrint("sortChange SAVE ERROR: " .. tostring(saveErr)) end
                    end
                end)

                -- Sort dial before the name: a vertical scroll bar then only covers the end of
                -- long names, not the dial, and the dials line up.
                sl:addItem(cb); sl:addItem(sp); sl:addItem(lb)
                nl:addItem(sr)
                table.insert(rows, {comp = sr, ck = ck, sp = sp, st = st})
            end
        end
        stationRowGroups[ps.id] = rows
    end

    menu.presetScrollArea:setContent(nc)
    -- 恢复刷新/重建前的滚动位置，避免铁路线列表回到最上面
    restoreScrollOffset(menu.presetScrollArea, prevOffset)
end

local function addNewPreset()
    local id = tostring(#localPresets + 1)
    local ps = {id = id, name = D.preset .. (#localPresets + 1), stationData = {}, lineData = nil}
    table.insert(localPresets, ps)
    setActivePresetId(id)
    currentPresetRef = ps
    expandedPresetId = id
    applyPresetToStations(ps)
    -- 新预设默认全部线路勾选：显式重置 allLines.checked（否则会继承上一预设经 allLines
    -- 传递的勾选状态，导致"只默认勾选第一个"）。
    for _, ld in pairs(allLines) do ld.checked = true end
    -- 新预设无勾选车站：清空车次列表与运行图（不绘制），等待玩家勾选车站后点刷新绘制
    displayedLines = {}
    updateLineList()
    clearDiagramViews()
    pendingScrollPresetId = id
    pendingScrollPresetRow = nil
    rebuildPresetList()
    pendingScrollPresetId = nil
    -- 滚动预设列表，让新增加的预设表头露出：用 ensureVisible 做最小滚动，
    -- 保留上方已有配置（如配置11）仍在视口内，同时能看到新增的配置12。
    -- 不能滚到顶部也不能滚到底部（新预设已展开，底部只有它的最后一个车站行）。
    local psa = menu.presetScrollArea
    local targetRow = pendingScrollPresetRow
    if psa and targetRow then
        psa:invokeLater(function()
            psa:invokeLater(function()
                pcall(function() psa:ensureVisible(targetRow) end)
            end)
        end)
    end
end

local function persistConfig()
    -- onClose 兜底保存：整体包 pcall，避免删除预设后关窗时 Lua 错误传播导致崩溃
    local ok, err = pcall(function()
        if currentPresetRef then saveCurrentPreset() end
        savePresetsToTimetableObject()
        saveAllLineColors()
        local pc = #localPresets
        local ac = 0
        if currentPresetRef and currentPresetRef.stationData then
            for _ in pairs(currentPresetRef.stationData) do ac = ac + 1 end
        end
        debugPrint("persistConfig: " .. pc .. " presets, current has " .. ac .. " station data entries")
    end)
    if not ok then debugPrint("persistConfig ERROR: " .. tostring(err)) end
end

-- Identifies the station/waypoint list (keys and names, order-independent), so that a
-- refresh can tell whether the list in the station panel needs to be rebuilt.
local function stationListSignature(list)
    local keys = {}
    for _, st in pairs(list) do
        keys[#keys + 1] = stableKey(st.stopType, st.id, st.uniqueKey, st.entityId) .. "=" .. tostring(st.name)
    end
    table.sort(keys)
    return table.concat(keys, "|")
end

---@param keepStationList boolean|nil auto refresh: keep the station panel (and its scroll
---  position and filter) as it is unless the set of stations/waypoints changed
local function doRefreshData(keepStationList)
    -- 记录刷新前线路勾选状态：getAllTimetableData 会重建 allLines（默认全勾选），
    -- 刷新后恢复，保证"刚才勾选/取消勾选的线路"在刷新后不消失。
    local prevChecks = {}
    for _, ld in pairs(allLines) do
        if ld.id then prevChecks[tostring(ld.id)] = ld.checked end
    end
    local to = timetable.getTimetableObject()
    local host = getHostLineKey(to)
    if host and to[host].dp and to[host].dp.colorList then
        local cfg = getConfig()
        if not cfg.lineColors then cfg.lineColors = {} end
        for _, entry in pairs(to[host].dp.colorList) do
            cfg.lineColors[entry.i] = {entry.r, entry.g, entry.b, entry.a}
        end
    end
    local lineDataList = getAllTimetableData()
    local newStations = getAllStationsFlat(lineDataList)
    -- The rows of the station panel hold references to the allStations entries, so the old
    -- entries are kept when the panel is not rebuilt.
    local rebuildList = not keepStationList
        or stationListSignature(newStations) ~= stationListSignature(allStations)
    if rebuildList then
        stationFilterText = ""
        allStations = newStations
    end
    allLines = lineDataList
    displayedLines = {}
    for _, ld in pairs(lineDataList) do
        local sc = getLineColor(ld.id)
        if sc then ld.color = sc end
    end
    if currentPresetRef then applyPresetToStations(currentPresetRef) end
    -- 恢复刷新前内存中的勾选状态（与即时保存一致；未展开预设时的改动刷新后也能保留）
    for _, ld in pairs(allLines) do
        local pc = prevChecks[tostring(ld.id)]
        if pc ~= nil then ld.checked = pc end
    end
    sortAllStations()
    -- 刷新车次列表 + 重绘运行图；勾选车站少于1个时 refreshDiagram 内部会清除旧图
    displayedLines = getRelevantLines(getSelectedStationList())
    updateLineList()
    if menu.renderLayout and menu.stationLabels and menu.timeBarTop then
        pcall(function() refreshDiagram() end)
    end
    if rebuildList then rebuildPresetList() end
end

-- 应用"时间标签位置"设置：把图表区（ca，含站名标签+运行图）与时间标签条（顶部条/底部条）
-- 在 da 的 FloatingLayout 里按目标位置排布。三态：
--   bottom（默认）：ca 顶部对齐(0.5,0) + 底部条(0.5,1) → 时间标签在下方
--   top：顶部条(0.5,0) + ca 底部对齐(0.5,1) → 时间标签在上方，图表区下移腾位
--   both：顶部条(0.5,0) + ca 居中(0.5,0.5) + 底部条(0.5,1) → 上下各一条，图表夹中间
-- both 时 ca 高度再让出第二条时间标签（图表可视高度相应缩 TIME_LABEL_HEIGHT）。
-- 用 removeItem + 重新 addItem(comp, alignX, alignY) 切换——addItem 是 renderLayout
-- 一直使用的形态（FloatingLayout 按对齐值放置子项，AGENTS.md 已验证）。setAlignment
-- 的索引在引擎里取不到可靠值（getItem:getId 无法匹配），故改用重建加入。
local function applyTimeLabelPosition()
    local pos = timetable.getTimeLabelPos()
    if pos ~= "top" and pos ~= "both" then pos = "bottom" end
    local dal = menu.daLayout
    local ca = menu.chartArea
    local tlcT = menu.timeBarTop and menu.timeBarTop.component
    local tlcB = menu.timeBarBottom and menu.timeBarBottom.component
    if not dal or not ca or not tlcT or not tlcB then
        dbgPrint("applyTimeLabelPosition: missing layout refs, skip")
        return
    end
    -- 已处于目标布局时跳过（幂等）
    if menu.appliedTimeLabelPos == pos then
        dbgPrint("applyTimeLabelPosition: already " .. pos .. ", skip")
        return
    end
    -- ca 高度联动：both = 让出两条时间标签；单条 = 让出一条（ca 内站名列/绘制区同步缩放）
    local caH = WINDOW_HEIGHT - TITLE_BAR_H - ((pos == "both") and (2 * TIME_LABEL_HEIGHT) or TIME_LABEL_HEIGHT)
    menu.chartH = caH
    local caW = WINDOW_WIDTH - STATION_PANEL_WIDTH
    local raW = caW - STATION_LABEL_WIDTH
    local function setH(comp, w, h)
        pcall(function()
            comp:setMinimumSize(api.gui.util.Size.new(w, h))
            comp:setMaximumSize(api.gui.util.Size.new(w, h))
        end)
    end
    -- ca 位置：bottom→(0.5,0) 顶部 / top→(0.5,1) 底部 / both→(0.5,0.5) 居中。
    -- 常驻结构下 ca 始终在 dal 中（构建时加入），removeItem(ca) 恒安全；tlcT/tlcB 从不 remove。
    local ax, ay = 0.5, 0
    if pos == "top" then ay = 1 elseif pos == "both" then ay = 0.5 end
    local prevAy = 0
    local prevPos = menu.appliedTimeLabelPos
    if prevPos == "top" then prevAy = 1 elseif prevPos == "both" then prevAy = 0.5 end
    if prevPos == nil or prevAy ~= ay then
        pcall(function() dal:removeItem(ca) end)
        -- 先设尺寸再重新加入（detached 时 set 更可靠），加入后再补设一次
        setH(ca, caW, caH)
        local ok, err = pcall(function() dal:addItem(ca, ax, ay) end)
        if not ok then debugPrint("applyTimeLabelPosition ca addItem FAILED: " .. tostring(err)) end
    end
    setH(ca, caW, caH)
    local slc = menu.stationLabels and menu.stationLabels.component
    if slc then setH(slc, STATION_LABEL_WIDTH, caH) end
    local ra = menu.renderArea
    if ra then setH(ra, raW, caH) end
    -- 时间条可见性：bottom=只底条 / top=只顶条 / both=两条
    pcall(function() tlcT:setVisible(pos == "top" or pos == "both", false) end)
    pcall(function() tlcB:setVisible(pos == "bottom" or pos == "both", false) end)
    menu.appliedTimeLabelPos = pos
    dbgPrint("applyTimeLabelPosition: pos=" .. pos .. " caH=" .. caH)
end

-- 运行图放大窗口（2026-08-16 功能）：
-- 保持画布大小不变，改变绘制范围放大运行图。
--  第一行：时间刻度（与设置同等效力，改刻度会同步设置）；
--  第二行：时间区间（随刻度变化的窗口长度下拉）+ 车站区间（当前可见行数递减到2）；
--  第三行：确定（应用窗口尺寸并重置到左下角，重新绘制）；
--  手柄：↑↓←→ 平移（时间步进=刻度，车站步进=1行），带边界防护；
--  底部：恢复默认（回到完整视图）。
function diagramGUI.showZoomWindow()
    local okBody, bodyErr = pcall(function()
        local cc = api.gui.comp.Component.new("zoomContent")
        local cl = api.gui.layout.BoxLayout.new("VERTICAL")
        cc:setLayout(cl)
        cc:setMinimumSize(api.gui.util.Size.new(320, 430))
        cc:setMaximumSize(api.gui.util.Size.new(320, 430))

        -- 各刻度的时间区间下拉项（分钟）："60:00" 格式
        local function zoomIntervalItems(scale)
            local opts = ZOOM_INTERVAL_OPTIONS[scale] or ZOOM_INTERVAL_OPTIONS[5]
            local items = {}
            for _, v in ipairs(opts) do items[#items + 1] = tostring(v) .. ":00" end
            return items, opts
        end

        local function makeComboRow(labelText, rowName, cb, onChange)
            local row = api.gui.comp.Component.new(rowName)
            local rl = api.gui.layout.BoxLayout.new("HORIZONTAL")
            row:setLayout(rl)
            if labelText and labelText ~= "" then
                local lbl = api.gui.comp.TextView.new(labelText)
                lbl:setStyleClassList({"timetable-mono-sc"})
                rl:addItem(lbl)
            end
            rl:addItem(cb)
            cb:onIndexChanged(function(i)
                if i == -1 then return end
                onChange(i)
            end)
            cl:addItem(row)
        end

        local curScale = timetable.getTimeScale()
        local selScale = curScale
        local selInterval = 60
        local totalRanks = 1
        pcall(function()
            local sel = getSelectedStationList()
            totalRanks = #computeSortRanks(sel)
        end)
        if totalRanks < 1 then totalRanks = 1 end
        local selStations = totalRanks

        -- 第一行：时间刻度（与设置同等效力）
        local scaleCb = api.gui.comp.ComboBox.new()
        local SCALE_ITEMS = { D.settings_scale_2, D.settings_scale_5, D.settings_scale_10 }
        local SCALE_VALUES = { 2, 5, 10 }
        for _, it in ipairs(SCALE_ITEMS) do scaleCb:addItem(it) end
        local scaleIdx = 1
        for i, v in ipairs(SCALE_VALUES) do if v == selScale then scaleIdx = i - 1 end end
        pcall(function() scaleCb:setSelected(scaleIdx, false) end)

        -- 第二行：时间区间（选项随刻度变化）+ 车站区间
        local intervalCb = api.gui.comp.ComboBox.new()
        local function rebuildIntervalItems(scale, toDefault)
            -- 注意：该版本 TPF2 的 ComboBox:clear() 绑定签名是 void(ComboBox*, bool)，
            -- 必须传布尔（false=不触发信号），API 文档未列出该参数（实测报
            -- "expected boolean, received no value"）。
            intervalCb:clear(false)
            local items, opts = zoomIntervalItems(scale)
            for _, it in ipairs(items) do intervalCb:addItem(it) end
            local idx = 0
            if not toDefault then
                for i, v in ipairs(opts) do if v == selInterval then idx = i - 1 end end
            end
            pcall(function() intervalCb:setSelected(idx, false) end)
            selInterval = opts[idx + 1] or opts[1]
        end
        makeComboRow(D.settings_time_scale, "zoomRowScale", scaleCb, function(i)
            selScale = SCALE_VALUES[i + 1] or 5
            rebuildIntervalItems(selScale, true)
        end)

        rebuildIntervalItems(selScale, true)  -- 初始默认 60:00
        makeComboRow(D.zoom_time_interval, "zoomRowInterval", intervalCb, function(i)
            local opts = ZOOM_INTERVAL_OPTIONS[selScale] or ZOOM_INTERVAL_OPTIONS[5]
            selInterval = opts[i + 1] or opts[1]
        end)

        local stationCb = api.gui.comp.ComboBox.new()
        for v = totalRanks, 2, -1 do stationCb:addItem(tostring(v)) end
        if totalRanks < 2 then stationCb:addItem("1") end
        pcall(function() stationCb:setSelected(0, false) end)
        makeComboRow(D.zoom_station_interval, "zoomRowStation", stationCb, function(i)
            selStations = math.max(1, totalRanks - i)
        end)

        -- 第三行：确定（应用窗口尺寸并重置到左下角，重新绘制）
        local btnRow = api.gui.comp.Component.new("zoomBtns")
        local btnRl = api.gui.layout.BoxLayout.new("HORIZONTAL")
        btnRow:setLayout(btnRl)
        local okBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(D.confirm), true)
        btnRl:addItem(okBtn)
        cl:addItem(btnRow)

        -- 手柄：↑ ↓ ← →（十字布局）
        local pad = api.gui.comp.Component.new("zoomPad")
        local padL = api.gui.layout.BoxLayout.new("VERTICAL")
        pad:setLayout(padL)
        local btnUp = api.gui.comp.Button.new(api.gui.comp.TextView.new("↑"), true)
        local btnLeft = api.gui.comp.Button.new(api.gui.comp.TextView.new("←"), true)
        local btnRight = api.gui.comp.Button.new(api.gui.comp.TextView.new("→"), true)
        local btnDown = api.gui.comp.Button.new(api.gui.comp.TextView.new("↓"), true)
        local function makePadRow(a, b, c)
            local row = api.gui.comp.Component.new("zoomPadRow")
            local rl = api.gui.layout.BoxLayout.new("HORIZONTAL")
            row:setLayout(rl)
            if a then rl:addItem(a) end
            if b then rl:addItem(b) end
            if c then rl:addItem(c) end
            padL:addItem(row)
        end
        makePadRow(nil, btnUp, nil)
        makePadRow(btnLeft, nil, btnRight)
        makePadRow(nil, btnDown, nil)
        cl:addItem(pad)

        -- 底部：恢复默认
        local restoreBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(D.zoom_restore), true)
        cl:addItem(restoreBtn)

        okBtn:onClick(function()
            timetable.setTimeScale(selScale)
            zoomState.active = (selInterval < 60 or selStations < totalRanks)
            zoomState.tStart = 0
            zoomState.tLen = selInterval
            zoomState.rStart = 1
            zoomState.rLen = selStations
            _G._diagramForceSync = true  -- 时间刻度改动持久化同步（与设置同等效力）
            pcall(function() refreshDiagram() end)
        end)

        -- 手柄平移：时间步进=刻度分钟，车站步进=1行；边界防护（钳制）
        local function padPan(dir)
            if not zoomState.active then return end
            local total = 1
            pcall(function()
                local sel = getSelectedStationList()
                total = #computeSortRanks(sel)
            end)
            local step = timetable.getTimeScale()
            if dir == "left" then
                zoomState.tStart = math.max(0, zoomState.tStart - step)
            elseif dir == "right" then
                zoomState.tStart = math.min(60 - zoomState.tLen, zoomState.tStart + step)
            elseif dir == "up" then
                zoomState.rStart = math.min(math.max(1, total - zoomState.rLen + 1), zoomState.rStart + 1)
            elseif dir == "down" then
                zoomState.rStart = math.max(1, zoomState.rStart - 1)
            end
            clampZoom(total)
            pcall(function() refreshDiagram() end)
        end
        btnUp:onClick(function() padPan("up") end)
        btnDown:onClick(function() padPan("down") end)
        btnLeft:onClick(function() padPan("left") end)
        btnRight:onClick(function() padPan("right") end)

        restoreBtn:onClick(function()
            zoomState.active = false
            pcall(function() refreshDiagram() end)
        end)

        local okW, w = pcall(function() return api.gui.comp.Window.new(D.zoom, cc) end)
        if not okW or not w then return end
        zoomWinRef = w
        w:addHideOnCloseHandler()
        w:setMovable(true)
        w:setSize(api.gui.util.Size.new(340, 470))
        w:setPosition(400, 300)
    end)
    if not okBody then
        -- 无条件输出（不受 _G._diagramDebug 门控）：放大窗口构建失败时可见，便于排查
        print("[DiagramGUI] showZoomWindow ERROR: " .. tostring(bodyErr))
    end
end

function diagramGUI.showDiagram()
    if menu.window ~= nil then
        local ok = pcall(function()
            stationFilterText = ""
            local to = timetable.getTimetableObject()
            local host = getHostLineKey(to)
            if host and to[host].dp and to[host].dp.colorList then
                local cfg = getConfig()
                if not cfg.lineColors then cfg.lineColors = {} end
                for _, entry in pairs(to[host].dp.colorList) do
                    cfg.lineColors[entry.i] = {entry.r, entry.g, entry.b, entry.a}
                end
            end
            local lineDataList = getAllTimetableData()
            allStations = getAllStationsFlat(lineDataList)
            allLines = lineDataList
            for _, ld in pairs(lineDataList) do
                local sc = getLineColor(ld.id)
                if sc then ld.color = sc end
            end
            if currentPresetRef then applyPresetToStations(currentPresetRef) end
            sortAllStations()
            local sel = getSelectedStationList()
            if #sel > 0 then
                displayedLines = getRelevantLines(sel)
                updateLineList()
            end
            rebuildPresetList()
            menu.window:setVisible(true, true)
        end)
        if ok then return end
        menu.window = nil
        menu.lineRenderViews = {}
        menu.stationLabels = {}
        menu.stationLabelViews = {}
        menu.timeLabelViews = {}
        menu.timeLabels = {}
        menu.timeBarTop = nil
        menu.timeBarBottom = nil
    end

    -- 关窗即重置缩放（临时查看辅助，不持久化）
    zoomState.active = false
    -- 设置/放大弹窗引用重置：重开运行图时旧的弹窗大概率已被引擎清理，避免引用失效
    settingsWinRef = nil
    zoomWinRef = nil
    stationFilterText = ""
    loadPresetsFromTimetableObject()

    -- 2026-08-16 方案定稿：打开运行图窗口时，
    -- 1) 对账时刻表数据（拆/建站后把幸存站时刻归位到新位置、删除被拆站时刻）——有变化则触发跨线程同步；
    -- 2) 清理预设里已删除车站的勾选/序号条目（其余站序号原样保留）。
    pcall(function()
        local rc = timetable.reconcileStationData()
        if rc and (rc.rekeyed or 0) + (rc.removed or 0) > 0 then
            _G._diagramForceSync = true
        end
    end)
    pcall(function() purgeDeletedStationsFromPresets() end)

    local lineDataList = getAllTimetableData()
    allStations = getAllStationsFlat(lineDataList)
    allLines = lineDataList
    displayedLines = {}

    dbgPrint("Window open: " .. #localPresets .. " presets, activeId='" .. getActivePresetId() .. "'")
    for _, lp in pairs(localPresets) do
        local sc = 0
        if lp.stationData then for _ in pairs(lp.stationData) do sc = sc + 1 end end
        dbgPrint("  preset " .. lp.id .. "='" .. lp.name .. "' stationData=" .. sc)
    end

    expandedPresetId = nil
    currentPresetRef = nil

    for _, ld in pairs(lineDataList) do
        local sc = getLineColor(ld.id)
        if sc then ld.color = sc end
    end

    local mainLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")

    local leftPanel = api.gui.comp.Component.new("leftPanel")
    local leftLayout = api.gui.layout.BoxLayout.new("VERTICAL")
    leftPanel:setLayout(leftLayout)
    leftPanel:setMinimumSize(api.gui.util.Size.new(STATION_PANEL_WIDTH, WINDOW_HEIGHT - TITLE_BAR_H))
    leftPanel:setMaximumSize(api.gui.util.Size.new(STATION_PANEL_WIDTH, WINDOW_HEIGHT - TITLE_BAR_H))

    -- 设置按钮行：位于左面板顶部（"铁路线"标题上方），打开刷新模式设置弹窗
    local settingsBar = api.gui.comp.Component.new("settingsBar")
    local sbl = api.gui.layout.BoxLayout.new("HORIZONTAL")
    settingsBar:setLayout(sbl)
    local setBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(D.settings), true)
    setBtn:onClick(function()
        -- 单例：已打开的设置弹窗只置顶/重显，不重复创建（2026-08-16 反馈）
        if reshowOrReset(settingsWinRef) then return end
        settingsWinRef = nil
        local okSetting, settingErr = pcall(function()
            -- 设置弹窗：
            -- 分区1 "刷新频率"：勾选 10s 自动刷新 或 手动刷新（互斥）
            -- 分区2 "时间标签"：位置（上/下下拉）+ 时间刻度（2/5/10分下拉，默认5分）
            -- 分区3 "准点判定阈值"：0/5/10/20/30/40/50/60s 下拉（默认10s）
            -- 分区5 "车站间距"：等距 / 按距离 / 按运行时间 下拉（默认等距）
            -- 点"确定"应用设置并刷新运行图；设置存 timetableObject 随存档永久保存，
            -- 并置 _diagramForceSync 触发跨线程同步（GUI→引擎 state.timetable）。
            local cc = api.gui.comp.Component.new("settingsContent")
            local cl = api.gui.layout.BoxLayout.new("VERTICAL")
            cc:setLayout(cl)
            cc:setMinimumSize(api.gui.util.Size.new(320, 560))
            cc:setMaximumSize(api.gui.util.Size.new(320, 560))

            local curAuto = timetable.getDiagramAutoRefresh()
            local curPos = timetable.getTimeLabelPos()
            if curPos == nil or (curPos ~= "top" and curPos ~= "bottom" and curPos ~= "both") then curPos = "bottom" end
            local curScale = timetable.getTimeScale()
            local curPunct = timetable.getPunctThreshold()
            local curFilter = timetable.getPolylineFilter()
            -- 待应用值：点"确定"才写入（用户要求"点击确定更改设置并刷新"）
            local selAuto = curAuto
            local selPos = curPos
            local selScale = curScale
            local selPunct = curPunct
            local selFilter = curFilter
            local selSpacing = timetable.getRowSpacing()
            local selPlatforms = timetable.getShowPlatforms()
            local selVehicles = timetable.getShowVehicles()

            local function makeSectionLabel(text)
                local lbl = api.gui.comp.TextView.new(text)
                lbl:setStyleClassList({"timetable-settings-header"})
                return lbl
            end

            -- 生成 "文字标签 + 下拉框" 一行；onChange(i) 收到 0 基索引（-1=空）
            local function makeComboRow(labelText, rowName, items, curIdx, onChange)
                local row = api.gui.comp.Component.new(rowName)
                local rl = api.gui.layout.BoxLayout.new("HORIZONTAL")
                row:setLayout(rl)
                if labelText and labelText ~= "" then
                    local lbl = api.gui.comp.TextView.new(labelText)
                    lbl:setStyleClassList({"timetable-mono-sc"})
                    rl:addItem(lbl)
                end
                local cb = api.gui.comp.ComboBox.new()
                for _, it in ipairs(items) do cb:addItem(it) end
                pcall(function() cb:setSelected(curIdx, false) end)
                cb:onIndexChanged(function(i)
                    if i == -1 then return end
                    onChange(i)
                end)
                rl:addItem(cb)
                cl:addItem(row)
            end

            -- 分区1：刷新频率
            cl:addItem(makeSectionLabel(D.settings_refresh_rate))

            local autoCk = api.gui.comp.ImageView.new(curAuto and "ui/checkbox1.tga" or "ui/checkbox0.tga")
            local autoBtn = api.gui.comp.Button.new(autoCk, true)
            local autoLbl = api.gui.comp.TextView.new(D.settings_auto)
            local autoRow = api.gui.comp.Component.new("settingRowAuto")
            local autoRl = api.gui.layout.BoxLayout.new("HORIZONTAL")
            autoRow:setLayout(autoRl)
            autoRl:addItem(autoBtn); autoRl:addItem(autoLbl)

            local manCk = api.gui.comp.ImageView.new((not curAuto) and "ui/checkbox1.tga" or "ui/checkbox0.tga")
            local manBtn = api.gui.comp.Button.new(manCk, true)
            local manLbl = api.gui.comp.TextView.new(D.settings_manual)
            local manRow = api.gui.comp.Component.new("settingRowMan")
            local manRl = api.gui.layout.BoxLayout.new("HORIZONTAL")
            manRow:setLayout(manRl)
            manRl:addItem(manBtn); manRl:addItem(manLbl)

            cl:addItem(autoRow); cl:addItem(manRow)

            -- 分区2：时间标签（位置 + 时间刻度）
            cl:addItem(makeSectionLabel(D.settings_time_label))

            local POS_ITEMS = { D.settings_top, D.settings_bottom, D.settings_both }  -- 上/下/上下
            local posCurIdx = 1
            if curPos == "top" then posCurIdx = 0 elseif curPos == "both" then posCurIdx = 2 end
            makeComboRow(D.settings_position, "settingRowPos", POS_ITEMS, posCurIdx, function(i)
                selPos = (i == 0) and "top" or ((i == 2) and "both" or "bottom")
            end)

            local SCALE_ITEMS = { D.settings_scale_2, D.settings_scale_5, D.settings_scale_10 }  -- 2/5/10分
            local SCALE_VALUES = { 2, 5, 10 }
            local scaleCurIdx = 1
            for i, v in ipairs(SCALE_VALUES) do if v == curScale then scaleCurIdx = i - 1 end end
            makeComboRow(D.settings_time_scale, "settingRowScale", SCALE_ITEMS, scaleCurIdx, function(i)
                selScale = SCALE_VALUES[i + 1] or 5
            end)

            -- 分区3：准点判定阈值
            cl:addItem(makeSectionLabel(D.settings_punct_threshold))

            local PUNCT_VALUES = { 0, 5, 10, 20, 30, 40, 50, 60 }
            local PUNCT_ITEMS = {}
            for _, v in ipairs(PUNCT_VALUES) do PUNCT_ITEMS[#PUNCT_ITEMS + 1] = tostring(v) .. "s" end
            local punctCurIdx = 2   -- 默认 10s
            for i, v in ipairs(PUNCT_VALUES) do if v == curPunct then punctCurIdx = i - 1 end end
            makeComboRow("", "settingRowPunct", PUNCT_ITEMS, punctCurIdx, function(i)
                selPunct = PUNCT_VALUES[i + 1] or 10
            end)

            -- 分区4：运行方向筛选（折线只画往上/往下/全部）
            cl:addItem(makeSectionLabel(D.settings_polyline_filter))

            local FILTER_ITEMS = { D.settings_polyline_all, D.settings_polyline_up, D.settings_polyline_down }
            local FILTER_VALUES = { "all", "up", "down" }
            local filterCurIdx = 0
            for i, v in ipairs(FILTER_VALUES) do if v == curFilter then filterCurIdx = i - 1 end end
            makeComboRow("", "settingRowFilter", FILTER_ITEMS, filterCurIdx, function(i)
                selFilter = FILTER_VALUES[i + 1] or "all"
            end)

            -- 分区5：车站间距（等距 / 按线路距离 / 按运行时间）
            cl:addItem(makeSectionLabel(D.settings_spacing))

            local SPACING_ITEMS = { D.settings_spacing_equal, D.settings_spacing_distance, D.settings_spacing_time }
            local SPACING_VALUES = { "equal", "distance", "time" }
            local spacingCurIdx = 0
            for i, v in ipairs(SPACING_VALUES) do if v == selSpacing then spacingCurIdx = i - 1 end end
            makeComboRow("", "settingRowSpacing", SPACING_ITEMS, spacingCurIdx, function(i)
                selSpacing = SPACING_VALUES[i + 1] or "equal"
            end)

            -- Section 6: platform number labels above the dwell segments
            cl:addItem(makeSectionLabel(D.settings_platforms))

            local platCk = api.gui.comp.ImageView.new(selPlatforms and "ui/checkbox1.tga" or "ui/checkbox0.tga")
            local platBtn = api.gui.comp.Button.new(platCk, true)
            local platLbl = api.gui.comp.TextView.new(D.settings_platforms_show)
            local platRow = api.gui.comp.Component.new("settingRowPlatforms")
            local platRl = api.gui.layout.BoxLayout.new("HORIZONTAL")
            platRow:setLayout(platRl)
            platRl:addItem(platBtn); platRl:addItem(platLbl)
            cl:addItem(platRow)

            -- Section 7: live vehicle overlay (positions and delays)
            cl:addItem(makeSectionLabel(D.settings_vehicles))

            local vehicleCk = api.gui.comp.ImageView.new(selVehicles and "ui/checkbox1.tga" or "ui/checkbox0.tga")
            local vehicleBtn = api.gui.comp.Button.new(vehicleCk, true)
            local vehicleLbl = api.gui.comp.TextView.new(D.settings_vehicles_show)
            local vehicleRow = api.gui.comp.Component.new("settingRowVehicles")
            local vehicleRl = api.gui.layout.BoxLayout.new("HORIZONTAL")
            vehicleRow:setLayout(vehicleRl)
            vehicleRl:addItem(vehicleBtn); vehicleRl:addItem(vehicleLbl)
            cl:addItem(vehicleRow)

            local btnRow = api.gui.comp.Component.new("settingBtns")
            local btnRl = api.gui.layout.BoxLayout.new("HORIZONTAL")
            btnRow:setLayout(btnRl)
            local okBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(D.confirm), true)
            local cancelBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(D.cancel), true)
            btnRl:addItem(okBtn); btnRl:addItem(cancelBtn); cl:addItem(btnRow)

            local okW, w = pcall(function() return api.gui.comp.Window.new(D.settings, cc) end)
            if not okW or not w then return end
            settingsWinRef = w
            w:addHideOnCloseHandler()
            w:setMovable(true)
            w:setSize(api.gui.util.Size.new(340, 600))
            w:setPosition(400, 300)

            autoBtn:onClick(function()
                selAuto = true
                pcall(function() autoCk:setImage("ui/checkbox1.tga", false) end)
                pcall(function() manCk:setImage("ui/checkbox0.tga", false) end)
            end)
            manBtn:onClick(function()
                selAuto = false
                pcall(function() autoCk:setImage("ui/checkbox0.tga", false) end)
                pcall(function() manCk:setImage("ui/checkbox1.tga", false) end)
            end)
            platBtn:onClick(function()
                selPlatforms = not selPlatforms
                pcall(function() platCk:setImage(selPlatforms and "ui/checkbox1.tga" or "ui/checkbox0.tga", false) end)
            end)
            vehicleBtn:onClick(function()
                selVehicles = not selVehicles
                pcall(function() vehicleCk:setImage(selVehicles and "ui/checkbox1.tga" or "ui/checkbox0.tga", false) end)
            end)
            okBtn:onClick(function()
                pcall(function() w:setVisible(false, false) end)
                -- 点"确定"才应用设置并刷新运行图：
                -- 1) 刷新频率（10s 自动刷新 / 手动刷新）
                -- 2) 时间标签位置（重排图表区 + 重绘时间标签）
                -- 3) 时间刻度（重绘网格竖线 + 时间标签步长）
                -- 4) 准点判定阈值（重算晚点/正点/早点分类）
                -- 5) 运行方向筛选（重绘折线：只画往上/往下/全部）
                -- 6) 车站间距（重算各行纵坐标）
                -- 7) platform number labels
                -- 8) live vehicle overlay
                local okApply, applyErr = pcall(function()
                    timetable.setDiagramAutoRefresh(selAuto)
                    timetable.setTimeLabelPos(selPos)
                    timetable.setTimeScale(selScale)
                    timetable.setPunctThreshold(selPunct)
                    timetable.setPolylineFilter(selFilter)
                    timetable.setRowSpacing(selSpacing)
                    timetable.setShowPlatforms(selPlatforms)
                    timetable.setShowVehicles(selVehicles)
                    _G._diagramForceSync = true
                    applyTimeLabelPosition()
                    -- 布局切换（ca 重放/尺寸/时间条可见性）需要一帧让引擎重排收敛后再刷新——
                    -- 立即 doRefreshData 会读到未收敛的布局（首次切「上下」顶条与图重叠、
                    -- 二次切换才正常，玩家实测 2026-08-16）
                    if menu.window then
                        menu.window:invokeLater(function()
                            pcall(function() doRefreshData() end)
                        end)
                    else
                        doRefreshData()
                    end
                end)
                if not okApply then debugPrint("settings apply ERROR: " .. tostring(applyErr)) end
            end)
            cancelBtn:onClick(function() pcall(function() w:setVisible(false, false) end) end)
        end)
        if not okSetting then debugPrint("settings window ERROR: " .. tostring(settingErr)) end
    end)
    sbl:addItem(setBtn)
    -- 放大手柄按钮：打开运行图放大窗口（时间/车站区间 + 平移手柄 + 恢复默认）
    local zoomBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(D.zoom), true)
    zoomBtn:onClick(function()
        -- 单例：已打开的放大弹窗只置顶/重显，不重复创建（2026-08-16 反馈）
        if reshowOrReset(zoomWinRef) then return end
        zoomWinRef = nil
        local okZ, zErr = pcall(diagramGUI.showZoomWindow)
        if not okZ then print("[DiagramGUI] showZoomWindow error: " .. tostring(zErr)) end
    end)
    sbl:addItem(zoomBtn)
    leftLayout:addItem(settingsBar)

    local phc = api.gui.comp.Component.new("presetHeader")
    local phl = api.gui.layout.BoxLayout.new("HORIZONTAL")
    phc:setLayout(phl)
    phl:addItem(api.gui.comp.TextView.new(D.railway_lines))
    local addBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new("+"), true)
    addBtn:onClick(function() addNewPreset() end)
    phl:addItem(addBtn)

    leftLayout:addItem(phc)

    -- 搜索行：独立一行（"车站搜索"标题 + 输入框）。
    -- 旧布局把"搜索"标题塞进"铁路线"标题行，英文单词过长把输入框挤出左栏被遮挡；
    -- 拆成单独一行后输入框有完整宽度可用。
    local shc = api.gui.comp.Component.new("searchHeader")
    local shl = api.gui.layout.BoxLayout.new("HORIZONTAL")
    shc:setLayout(shl)
    shl:addItem(api.gui.comp.TextView.new(D.station_search))

    leftLayout:addItem(shc)

    local psa = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new("presetScroll"), "diagram.presetScroll_" .. nextLabelName())
    psa:setMinimumSize(api.gui.util.Size.new(STATION_PANEL_WIDTH, 270))
    psa:setMaximumSize(api.gui.util.Size.new(STATION_PANEL_WIDTH, 270))
    menu.presetScrollArea = psa
    leftLayout:addItem(psa)

    local btnBar = api.gui.comp.Component.new("buttonBar")
    local bbl = api.gui.layout.BoxLayout.new("HORIZONTAL")
    btnBar:setLayout(bbl)
    -- 保存按钮已移除：车站勾选/排序序号/线路勾选均为即时保存；
    -- 车次列表与运行图由"展开预设"或"刷新"按钮触发。
    local refBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(D.refresh), true)
    refBtn:onClick(function()
        local ok, err = pcall(function() doRefreshData() end)
        if not ok then debugPrint("Refresh error: " .. tostring(err)) end
    end)
    bbl:addItem(refBtn)
    leftLayout:addItem(api.gui.comp.Component.new("HorizontalLine"))
    leftLayout:addItem(btnBar)

    local lsc = api.gui.comp.Component.new("lineSection")
    local lsl = api.gui.layout.BoxLayout.new("VERTICAL")
    lsc:setLayout(lsl)

    local lhc = api.gui.comp.Component.new("lineHeader")
    local lhl = api.gui.layout.BoxLayout.new("HORIZONTAL")
    lhc:setLayout(lhl)
    lhl:addItem(api.gui.comp.TextView.new(D.train_list))

    local lineColorBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(D.color), true)
    lineColorBtn:setStyleClassList({"timetable-avtivateTimetableButton"})
    lineColorBtn:onClick(function()
        local boldLines = {}
        for _, ld in pairs(displayedLines) do
            if ld.bold then table.insert(boldLines, ld) end
        end
        if #boldLines == 0 then return end
        local cp = api.gui.comp.ColorPicker.new()
        cp:onColorChanged(function(c)
            local newColor = api.type.Vec4f.new(c.x, c.y, c.z, 1.0)
            for _, ld2 in pairs(boldLines) do
                ld2.color = newColor
                saveLineColor(ld2.id, newColor)
                pcall(function()
                    api.cmd.sendCommand(api.cmd.make.setColor(ld2.id, api.type.Vec3f.new(c.x, c.y, c.z)))
                end)
            end
            local to = timetable.getTimetableObject()
            local host = getHostLineKey(to)
            if host and to[host].dp then
                if not to[host].dp.colorList then to[host].dp.colorList = {} end
                for _, ld2 in pairs(boldLines) do
                    local found = false
                    for _, entry in pairs(to[host].dp.colorList) do
                        if entry.i == tostring(ld2.id) then
                            entry.r = c.x; entry.g = c.y; entry.b = c.z; entry.a = 1.0
                            found = true; break
                        end
                    end
                    if not found then
                        table.insert(to[host].dp.colorList, {i = tostring(ld2.id), r = c.x, g = c.y, b = c.z, a = 1.0})
                    end
                end
            end
            _G._diagramForceSync = true
            pcall(function() refreshDiagram() end)
            updateLineList()
        end)
        local okW, w = pcall(function() return api.gui.comp.Window.new(D.choose_color, cp) end)
        if okW and w then w:addHideOnCloseHandler(); w:setMovable(true); w:setPosition(300, 200) end
    end)
    lhl:addItem(lineColorBtn)

    -- 准点信息标题：比"车次列表"小一号字号（timetable-mono-sc 为 10px），位于颜色按钮右侧
    local punctTv = api.gui.comp.TextView.new(D.punctuality)
    punctTv:setStyleClassList({"timetable-mono-sc"})
    lhl:addItem(punctTv)
    lsl:addItem(lhc)

    local lsa = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new("lineScroll"), "diagram.lineScroll_" .. nextLabelName())
    menu.lineListComponent = api.gui.comp.Component.new("lineList")
    menu.lineListLayout = api.gui.layout.BoxLayout.new("VERTICAL")
    menu.lineListComponent:setLayout(menu.lineListLayout)
    lsa:setContent(menu.lineListComponent)
    lsa:setMinimumSize(api.gui.util.Size.new(STATION_PANEL_WIDTH, 270))
    lsa:setMaximumSize(api.gui.util.Size.new(STATION_PANEL_WIDTH, 270))
    menu.lineScrollArea = lsa
    -- 允许横向滚动：线路名过长把准点信息顶出后，可横向滚动查看。
    -- ScrollBarPolicy 枚举未在官方 API 文档中列出（只提到 setHorizontalScrollBarPolicy），
    -- 故 best-effort：枚举路径取不到就跳过，依赖 ScrollArea 默认行为。
    pcall(function()
        local policy = nil
        pcall(function()
            local e = api.type and api.type.enum and api.type.enum.ScrollBarPolicy
            if e then policy = e.ScrollBarAsNeeded end
        end)
        if policy then
            pcall(function() lsa:setHorizontalScrollBarPolicy(policy) end)
        end
    end)
    lsl:addItem(lsa)
    leftLayout:addItem(lsc)
    mainLayout:addItem(leftPanel)

    local da = api.gui.comp.Component.new("diagramArea")
    -- 用 FloatingLayout 承载 ca(图表区)/tlc(时间标签条)：子项按相对父容器的对齐位置放置
    -- （0=左/上, 0.5=中, 1=右/下），可通过 setAlignment(index, x, y) 运行时切换。
    -- 说明：BoxLayout 的 removeItem+addItem 动态重排实测不生效；AbsoluteLayout 的
    -- Rect 坐标语义与 LineRenderView 不一致（实测把 ca 放错位置）。FloatingLayout
    -- 与 renderLayout 同款，对齐行为可靠。
    local dal = api.gui.layout.FloatingLayout.new(0, 1)
    da:setLayout(dal)
    da:setMinimumSize(api.gui.util.Size.new(WINDOW_WIDTH - STATION_PANEL_WIDTH, WINDOW_HEIGHT - TITLE_BAR_H))
    da:setMaximumSize(api.gui.util.Size.new(WINDOW_WIDTH - STATION_PANEL_WIDTH, WINDOW_HEIGHT - TITLE_BAR_H))
    menu.daLayout = dal

    local ca = api.gui.comp.Component.new("chartArea")
    local cl2 = api.gui.layout.BoxLayout.new("HORIZONTAL")
    ca:setLayout(cl2)
    ca:setMinimumSize(api.gui.util.Size.new(WINDOW_WIDTH - STATION_PANEL_WIDTH, WINDOW_HEIGHT - TITLE_BAR_H - TIME_LABEL_HEIGHT))
    ca:setMaximumSize(api.gui.util.Size.new(WINDOW_WIDTH - STATION_PANEL_WIDTH, WINDOW_HEIGHT - TITLE_BAR_H - TIME_LABEL_HEIGHT))
    menu.chartArea = ca
    local slc = api.gui.comp.Component.new("stationLabels")
    local sll = api.gui.layout.AbsoluteLayout.new()
    slc:setLayout(sll)
    slc:setMinimumSize(api.gui.util.Size.new(STATION_LABEL_WIDTH, WINDOW_HEIGHT - TITLE_BAR_H - TIME_LABEL_HEIGHT))
    slc:setMaximumSize(api.gui.util.Size.new(STATION_LABEL_WIDTH, WINDOW_HEIGHT - TITLE_BAR_H - TIME_LABEL_HEIGHT))
    menu.stationLabels = {layout = sll, component = slc, parentLayout = cl2}
    cl2:addItem(slc)

    local ra = api.gui.comp.Component.new("renderArea")
    menu.renderArea = ra
    menu.renderLayout = api.gui.layout.FloatingLayout.new(0, 1)
    ra:setLayout(menu.renderLayout)
    local rw = WINDOW_WIDTH - STATION_PANEL_WIDTH - STATION_LABEL_WIDTH
    local rh = WINDOW_HEIGHT - TITLE_BAR_H - TIME_LABEL_HEIGHT
    ra:setMinimumSize(api.gui.util.Size.new(rw, rh))
    ra:setMaximumSize(api.gui.util.Size.new(rw, rh))
    menu.lineRenderViews = {}
    local function mkiv()
        local v = api.gui.comp.LineRenderView.new()
        v:setMinimumSize(api.gui.util.Size.new(rw, rh))
        v:setMaximumSize(api.gui.util.Size.new(rw, rh))
        menu.renderLayout:addItem(v, 0.5, 0)
        table.insert(menu.lineRenderViews, v)
    end
    mkiv(); mkiv()
    cl2:addItem(ra)
    -- 常驻布局（2026-08-16 重构，修复 RemoveChild assert + 顶条 0 尺寸问题）：
    -- ca(图表区) + 顶部时间条 tlcT + 底部时间条 tlcB 三者在构建时就全部 addItem 进 dal
    -- （tlcT 顶 0.5,0 / tlcB 底 0.5,1，位置固定），applyTimeLabelPosition 只切换条的
    -- 可见性与 ca 的位置/尺寸——**不再动态 add/remove 时间条**（上一版对"未加入的组件"
    -- removeItem 触发 UI::CComponent::RemoveChild assert，玩家实测崩溃）。
    dal:addItem(ca, 0.5, 0)
    local function makeTimeBar(compName)
        local bar = api.gui.comp.Component.new(compName)
        local lay = api.gui.layout.AbsoluteLayout.new()
        bar:setLayout(lay)
        bar:setMinimumSize(api.gui.util.Size.new(WINDOW_WIDTH - STATION_PANEL_WIDTH, TIME_LABEL_HEIGHT))
        bar:setMaximumSize(api.gui.util.Size.new(WINDOW_WIDTH - STATION_PANEL_WIDTH, TIME_LABEL_HEIGHT))
        return { layout = lay, component = bar, views = {} }
    end
    menu.timeBarTop = makeTimeBar("timeLabelsTop")
    menu.timeBarBottom = makeTimeBar("timeLabelsBottom")
    dal:addItem(menu.timeBarTop.component, 0.5, 0)
    dal:addItem(menu.timeBarBottom.component, 0.5, 1)
    menu.daComponent = da
    mainLayout:addItem(da)

    local wrapper = api.gui.comp.Component.new("diagramWrapper")
    wrapper:setLayout(mainLayout)
    rebuildPresetList()

    local ttWasVisible = _G._timetableVisible
    local okW2, newWin = pcall(function() return api.gui.comp.Window.new(D.title, wrapper) end)
    if not okW2 or not newWin then debugPrint("Window.new failed"); return end
    menu.window = newWin
    -- 应用已保存的时间标签位置（bottom/top/both）：窗口创建后按 pos 统一执行
    -- （可见性切换 + ca 位置/尺寸），此时引擎组件才真正 attach。
    menu.appliedTimeLabelPos = nil
    pcall(function() applyTimeLabelPosition() end)
    menu.window:invokeLater(function()
        pcall(function()
            if _G._timetableWindow and ttWasVisible then
                _G._timetableWindow:setVisible(true, false)
            end
        end)
    end)
    menu.window:addHideOnCloseHandler()
    menu.window:setMovable(true); menu.window:setResizable(true)
    menu.window:setSize(api.gui.util.Size.new(WINDOW_WIDTH, WINDOW_HEIGHT))
    menu.window:setPosition(200, 100)
    -- 自动刷新：勾选"10s 自动刷新"时，每 10s 执行一次完整刷新（与"刷新"按钮等同：
    -- 重新读取时刻表数据 + 重建车次列表含准点 + 重绘运行图）。
    menu.window:onStep(function()
        -- live vehicle overlay: redrawn once per game second
        pcall(function()
            if not menu.liveCtx then return end
            local t = timetableHelper.getTime()
            if t == menu.liveLastDraw then return end
            menu.liveLastDraw = t
            drawLiveOverlay()
        end)
        pcall(function()
            if not timetable.getDiagramAutoRefresh() then return end
            local t = timetableHelper.getTime()
            if not _G._punctLastRefresh then _G._punctLastRefresh = t end
            if t - _G._punctLastRefresh >= 10 then
                _G._punctLastRefresh = t
                doRefreshData(true)
            end
        end)
    end)
    menu.window:invokeLater(function()
        local okSF, ff = pcall(function()
            local f = api.gui.comp.TextInputField.new("")
            f:setText(stationFilterText, false)
            f:onChange(function(text)
                stationFilterText = text or ""
                updateStationVisibility()
            end)
            return f
        end)
        if okSF and ff then
            shl:addItem(ff)
        else
            debugPrint("filterField FAIL deferred: " .. tostring(ff))
        end
    end)
    menu.window:onClose(function()
        persistConfig()
        menu.window = nil; menu.lineRenderViews = {}; menu.stationLabels = {}
        menu.stationLabelViews = {}; menu.timeLabelViews = {}
        menu.timeLabels = {}; menu.timeBarTop = nil; menu.timeBarBottom = nil
        menu.lineListLayout = nil; menu.lineListComponent = nil
        menu.renderLayout = nil; menu.renderArea = nil
        menu.daLayout = nil; menu.chartArea = nil; menu.appliedTimeLabelPos = nil
        menu.timeBarTop = nil; menu.timeBarBottom = nil; menu.chartH = nil
        menu.lineScrollArea = nil; menu.presetScrollArea = nil
        menu.liveViews = {}; menu.liveCtx = nil; menu.liveLastDraw = nil
        stationRowGroups = {}; displayedLines = {}
    end)
end

return diagramGUI
