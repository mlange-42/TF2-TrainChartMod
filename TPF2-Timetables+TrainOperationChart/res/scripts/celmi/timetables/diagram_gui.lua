local timetable = require "celmi/timetables/timetable"
local timetableHelper = require "celmi/timetables/timetable_helper"
local diagramTrains = require "celmi/timetables/diagram_trains"
local diagramLayout = require "celmi/timetables/diagram_layout"
-- The train rotation system is now the separate TrainRoute mod: _G._trainRouteDiagramHook exposes its
-- getDiagramMode()/isConfigLine(), which decide whether to draw in "rotation diagram mode"; without TrainRoute installed the hook is nil
-- and the diagram is drawn in normal mode (same as without a rotation system).

local diagramGUI = {}

-- Rotation diagram mode interface (registered by the TrainRoute mod): whether the line is a configured rotation line and the rotation diagram switch is on
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
-- After adding a preset, the list should scroll to the new preset's header (shown from the top of the viewport); rebuildPresetList records the row
local pendingScrollPresetId = nil
local pendingScrollPresetRow = nil

-- Forward declarations: the following functions are defined by assignment (xxx = function ... end) and may be referenced by
-- closures of other functions before their definition. Lua locals are only visible after their declaration; without forward declarations the references resolve to a nil global
-- ("attempt to call global 'xxx' (a nil value)").
local rebuildPresetList
local saveCurrentPreset

-- Component name counter: must be unique across refresh cycles (AGENTS.md: names of components removed via removeItem may not be
-- released by the engine immediately; recreating with the same name conflicts). Incremented for every station name/time label created on refresh, never repeats.
-- Stored in _G rather than a local: module-level locals don't survive Lua VM reloads, _G survives module reloads.
local function nextLabelName()
    if not _G._diagramLabelCounter then _G._diagramLabelCounter = 0 end
    _G._diagramLabelCounter = _G._diagramLabelCounter + 1
    return _G._diagramLabelCounter
end

local WINDOW_WIDTH = 1200
local WINDOW_HEIGHT = 780
-- The title bar is actually about 36px high (2026-08-16, measured from player logs: da rendered height 930px / 1.25 = 744 = 780 - 36;
-- the old value 30 made the da/ca height estimate 750 while it was actually only 744 -> ca overlapped the time bar)
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

-- Error log: always printed (only triggered on errors, no performance cost)
local function debugPrint(msg) print("[DiagramGUI] " .. msg) end
-- Debug summary log: controlled by the _G._diagramDebug switch (off by default), to avoid flooding the log and I/O
-- with high-frequency summaries on every refresh/save. For troubleshooting, set `_G._diagramDebug=true` in the console.
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
    -- Data safety guard (added 2026-08-09): presets in memory are empty but the save already has presets (loadPresets failed/module reload etc.);
    -- refuse to overwrite the saved configuration with an empty list, so that "the saved railway line configuration gets wiped" can't happen.
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

-- Preset station cleanup (2026-08-16 final design): after removing a station, its checkbox/sort number entry in the preset's stationData is deleted;
-- entries of the other stations are kept as is, sort numbers unchanged (presets are stored by entity key "s_<stationID>", independent of the position in the line).
-- Validity is checked with entityExists (conservative: kept while the entity isn't recycled yet -- a removed station isn't in allStations so it is never
-- applied, harmless; if a rebuilt station reuses the entity ID -> entityExists true -> entry kept, same position treated as the same station).
-- Waypoint entries ("wp_" prefix) are not cleaned up here.
-- When something was deleted, savePresetsToTimetableObject() immediately writes back to the save (dp.presetList) + triggers cross-thread sync.
-- Returns the number of removed entries.
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
        -- The diagram only shows rail lines (the timetable shows all lines, so filtering is done on the diagram side only).
        -- Uses reverse filtering: exclude lines that are definitely non-rail (bus/tram/water/air); empty lines are kept conservatively to avoid wrongly removing them.
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
    -- Line list sorting: ticked lines first + natural sort by line name.
    -- 1) Ticked lines go to the top (user request: after ticking, a refresh moves them all up)
    -- 2) Line names with a "letters+digits" prefix (e.g. G123/G34) compare by (letters, number) -> G1,G2,G10,G21,G111
    -- 3) Everything else (including Chinese) is sorted stably by UTF-8 code point. Sorting Chinese by pinyin initials would need a built-in pinyin table of thousands of characters;
    --    TPF2 has no such library, so it isn't done (this is the part dropped from "hard, so only move ticked lines up").
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
            -- One has a letter/digit prefix and the other doesn't: the one with the prefix comes first
            return ka.p ~= nil
        else
            if tostring(ka.s) ~= tostring(kb.s) then return tostring(ka.s) < tostring(kb.s) end
        end
        -- Same name/same key fallback: stable by line ID
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

-- Compute the y coordinate of each row (sort group) according to the setting:
--   equal    equal spacing
--   distance straight-line distance between stations along the lines (averaged over lines and both directions); adjacent rows not served by any line use the straight-line distance between the two rows' stations
--   time     estimated section running time along the lines (averaged over lines and both directions); missing ones are derived from distance
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

-- Zoom window: map the full chart's row positions (rowFracs, first row 1, last row 0) to y coordinates so that the window's first row is at y = h
-- and its last row at y = 0; rows outside the window are extrapolated with the same scale (may exceed [0,h], clipped when drawing).
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

-- Diagram zoom (2026-08-16 feature): keeps the canvas size and changes the drawn range to zoom the diagram.
--   tStart/tLen = time window (minutes, within 0-60); rStart/rLen = station row window (1-based row rank).
--   active=false -> full view (0-60 minutes, all rows). Reset when the window is closed (temporary viewing aid, not persisted).
local zoomState = {
    active = false,
    tStart = 0,
    tLen = 60,
    rStart = 1,
    rLen = 0,
}

