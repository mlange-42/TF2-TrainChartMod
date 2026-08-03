local timetable = require "celmi/timetables/timetable"
local timetableHelper = require "celmi/timetables/timetable_helper"

local diagramGUI = {}

local menu = {
    window = nil, lineRenderViews = {}, stationLabels = {}, timeLabels = {},
    stationLabelViews = {}, timeLabelViews = {},
    lineListLayout = nil, lineScrollArea = nil,
    presetScrollArea = nil,
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
local TITLE_BAR_H = 30
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

local function getLineColor(lineID)
    local cfg = getConfig()
    if cfg.lineColors and cfg.lineColors[tostring(lineID)] then
        local c = cfg.lineColors[tostring(lineID)]
        return api.type.Vec4f.new(c[1], c[2], c[3], c[4])
    end
    return nil
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

local function stationToY(idx, total, height)
    if total <= 1 then return height / 2 end
    return (1 - (idx - 1) / (total - 1)) * height
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
        local savedColor = getLineColor(lineID)
        local lineData = {
            id = lineID, name = lineInfo.name, stations = {},
            color = savedColor or getColor(#data + 1),
            selected = false, bold = false, checked = true,
        }        for flatIdx, stopInfo in ipairs(stops) do
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
                gwKey = gk }
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
            lineData.stations[flatIdx] = entry
        end
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
                    sourceLineID = ld.id, sourceLineName = ld.name,
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

local function getYMap(selList, h)
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
    local map = {}
    for i, sv in ipairs(sorts) do
        local y = stationToY(i, #sorts, h)
        for _, s in pairs(labelGroups[sv]) do
            if s.stopType == "station" then
                local eid = tostring(s.id)
                for _, ld in pairs(allLines) do
                    for _, st in pairs(ld.stations) do
                        if st.stopType == "station" and tostring(st.id) == eid then
                            map[st.uniqueKey] = y
                        end
                    end
                end
            else
                if s.entityId then
                    for _, ld in pairs(allLines) do
                        for _, st in pairs(ld.stations) do
                            if st.stopType == "waypoint" and st.entityId == s.entityId then
                                map[st.uniqueKey] = y
                            end
                        end
                    end
                else
                    map[s.uniqueKey] = y
                end
            end
        end
    end
    return map, labelGroups, sorts
end

-- 清除运行图渲染区（折线视图 + 站名标签 + 时间标签），全部 pcall 保护。
local function clearDiagramViews()
    if menu.renderLayout then
        for _, v in pairs(menu.lineRenderViews) do
            pcall(function() menu.renderLayout:removeItem(v) end)
        end
    end
    menu.lineRenderViews = {}
    if menu.stationLabels and menu.stationLabels.layout then
        for _, oldCont in ipairs(menu.stationLabelViews) do
            pcall(function() menu.stationLabels.layout:removeItem(oldCont) end)
        end
    end
    menu.stationLabelViews = {}
    if menu.timeLabels and menu.timeLabels.layout then
        for _, oldCont in ipairs(menu.timeLabelViews) do
            pcall(function() menu.timeLabels.layout:removeItem(oldCont) end)
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
    local lh_logical = WINDOW_HEIGHT - TITLE_BAR_H - TIME_LABEL_HEIGHT
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
    local yMap, groups, sorts = getYMap(selList, dh)

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
    for m = 5, 55, 5 do
        local x = (m / 60) * dw
        rv:addLine(api.type.Vec2f.new(x, 0), api.type.Vec2f.new(x, dh))
    end
    for i = 1, #sorts do
        local y = stationToY(i, #sorts, dh)
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
        for idx = #sorts, 1, -1 do
            local sv = sorts[idx]
            local groupStations = groups[sv]
            local stationName = nil
            if groupStations then
                for _, s in pairs(groupStations) do
                    if s.stopType == "station" then
                        stationName = s.name
                        break
                    end
                end
            end
            if stationName then
                local nameTag = nextLabelName()
                local ok2, result = pcall(function()
                    local y = stationToY(idx, #sorts, dh)
                    local label = api.gui.comp.TextView.new(stationName)
                    label:setStyleClassList({"timetable-mono-sc"})
                    label:setGravity(1, 0.5)
                    local cont = api.gui.comp.Component.new("stCont_" .. sv .. "_" .. nameTag)
                    cont:setMinimumSize(api.gui.util.Size.new(STATION_LABEL_WIDTH, labelH))
                    cont:setMaximumSize(api.gui.util.Size.new(STATION_LABEL_WIDTH, labelH))
                    cont:setLayout(api.gui.layout.BoxLayout.new("VERTICAL"))
                    cont:getLayout():addItem(label)
                    local rectY = math.max(topPad, math.min(dh - labelH - topPad, math.floor(y - labelH / 2 + topPad)))
                    local rect = api.gui.util.Rect.new(0, rectY, STATION_LABEL_WIDTH, labelH)
                    sll:addItem(cont, rect)
                    table.insert(menu.stationLabelViews, cont)
                end)
                if not ok2 then debugPrint("stationLabel add failed: " .. tostring(result)) end
            end
        end
        dbgPrint("stationLabels: " .. #menu.stationLabelViews .. " items, sorts=" .. #sorts)
    end

    if menu.timeLabels and menu.timeLabels.layout and menu.timeLabels.component then
        pcall(function()
            menu.timeLabels.component:invokeLater(function()
                pcall(function()
                    local tll = menu.timeLabels.layout
                    if not tll then return end
                    for _, oldCont in ipairs(menu.timeLabelViews) do
                        pcall(function() tll:removeItem(oldCont) end)
                    end
                    menu.timeLabelViews = {}
                    local raRect = menu.renderArea and menu.renderArea:getContentRect()
                    local tlcRect = menu.timeLabels.component:getContentRect()
                    local labelW = 44
                    if raRect and raRect.w > 0 and tlcRect and tlcRect.w > 0 then
                        local offsetX = raRect.x - tlcRect.x
                        local offsetY = (raRect.y + raRect.h) - tlcRect.y
                        for m = 0, 55, 5 do
                            local fx = m / 60
                            local cx = offsetX + fx * dw
                            local label = api.gui.comp.TextView.new(string.format("%02d:00", m))
                            label:setStyleClassList({"timetable-mono-sc"})
                            -- 时间标签在下方时：文字贴容器底部（gravity 1），从居中位置下移约半字，
                            -- 避免紧贴运行图底边框；在上方时保持居中。
                            -- 注意：label 必须显式占满 TIME_LABEL_HEIGHT 高，gravity 才有效——
                            -- 否则 TextView 按文字高度自适应，gravity 形同虚设。
                            label:setMinimumSize(api.gui.util.Size.new(labelW, TIME_LABEL_HEIGHT))
                            label:setMaximumSize(api.gui.util.Size.new(labelW, TIME_LABEL_HEIGHT))
                            if timetable.getTimeLabelPos() == "top" then
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
                            table.insert(menu.timeLabelViews, cont)
                        end
                    else
                        debugPrint("timeLabels: raRect or tlcRect invalid")
                    end
                    dbgPrint("timeLabels: " .. #menu.timeLabelViews .. " items")
                end)
            end)
        end)
    end

    local drawDebug = {}
    if #displayedLines > 0 then
    for _ in pairs(displayedLines) do makeLRV() end

    local function drawWrappedSegment(lv, t1, y1, t2, y2)
        local c1 = math.floor(t1 / 3600)
        local c2 = math.floor(t2 / 3600)
        if c1 == c2 then
            local x1 = ((t1 - c1 * 3600) / 3600) * dw
            local x2 = ((t2 - c1 * 3600) / 3600) * dw
            lv:addLine(api.type.Vec2f.new(x1, y1), api.type.Vec2f.new(x2, y2))
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
                    local cx1 = ((s - c * 3600) / 3600) * dw
                    local cx2 = ((e - c * 3600) / 3600) * dw
                    lv:addLine(api.type.Vec2f.new(cx1, cy1), api.type.Vec2f.new(cx2, cy2))
                end
            end
        end
    end

    for li, ld in pairs(displayedLines) do
        if not ld.checked then goto continueLine end
        table.insert(drawDebug, ld.name)
        local lv = menu.lineRenderViews[li + 1]
        if lv then
            lv:setColor(ld.color)
            local lw = ld.bold and 4 or 2
            local maxG = 0
            for __, st in pairs(ld.stations) do
                if st.times and #st.times > maxG then maxG = #st.times end
            end
            if maxG == 0 then maxG = 1 end
            for g = 1, maxG do
                local polylines = {}
                local cur = {}
                local timeOffset = 0
                local prevDep = nil
                for fIdx = 1, #ld.stations do
                    local st = ld.stations[fIdx]
                    if st then
                        local y = yMap[st.uniqueKey]
                        if not y then
                            -- 该停站不在当前运行图纵轴上
                            -- 车站：跨线车次的异线车站 → 方案A断开折线
                            -- 路径点：仅"沿轨道经过"的路径控制点 → 静默跳过（不添加点也不断开）
                            if st.stopType == "station" then
                                if #cur > 0 then
                                    polylines[#polylines + 1] = cur
                                    cur = {}
                                end
                            end
                        else
                            local t = nil
                            if st.times and #st.times >= g then
                                t = st.times[g]
                            end
                            if t then
                                local arr = t[1] * 60 + t[2]
                                local dep = t[3] * 60 + t[4]
                                if prevDep and (timeOffset + arr) < prevDep then
                                    timeOffset = timeOffset + 3600
                                end
                                local uwArr = timeOffset + arr
                                local uwDep = timeOffset + dep
                                if uwDep < uwArr then
                                    uwDep = uwDep + 3600
                                end
                                if fIdx > 1 then
                                    table.insert(cur, {uw = uwArr, y = y})
                                end
                                local isTerminalReturn = (ld.stations[1] and st.uniqueKey == ld.stations[1].uniqueKey) and (fIdx == #ld.stations)
                                if not isTerminalReturn then
                                    table.insert(cur, {uw = uwDep, y = y})
                                    prevDep = uwDep
                                else
                                    prevDep = uwArr
                                end
                            end
                        end
                    end
                end
                if #cur > 0 then
                    polylines[#polylines + 1] = cur
                end

                -- 循环闭合：连接最后一折线的末端到下一周期始发站的到达
                if #polylines > 0 and #ld.stations >= 1 then
                    local firstSt = ld.stations[1]
                    local lastSt = ld.stations[#ld.stations]
                    local firstY = yMap[firstSt.uniqueKey]
                    local lastY = yMap[lastSt.uniqueKey]
                    if firstY and firstY ~= lastY then
                        local nextG = (g % maxG) + 1
                        if firstSt.times and #firstSt.times >= nextG then
                            local t = firstSt.times[nextG]
                            if t then
                                local arr = t[1] * 60 + t[2]
                                if (timeOffset + arr) < prevDep then
                                    timeOffset = timeOffset + 3600
                                end
                                local uwArr = timeOffset + arr
                                local lastPl = polylines[#polylines]
                                table.insert(lastPl, {uw = uwArr, y = firstY})
                                if g < maxG then
                                    local dep = t[3] * 60 + t[4]
                                    local uwDep = timeOffset + dep
                                    if uwDep < uwArr then
                                        uwDep = uwDep + 3600
                                    end
                                    table.insert(lastPl, {uw = uwDep, y = firstY})
                                end
                            end
                        end
                    end
                end

                lv:setWidth(lw)
                for _, pl in ipairs(polylines) do
                    for i = 1, #pl - 1 do
                        drawWrappedSegment(lv, pl[i].uw, pl[i].y, pl[i+1].uw, pl[i+1].y)
                    end
                end
                lv:setWidth(lw + 2)
                for _, pl in ipairs(polylines) do
                    for __, p in pairs(pl) do
                        local nx = ((p.uw % 3600) / 3600) * dw
                        local ny = p.y
                        lv:addLine(api.type.Vec2f.new(nx - 2, ny), api.type.Vec2f.new(nx + 2, ny))
                        lv:addLine(api.type.Vec2f.new(nx, ny - 2), api.type.Vec2f.new(nx, ny + 2))
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
                if menu.renderLayout and menu.stationLabels and menu.timeLabels then
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

                local sld = api.gui.comp.TextView.new(D.sort)
                sld:setStyleClassList({"timetable-mono-sc"})

                local sp = api.gui.comp.DoubleSpinBox.new()
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

                sl:addItem(cb); sl:addItem(lb); sl:addItem(sld); sl:addItem(sp)
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

local function doRefreshData()
    stationFilterText = ""
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
    allStations = getAllStationsFlat(lineDataList)
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
    if menu.renderLayout and menu.stationLabels and menu.timeLabels then
        pcall(function() refreshDiagram() end)
    end
    rebuildPresetList()
end

-- 应用"时间标签位置"设置：把图表区（ca，含站名标签+运行图）与时间标签条（tlc）
-- 在 da 的 FloatingLayout 里切换对齐位置。
--   bottom（默认）：ca 对齐顶部(0.5,0)，tlc 对齐底部(0.5,1) → 时间标签在下方
--   top：tlc 对齐顶部(0.5,0)，ca 对齐底部(0.5,1) → 时间标签在上方，图表区下移腾位
-- 用 removeItem + 重新 addItem(comp, alignX, alignY) 切换——addItem 是 renderLayout
-- 一直使用的形态（FloatingLayout 按对齐值放置子项，AGENTS.md 已验证）。setAlignment
-- 的索引在引擎里取不到可靠值（getItem:getId 无法匹配），故改用重建加入。
local function applyTimeLabelPosition()
    local pos = timetable.getTimeLabelPos()
    if pos ~= "top" then pos = "bottom" end
    local dal = menu.daLayout
    local ca = menu.chartArea
    local tlc = menu.timeLabels and menu.timeLabels.component
    if not dal or not ca or not tlc then
        dbgPrint("applyTimeLabelPosition: missing layout refs, skip")
        return
    end
    -- 已处于目标布局时跳过（幂等）
    if menu.appliedTimeLabelPos == pos then
        dbgPrint("applyTimeLabelPosition: already " .. pos .. ", skip")
        return
    end
    -- 移除旧的 ca/tlc，再按目标顺序/对齐重新加入。
    -- removeItem 属于 ILayout 基类（AGENTS.md），FloatingLayout 可用；pcall 保护。
    pcall(function() dal:removeItem(ca) end)
    pcall(function() dal:removeItem(tlc) end)
    if pos == "top" then
        pcall(function() dal:addItem(tlc, 0.5, 0) end)  -- tlc 顶部
        pcall(function() dal:addItem(ca, 0.5, 1) end)   -- ca 底部（图表下移腾位）
    else
        pcall(function() dal:addItem(ca, 0.5, 0) end)   -- ca 顶部
        pcall(function() dal:addItem(tlc, 0.5, 1) end)  -- tlc 底部
    end
    menu.appliedTimeLabelPos = pos
    dbgPrint("applyTimeLabelPosition: pos=" .. pos)
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
    end

    stationFilterText = ""
    loadPresetsFromTimetableObject()

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
        local okSetting, settingErr = pcall(function()
            -- 设置弹窗：
            -- 分区1 "刷新频率"：勾选 10s 自动刷新 或 手动刷新（互斥）
            -- 分区2 "时间标签位置"：上 / 下（互斥，默认下）
            -- 点"确定"应用设置并刷新运行图（时间标签位置改变会重新排布图表并重绘）。
            local cc = api.gui.comp.Component.new("settingsContent")
            local cl = api.gui.layout.BoxLayout.new("VERTICAL")
            cc:setLayout(cl)
            cc:setMinimumSize(api.gui.util.Size.new(300, 240))
            cc:setMaximumSize(api.gui.util.Size.new(300, 240))

            local curAuto = _G._diagramAutoRefresh
            if curAuto == nil then curAuto = false end
            local curPos = timetable.getTimeLabelPos()
            if curPos == nil or (curPos ~= "top" and curPos ~= "bottom") then curPos = "bottom" end
            -- 待应用值：点"确定"才写入（用户要求"点击确定更改设置并刷新"）
            local selAuto = curAuto
            local selPos = curPos

            local function makeSectionLabel(text)
                local lbl = api.gui.comp.TextView.new(text)
                lbl:setStyleClassList({"timetable-settings-header"})
                return lbl
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

            -- 分区2：时间标签位置
            cl:addItem(makeSectionLabel(D.settings_time_label))

            local topCk = api.gui.comp.ImageView.new(curPos == "top" and "ui/checkbox1.tga" or "ui/checkbox0.tga")
            local topBtn = api.gui.comp.Button.new(topCk, true)
            local topLbl = api.gui.comp.TextView.new(D.settings_top)
            local topRow = api.gui.comp.Component.new("settingRowTop")
            local topRl = api.gui.layout.BoxLayout.new("HORIZONTAL")
            topRow:setLayout(topRl)
            topRl:addItem(topBtn); topRl:addItem(topLbl)

            local botCk = api.gui.comp.ImageView.new(curPos == "bottom" and "ui/checkbox1.tga" or "ui/checkbox0.tga")
            local botBtn = api.gui.comp.Button.new(botCk, true)
            local botLbl = api.gui.comp.TextView.new(D.settings_bottom)
            local botRow = api.gui.comp.Component.new("settingRowBottom")
            local botRl = api.gui.layout.BoxLayout.new("HORIZONTAL")
            botRow:setLayout(botRl)
            botRl:addItem(botBtn); botRl:addItem(botLbl)

            cl:addItem(topRow); cl:addItem(botRow)

            local btnRow = api.gui.comp.Component.new("settingBtns")
            local btnRl = api.gui.layout.BoxLayout.new("HORIZONTAL")
            btnRow:setLayout(btnRl)
            local okBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(D.confirm), true)
            local cancelBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(D.cancel), true)
            btnRl:addItem(okBtn); btnRl:addItem(cancelBtn); cl:addItem(btnRow)

            local okW, w = pcall(function() return api.gui.comp.Window.new(D.settings, cc) end)
            if not okW or not w then return end
            w:addHideOnCloseHandler()
            w:setMovable(true)
            w:setSize(api.gui.util.Size.new(320, 280))
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
            topBtn:onClick(function()
                selPos = "top"
                pcall(function() topCk:setImage("ui/checkbox1.tga", false) end)
                pcall(function() botCk:setImage("ui/checkbox0.tga", false) end)
            end)
            botBtn:onClick(function()
                selPos = "bottom"
                pcall(function() topCk:setImage("ui/checkbox0.tga", false) end)
                pcall(function() botCk:setImage("ui/checkbox1.tga", false) end)
            end)
            okBtn:onClick(function()
                pcall(function() w:setVisible(false, false) end)
                -- 点"确定"才应用设置并刷新运行图：
                -- 1) 刷新频率（10s 自动刷新 / 手动刷新）
                -- 2) 时间标签位置（重排图表区 + 重绘时间标签）
                local okApply, applyErr = pcall(function()
                    _G._diagramAutoRefresh = selAuto
                    timetable.setTimeLabelPos(selPos)
                    applyTimeLabelPosition()
                    doRefreshData()
                end)
                if not okApply then debugPrint("settings apply ERROR: " .. tostring(applyErr)) end
            end)
            cancelBtn:onClick(function() pcall(function() w:setVisible(false, false) end) end)
        end)
        if not okSetting then debugPrint("settings window ERROR: " .. tostring(settingErr)) end
    end)
    sbl:addItem(setBtn)
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

    local psa = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new("presetScroll"), "diagram.presetScroll")
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

    local lsa = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new("lineScroll"), "diagram.lineScroll")
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
    -- 默认时间标签在底部：ca(图表) 对齐顶部(0.5,0)，tlc(时间标签) 对齐底部(0.5,1)。
    -- FloatingLayout 对齐值：alignX 0=左/0.5=中/1=右，alignY 0=顶/0.5=中/1=底。
    dal:addItem(ca, 0.5, 0)

    local tlc = api.gui.comp.Component.new("timeLabels")
    local tll = api.gui.layout.AbsoluteLayout.new()
    tlc:setLayout(tll)
    tlc:setMinimumSize(api.gui.util.Size.new(WINDOW_WIDTH - STATION_PANEL_WIDTH, TIME_LABEL_HEIGHT))
    tlc:setMaximumSize(api.gui.util.Size.new(WINDOW_WIDTH - STATION_PANEL_WIDTH, TIME_LABEL_HEIGHT))
    menu.timeLabels = {layout = tll, component = tlc, parentLayout = dal}
    dal:addItem(tlc, 0.5, 1); mainLayout:addItem(da)

    local wrapper = api.gui.comp.Component.new("diagramWrapper")
    wrapper:setLayout(mainLayout)
    rebuildPresetList()

    local ttWasVisible = _G._timetableVisible
    local okW2, newWin = pcall(function() return api.gui.comp.Window.new(D.title, wrapper) end)
    if not okW2 or not newWin then debugPrint("Window.new failed"); return end
    menu.window = newWin
    -- 应用已保存的时间标签位置：FloatingLayout 默认 ca 对齐顶、tlc 对齐底（时间标签在下）。
    -- 若玩家上次选了"上"，这里用 setAlignment 把 tlc 移到顶部、ca 移到底部腾出空间。
    pcall(function()
        if timetable.getTimeLabelPos() == "top" then
            menu.appliedTimeLabelPos = "bottom"  -- 强制重排为 top
            applyTimeLabelPosition()
        else
            menu.appliedTimeLabelPos = "bottom"
        end
    end)
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
        pcall(function()
            if not _G._diagramAutoRefresh then return end
            local t = timetableHelper.getTime()
            if not _G._punctLastRefresh then _G._punctLastRefresh = t end
            if t - _G._punctLastRefresh >= 10 then
                _G._punctLastRefresh = t
                doRefreshData()
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
        menu.timeLabels = {}; menu.lineListLayout = nil; menu.lineListComponent = nil
        menu.renderLayout = nil; menu.renderArea = nil
        menu.daLayout = nil; menu.chartArea = nil; menu.appliedTimeLabelPos = nil
        menu.lineScrollArea = nil; menu.presetScrollArea = nil
        stationRowGroups = {}; displayedLines = {}
    end)
end

return diagramGUI