-- Dropdown options for the "time range" (window length, minutes) per time scale (final user decision)
local ZOOM_INTERVAL_OPTIONS = {
    [2] = {60, 30, 20, 10, 6},
    [5] = {60, 30, 20, 10},
    [10] = {60, 40, 30, 20},
}

-- Singleton references to the settings/zoom popups: repeated clicks only raise/re-show the open window instead of creating another one (2026-08-16 feedback).
-- isAttached() detects whether the window has been destroyed (e.g. cleaned up by the engine when reopening the diagram); setVisible(true,true) re-shows/raises it.
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

-- Sorted (ascending) list of unique sort numbers of the current selection (station + waypoint rows of the expanded lines, merged and deduplicated)
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

-- Clamp the zoom window (when the selection changes/out of range): the window must lie within the valid range; if it doesn't actually zoom (full width, all rows) it counts as inactive.
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

-- Build the Y axis mapping: every selected row gets a Y value (2026-08-16 zoom feature).
-- Row positions are computed according to the "station spacing" setting (computeRowYs), then mapped to the zoom window (windowRowYs);
-- rows outside the window are extrapolated with the same window scale and may exceed [0,h] --
-- polyline segments crossing the station window boundary are clipped by drawClippedSegment to the window's Y range [0,dh] (the horizontal cut point is drawn normally,
-- so the line no longer breaks just because stations outside the window had no Y value). Unselected stations of through lines (uniqueKey not in the map) still break the line (original behavior).
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

-- same colors as the punctuality dots of the line list
local LIVE_COLORS = { ontime = {1, 1, 1}, early = {0, 1, 0}, late = {1, 0, 0} }
local LIVE_CLASSES = { "ontime", "early", "late" }

-- The overlay's views in drawing order (later ones on top): the "now" line, whisker edges,
-- whiskers per class, square edges, squares per class. Each has a fixed color and width,
-- because the width applies to the whole view. A dark edge separates the marks from lines of
-- the same color.
local function liveViewSpecs(ctx)
    local half = 4 * ctx.scale
    local edge = 1.5 * ctx.scale
    local specs = { { key = "now", color = {1, 1, 1, 0.35}, width = 1 } }
    specs[#specs + 1] = { key = "wEdge", color = {0, 0, 0, 0.85}, width = 2 + 2 * edge }
    for _, cls in ipairs(LIVE_CLASSES) do
        local c = LIVE_COLORS[cls]
        specs[#specs + 1] = { key = "w_" .. cls, color = {c[1], c[2], c[3], 0.9}, width = 2 }
    end
    specs[#specs + 1] = { key = "sEdge", color = {0, 0, 0, 0.85}, width = 2 * (half + edge), r = half + edge }
    for _, cls in ipairs(LIVE_CLASSES) do
        local c = LIVE_COLORS[cls]
        specs[#specs + 1] = { key = "s_" .. cls, color = {c[1], c[2], c[3], 1}, width = 2 * half, r = half }
    end
    return specs
end

-- Live vehicle overlay: a "now" line and, for every vehicle of the displayed lines, a square at
-- (now, position) plus a whisker back to where the timetable has it now (length = delay),
-- colored like the punctuality dots.
-- The views are created once per chart refresh (rebuild = true, so they stay on top of the new
-- line views) and cleared and refilled on the per-second updates.
---@param rebuild boolean|nil
local function drawLiveOverlay(rebuild)
    local ctx = menu.liveCtx
    if not (ctx and menu.renderLayout and timetable.getShowVehicles()) then
        clearLiveViews()
        return
    end
    local specs = liveViewSpecs(ctx)

    if not rebuild and #menu.liveViews == #specs then
        for _, v in ipairs(menu.liveViews) do v:clear() end
    else
        clearLiveViews()
        for _, sp in ipairs(specs) do
            local v = api.gui.comp.LineRenderView.new()
            v:setMinimumSize(api.gui.util.Size.new(ctx.lw, ctx.lh))
            v:setMaximumSize(api.gui.util.Size.new(ctx.lw, ctx.lh))
            menu.renderLayout:addItem(v, 0.5, 0)
            table.insert(menu.liveViews, v)
        end
    end
    local views = {}
    for i, sp in ipairs(specs) do
        local v = menu.liveViews[i]
        v:setColor(api.type.Vec4f.new(sp.color[1], sp.color[2], sp.color[3], sp.color[4]))
        v:setWidth(sp.width)
        views[sp.key] = { view = v, r = sp.r }
    end

    local now = timetableHelper.getTime()
    local nowM = (now % 3600) / 60
    local tol = timetable.getPunctThreshold()

    local byClass = { ontime = {}, early = {}, late = {} }
    for _, ld in pairs(displayedLines) do
        if ld.checked and ld.runs then
            for _, vehicle in pairs(timetableHelper.getVehiclesOnLine(ld.id)) do
                local okL, m = pcall(locateVehicle, ld, vehicle, now, ctx.yMap, ctx.keepSeg)
                if okL and m and m.y >= 0 and m.y <= ctx.dh then
                    local cls = (m.delay > tol and "late") or (m.delay < -tol and "early") or "ontime"
                    table.insert(byClass[cls], m)
                end
            end
        end
    end

    local nowVisible = nowM >= ctx.tWin0 and nowM <= ctx.tWin1
    local x = ctx.timeX(nowM)
    if nowVisible then
        views.now.view:addLine(api.type.Vec2f.new(x, 0), api.type.Vec2f.new(x, ctx.dh))
    end
    local function drawWhiskers(v, markers)
        for _, m in ipairs(markers) do
            if math.abs(m.delay) >= 1 then
                local t1, t2 = math.min(now, now - m.delay), math.max(now, now - m.delay)
                ctx.drawWrapped(v, t1, m.y, t2, m.y)
            end
        end
    end
    -- a filled square: one short, wide stroke
    local function drawSquares(vs, markers)
        for _, m in ipairs(markers) do
            vs.view:addLine(api.type.Vec2f.new(x - vs.r, m.y), api.type.Vec2f.new(x + vs.r, m.y))
        end
    end
    for _, cls in ipairs(LIVE_CLASSES) do
        local markers = byClass[cls]
        drawWhiskers(views.wEdge.view, markers)
        drawWhiskers(views["w_" .. cls].view, markers)
        if nowVisible then
            drawSquares(views.sEdge, markers)
            drawSquares(views["s_" .. cls], markers)
        end
    end
end

-- Clear the diagram render area (polyline view + station name labels + time labels), all protected by pcall.
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
    -- There may be two time label bars, top and bottom (both are drawn when shown at top and bottom); clear each
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
        -- Fewer than 1 station ticked: don't draw, and clear the leftover previous diagram (including the previous preset's polylines/labels),
        -- so that expanding an empty preset doesn't show stale, misleading graphics.
        clearDiagramViews()
        dbgPrint("refreshDiagram: no stations selected, cleared")
        return
    end

    -- LineRenderView logical component size (displayed scaled up by the engine's UI scale factor),
    -- but addLine uses the component's actual rendered pixel coordinates (affected by scaling), so drawing coordinates must be multiplied by the scale factor:
    -- actual pixels = logical pixels x scale, scale = actual renderArea size / logical size.
    local lw_logical = WINDOW_WIDTH - STATION_PANEL_WIDTH - STATION_LABEL_WIDTH
    -- The logical height follows the "time label position": when shown at top and bottom, the chart gives up space for two label bars (menu.chartH is maintained by applyTimeLabelPosition)
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
            -- renderArea may extend past the window's right/bottom edge due to layout offsets and get clipped (measured: 14px past the right edge).
            -- Compute "visible right edge of the window - renderArea left edge" and shrink dw to fit inside the window, so that the right ends of the border/
            -- polylines/grid are all drawn in the visible area and the four lines meet at the bottom right corner.
            -- When time labels are switched to "top", renderArea moves down and its bottom may also extend past the window's bottom edge (bottom border disappears);
            -- shrink dh into the window the same way, with an extra bottom safety margin (moves everything up).
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
            -- With time labels at the top, renderArea moves down and its bottom may be clipped by the window (bottom border disappears).
            -- Fallback: shrink dh by an additional bottom safety margin (moves everything up), keeping the bottom border away from the component's bottom edge.
            -- With time labels at the bottom, keep dh = rr.h as is (the bottom border touching the component's bottom edge is normal).
            if timetable.getTimeLabelPos() == "top" then
                local bottomPad = 16
                if dh > rr.h - bottomPad then dh = rr.h - bottomPad end
            end
        end
    end)
    local sorts, groups = computeSortRanks(selList)
    local totalRanks = #sorts
    clampZoom(totalRanks)
    -- Zoom window parameters (when inactive = full view, same as the old formula)
    local tWin0 = zoomState.active and zoomState.tStart or 0
    local tWin1 = zoomState.active and (zoomState.tStart + zoomState.tLen) or 60
    local rWin0 = zoomState.active and zoomState.rStart or 1
    local rWinLen = zoomState.active and zoomState.rLen or totalRanks
    local function timeX(m)  -- m = minutes
        return (m - tWin0) / (tWin1 - tWin0) * dw
    end
    -- Margin above the first and below the last row, so markers on those rows are not cut off.
    local margin = math.min(8 * scale, dh / 4)
    local yMap, rowYs = buildYMap(selList, groups, sorts, rWin0, rWinLen, dh - 2 * margin)
    for k, y in pairs(yMap) do yMap[k] = y + margin end
    for i, y in pairs(rowYs) do rowYs[i] = y + margin end

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

    -- The border view bv is created last (on top), otherwise the polylines' cross markers cover the border lines.
    -- Creation order: rv (grid, bottom) -> polylines (middle) -> bv (border, top).
    local rv = makeLRV()
    rv:setColor(api.type.Vec4f.new(0.5, 0.5, 0.5, 0.3))
    rv:setWidth(1)
    -- Vertical time reference line interval = time scale setting (2/5/10 minutes, default 5); the window boundaries (0/60 or tWin0/tWin1) are covered by the border lines.
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
        -- Top margin: the topmost station is at y=0; if rectY were clamped to 0 it would touch the top of the component,
        -- and the upper half of the text would be hidden by the title bar/component edge. Move everything down by a margin so all labels are visible.
        local topPad = labelH / 2
        for idx = rWin0 + rWinLen - 1, rWin0, -1 do
            local sv = sorts[idx]
            local groupStations = groups[sv]
            -- Label text of the row (final user decision 2026-08-16): with a station -> only the station name; without a station (pure waypoint row)
            -- -> the waypoint name (1-2 shown on separate lines, >=3 only the first -- stable, not random).
            -- Waypoint names have the "▶ " prefix used in the list UI removed.
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
                    -- Pure waypoint row: only show the first waypoint (user 2026-08-16: two-line labels are hard to read with equal row spacing,
                    -- so changed to "only show the first one", stable, not random)
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

    -- Refresh a time label bar (shared by top/bottom bars; isTop decides whether text is vertically centered or bottom-aligned)
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
                        -- The time scale setting decides the label step: full view 2 min -> every 4 min (0,4,8...), 5 min -> every 5 min, 10 min -> every 10 min;
                        -- when zoomed, the scale step is used (denser, matching the reference lines).
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
                            -- Bottom bar: text aligned to the container's bottom (gravity 1), moved down about half a character from the centered position,
                            -- so it doesn't touch the diagram's bottom border; the top bar stays vertically centered.
                            -- Note: the label must explicitly fill the TIME_LABEL_HEIGHT height for gravity to work --
                            -- otherwise the TextView sizes itself to the text height and gravity has no effect.
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
    -- Refresh the time bars for the current time label position: both = draw top and bottom; single-bar modes only draw their side
    local tlp = timetable.getTimeLabelPos()
    if tlp ~= "top" and tlp ~= "both" then tlp = "bottom" end
    if tlp == "top" or tlp == "both" then updateTimeBar(menu.timeBarTop, true) end
    if tlp == "bottom" or tlp == "both" then updateTimeBar(menu.timeBarBottom, false) end

    local drawDebug = {}
    -- Platform labels, collected while drawing: {t = absolute seconds, y = px, text}
    local showPlatforms = timetable.getShowPlatforms()
    local platformLabels = {}
    -- Draw a single polyline segment (zoom window aware): first split per hour, then clip each piece to the window.
    -- Clipping uses Liang-Barsky (timetableHelper.clipSegmentToRect), window = visible time range x canvas height
    -- (the station direction is naturally limited by the window -- stations outside the window have no Y value and the polyline is already broken; y clipping is just defensive).
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
        -- Rotation drawing mode: if the line belongs to a rotation configuration (TrainRoute mod hook), only draw up to the transfer station (last station), not the reversal/loop closing segment
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
            -- Track each run by projecting the journey: starting from every slot of the first stop with times, estimate the arrival
            -- at the next station from the section running time and pick the nearest slot (rather than pairing slots by index).
            -- Rotation lines: the last station is the transfer station; trains switch to the next rotation line on arrival, so this line's departure isn't drawn and there is no reversal/loop closing.
            -- The runs are kept for the live vehicle overlay.
            ld.runs = diagramTrains.buildRuns(ld.stations, ld.legTimes or {}, isJRL)
            for _, run in ipairs(ld.runs) do
                local polylines = {}
                local cur = {}
                for vi, visit in ipairs(run) do
                    local st = ld.stations[visit.flatIdx]
                    local y = yMap[st.uniqueKey]
                    if not y then
                        -- This stop is not on the current diagram's vertical axis
                        -- Station: a foreign station of a through run -> option A, break the polyline
                        -- Waypoint: only path control points "passed along the track" -> silently skipped (no point added, no break)
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
                        -- Double filter on time window + station window: cross markers outside the window (including extrapolated out-of-range Y) are not drawn
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

    -- The border view is created last (on top of the polylines), so the polylines' cross markers don't cover the border lines.
    -- addLine uses actual rendered pixel coordinates (dw/dh are already the actual renderArea size, shrunk to fit the window)
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
    drawLiveOverlay(true)

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

-- setContent resets the content view to the top but may keep the old scroll bar value, causing a "content at top, scroll bar at bottom" mismatch
-- (setScrollOffset with the same value doesn't trigger a resync). So reset to zero first, then set the target value, forcing the engine to resync;
-- if the initial capture failed, capture again after layout. Double invokeLater waits for the layout to finish.
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

-- Text and style class of a vehicle's punctuality entry in the line list.
local function punctDisplay(pv)
    local text = D.punct_ontime
    local punctClass = "timetable-punct-ontime"
    local diff = nil
    -- Two stages: before the departure, the arrival decides (early / on time / late);
    -- after the departure, the departure decides. A train that arrived late but departed on
    -- time has caught up and shows "on time".
    if pv.arrDone then
        if pv.depPunct == "late" then
            diff = pv.depDiff
        elseif pv.depPunct == "early" then
            diff = pv.depDiff
        end
    else
        if pv.arrPunct == "early" then
            diff = pv.arrDiff  -- negative (early)
        elseif pv.arrPunct == "late" then
            diff = pv.arrDiff  -- positive (late)
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
    -- dot and text in one TextView ("●On time"); the style class sets the color
    return "●" .. text, punctClass
end

-- Identifies the structure of the line list: the lines (with name, color, check and selection
-- state) and the vehicles listed under each. If it is unchanged, the list is updated in place.
local function lineListSignature()
    local parts = {}
    local punctData = _G._punctuality or {}
    for li, ld in pairs(displayedLines) do
        local c = ld.color
        local vIds = {}
        for vId, pv in pairs(punctData) do
            if pv and pv.lineId and tostring(pv.lineId) == tostring(ld.id) then vIds[#vIds + 1] = tostring(vId) end
        end
        table.sort(vIds)
        parts[#parts + 1] = table.concat({ tostring(li), tostring(ld.id), tostring(ld.name),
            tostring(ld.checked), tostring(ld.bold),
            c and string.format("%.3f,%.3f,%.3f", c.x, c.y, c.z) or "-", table.concat(vIds, ",") }, ";")
    end
    return table.concat(parts, "|")
end

local function updateLineList()
    if not menu.lineScrollArea then return end
    -- Rebuilding the list resets and restores its scroll position, which makes it jump.
    -- Update the punctuality texts in place when the structure did not change.
    local sig = lineListSignature()
    if menu.lineListRows and sig == menu.lineListSig then
        local okIp = pcall(function()
            local punctData = _G._punctuality or {}
            for _, ld in pairs(displayedLines) do
                local row = menu.lineListRows[tostring(ld.id)]
                ld.nameView = row.nameView
                for vId, ptv in pairs(row.punct) do
                    local pv = punctData[vId]
                    if pv then
                        local text, punctClass = punctDisplay(pv)
                        ptv:setText(text, false)
                        ptv:setStyleClassList({"timetable-mono-sc", punctClass})
                    end
                end
            end
        end)
        if okIp then return end
    end
    menu.lineListSig = sig
    menu.lineListRows = {}
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
        -- First count the line's vehicles with punctuality info to decide the row height (punctuality text is part of the line row, stacked vertically right of the color swatch)
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
        -- Minimum row width 220 (same as the left column), maximum relaxed: overly long line names make the row naturally wider,
        -- and the ScrollArea's horizontal scroll bar brings the pushed-out punctuality info back into view (see
        -- lineScrollArea's setHorizontalScrollBarPolicy in showDiagram).
        ic:setMinimumSize(api.gui.util.Size.new(STATION_PANEL_WIDTH, rowH))
        ic:setMaximumSize(api.gui.util.Size.new(600, rowH))

        local row = { punct = {} }
        menu.lineListRows[tostring(ld.id)] = row
        local ckImg = api.gui.comp.ImageView.new(ld.checked and "ui/checkbox1.tga" or "ui/checkbox0.tga")
        local ckBtn = api.gui.comp.Button.new(ckImg, true)
        local lineId = tostring(ld.id)
        ckBtn:onClick(function()
            -- the row is kept across refreshes, which replace the line data: look it up
            local cur = nil
            for _, l in pairs(displayedLines) do
                if tostring(l.id) == lineId then cur = l; break end
            end
            if not cur then return end
            cur.checked = not cur.checked
            pcall(function() ckImg:setImage(cur.checked and "ui/checkbox1.tga" or "ui/checkbox0.tga", false) end)
            pcall(function() refreshDiagram() end)
            -- Save to the current preset immediately after ticking/unticking a line (internally triggers _diagramForceSync),
            -- so the tick state isn't lost when quitting the game/closing the window directly ("doesn't save").
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
        row.nameView = nameTv
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

        -- Punctuality info: dot (●) and text merged into one TextView ("●On time"), both in the punctuality style color
        -- (on time white/early green/late red). No fixed width: the TextView sizes itself to the actual rendered width,
        -- and pvCont follows -- avoids text being clipped due to inaccurate width estimates ("pushed back and hidden").
        -- If the whole row (checkbox + line name + swatch + punctuality) exceeds 220, the row naturally gets wider and the horizontal scroll bar brings it back.
        local pvCont = api.gui.comp.Component.new("pvCont_" .. li)
        local pvl = api.gui.layout.BoxLayout.new("VERTICAL")
        pvCont:setLayout(pvl)
        pvCont:setMinimumSize(api.gui.util.Size.new(0, rowH))
        pvCont:setMaximumSize(api.gui.util.Size.new(600, rowH))
        if punctRowCount > 0 then
            local punctData = _G._punctuality
            for vId, pv in pairs(punctData) do
                if pv and pv.lineId and tostring(pv.lineId) == tostring(ld.id) then
                    local text, punctClass = punctDisplay(pv)
                    local ptv = api.gui.comp.TextView.new(text)
                    ptv:setStyleClassList({"timetable-mono-sc", punctClass})
                    ptv:setMinimumSize(api.gui.util.Size.new(0, 24))
                    ptv:setMaximumSize(api.gui.util.Size.new(600, 24))
                    ptv:setGravity(0, 0.5)
                    row.punct[tostring(vId)] = ptv
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
    -- Restore the scroll position from before the refresh, so the line list doesn't jump back to the top (would disrupt the user's further edits)
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
    -- Line ticks are first all reset to ticked, then overridden by preset.lineData:
    -- station ticks are assigned explicitly (else st.selected = false), but lines used to only override lines present in lineData;
    -- lines not overridden inherited the previous preset's tick state (left fully ticked), so "switching back to a preset ticks everything again".
    -- Resetting before overriding makes line state as deterministic as station state.
    for _, ld in pairs(allLines) do ld.checked = true end
    if preset.lineData then
        for _, ld in pairs(allLines) do
            local chk = preset.lineData[tostring(ld.id)]
            if chk ~= nil then ld.checked = chk end
        end
    end
end

saveCurrentPreset = function()
    -- Only the currently expanded preset may be saved; don't fall back to getActivePreset(),
    -- to avoid writing back an empty configuration while allStations is in its unloaded default state (data loss).
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
    -- Line tick state is saved from allLines (not displayedLines):
    -- displayedLines is only the subset "of lines related to the currently selected stations" and is empty on first open/before drawing;
    -- using it would wrongly clear the saved lineData (i.e. "tick state doesn't save").
    -- allLines is the complete line set, consistent with the applying side applyPresetToStations (which also iterates allLines).
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
        -- the default UI font (Lato) has no triangles; the Noto font has
        tglIcon:setStyleClassList({"timetable-mono-sc"})
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
                -- Expanding a preset expands the line list and immediately draws that preset's diagram.
                -- With fewer than 1 station ticked, refreshDiagram clears the old diagram internally without drawing (new configs: tick stations first, then click refresh).
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
                -- The whole delete confirmation callback is wrapped in pcall: players reported occasional Lua exception crashes when deleting railway line configurations
                -- (e.g. attempt to index nil). pcall catches it so the specific error can be logged and the crash doesn't propagate.
                local okDel, delErr = pcall(function()
                    pcall(function() cw2:setVisible(false, false) end)
                    for i, p in ipairs(localPresets) do if p.id == targetId then table.remove(localPresets, i); break end end
                    if expandedPresetId == targetId then
                        expandedPresetId = nil
                        currentPresetRef = nil
                        -- Deleting the currently expanded preset: clear the line list and diagram to avoid leftover graphics of the deleted preset
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
                    -- Save the current railway line configuration immediately after ticking/unticking a station, no longer relying on the save button
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
                    -- Save immediately after the sort number changes (note: onChange fires per keystroke; only write data here, don't rebuild the UI,
                    -- otherwise the input field loses focus/value, see the AGENTS.md lesson on timetable SpinBox losing values)
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
    -- Restore the scroll position from before the refresh/rebuild, so the railway line list doesn't jump back to the top
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
    -- New presets have all lines ticked by default: explicitly reset allLines.checked (otherwise it inherits the tick state passed on via allLines
    -- from the previous preset, causing "only the first one ticked by default").
    for _, ld in pairs(allLines) do ld.checked = true end
    -- New preset without ticked stations: clear the line list and diagram (don't draw); wait for the player to tick stations and click refresh
    displayedLines = {}
    updateLineList()
    clearDiagramViews()
    pendingScrollPresetId = id
    pendingScrollPresetRow = nil
    rebuildPresetList()
    pendingScrollPresetId = nil
    -- Scroll the preset list so the newly added preset's header becomes visible: use ensureVisible for minimal scrolling,
    -- keeping existing configurations above (e.g. config 11) in the viewport while the new config 12 is visible too.
    -- Must scroll neither to the top nor to the bottom (the new preset is expanded; the bottom only shows its last station row).
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
    -- Fallback save on close: wrapped in pcall, so a Lua error when closing the window after deleting a preset doesn't propagate and crash
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
    -- Remember the line tick state from before the refresh: getAllTimetableData rebuilds allLines (all ticked by default);
    -- restore it after the refresh, so "lines just ticked/unticked" don't get lost by the refresh.
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
    -- Restore the in-memory tick state from before the refresh (consistent with immediate saving; changes made without an expanded preset survive the refresh too)
    for _, ld in pairs(allLines) do
        local pc = prevChecks[tostring(ld.id)]
        if pc ~= nil then ld.checked = pc end
    end
    sortAllStations()
    -- Refresh the line list + redraw the diagram; with fewer than 1 station ticked, refreshDiagram clears the old diagram internally
    displayedLines = getRelevantLines(getSelectedStationList())
    updateLineList()
    if menu.renderLayout and menu.stationLabels and menu.timeBarTop then
        pcall(function() refreshDiagram() end)
    end
    if rebuildList then rebuildPresetList() end
end

-- Apply the "time label position" setting: arrange the chart area (ca, containing station labels + diagram) and the time label bars (top/bottom)
-- in da's FloatingLayout according to the target position. Three states:
--   bottom (default): ca top-aligned (0.5,0) + bottom bar (0.5,1) -> time labels below
--   top: top bar (0.5,0) + ca bottom-aligned (0.5,1) -> time labels above, chart area moved down to make room
--   both: top bar (0.5,0) + ca centered (0.5,0.5) + bottom bar (0.5,1) -> one bar above and one below, chart in between
-- With both, ca's height also gives up room for the second time label bar (visible chart height shrinks by TIME_LABEL_HEIGHT).
-- Switching uses removeItem + addItem(comp, alignX, alignY) again -- addItem is the form renderLayout
-- has always used (FloatingLayout places children by alignment value, verified in AGENTS.md). setAlignment's
-- index can't be obtained reliably from the engine (getItem:getId doesn't match), hence re-adding instead.
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
    -- Skip if already in the target layout (idempotent)
    if menu.appliedTimeLabelPos == pos then
        dbgPrint("applyTimeLabelPosition: already " .. pos .. ", skip")
        return
    end
    -- ca height follows: both = room for two time label bars; single = room for one (station label column/draw area inside ca scale accordingly)
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
    -- ca position: bottom->(0.5,0) top / top->(0.5,1) bottom / both->(0.5,0.5) centered.
    -- In the persistent structure ca is always in dal (added at build time), so removeItem(ca) is always safe; tlcT/tlcB are never removed.
    local ax, ay = 0.5, 0
    if pos == "top" then ay = 1 elseif pos == "both" then ay = 0.5 end
    local prevAy = 0
    local prevPos = menu.appliedTimeLabelPos
    if prevPos == "top" then prevAy = 1 elseif prevPos == "both" then prevAy = 0.5 end
    if prevPos == nil or prevAy ~= ay then
        pcall(function() dal:removeItem(ca) end)
        -- Set the size before re-adding (setting while detached is more reliable), then set it once more after adding
        setH(ca, caW, caH)
        local ok, err = pcall(function() dal:addItem(ca, ax, ay) end)
        if not ok then debugPrint("applyTimeLabelPosition ca addItem FAILED: " .. tostring(err)) end
    end
    setH(ca, caW, caH)
    local slc = menu.stationLabels and menu.stationLabels.component
    if slc then setH(slc, STATION_LABEL_WIDTH, caH) end
    local ra = menu.renderArea
    if ra then setH(ra, raW, caH) end
    -- Time bar visibility: bottom = bottom bar only / top = top bar only / both = both bars
    pcall(function() tlcT:setVisible(pos == "top" or pos == "both", false) end)
    pcall(function() tlcB:setVisible(pos == "bottom" or pos == "both", false) end)
    menu.appliedTimeLabelPos = pos
    dbgPrint("applyTimeLabelPosition: pos=" .. pos .. " caH=" .. caH)
end

-- Diagram zoom window (2026-08-16 feature):
-- keeps the canvas size and changes the drawn range to zoom the diagram.
--  Row 1: time scale (same effect as in settings; changing the scale syncs the setting);
--  Row 2: time range (window length dropdown depending on the scale) + station range (currently visible row count, down to 2);
--  Row 3: OK (apply window size, reset to bottom left and redraw);
--  Pad: arrow buttons pan (time step = scale, station step = 1 row), with bounds protection;
--  Bottom: restore default (back to full view).
function diagramGUI.showZoomWindow()
    local okBody, bodyErr = pcall(function()
        local cc = api.gui.comp.Component.new("zoomContent")
        local cl = api.gui.layout.BoxLayout.new("VERTICAL")
        cc:setLayout(cl)
        cc:setMinimumSize(api.gui.util.Size.new(320, 430))
        cc:setMaximumSize(api.gui.util.Size.new(320, 430))

        -- Time range dropdown items per scale (minutes): "60:00" format
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

        -- Row 1: time scale (same effect as in settings)
        local scaleCb = api.gui.comp.ComboBox.new()
        local SCALE_ITEMS = { D.settings_scale_2, D.settings_scale_5, D.settings_scale_10 }
        local SCALE_VALUES = { 2, 5, 10 }
        for _, it in ipairs(SCALE_ITEMS) do scaleCb:addItem(it) end
        local scaleIdx = 1
        for i, v in ipairs(SCALE_VALUES) do if v == selScale then scaleIdx = i - 1 end end
        pcall(function() scaleCb:setSelected(scaleIdx, false) end)

        -- Row 2: time range (options depend on the scale) + station range
        local intervalCb = api.gui.comp.ComboBox.new()
        local function rebuildIntervalItems(scale, toDefault)
            -- Note: in this TPF2 version the ComboBox:clear() binding signature is void(ComboBox*, bool);
            -- a boolean must be passed (false = don't fire signals); the API docs don't list this parameter (verified error:
            -- "expected boolean, received no value").
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

        rebuildIntervalItems(selScale, true)  -- initial default 60:00
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

        -- Row 3: OK (apply window size, reset to bottom left and redraw)
        local btnRow = api.gui.comp.Component.new("zoomBtns")
        local btnRl = api.gui.layout.BoxLayout.new("HORIZONTAL")
        btnRow:setLayout(btnRl)
        local okBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(D.confirm), true)
        btnRl:addItem(okBtn)
        cl:addItem(btnRow)

        -- Pad: up/down/left/right (cross layout)
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

        -- Bottom: restore default
        local restoreBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(D.zoom_restore), true)
        cl:addItem(restoreBtn)

        okBtn:onClick(function()
            timetable.setTimeScale(selScale)
            zoomState.active = (selInterval < 60 or selStations < totalRanks)
            zoomState.tStart = 0
            zoomState.tLen = selInterval
            zoomState.rStart = 1
            zoomState.rLen = selStations
            _G._diagramForceSync = true  -- persist and sync time scale changes (same effect as in settings)
            pcall(function() refreshDiagram() end)
        end)

        -- Pad panning: time step = scale minutes, station step = 1 row; bounds protection (clamping)
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
        -- Printed unconditionally (not gated by _G._diagramDebug): visible when building the zoom window fails, for troubleshooting
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

    -- Reset zoom when the window is closed (temporary viewing aid, not persisted)
    zoomState.active = false
    -- Reset settings/zoom popup references: when reopening the diagram the old popups have most likely been cleaned up by the engine; avoids stale references
    settingsWinRef = nil
    zoomWinRef = nil
    stationFilterText = ""
    loadPresetsFromTimetableObject()

    -- 2026-08-16 final design: when the diagram window opens,
    -- 1) reconcile timetable data (move surviving stations' times to their new positions after removing/building stations, delete times of removed stations) -- trigger cross-thread sync on changes;
    -- 2) clean up checkbox/sort number entries of deleted stations in presets (other stations keep their sort numbers).
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

    -- Settings button row: at the top of the left panel (above the "Railway lines" title), opens the refresh mode settings popup
    local settingsBar = api.gui.comp.Component.new("settingsBar")
    local sbl = api.gui.layout.BoxLayout.new("HORIZONTAL")
    settingsBar:setLayout(sbl)
    local setBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(D.settings), true)
    setBtn:onClick(function()
        -- Singleton: an already open settings popup is only raised/re-shown, not created again (2026-08-16 feedback)
        if reshowOrReset(settingsWinRef) then return end
        settingsWinRef = nil
        local okSetting, settingErr = pcall(function()
            -- Settings popup:
            -- Section 1 "Refresh rate": tick 10s auto refresh or manual refresh (mutually exclusive)
            -- Section 2 "Time labels": position (top/bottom dropdown) + time scale (2/5/10 min dropdown, default 5 min)
            -- Section 3 "Punctuality threshold": 0/5/10/20/30/40/50/60s dropdown (default 10s)
            -- Section 5 "Station spacing": equal / by distance / by running time dropdown (default equal)
            -- Clicking "OK" applies the settings and refreshes the diagram; settings are stored in timetableObject and saved permanently with the game,
            -- and _diagramForceSync is set to trigger cross-thread sync (GUI -> engine state.timetable).
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
            -- Pending values: only written on "OK" (user request: "click OK to change settings and refresh")
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

            -- Build a "text label + dropdown" row; onChange(i) receives a 0-based index (-1 = empty)
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

            -- Section 1: refresh rate
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

            -- Section 2: time labels (position + time scale)
            cl:addItem(makeSectionLabel(D.settings_time_label))

            local POS_ITEMS = { D.settings_top, D.settings_bottom, D.settings_both }  -- top/bottom/both
            local posCurIdx = 1
            if curPos == "top" then posCurIdx = 0 elseif curPos == "both" then posCurIdx = 2 end
            makeComboRow(D.settings_position, "settingRowPos", POS_ITEMS, posCurIdx, function(i)
                selPos = (i == 0) and "top" or ((i == 2) and "both" or "bottom")
            end)

            local SCALE_ITEMS = { D.settings_scale_2, D.settings_scale_5, D.settings_scale_10 }  -- 2/5/10 min
            local SCALE_VALUES = { 2, 5, 10 }
            local scaleCurIdx = 1
            for i, v in ipairs(SCALE_VALUES) do if v == curScale then scaleCurIdx = i - 1 end end
            makeComboRow(D.settings_time_scale, "settingRowScale", SCALE_ITEMS, scaleCurIdx, function(i)
                selScale = SCALE_VALUES[i + 1] or 5
            end)

            -- Section 3: punctuality threshold
            cl:addItem(makeSectionLabel(D.settings_punct_threshold))

            local PUNCT_VALUES = { 0, 5, 10, 20, 30, 40, 50, 60 }
            local PUNCT_ITEMS = {}
            for _, v in ipairs(PUNCT_VALUES) do PUNCT_ITEMS[#PUNCT_ITEMS + 1] = tostring(v) .. "s" end
            local punctCurIdx = 2   -- default 10s
            for i, v in ipairs(PUNCT_VALUES) do if v == curPunct then punctCurIdx = i - 1 end end
            makeComboRow("", "settingRowPunct", PUNCT_ITEMS, punctCurIdx, function(i)
                selPunct = PUNCT_VALUES[i + 1] or 10
            end)

            -- Section 4: running direction filter (polylines drawn upward only/downward only/all)
            cl:addItem(makeSectionLabel(D.settings_polyline_filter))

            local FILTER_ITEMS = { D.settings_polyline_all, D.settings_polyline_up, D.settings_polyline_down }
            local FILTER_VALUES = { "all", "up", "down" }
            local filterCurIdx = 0
            for i, v in ipairs(FILTER_VALUES) do if v == curFilter then filterCurIdx = i - 1 end end
            makeComboRow("", "settingRowFilter", FILTER_ITEMS, filterCurIdx, function(i)
                selFilter = FILTER_VALUES[i + 1] or "all"
            end)

            -- Section 5: station spacing (equal / by line distance / by running time)
            cl:addItem(makeSectionLabel(D.settings_spacing))

            local SPACING_ITEMS = { D.settings_spacing_equal, D.settings_spacing_distance, D.settings_spacing_time }
            local SPACING_VALUES = { "equal", "distance", "time" }
            local spacingCurIdx = 0
            for i, v in ipairs(SPACING_VALUES) do if v == selSpacing then spacingCurIdx = i - 1 end end
            makeComboRow("", "settingRowSpacing", SPACING_ITEMS, spacingCurIdx, function(i)
                selSpacing = SPACING_VALUES[i + 1] or "distance"
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
                -- Settings are only applied and the diagram refreshed on "OK":
                -- 1) refresh rate (10s auto refresh / manual refresh)
                -- 2) time label position (rearrange chart area + redraw time labels)
                -- 3) time scale (redraw vertical grid lines + time label step)
                -- 4) punctuality threshold (recompute late/on time/early classification)
                -- 5) running direction filter (redraw polylines: upward only/downward only/all)
                -- 6) station spacing (recompute row y coordinates)
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
                    -- Layout switching (ca repositioning/size/time bar visibility) needs a frame for the engine's relayout to settle before refreshing --
                    -- calling doRefreshData immediately reads an unsettled layout (the first switch to "top and bottom" overlapped the top bar with the chart,
                    -- only the second switch was correct, player testing 2026-08-16)
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
    -- Zoom pad button: opens the diagram zoom window (time/station range + pan pad + restore default)
    local zoomBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(D.zoom), true)
    zoomBtn:onClick(function()
        -- Singleton: an already open zoom popup is only raised/re-shown, not created again (2026-08-16 feedback)
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

    -- Search row: a row of its own ("Station search" title + input field).
    -- The old layout put the "Search" title into the "Railway lines" title row; long English words pushed the input field out of the left column where it was hidden;
    -- in a separate row the input field has the full width available.
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
    -- Save button removed: station ticks/sort numbers/line ticks are all saved immediately;
    -- the line list and diagram are triggered by "expand preset" or the "Refresh" button.
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

    -- Punctuality info title: one font size smaller than "Line list" (timetable-mono-sc is 10px), right of the color button
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
    -- Allow horizontal scrolling: when long line names push the punctuality info out, it can be scrolled into view horizontally.
    -- The ScrollBarPolicy enum isn't listed in the official API docs (only setHorizontalScrollBarPolicy is mentioned),
    -- so best effort: skip if the enum path can't be resolved and rely on the ScrollArea's default behavior.
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
    -- A FloatingLayout holds ca (chart area)/tlc (time label bar): children are placed by alignment relative to the parent container
    -- (0 = left/top, 0.5 = center, 1 = right/bottom) and can be switched at runtime via setAlignment(index, x, y).
    -- Note: dynamic rearranging via BoxLayout's removeItem+addItem was verified not to work; AbsoluteLayout's
    -- Rect coordinate semantics differ from LineRenderView (verified: it put ca in the wrong place). FloatingLayout
    -- is the same as renderLayout, and its alignment behavior is reliable.
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
    -- Persistent layout (2026-08-16 refactor, fixes the RemoveChild assert + zero-size top bar issues):
    -- ca (chart area) + top time bar tlcT + bottom time bar tlcB are all added to dal via addItem at build time
    -- (tlcT top 0.5,0 / tlcB bottom 0.5,1, fixed positions); applyTimeLabelPosition only toggles the bars'
    -- visibility and ca's position/size -- **time bars are no longer added/removed dynamically** (the previous version called removeItem on "components not added",
    -- triggering the UI::CComponent::RemoveChild assert; players hit crashes).
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
    -- Apply the saved time label position (bottom/top/both): done uniformly by pos after the window is created
    -- (visibility toggling + ca position/size), when the engine components are actually attached.
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
    -- Auto refresh: with "10s auto refresh" ticked, a full refresh runs every 10s (same as the "Refresh" button:
    -- re-read timetable data + rebuild the line list including punctuality + redraw the diagram).
    menu.window:onStep(function()
        -- live vehicle overlay: redrawn when the game second changes, but at most twice per real
        -- second (os.clock), so fast game speeds do not rebuild the views more often
        pcall(function()
            if not menu.liveCtx then return end
            local t = timetableHelper.getTime()
            if t == menu.liveLastDraw then return end
            local okC, real = pcall(os.clock)
            if okC and real and menu.liveLastReal and real - menu.liveLastReal < 0.5 then return end
            menu.liveLastDraw = t
            menu.liveLastReal = okC and real or nil
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
        menu.lineListRows = nil; menu.lineListSig = nil
        menu.renderLayout = nil; menu.renderArea = nil
        menu.daLayout = nil; menu.chartArea = nil; menu.appliedTimeLabelPos = nil
        menu.timeBarTop = nil; menu.timeBarBottom = nil; menu.chartH = nil
        menu.lineScrollArea = nil; menu.presetScrollArea = nil
        menu.liveViews = {}; menu.liveCtx = nil; menu.liveLastDraw = nil; menu.liveLastReal = nil
        stationRowGroups = {}; displayedLines = {}
    end)
end

return diagramGUI
