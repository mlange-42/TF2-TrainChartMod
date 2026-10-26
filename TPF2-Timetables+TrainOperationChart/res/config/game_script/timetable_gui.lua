local timetable = require "celmi/timetables/timetable"
local timetableHelper = require "celmi/timetables/timetable_helper"
local diagramGUI = require "celmi/timetables/diagram_gui"

-- The train rotation system is now the separate TrainRoute mod (res/scripts/trainroute). This mod no longer requires it,
-- but reads the hooks TrainRoute registers, _G._trainRouteHooks (engine thread) / _G._trainRouteDiagramHook (GUI thread):
-- TrainRoute not installed -> hooks are nil -> behavior is exactly the same as without a rotation system.

local gui = require "gui"

local clockstate = nil

local menu = {window = nil, lineTableItems = {}}

local timetableGUI = {}

local UIState = {
    currentlySelectedLineTableIndex = nil ,
    currentlySelectedStationIndex = nil,
    currentlySelectedConstraintType = nil,
    currentlySelectedStationTabStation = nil
}
local co = nil
local state = nil

local timetableChanged = false
local clearConstraintWindowLaterHACK = nil
local stationSummaryRefreshDue = nil  -- real time (os.clock seconds, runs while paused too) of the delayed refresh of the intermediate station table summary

-- Real-time clock (os.clock, CPU seconds, monotonic): lets the debounce fire even while the game is paused (getTime frozen),
-- used for "auto-refresh the intermediate station table after typing", independent of game world time.
local function realTimeNow()
    local ok, t = pcall(os.clock)
    if ok and t then return t end
    return 0
end

-- ===== Performance optimization group A (2026-08-16, round 21): hoist hot-path pcall targets to module level =====
-- The per-second punctuality scan / slot mirroring calls pcall(function() ... end) several times for "every line x every vehicle",
-- creating a new closure on every execution -> tens of thousands of allocations per second -> shorter Lua GC cycles -> periodic frame drops noticeable to players.
-- Changed to pcall(fn, args...) reusing module-level functions: error protection semantics unchanged, just no garbage.
-- (Function bodies only access api when called -- module top level never touches api, per the AGENTS hard rule.)
local function _entityExists(id) return api.engine.entityExists(id) end
local function _getComponent(id, ctype) return api.engine.getComponent(id, ctype) end
local function _lineVehicleMap() return api.engine.system.transportVehicleSystem.getLine2VehicleMap() end
local function _slotMode(lineID) return timetable.getLineSlotMode(lineID) end
local function _vehCountCfg(lineID) return timetable.getLineVehicleCount(lineID) end
-- Real time in seconds; returns nil if unavailable (keeps the original semantics "skip this time if the clock is unavailable")
local function rawRealSeconds()
    local ok, t = pcall(os.clock)
    if ok and type(t) == "number" then return t end
    return nil
end

-- Component name counter: names of components like ScrollArea must be unique across refresh cycles (AGENTS.md: names of components removed via removeItem
-- may not be released by the engine immediately; creating a component with the same name next time conflicts/addItem fails silently, leading to nil accesses later).
-- When the timetable is rebuilt after its window was destroyed by the diagram's Window.new(), fixed names ("timetable.LineOverview" etc.)
-- would conflict with leftover old names -> crash (attempt to index a nil value). Stored in _G to survive Lua VM reloads.
local function nextScrollName()
    if not _G._ttScrollNameCounter then _G._ttScrollNameCounter = 0 end
    _G._ttScrollNameCounter = _G._ttScrollNameCounter + 1
    return _G._ttScrollNameCounter
end

local stationTableScrollOffset
local lineTableScrollOffset
local constraintTableScrollOffset


local UIStrings = {
        arr	= _("arr_i18n"),
		arrival	= _("arrival_i18n"),
		dep	= _("dep_i18n"),
		departure = _("departure_i18n"),
		unbunch_time = _("unbunch_time_i18n"),
		unbunch	= _("unbunch_i18n"),
		timetable = _("timetable_i18n"),
		timetables = _("timetables_i18n"),
		line = _("line_i18n"),
		lines = _("lines_i18n"),
		min	= _("time_min_i18n"),
		sec	= _("time_sec_i18n"),
		stations = _("stations_i18n"),
		frequency = _("frequency_i18n"),
		journey_time = _("journey_time_i18n"),
		arr_dep	= _("arr_dep_i18n"),
		no_timetable = _("no_timetable_i18n"),
		all	= _("all_i18n"),
		add	= _("add_i18n"),
		none = _("none_i18n"),
		tooltip	= _("tooltip_i18n"),
		waypoint = _("diagram_waypoint_i18n"),
		passing_point = _("diagram_passing_point_i18n"),
		passing = _("diagram_passing_i18n"),
		passing_n = _("diagram_passing_n_i18n"),
		wp_tooltip = _("diagram_wp_tooltip_i18n"),
		name_label = _("diagram_name_i18n"),
		rename_hint = _("diagram_rename_hint_i18n"),
		refresh = _("diagram_refresh_i18n"),
		title_short = _("diagram_title_short_i18n"),
		settings = _("diagram_settings_i18n"),
		delay_tol = _("diagram_delay_tol_i18n"),
		delay_none = _("diagram_delay_none_i18n"),
		data_sync = _("diagram_data_sync_i18n"),
		data_sync_desc = _("diagram_data_sync_desc_i18n"),
		data_sync_result = _("diagram_data_sync_result_i18n"),
		data_sync_none = _("diagram_data_sync_none_i18n"),
		data_sync_line = _("diagram_data_sync_line_i18n"),
		data_sync_station = _("diagram_data_sync_station_i18n"),
		data_sync_sep = _("diagram_data_sync_sep_i18n"),
		confirm = _("diagram_confirm_i18n"),
		separation = _("diagram_separation_i18n"),
		generate = _("diagram_generate_i18n"),
		force_departure = _("diagram_force_departure_i18n"),
		hold_late = _("diagram_hold_late_i18n"),
		hold_late_tooltip = _("diagram_hold_late_tooltip_i18n"),
		min_wait = _("diagram_min_wait_i18n"),
		max_wait = _("diagram_max_wait_i18n"),
		help = _("diagram_help_i18n"),
	}

local local_styles = {
    zh_CN = "timetable-mono-sc",
    zh_TW = "timetable-mono-tc",
    ja = "timetable-mono-ja",
    kr = "timetable-mono-kr"
}

-- Data sync result popup: lists per line "which stations, and how many arrival/departure slot sets were added per station".
-- report = { lines = { [lineKey] = { [stationNumber] = number of added sets } }, totalSlots = N }
local function showSyncResultWindow(report)
    local bodyText
    if report and report.totalSlots and report.totalSlots > 0 and report.lines then
        local lineList = {}
        for lineKey, stations in pairs(report.lines) do
            lineList[#lineList + 1] = { key = lineKey, stations = stations }
        end
        table.sort(lineList, function(a, b)
            return (tonumber(a.key) or 0) < (tonumber(b.key) or 0)
        end)
        local parts = {}
        for _, le in ipairs(lineList) do
            local lineName = timetableHelper.getLineName(le.key)
            if not lineName or lineName == "ERROR" then lineName = le.key end
            local snList = {}
            for sn, cnt in pairs(le.stations) do
                snList[#snList + 1] = { sn = sn, cnt = cnt }
            end
            table.sort(snList, function(a, b) return a.sn < b.sn end)
            local stationParts = {}
            for _, se in ipairs(snList) do
                stationParts[#stationParts + 1] = string.format(UIStrings.data_sync_station, se.sn, se.cnt)
            end
            parts[#parts + 1] = string.format(UIStrings.data_sync_line, lineName) .. table.concat(stationParts, UIStrings.data_sync_sep)
        end
        bodyText = table.concat(parts, "\n")
    else
        bodyText = UIStrings.data_sync_none
    end

    local cc = api.gui.comp.Component.new("dataSyncResultContent")
    local cl = api.gui.layout.BoxLayout.new("VERTICAL")
    cc:setLayout(cl)
    local body = api.gui.comp.TextView.new(bodyText)
    body:setStyleClassList({"timetable-mono-sc"})
    local scroll = api.gui.comp.ScrollArea.new(body, "timetable.dataSyncResultScroll_" .. nextScrollName())
    scroll:setMinimumSize(api.gui.util.Size.new(420, 200))
    scroll:setMaximumSize(api.gui.util.Size.new(420, 260))
    cl:addItem(scroll)

    local blc = api.gui.comp.Component.new("dataSyncResultBtns")
    local bll = api.gui.layout.BoxLayout.new("HORIZONTAL")
    blc:setLayout(bll)
    local okBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(UIStrings.confirm), true)
    bll:addItem(okBtn)
    cl:addItem(blc)

    local okW, win = pcall(function() return api.gui.comp.Window.new(UIStrings.data_sync_result, cc) end)
    if not okW or not win then return end
    win:addHideOnCloseHandler()
    win:setMovable(true)
    win:setSize(api.gui.util.Size.new(440, 310))
    win:setPosition(400, 300)
    okBtn:onClick(function() pcall(function() win:setVisible(false, false) end) end)
end
-------------------------------------------------------------
---------------------- stationTab ---------------------------
-------------------------------------------------------------

function timetableGUI.initStationTab()
    if UIState.floatingLayoutStationTab and menu.stationTabScrollArea then
        pcall(function() UIState.floatingLayoutStationTab:removeItem(menu.stationTabScrollArea) end)
    end
    if UIState.floatingLayoutStationTab and menu.stationTabLinesScrollArea then
        pcall(function() UIState.floatingLayoutStationTab:removeItem(menu.stationTabLinesScrollArea) end)
    end

    --left table
    local stationOverview = api.gui.comp.TextView.new('StationOverview')
    menu.stationTabScrollArea = api.gui.comp.ScrollArea.new(stationOverview, "timetable.stationTabStationOverviewScrollArea_" .. nextScrollName())
    menu.stationTabStationTable = api.gui.comp.Table.new(1, 'SINGLE')
    menu.stationTabScrollArea:setMinimumSize(api.gui.util.Size.new(300, 700))
    menu.stationTabScrollArea:setMaximumSize(api.gui.util.Size.new(300, 700))
    menu.stationTabScrollArea:setContent(menu.stationTabStationTable)
    timetableGUI.fillStationTabStationTable()
    if UIState.floatingLayoutStationTab then UIState.floatingLayoutStationTab:addItem(menu.stationTabScrollArea,0,0) end

    menu.stationTabLinesScrollArea = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('LineOverview'), "timetable.stationTabLinesScrollArea_" .. nextScrollName())
    menu.stationTabLinesTable = api.gui.comp.Table.new(3, 'NONE')
    menu.stationTabLinesScrollArea:setMinimumSize(api.gui.util.Size.new(799, 700))
    menu.stationTabLinesScrollArea:setMaximumSize(api.gui.util.Size.new(799, 700))
    menu.stationTabLinesTable:setColWidth(0,23)
    menu.stationTabLinesTable:setColWidth(1,150)

    menu.stationTabLinesScrollArea:setContent(menu.stationTabLinesTable)
    if UIState.floatingLayoutStationTab then UIState.floatingLayoutStationTab:addItem(menu.stationTabLinesScrollArea,1,0) end
end

function timetableGUI.fillStationTabStationTable()
    menu.stationTabStationTable:deleteAll()
    menu.stationTabEntryData = {}

    local entries = {}
    for sid, _ in pairs(timetable.getAllConditionsOfAllStations()) do
        local name = timetableHelper.getStationName(sid)
        if name and name ~= "ERROR" then
            table.insert(entries, {type = "station", id = sid, name = name})
        end
    end

    local wpData = timetable.getAllWaypointData()
    for gwKey, wp in pairs(wpData) do
        table.insert(entries, {type = "waypoint", gwKey = gwKey, name = "▶ " .. wp.name})
    end

    table.sort(entries, function(a, b) return string.lower(a.name) < string.lower(b.name) end)

    for i, entry in ipairs(entries) do
        menu.stationTabStationTable:addRow({api.gui.comp.TextView.new(entry.name)})
        menu.stationTabEntryData[i - 1] = entry
    end

    menu.stationTabStationTable:onSelect(function(tableIndex)
        if tableIndex == -1 then return end
        UIState.currentlySelectedStationTabStation = tableIndex
        local entry = menu.stationTabEntryData[tableIndex]
        if entry then
            if entry.type == "waypoint" then
                timetableGUI.fillWaypointTabLineTable(entry.gwKey)
            else
                timetableGUI.fillStationTabLineTable(entry.id)
            end
        end
    end)

    if UIState.currentlySelectedStationTabStation
       and menu.stationTabStationTable:getNumRows() > UIState.currentlySelectedStationTabStation then
        menu.stationTabStationTable:select(UIState.currentlySelectedStationTabStation, true)
    end
end

function timetableGUI.fillStationTabLineTable(stationID)

    local lang = api.util.getLanguage()
    local local_style = {local_styles[lang.code]}

    if not stationID or stationID == -1 then return end
    menu.stationTabLinesTable:deleteAll()

    local constraints = timetable.getAllConditionsOfAllStations()[stationID]
    if not constraints then return end

    local lineNames2 ={}
    for k,v in  pairs(constraints) do
        -- Orphaned lines (deleted by the player) are intercepted at multiple levels:
        -- 1) lineExists checks against the current line set of lineSystem.getLines() (most reliable, deleted lines are never in it);
        -- 2) getLineName returning "ERROR" as a fallback (covers the extreme case of getLines failing).
        -- Note: calling getComponent on a deleted line may trigger a C++ assert (AGENTS.md),
        -- so lineExists intercepts first before getLineName is called, never reaching getComponent.
        if not timetable.lineExists(k) then goto continueStationLine end
        local lineName = timetableHelper.getLineName(k)
        if lineName == "ERROR" then goto continueStationLine end
        lineNames2[#lineNames2 + 1] = lineName

        local lineColour2 = api.gui.comp.LineRenderView.new()
        lineColour2:setMinimumSize(api.gui.util.Size.new(28, 28))
        lineColour2:setMaximumSize(api.gui.util.Size.new(28, 28))
        local lc2 = timetableHelper.getLineColourVec4(tonumber(k))
        if lc2 then lineColour2:setColor(lc2) end
        lineColour2:setWidth(4)
        for y = 4, 24, 2 do
            lineColour2:addLine(api.type.Vec2f.new(4, y), api.type.Vec2f.new(24, y))
        end

        local type = timetableHelper.conditionToString(v.conditions[v.conditions.type], v.conditions.type)
        local stConditionString = api.gui.comp.TextView.new(type)
        stConditionString:setName("conditionString")
        stConditionString:setStyleClassList(local_style)
        menu.stationTabLinesTable:addRow({lineColour2, api.gui.comp.TextView.new(lineName), stConditionString})
        ::continueStationLine::
    end
    local order = timetableHelper.getOrderOfArray(lineNames2)
    menu.stationTabLinesTable:setOrder(order)

end

function timetableGUI.fillWaypointTabLineTable(gwKey)
    local lang = api.util.getLanguage()
    local local_style = {local_styles[lang.code]}

    if not gwKey then return end
    menu.stationTabLinesTable:deleteAll()

    local wpData = timetable.getAllWaypointData()
    local wp = wpData and wpData[gwKey]
    if not wp or not wp.lines then return end

    local lineNames = {}
    for lineStr, data in pairs(wp.lines) do
        -- Orphaned lines (deleted by the player) are intercepted twice: first via the getLines set (reliable),
        -- then via getLineName returning "ERROR" as a fallback.
        if not timetable.lineExists(lineStr) then goto continueWaypointLine end
        local lineName = timetableHelper.getLineName(lineStr)
        if lineName == "ERROR" then goto continueWaypointLine end
        table.insert(lineNames, lineName)

        local lineColour = api.gui.comp.LineRenderView.new()
        lineColour:setMinimumSize(api.gui.util.Size.new(28, 28))
        lineColour:setMaximumSize(api.gui.util.Size.new(28, 28))
        local lc3 = timetableHelper.getLineColourVec4(tonumber(lineStr))
        if lc3 then lineColour:setColor(lc3) end
        lineColour:setWidth(4)
        for y = 4, 24, 2 do
            lineColour:addLine(api.type.Vec2f.new(4, y), api.type.Vec2f.new(24, y))
        end

        local parts = {}
        for _, t in ipairs(data.times) do
            table.insert(parts, string.format("%02d:%02d", t[1], t[2]))
        end
        local timeStr = UIStrings.passing .. ": " .. table.concat(parts, " ")
        local timeText = api.gui.comp.TextView.new(timeStr)
        timeText:setName("conditionString")
        timeText:setStyleClassList(local_style)

        menu.stationTabLinesTable:addRow({lineColour, api.gui.comp.TextView.new(lineName), timeText})
        ::continueWaypointLine::
    end

    local order = timetableHelper.getOrderOfArray(lineNames)
    menu.stationTabLinesTable:setOrder(order)
end

-------------------------------------------------------------
---------------------- SETUP --------------------------------
-------------------------------------------------------------

function timetableGUI.initLineTable()
    -- Make sure the component belongs to the current layout before removeItem: the reopen path (showLineMenu) already reset menu.scrollArea=nil;
    -- only remove here if it actually exists and belongs to the current layout (avoids duplicate addItem when initLineTable is called repeatedly during normal operation).
    if menu.scrollArea then
        pcall(function()
            local tmp = menu.scrollArea:getScrollOffset()
            lineTableScrollOffset = api.type.Vec2i.new(tmp.x, tmp.y)
        end)
        pcall(function() UIState.boxlayout2:removeItem(menu.scrollArea) end)
    else
        lineTableScrollOffset = api.type.Vec2i.new()
    end

    menu.scrollArea = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('LineOverview'), "timetable.LineOverview_" .. nextScrollName())
    menu.lineTable = api.gui.comp.Table.new(3, 'SINGLE')
    menu.lineTable:setColWidth(0,28)

    menu.lineTable:onSelect(function(index)
        if not index == -1 then UIState.currentlySelectedLineTableIndex = index end
        UIState.currentlySelectedStationIndex = 0
        timetableGUI.fillStationTable(index, true)
    end)

    menu.lineTable:setColWidth(1,240)

    menu.scrollArea:setMinimumSize(api.gui.util.Size.new(300, 670))
    menu.scrollArea:setMaximumSize(api.gui.util.Size.new(300, 670))
    menu.scrollArea:setContent(menu.lineTable)

    timetableGUI.fillLineTable()

    UIState.boxlayout2:addItem(menu.scrollArea,0,1)
end

function timetableGUI.initStationTable()
    -- Make sure the component belongs to the current layout before removeItem: the reopen path (showLineMenu) already reset the references to nil.
    -- The line control switch row (stationHeaderRow) is removed before the scroll area (rebuilt on every init, prevents piling up).
    if menu.stationHeaderRow then
        pcall(function() UIState.boxlayout2:removeItem(menu.stationHeaderRow) end)
        menu.stationHeaderRow = nil
        menu.stationHeaderRowLineID = nil
    end
    if menu.stationScrollArea then
        pcall(function()
            local tmp = menu.stationScrollArea:getScrollOffset()
            stationTableScrollOffset = api.type.Vec2i.new(tmp.x, tmp.y)
        end)
        pcall(function() UIState.boxlayout2:removeItem(menu.stationScrollArea) end)
    else
        stationTableScrollOffset = api.type.Vec2i.new()
    end

    menu.stationScrollArea = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('stationScrollArea'), "timetable.stationScrollArea_" .. nextScrollName())
    menu.stationTable = api.gui.comp.Table.new(4, 'SINGLE')
    menu.stationTable:setColWidth(0,40)
    menu.stationTable:setColWidth(1,120)
    -- Height 670: 34px at the top are left for the "line control switch row" (refreshStationHeaderRow places it at (0.5,0)),
    -- the scroll area goes at (0.5,1) -- the same FloatingLayout anchor layout as the left column's "sort row on top/list below"; total height stays ~700.
    menu.stationScrollArea:setMinimumSize(api.gui.util.Size.new(500, 670))
    menu.stationScrollArea:setMaximumSize(api.gui.util.Size.new(500, 670))
    menu.stationScrollArea:setContent(menu.stationTable)
    UIState.boxlayout2:addItem(menu.stationScrollArea,0.5,1)
end

function timetableGUI.initConstraintTable()
    -- Make sure the component belongs to the current layout before removeItem: the reopen path (showLineMenu) already reset the references to nil.
    if menu.scrollAreaConstraint then
        pcall(function()
            local tmp = menu.scrollAreaConstraint:getScrollOffset()
            constraintTableScrollOffset = api.type.Vec2i.new(tmp.x, tmp.y)
        end)
        pcall(function() UIState.boxlayout2:removeItem(menu.scrollAreaConstraint) end)
    else
        constraintTableScrollOffset = api.type.Vec2i.new()
    end

    menu.scrollAreaConstraint = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('scrollAreaConstraint'), "timetable.scrollAreaConstraint_" .. nextScrollName())
    menu.constraintTable = api.gui.comp.Table.new(1, 'NONE')
    menu.scrollAreaConstraint:setMinimumSize(api.gui.util.Size.new(300, 700))
    menu.scrollAreaConstraint:setMaximumSize(api.gui.util.Size.new(300, 700))
    menu.scrollAreaConstraint:setContent(menu.constraintTable)
    UIState.boxlayout2:addItem(menu.scrollAreaConstraint,1,0)
end

function timetableGUI.showLineMenu()
    if menu.window ~= nil then
        -- Reopen path: the window is hidden via addHideOnCloseHandler, not destroyed, so its layout/components are still alive.
        -- Just show it, never rebuild the layout (a new layout not attached to the window, or removeItem on old components, both cause problems).
        local ok = pcall(function()
            menu.window:setVisible(true, true)
        end)
        if ok then
            _G._timetableVisible = true
            return
        end
        -- setVisible failing means the window is invalid; reset and create from scratch
        menu.window = nil
        menu.lineTableItems = {}
        menu.scrollArea = nil
        menu.lineHeader = nil
        menu.stationScrollArea = nil
        menu.stationHeaderRow = nil
        menu.stationHeaderRowLineID = nil
        menu.stationTable = nil
        menu.scrollAreaConstraint = nil
        menu.constraintTable = nil
    end

    UIState.boxlayout2 = api.gui.layout.FloatingLayout.new(0,1)
    UIState.boxlayout2:setGravity(-1,-1)

    timetableGUI.initLineTable()
    timetableGUI.initStationTable()
    timetableGUI.initConstraintTable()

    -- Setting up Line Tab
    menu.tabWidget = api.gui.comp.TabWidget.new("NORTH")
    local wrapper = api.gui.comp.Component.new("wrapper")
    wrapper:setLayout(UIState.boxlayout2 )
    menu.tabWidget:addTab(api.gui.comp.TextView.new(UIStrings.lines), wrapper)


    UIState.floatingLayoutStationTab = api.gui.layout.FloatingLayout.new(0,1)
    UIState.floatingLayoutStationTab:setGravity(-1,-1)

    timetableGUI.initStationTab()
    local wrapper2 = api.gui.comp.Component.new("wrapper2")
    wrapper2:setLayout(UIState.floatingLayoutStationTab)
    menu.tabWidget:addTab(api.gui.comp.TextView.new(UIStrings.stations),wrapper2)

    -- Settings tab: delay tolerance (global setting, saved permanently with the game; 0 = none)
    local wrapper3 = api.gui.comp.Component.new("wrapper3")
    local settingsLayout = api.gui.layout.BoxLayout.new("VERTICAL")
    wrapper3:setLayout(settingsLayout)
    local tolRow = api.gui.comp.Component.new("delayTolRow")
    local tolRowLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
    tolRow:setLayout(tolRowLayout)
    local tolLabel = api.gui.comp.TextView.new(UIStrings.delay_tol)
    tolLabel:setStyleClassList({"timetable-mono-sc"})
    tolRowLayout:addItem(tolLabel)
    -- Options: none / 5:00 / 10:00 / 20:00 / 30:00 (seconds)
    local TOL_OPTIONS = {
        { 0,    UIStrings.delay_none },
        { 300,  "5:00" },
        { 600,  "10:00" },
        { 1200, "20:00" },
        { 1800, "30:00" },
    }
    local tolCombo = api.gui.comp.ComboBox.new()
    for _, o in ipairs(TOL_OPTIONS) do tolCombo:addItem(o[2]) end
    local curTol = timetable.getDelayTolerance()
    local curTolIdx = 0
    for i, o in ipairs(TOL_OPTIONS) do
        if o[1] == curTol then curTolIdx = i - 1 end
    end
    tolCombo:setSelected(curTolIdx, false)
    tolCombo:onIndexChanged(function(i)
        if i == -1 then return end
        local v = TOL_OPTIONS[i + 1] and TOL_OPTIONS[i + 1][1] or 0
        pcall(function()
            timetable.setDelayTolerance(v)
            timetableChanged = true
        end)
    end)
    tolRowLayout:addItem(tolCombo)
    settingsLayout:addItem(tolRow)

    -- Data sync: migrate time data of the old mod (number format) to this mod (string format), appending without overwriting.
    -- Triggered explicitly by the user (no automatic migration on load, so the user is aware). After syncing, show the result popup and refresh the UI.
    local syncRow = api.gui.comp.Component.new("dataSyncRow")
    local syncRowLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
    syncRow:setLayout(syncRowLayout)
    local syncBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(UIStrings.data_sync), true)
    syncRowLayout:addItem(syncBtn)
    settingsLayout:addItem(syncRow)
    local syncDesc = api.gui.comp.TextView.new(UIStrings.data_sync_desc)
    syncDesc:setStyleClassList({"timetable-mono-sc"})
    settingsLayout:addItem(syncDesc)

    syncBtn:onClick(function()
        pcall(function()
            local report = timetable.migrateNumberLineKeys()
            timetableChanged = true
            -- After syncing, refresh the currently open timetable UI (line table + intermediate station table + right constraint window) so added times are visible immediately
            pcall(function() timetableGUI.fillLineTable() end)
            local idx = UIState.currentlySelectedLineTableIndex
            if idx ~= nil then
                local lines = timetableHelper.getAllRailLines()
                if lines and lines[idx + 1] then
                    timetableGUI.refreshTimetableUI(lines[idx + 1].id)
                end
            end
            showSyncResultWindow(report)
        end)
    end)

    menu.tabWidget:addTab(api.gui.comp.TextView.new(UIStrings.settings), wrapper3)

    -- Help page (to the right of the "Settings" tab, a separate page next to it -- final user decision, no popup):
    -- explains how the line control switches (depart on time / min / max dwell time) combine. The long help text is inlined per language
    -- (one Chinese version each for zh_CN/zh_TW, English for all other languages) instead of going line by line through strings.lua (i18n convention: non-Chinese = English).
    local helpText = nil
    do
        local helpLang = api.util.getLanguage()
        local hlc = (helpLang and helpLang.code) or "en"
        if hlc == "zh_CN" then
            helpText = {
                { 0, "【线路控车 说明】" },
                { 0, "◇ 到点发车 ✓：" },
                { 1, "到点强制发车，无论装卸是否完成。" },
                { 1, "（勾选后 最小/最大停站时间 会自动清空、不可再勾）" },
                { 0, "◇ 到点发车 ✗：可单独或组合勾选 最小/最大停站时间。" },
                { 0, "■ 勾 最小停站时间：" },
                { 1, "列车在站内至少停满“最小停站时间”。" },
                { 1, "· 装卸完成：发车时刻未到 → 等到点再发车；" },
                { 2, "已过发车时刻 → 停满最小时间后发车（晚点超容差仍扣到下一趟）。" },
                { 1, "· 装卸未完成：继续装卸，装完后再按上条判定。" },
                { 1, "※ 游戏默认最小停站时间 = 0 秒，不调大则此勾选无实际效果。" },
                { 0, "■ 勾 最大停站时间：" },
                { 1, "给停站时长设上限，防止“死等下一趟 / 装卸拖沓”。" },
                { 1, "· 发车时刻未到：自由装卸，等到点，到点发车（装没装完都发）。" },
                { 1, "· 已过发车时刻：" },
                { 2, "装完且晚点在容差内 → 立刻发车；" },
                { 2, "装完但晚点超容差 / 一直没装完 → 最迟停到“到站+最大停站时间”强制发车。" },
                { 0, "■ 最小+最大 同时勾：" },
                { 1, "停站时长限制在 [最小, 最大] 区间内（上面两条合并）。" },
            }
        elseif hlc == "zh_TW" then
            helpText = {
                { 0, "【線路控車 說明】" },
                { 0, "◇ 到點發車 ✓：" },
                { 1, "到點強制發車，無論裝卸是否完成。" },
                { 1, "（勾選後 最小/最大停站時間 會自動清空、不可再勾）" },
                { 0, "◇ 到點發車 ✗：可單獨或組合勾選 最小/最大停站時間。" },
                { 0, "■ 勾 最小停站時間：" },
                { 1, "列車在站內至少停滿「最小停站時間」。" },
                { 1, "· 裝卸完成：發車時刻未到 → 等到點再發車；" },
                { 2, "已過發車時刻 → 停滿最小時間後發車（晚點超容差仍扣到下一趟）。" },
                { 1, "· 裝卸未完成：繼續裝卸，裝完後再按上條判定。" },
                { 1, "※ 遊戲預設最小停站時間 = 0 秒，不調大則此勾選無實際效果。" },
                { 0, "■ 勾 最大停站時間：" },
                { 1, "給停站時長設上限，防止「死等下一趟 / 裝卸拖沓」。" },
                { 1, "· 發車時刻未到：自由裝卸，等到點，到點發車（裝沒裝完都發）。" },
                { 1, "· 已過發車時刻：" },
                { 2, "裝完且晚點在容差內 → 立刻發車；" },
                { 2, "裝完但晚點超容差 / 一直沒裝完 → 最遲停到「到站+最大停站時間」強制發車。" },
                { 0, "■ 最小+最大 同時勾：" },
                { 1, "停站時長限制在 [最小, 最大] 區間內（上面兩條合併）。" },
            }
        else
            helpText = {
                { 0, "[Line control switches]" },
                { 0, "◇ Force departure ✓:" },
                { 1, "Departure is FORCED at the scheduled time, even if loading is not finished." },
                { 1, "(Ticking it clears and disables Min./Max. wait)" },
                { 0, "◇ Force departure ✗ — tick Min./Max. wait alone or together:" },
                { 0, "■ Min. wait ticked:" },
                { 1, "The train must stay at the station at least the \"min waiting time\"." },
                { 1, "· Loading finished: before departure time → wait until it departs;" },
                { 2, "past departure time → leave once the min. time is met (still waits for" },
                { 2, "the next slot if the delay exceeds the tolerance)." },
                { 1, "· Loading not finished: keep loading, then apply the rules above." },
                { 1, "Note: the game default min waiting time is 0 s — no real effect unless raised." },
                { 0, "■ Max. wait ticked:" },
                { 1, "Caps the dwell time (avoids waiting forever / endless loading)." },
                { 1, "· Before departure time: load freely; leave AT the departure time" },
                { 2, "(forced, even if loading is unfinished)." },
                { 1, "· Past departure time:" },
                { 2, "loading done & delay within tolerance → leave immediately;" },
                { 2, "loading done but beyond tolerance, or still loading → forced out no" },
                { 2, "later than \"arrival + max waiting time\"." },
                { 0, "■ Min. + Max. both ticked:" },
                { 1, "Dwell time is clamped to the [min, max] interval (rules above combined)." },
            }
        end
    end
    local wrapper4 = api.gui.comp.Component.new("wrapper4")
    local helpLayout = api.gui.layout.BoxLayout.new("VERTICAL")
    wrapper4:setLayout(helpLayout)
    local helpLang = api.util.getLanguage()
    local helpStyle = local_styles[helpLang and helpLang.code or "en"]
    for _, li in ipairs(helpText) do
        if li[2] == "" then
            local spacer = api.gui.comp.Component.new("helpSpacer")
            spacer:setMinimumSize(api.gui.util.Size.new(10, 8))
            spacer:setMaximumSize(api.gui.util.Size.new(10, 8))
            helpLayout:addItem(spacer)
        else
            local t = api.gui.comp.TextView.new(string.rep("   ", li[1]) .. li[2])
            if helpStyle then t:setStyleClassList({ helpStyle }) end
            helpLayout:addItem(t)
        end
    end
    menu.tabWidget:addTab(api.gui.comp.TextView.new(UIStrings.help), wrapper4)

    menu.tabWidget:onCurrentChanged(function(i)
        if i == 1 then
            timetableGUI.fillStationTabStationTable()
        end
    end)

    -- create final window
    local okW, newWin = pcall(function() return api.gui.comp.Window.new(UIStrings.timetables, menu.tabWidget) end)
    if not okW or not newWin then
        print("[TimetableGUI] Window.new failed")
        return
    end
    menu.window = newWin
    _G._timetableWindow = menu.window
    _G._timetableVisible = true
    menu.window:addHideOnCloseHandler()
    menu.window:setMovable(true)
    menu.window:setPinButtonVisible(true)
    menu.window:setResizable(false)
    menu.window:setSize(api.gui.util.Size.new(1100, 780))
    menu.window:setPosition(200,200)
    menu.window:onClose(function()
        menu.lineTableItems = {}
        menu.scrollArea = nil
        menu.stationScrollArea = nil
        menu.stationHeaderRow = nil
        menu.stationHeaderRowLineID = nil
        menu.scrollAreaConstraint = nil
        menu.lineHeader = nil
        menu.stationTabScrollArea = nil
        menu.stationTabLinesScrollArea = nil
        clearConstraintWindowLaterHACK = nil
        stationSummaryRefreshDue = nil
        timetableChanged = false
        _G._timetableVisible = false
        -- This window has been destroyed/closed; clear the global reference: the diagram's showDiagram invokeLater calls
        -- setVisible(true,false) on _G._timetableWindow to try to restore the timetable window --
        -- if the reference points to a destroyed window, it operates on an invalid component (crash). With it cleared, the restore logic is skipped naturally.
        if _G._timetableWindow == menu.window then
            _G._timetableWindow = nil
        end
        menu.window = nil
    end)

end

-------------------------------------------------------------
---------------------- LEFT TABLE ---------------------------
-------------------------------------------------------------

function timetableGUI.fillLineTable()
    menu.lineTable:deleteRows(0,menu.lineTable:getNumRows())
    if not (menu.lineHeader == nil) then menu.lineHeader:deleteRows(0,menu.lineHeader:getNumRows()) end

    menu.lineHeader = api.gui.comp.Table.new(6, 'None')
    local sortAll   = api.gui.comp.ToggleButton.new(api.gui.comp.TextView.new(UIStrings.all))
    local sortBus   = api.gui.comp.ToggleButton.new(api.gui.comp.ImageView.new("ui/icons/game-menu/hud_filter_road_vehicles.tga"))
    local sortTram  = api.gui.comp.ToggleButton.new(api.gui.comp.ImageView.new("ui/TimetableTramIcon.tga"))
    local sortRail  = api.gui.comp.ToggleButton.new(api.gui.comp.ImageView.new("ui/icons/game-menu/hud_filter_trains.tga"))
    local sortWater = api.gui.comp.ToggleButton.new(api.gui.comp.ImageView.new("ui/icons/game-menu/hud_filter_ships.tga"))
    local sortAir   = api.gui.comp.ToggleButton.new(api.gui.comp.ImageView.new("ui/icons/game-menu/hud_filter_planes.tga"))

    menu.lineHeader:addRow({sortAll,sortBus,sortTram,sortRail,sortWater,sortAir})

    local lineNames = {}
    for k,v in pairs(timetableHelper.getAllRailLines()) do
        local lineColour = api.gui.comp.LineRenderView.new()
        lineColour:setMinimumSize(api.gui.util.Size.new(28, 40))
        lineColour:setMaximumSize(api.gui.util.Size.new(28, 40))
        local lc = timetableHelper.getLineColourVec4(v.id)
        if lc then lineColour:setColor(lc) end
        lineColour:setWidth(4)
        for y = 4, 24, 2 do
            lineColour:addLine(api.type.Vec2f.new(4, y), api.type.Vec2f.new(24, y))
        end
        local lineName = api.gui.comp.TextView.new(v.name)
        lineNames[k] = v.name
        lineName:setName("timetable-linename")
        local buttonImage = api.gui.comp.ImageView.new("ui/checkbox0.tga")
        if timetable.hasTimetable(v.id) then buttonImage:setImage("ui/checkbox1.tga", false) end
        local button = api.gui.comp.Button.new(buttonImage, true)
        button:setStyleClassList({"timetable-avtivateTimetableButton"})
        button:setGravity(1,0.5)
        button:onClick(function()
            local imageVeiw = buttonImage
            local hasTimetable = timetable.hasTimetable(v.id)
            if  hasTimetable then
                timetable.setHasTimetable(v.id,false)
                timetableChanged = true
                imageVeiw:setImage("ui/checkbox0.tga", false)
                -- start all stopped vehicles again if the timetable is disabled for this line
                timetable.startAllLineVehicles(v.id)
            else
                timetable.setHasTimetable(v.id,true)
                timetableChanged = true
                imageVeiw:setImage("ui/checkbox1.tga", false)
            end
        end)
        menu.lineTableItems[#menu.lineTableItems + 1] = {lineColour, lineName, button}
        menu.lineTable:addRow({lineColour,lineName, button})
    end

    local order = timetableHelper.getOrderOfArray(lineNames)
    menu.lineTable:setOrder(order)

    sortAll:onToggle(function() pcall(function()
        for _,v in pairs(menu.lineTableItems) do
                v[1]:setVisible(true,false)
                v[2]:setVisible(true,false)
                v[3]:setVisible(true,false)
        end
        sortBus:setSelected(false,false)
        sortTram:setSelected(false,false)
        sortRail:setSelected(false,false)
        sortWater:setSelected(false,false)
        sortAir:setSelected(false,false)
        sortAll:setSelected(true,false)
    end) end)

    sortBus:onToggle(function() pcall(function()
        local linesOfType = timetableHelper.isLineOfType("ROAD")
        for k,v in pairs(menu.lineTableItems) do
            if not(linesOfType[k] == nil) then
                v[1]:setVisible(linesOfType[k],false)
                v[2]:setVisible(linesOfType[k],false)
                v[3]:setVisible(linesOfType[k],false)
            end
        end
        sortBus:setSelected(true,false)
        sortTram:setSelected(false,false)
        sortRail:setSelected(false,false)
        sortWater:setSelected(false,false)
        sortAir:setSelected(false,false)
        sortAll:setSelected(false,false)
    end) end)

    sortTram:onToggle(function() pcall(function()
        local linesOfType = timetableHelper.isLineOfType("TRAM")
        for k,v in pairs(menu.lineTableItems) do
            if not(linesOfType[k] == nil) then
                v[1]:setVisible(linesOfType[k],false)
                v[2]:setVisible(linesOfType[k],false)
                v[3]:setVisible(linesOfType[k],false)
            end
        end
        sortBus:setSelected(false,false)
        sortTram:setSelected(true,false)
        sortRail:setSelected(false,false)
        sortWater:setSelected(false,false)
        sortAir:setSelected(false,false)
        sortAll:setSelected(false,false)
    end) end)

    sortRail:onToggle(function() pcall(function()
        local linesOfType = timetableHelper.isLineOfType("RAIL")
        for k,v in pairs(menu.lineTableItems) do
            if not(linesOfType[k] == nil) then
                v[1]:setVisible(linesOfType[k],false)
                v[2]:setVisible(linesOfType[k],false)
                v[3]:setVisible(linesOfType[k],false)
            end
        end
        sortBus:setSelected(false,false)
        sortTram:setSelected(false,false)
        sortRail:setSelected(true,false)
        sortWater:setSelected(false,false)
        sortAir:setSelected(false,false)
        sortAll:setSelected(false,false)
    end) end)

    sortWater:onToggle(function() pcall(function()
        local linesOfType = timetableHelper.isLineOfType("WATER")
        for k,v in pairs(menu.lineTableItems) do
            if not(linesOfType[k] == nil) then
                v[1]:setVisible(linesOfType[k],false)
                v[2]:setVisible(linesOfType[k],false)
                v[3]:setVisible(linesOfType[k],false)
            end
        end
        sortBus:setSelected(false,false)
        sortTram:setSelected(false,false)
        sortRail:setSelected(false,false)
        sortWater:setSelected(true,false)
        sortAir:setSelected(false,false)
        sortAll:setSelected(false,false)
    end) end)

    sortAir:onToggle(function() pcall(function()
        local linesOfType = timetableHelper.isLineOfType("AIR")
        for k,v in pairs(menu.lineTableItems) do
            if not(linesOfType[k] == nil) then
                v[1]:setVisible(linesOfType[k],false)
                v[2]:setVisible(linesOfType[k],false)
                v[3]:setVisible(linesOfType[k],false)
            end
        end
        sortBus:setSelected(false,false)
        sortTram:setSelected(false,false)
        sortRail:setSelected(false,false)
        sortWater:setSelected(false,false)
        sortAir:setSelected(true,false)
        sortAll:setSelected(false,false)
    end) end)

    UIState.boxlayout2:addItem(menu.lineHeader,0,0)
    menu.scrollArea:invokeLater( function () menu.scrollArea:invokeLater(function () pcall(function() menu.scrollArea:setScrollOffset(lineTableScrollOffset) end) end) end)

end

-------------------------------------------------------------
---------------------- Middle TABLE -------------------------
-------------------------------------------------------------

-- Line control switch row (2026-08-16 feature): frequency + depart on time / minimum dwell time / maximum dwell time.
-- A separate fixed row above the intermediate station table's scroll area at (0.5,0) -- **not put into Table:setHeader**: header cells
-- are not clickable at the engine level, and the limited row height clips text (player testing 2026-08-16: ticked by default but not clickable, bottom of the frequency hidden).
-- Reuses the left column's pattern of "sort button row above the list": not rebuilt for the same line (prevents refresh flicker); only on a line change is the
-- old row removed via removeItem and the new one added via addItem. Checkbox interaction mirrors the left column's "follow timetable" checkbox (Button with swapped image, verified clickable).
function timetableGUI.refreshStationHeaderRow(lineID)
    if menu.stationHeaderRow and menu.stationHeaderRowLineID == lineID then
        return  -- same line: the row is already in the layout, don't rebuild (fillStationTable comes here on every refresh)
    end
    if menu.stationHeaderRow then
        pcall(function() UIState.boxlayout2:removeItem(menu.stationHeaderRow) end)
        menu.stationHeaderRow = nil
    end
    menu.stationHeaderRowLineID = lineID
    if not lineID then return end

    local freqLbl = api.gui.comp.TextView.new(UIStrings.frequency .. " " .. timetableHelper.getFrequency(lineID))
    freqLbl:setStyleClassList({"timetable-mono-sc"})
    local forceDep = timetable.getForceDepartureEnabled(lineID)
    -- Mutual exclusion (2026-08-16 player decision): depart on time = "forced departure on time" mode, mutually exclusive with min/max dwell time.
    -- Ticking depart on time -> clears the min/max ticks (no longer "greyed out but kept" -- all three ticked was too misleading); this also self-heals
    -- the "force ticked + min/max ticked" state left by old versions/old saves (previously kept greyed out). Clearing must be synced to the engine (timetableChanged).
    if forceDep and (timetable.getMinWaitEnabled(lineID) or timetable.getMaxWaitEnabled(lineID)) then
        timetable.setMinWaitEnabled(lineID, false)
        timetable.setMaxWaitEnabled(lineID, false)
        timetableChanged = true
    end
    local minEn = timetable.getMinWaitEnabled(lineID)
    local maxEn = timetable.getMaxWaitEnabled(lineID)
    local function ckImg(on) return api.gui.comp.ImageView.new(on and "ui/checkbox1.tga" or "ui/checkbox0.tga") end
    local forceImg, minImg, maxImg = ckImg(forceDep), ckImg(minEn), ckImg(maxEn)
    local forceBtn = api.gui.comp.Button.new(forceImg, true)
    local minBtn = api.gui.comp.Button.new(minImg, true)
    local maxBtn = api.gui.comp.Button.new(maxImg, true)
    for _, b in ipairs({forceBtn, minBtn, maxBtn}) do
        b:setStyleClassList({"timetable-avtivateTimetableButton"})
    end
    local function clearMinMax()
        timetable.setMinWaitEnabled(lineID, false)
        timetable.setMaxWaitEnabled(lineID, false)
        pcall(function() minImg:setImage("ui/checkbox0.tga", false) end)
        pcall(function() maxImg:setImage("ui/checkbox0.tga", false) end)
    end
    local function updateMinMaxEnabled()
        local on = not timetable.getForceDepartureEnabled(lineID)
        pcall(function() minBtn:setEnabled(on) end)
        pcall(function() maxBtn:setEnabled(on) end)
    end
    updateMinMaxEnabled()
    forceBtn:onClick(function()
        local now = not timetable.getForceDepartureEnabled(lineID)
        timetable.setForceDepartureEnabled(lineID, now)
        pcall(function() forceImg:setImage(now and "ui/checkbox1.tga" or "ui/checkbox0.tga", false) end)
        if now then
            clearMinMax()  -- ticking depart on time = switch to forced-on-time mode: clear the mutually exclusive min/max ticks
        end
        updateMinMaxEnabled()
        timetableChanged = true
    end)
    local function makeToggle(btn, img, getter, setter)
        btn:onClick(function()
            if timetable.getForceDepartureEnabled(lineID) then return end  -- not selectable while force is ticked (double safeguard)
            local now = not getter(lineID)
            setter(lineID, now)
            pcall(function() img:setImage(now and "ui/checkbox1.tga" or "ui/checkbox0.tga", false) end)
            timetableChanged = true
        end)
    end
    makeToggle(minBtn, minImg, timetable.getMinWaitEnabled, timetable.setMinWaitEnabled)
    makeToggle(maxBtn, maxImg, timetable.getMaxWaitEnabled, timetable.setMaxWaitEnabled)
    local function ctlGroup(lbl, btn)
        local c = api.gui.comp.Component.new("ctlGroup")
        local l = api.gui.layout.BoxLayout.new("HORIZONTAL")
        c:setLayout(l)
        local t = api.gui.comp.TextView.new(lbl)
        t:setStyleClassList({"timetable-mono-sc"})
        l:addItem(t)
        l:addItem(btn)
        return c
    end
    local headerRow = api.gui.comp.Component.new("stationHeaderControls")
    local hrl = api.gui.layout.BoxLayout.new("HORIZONTAL")
    headerRow:setLayout(hrl)
    hrl:addItem(freqLbl)
    hrl:addItem(ctlGroup(UIStrings.force_departure, forceBtn))
    hrl:addItem(ctlGroup(UIStrings.min_wait, minBtn))
    hrl:addItem(ctlGroup(UIStrings.max_wait, maxBtn))
    -- Row height 34: enough height so text/checkboxes aren't clipped (the root cause of the player report "bottom fifth of the frequency hidden" was the header cell row height being too small).
    headerRow:setMinimumSize(api.gui.util.Size.new(460, 34))
    headerRow:setMaximumSize(api.gui.util.Size.new(460, 34))
    menu.stationHeaderRow = headerRow
    pcall(function() UIState.boxlayout2:addItem(headerRow, 0.5, 0) end)
end

-- Image of the line strip at a station, for its entry from timetableHelper.getTrainLocations.
local function trainLocationImage(pos)
    if not pos then return "ui/timetable_line.tga" end
    if pos.atTerminal then
        if pos.countStr == "MANY" then return "ui/timetable_line_train_in_station_many.tga" end
        return "ui/timetable_line_train_in_station.tga"
    end
    if pos.countStr == "MANY" then return "ui/timetable_line_train_en_route_many.tga" end
    return "ui/timetable_line_train_en_route.tga"
end

-- params
-- index: index of currently selected line
-- bool: emit select signal when building table
function timetableGUI.fillStationTable(index, bool)
    local lang = api.util.getLanguage()
    local local_style = {local_styles[lang.code]}

    --initial checks
    if not index then return end
    if not(timetableHelper.getAllRailLines()[index+1]) or (not menu.stationTable)then return end

    -- initial cleanup
    menu.stationTable:deleteAll()
    menu.lineImage = {}
    menu.allStops = {}

    UIState.currentlySelectedLineTableIndex = index
    local lineID = timetableHelper.getAllRailLines()[index+1].id

    -- The line control switches (frequency + depart on time/min/max dwell time) are maintained by refreshStationHeaderRow as
    -- a separate fixed row above the station table (not in setHeader -- header cells aren't clickable and clip text, per player testing).
    timetableGUI.refreshStationHeaderRow(lineID)
    local header1 = api.gui.comp.TextView.new("")
    local header2 = api.gui.comp.TextView.new("")
    local header3 = api.gui.comp.TextView.new("")
    local header4 = api.gui.comp.TextView.new("")
    menu.stationTable:setHeader({header1,header2, header3, header4})

    -- Median leg times over all vehicles, as used for the operation chart; unmeasured legs
    -- hold a frequency-based estimate and are marked with "~".
    local okLE, stationLegTime, legDistances, legMeasured = pcall(timetableHelper.getLegEstimates, lineID)
    if not okLE then stationLegTime, legMeasured = {}, {} end
    menu.allStops = timetableHelper.getAllStops(lineID)

    -- Override waypoints with custom names (global name takes precedence; per-line names from old saves only serve as a one-time migration source)
    for _, stopInfo in ipairs(menu.allStops) do
        if stopInfo.type == "waypoint" then
            if stopInfo.gwKey then
                local globalName = timetable.getGlobalWaypointName(stopInfo.gwKey)
                if globalName then
                    stopInfo.name = globalName
                end
            end
            if not stopInfo.gwKey or not timetable.getGlobalWaypointName(stopInfo.gwKey) then
                local customName = timetable.getWaypointName(lineID, stopInfo.id)
                if customName then
                    stopInfo.name = customName
                    -- Self-healing migration: per-line names from old saves are promoted to global names (written to both _G and timetableObject);
                    -- from then on all lines show the same name; triggers sync and persistence.
                    if stopInfo.gwKey then
                        timetable.setGlobalWaypointName(stopInfo.gwKey, customName)
                        timetableChanged = true
                    end
                end
            end
        end
    end

    -- Train position icons: vehicle positions are read once here, and refreshed by a single
    -- step handler for all stations (not one handler per station, each reading all vehicles
    -- of the line every frame).
    local vehiclePositions = timetableHelper.getTrainLocations(lineID)
    local stationImages = {}

    for flatIdx, stopInfo in ipairs(menu.allStops) do
        if stopInfo.type == "station" then
            local key = tostring(stopInfo.stopIndex - 1)
            local img = trainLocationImage(vehiclePositions[key])
            menu.lineImage[flatIdx] = api.gui.comp.ImageView.new(img)
            stationImages[#stationImages + 1] = {view = menu.lineImage[flatIdx], key = key, img = img}
        else
            menu.lineImage[flatIdx] = api.gui.comp.ImageView.new("ui/timetable_line.tga")
        end

        local displayName = stopInfo.name
        if stopInfo.type == "station" then
            local st = timetableHelper.getStation(stopInfo.id)
            displayName = st.name
        end
        local displayNum = stopInfo.type == "waypoint" and "▶" or tostring(stopInfo.stopIndex)
        local stopIndicator = api.gui.comp.TextView.new(displayNum)
        stopIndicator:setStyleClassList({"timetable-stationcolour"})
        stopIndicator:setName("timetable-stationcolour-" .. timetableHelper.getLineColour(lineID))
        stopIndicator:setMinimumSize(api.gui.util.Size.new(30, 30))
        if stopInfo.type == "waypoint" then
            stopIndicator:setTooltip(UIStrings.waypoint)
        end

        local stationName = api.gui.comp.TextView.new(displayName)
        stationName:setName("stationName")

        local jurneyTime
        local legTime = stopInfo.type == "station" and stationLegTime[stopInfo.stopIndex]
        if legTime then
            local s = math.floor(legTime + 0.5)
            local prefix = legMeasured[stopInfo.stopIndex] and "" or "~"
            jurneyTime = api.gui.comp.TextView.new(UIStrings.journey_time .. ": " .. prefix
                .. string.format("%02d:%02d", math.floor(s / 60), s % 60))
        elseif stopInfo.type == "waypoint" then
            jurneyTime = api.gui.comp.TextView.new(UIStrings.passing_point)
        else
            jurneyTime = api.gui.comp.TextView.new("")
        end
        jurneyTime:setName("conditionString")
        jurneyTime:setStyleClassList(local_style)

        local stationNameTable = api.gui.comp.Table.new(1, 'NONE')
        stationNameTable:addRow({stationName})
        stationNameTable:addRow({jurneyTime})
        stationNameTable:setColWidth(0,120)

        local condStr
        if stopInfo.type == "station" then
            local ct = timetable.getConditionType(lineID, stopInfo.stopIndex)
            condStr = timetableHelper.conditionToString(timetable.getConditions(lineID, stopInfo.stopIndex, ct), ct)
        else
            local times = timetable.getWaypointPassingTime(lineID, stopInfo.id)
            if times and #times > 0 then
                local parts = {}
                for _, t in ipairs(times) do
                    table.insert(parts, string.format("%02d:%02d", t[1], t[2]))
                end
                condStr = UIStrings.passing .. ": " .. table.concat(parts, " ")
            else
                condStr = ""
            end
        end
        local conditionString = api.gui.comp.TextView.new(condStr)
        conditionString:setName("conditionString")
        conditionString:setStyleClassList(local_style)
        conditionString:setMinimumSize(api.gui.util.Size.new(285,50))
        conditionString:setMaximumSize(api.gui.util.Size.new(285,50))

        menu.stationTable:addRow({stopIndicator, stationNameTable, menu.lineImage[flatIdx], conditionString})
    end

    -- Refresh the icons when the game second changes, at most twice per real second
    -- (fast game speeds do not refresh more often); images are only set when they change.
    if stationImages[1] then
        local lastGameTime, lastReal = nil, nil
        stationImages[1].view:onStep(function()
            local t = timetableHelper.getTime()
            if t == lastGameTime then return end
            local real = realTimeNow()
            if lastReal and real - lastReal < 0.5 then return end
            lastGameTime, lastReal = t, real
            local vp = timetableHelper.getTrainLocations(lineID)
            for _, si in ipairs(stationImages) do
                local img = trainLocationImage(vp[si.key])
                if img ~= si.img then
                    si.img = img
                    si.view:setImage(img, false)
                end
            end
        end)
    end

    menu.stationTable:onSelect(function (tableIndex)
        if not (tableIndex == -1) then
            UIState.currentlySelectedStationIndex = tableIndex
            timetableGUI.initConstraintTable()
            timetableGUI.fillConstraintTable(tableIndex, lineID)
        end
    end)

    if UIState.currentlySelectedStationIndex then
        if menu.stationTable:getNumRows() > UIState.currentlySelectedStationIndex and not(menu.stationTable:getNumRows() == 0) then
            menu.stationTable:select(UIState.currentlySelectedStationIndex, bool)
        end
    end
    menu.stationScrollArea:invokeLater(
        function () menu.stationScrollArea:invokeLater(
            function () pcall(function() menu.stationScrollArea:setScrollOffset(stationTableScrollOffset) end) end) end)
end

-------------------------------------------------------------
---------------------- Right TABLE --------------------------
-------------------------------------------------------------

function timetableGUI.clearConstraintWindow()
    -- initial cleanup
    menu.constraintTable:deleteRows(1, menu.constraintTable:getNumRows())
end

-- Rebuild the whole right constraint window (new Table + refill). Old components are cleared by "building a new Table" rather than
-- deleteRows/deleteAll -- the engine's table deleteRows/deleteAll may not fully release nested
-- DoubleSpinBox components, causing "ghosting" of time input fields (old values on top of new ones). Only rebuilds the UI, doesn't change data;
-- the currently selected station is determined by UIState.currentlySelectedStationIndex.
function timetableGUI.rebuildConstraintWindow(lineID)
    if not lineID then return end
    timetableGUI.initConstraintTable()
    timetableGUI.fillConstraintTable(UIState.currentlySelectedStationIndex or 0, lineID)
end

-- Manual "Refresh" button: saves all current inputs (times/waypoint names/passing times -- onChange already writes data per keystroke)
-- and rebuilds the whole intermediate station table + right constraint window so every part of the UI shows the latest values, and triggers cross-thread sync.
-- Uses the HACK to defer to the next frame, avoiding rebuilding the button's own components inside its click event.
function timetableGUI.refreshTimetableUI(lineID)
    if not lineID then return end
    timetableChanged = true
    clearConstraintWindowLaterHACK = function()
        timetableGUI.initStationTable()
        timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
        timetableGUI.rebuildConstraintWindow(lineID)
    end
end

-- Delayed refresh of the intermediate station table summary: onChange fires per keystroke and keeps resetting the timer; after about 1s of no input (real time, fires while paused too)
-- the intermediate station table is rebuilt so the row's condition summary (arrival/departure times/waypoint name/passing time) shows the new values. Only the intermediate table is refreshed,
-- not the right constraint window, to avoid interrupting SpinBox input focus (AGENTS.md lesson "13:30 becomes 00:30").
function timetableGUI.scheduleStationSummaryRefresh()
    stationSummaryRefreshDue = realTimeNow() + 1
end

function timetableGUI.fillConstraintTable(index, lineID)
    --initial cleanup
    if index == -1 then
        menu.constraintTable:deleteAll()
        return
    end
    local flatIdx = index + 1
    menu.constraintTable:deleteAll()

    local stopInfo = menu.allStops and menu.allStops[flatIdx]
    if not stopInfo then return end

    local comboBox = api.gui.comp.ComboBox.new()
    comboBox:setGravity(1,0)

    if stopInfo.type == "waypoint" then
        comboBox:addItem(UIStrings.no_timetable)
        comboBox:addItem(UIStrings.passing)
        local times = timetable.getWaypointPassingTime(lineID, stopInfo.id)
        local hasTimes = times and #times > 0
        local selectedIdx = hasTimes and 1 or 0

        comboBox:onIndexChanged(function (i)
            if i == -1 then return end
            timetableChanged = true
            -- The name input is always shown; the "passing time" selection state decides whether the passing time editor is expanded
            timetableGUI.clearConstraintWindow()
            timetableGUI.makeWaypointNameWindow(lineID, stopInfo.id, stopInfo.gwKey)
            if i == 1 then
                timetableGUI.makePassingWindow(lineID, stopInfo.id, stopInfo.gwKey)
            end
        end)

        local infoImage = api.gui.comp.ImageView.new("ui/info_small.tga")
        infoImage:setTooltip(UIStrings.wp_tooltip)
        infoImage:setName("timetable-info-icon")

        -- Refresh button: saves all times/waypoint names/passing times in one click and refreshes the timetable UI (including waypoints)
        local refreshBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(UIStrings.refresh), true)
        refreshBtn:onClick(function()
            timetableGUI.refreshTimetableUI(lineID)
        end)

        local table = api.gui.comp.Table.new(3, 'NONE')
        table:addRow({infoImage, comboBox, refreshBtn})
        menu.constraintTable:addRow({table})
        comboBox:setSelected(selectedIdx, false)

        -- The name input field is always shown (independent of clicking "passing time")
        timetableGUI.makeWaypointNameWindow(lineID, stopInfo.id, stopInfo.gwKey)

        if hasTimes then
            timetableGUI.makePassingWindow(lineID, stopInfo.id, stopInfo.gwKey)
        end
    else
        comboBox:addItem(UIStrings.no_timetable)
        comboBox:addItem(UIStrings.arr_dep)
        comboBox:addItem(UIStrings.unbunch)

        local constraintIndex = timetableHelper.constraintStringToInt(timetable.getConditionType(lineID, stopInfo.stopIndex))

        comboBox:onIndexChanged(function (i)
            if i == -1 then return end
            timetable.setConditionType(lineID, stopInfo.stopIndex, timetableHelper.constraintIntToString(i))
            timetableChanged = true
            timetableGUI.initStationTable()
            timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            UIState.currentlySelectedConstraintType = i
            -- Rebuild the whole right constraint window (new Table + refill), completely clearing old DoubleSpinBoxes,
            -- to avoid "ghosting" of time input fields caused by deleteRows/deleteAll not fully releasing components
            local rebuildIdx = (stopInfo and stopInfo.flatIndex and stopInfo.flatIndex - 1)
                              or UIState.currentlySelectedStationIndex or 0
            timetableGUI.initConstraintTable()
            timetableGUI.fillConstraintTable(rebuildIdx, lineID)
        end)

        local infoImage = api.gui.comp.ImageView.new("ui/info_small.tga")
        infoImage:setTooltip(UIStrings.tooltip)
        infoImage:setName("timetable-info-icon")

        -- Refresh button: saves all arrival/departure/interval times in one click and refreshes the timetable UI
        local refreshBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(UIStrings.refresh), true)
        refreshBtn:onClick(function()
            timetableGUI.refreshTimetableUI(lineID)
        end)

        local table = api.gui.comp.Table.new(3, 'NONE')
        table:addRow({infoImage, comboBox, refreshBtn})
        menu.constraintTable:addRow({table})
        comboBox:setSelected(constraintIndex, false)
        if constraintIndex == 1 then
            timetableGUI.makeArrDepWindow(lineID, stopInfo.stopIndex)
        elseif constraintIndex == 2 then
            timetableGUI.makeDebounceWindow(lineID, stopInfo.stopIndex)
        end
    end

    menu.scrollAreaConstraint:invokeLater(
        function () menu.scrollAreaConstraint:invokeLater(
            function () pcall(function() menu.scrollAreaConstraint:setScrollOffset(constraintTableScrollOffset) end) end) end)
end


local SEPARATION_LIST = {30, 20, 15, 12, 10, 7.5, 6, 5, 4, 3, 2.5, 2, 1.5, 1.2, 1}
-- Last chosen separation (0-based combo index), kept across constraint window rebuilds
local selectedSeparationIdx = nil

-- Adds the "Separation [interval] Generate" row to the constraint window.
---@param generate function(sep) writes the generated times (sep in minutes, divides 60);
---  returns false if there is nothing to generate from
function timetableGUI.addSeparationRow(lineID, generate)
    local separationCombo = api.gui.comp.ComboBox.new()
    for _, sep in ipairs(SEPARATION_LIST) do
        separationCombo:addItem(string.format("%g min (%g/h)", sep, 60 / sep))
    end
    if selectedSeparationIdx then
        pcall(function() separationCombo:setSelected(selectedSeparationIdx, false) end)
    end
    separationCombo:onIndexChanged(function(i)
        if i ~= nil and i >= 0 then selectedSeparationIdx = i end
    end)
    separationCombo:setGravity(1, 0)
    local generateButton = api.gui.comp.Button.new(api.gui.comp.TextView.new(UIStrings.generate), true)
    generateButton:setGravity(1, 0)
    generateButton:onClick(function()
        local sepIdx = separationCombo:getCurrentIndex()
        if sepIdx == nil or sepIdx < 0 then
            print("[Timetable] Generate: select a separation first")
            return
        end
        if not generate(SEPARATION_LIST[sepIdx + 1]) then return end
        timetableChanged = true
        clearConstraintWindowLaterHACK = function()
            timetableGUI.initStationTable()
            timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            timetableGUI.rebuildConstraintWindow(lineID)
        end
    end)
    local sepRow = api.gui.comp.Table.new(3, 'NONE')
    sepRow:addRow({api.gui.comp.TextView.new(UIStrings.separation), separationCombo, generateButton})
    menu.constraintTable:addRow({sepRow})
end

function timetableGUI.makeArrDepWindow(lineID, stationID)
    if not menu.constraintTable then return end
    local conditions = timetable.getConditions(lineID,stationID, "ArrDep")
    if type(conditions) ~= "table" then conditions = {} end

    -- setup add button
    local addButton = api.gui.comp.Button.new(api.gui.comp.TextView.new(UIStrings.add), true)
    addButton:setGravity(1,0)
    addButton:onClick(function()
        timetable.addCondition(lineID,stationID, {type = "ArrDep", ArrDep = {{0,0,0,0}}})
        timetableChanged = true
        clearConstraintWindowLaterHACK = function()
            timetableGUI.initStationTable()
            timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            timetableGUI.rebuildConstraintWindow(lineID)
        end
    end)

    -- Separation row: fill the hour with evenly spaced copies of the first slot.
    timetableGUI.addSeparationRow(lineID, function(sep)
        local conds = timetable.getConditions(lineID, stationID, "ArrDep")
        if type(conds) ~= "table" or #conds < 1 then
            print("[Timetable] Generate: add one arrival/departure time as a template first")
            return false
        end
        local template = conds[1]
        -- More than one slot: keep the first as the template and replace the others
        if #conds > 1 then
            timetable.removeAllConditions(lineID, stationID, "ArrDep")
            timetable.addCondition(lineID, stationID, {type = "ArrDep", ArrDep = {template}})
        end
        for i = 1, 60 / sep - 1 do
            timetable.addCondition(lineID, stationID, {type = "ArrDep", ArrDep = {timetable.shiftSlot(template, i * sep * 60)}})
        end
        return true
    end)

    -- Holding point: whether trains beyond the delay tolerance are held here until the next slot.
    -- Same checkbox pattern as the line control switches (Button with swapped image).
    local holdImg = api.gui.comp.ImageView.new(
        timetable.getHoldLateEnabled(lineID, stationID) and "ui/checkbox1.tga" or "ui/checkbox0.tga")
    local holdBtn = api.gui.comp.Button.new(holdImg, true)
    holdBtn:setStyleClassList({"timetable-avtivateTimetableButton"})
    holdBtn:onClick(function()
        local now = not timetable.getHoldLateEnabled(lineID, stationID)
        timetable.setHoldLateEnabled(lineID, stationID, now)
        pcall(function() holdImg:setImage(now and "ui/checkbox1.tga" or "ui/checkbox0.tga", false) end)
        timetableChanged = true
    end)
    local holdLbl = api.gui.comp.TextView.new(UIStrings.hold_late)
    holdLbl:setTooltip(UIStrings.hold_late_tooltip)
    local holdRow = api.gui.comp.Table.new(2, 'NONE')
    holdRow:addRow({holdLbl, holdBtn})
    menu.constraintTable:addRow({holdRow})

    --setup header
    local headerTable = api.gui.comp.Table.new(4, 'NONE')
    headerTable:setColWidth(0,125)
    headerTable:setColWidth(1,76)
    headerTable:setColWidth(2,50)
    headerTable:setColWidth(3,48)
    headerTable:addRow({api.gui.comp.TextView.new(""),api.gui.comp.TextView.new(UIStrings.min),api.gui.comp.TextView.new(UIStrings.sec),addButton})
    menu.constraintTable:addRow({headerTable})


    -- setup arrival and depature content
    for k,v in pairs(conditions) do
        menu.constraintTable:addRow({api.gui.comp.Component.new("HorizontalLine")})


        local linetable = api.gui.comp.Table.new(5, 'NONE')
        local arivalLabel =  api.gui.comp.TextView.new(UIStrings.arrival .. ":  ")

        arivalLabel:setMinimumSize(api.gui.util.Size.new(80, 30))
        arivalLabel:setMaximumSize(api.gui.util.Size.new(80, 30))

        local arrivalMin = api.gui.comp.DoubleSpinBox.new()
        arrivalMin:setMinimum(0,false)
        arrivalMin:setMaximum(59,false)
        arrivalMin:setValue(v[1],false)
        arrivalMin:onChange(function(value)
            timetable.updateArrDep(lineID, stationID, k, 1, value)
            timetableChanged = true
            timetableGUI.scheduleStationSummaryRefresh()
            -- Note: don't rebuild the UI in onChange (initStationTable/fillStationTable).
            -- Rebuilding on every keystroke interrupts SpinBox focus/value, causing random value loss like "13:30 becomes 00:30".
        end)

        local arrivalSec = api.gui.comp.DoubleSpinBox.new()
        arrivalSec:setMinimum(0,false)
        arrivalSec:setMaximum(59,false)
        arrivalSec:setValue(v[2],false)
        arrivalSec:onChange(function(value)
            timetable.updateArrDep(lineID, stationID, k, 2, value)
            timetableChanged = true
            timetableGUI.scheduleStationSummaryRefresh()
        end)

        local deleteButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("X") ,true)
        deleteButton:onClick(function()
            timetable.removeCondition(lineID, stationID, "ArrDep", k)
            timetableChanged = true
            clearConstraintWindowLaterHACK = function()
                timetableGUI.initStationTable()
                timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
                timetableGUI.rebuildConstraintWindow(lineID)
            end
        end)

        linetable:addRow({
            arivalLabel,
            arrivalMin,
            api.gui.comp.TextView.new(":"),
            arrivalSec,
            deleteButton
        })
        menu.constraintTable:addRow({linetable})

        local departureLabel =  api.gui.comp.TextView.new(UIStrings.departure .. ":  ")

        departureLabel:setMinimumSize(api.gui.util.Size.new(80, 30))
        departureLabel:setMaximumSize(api.gui.util.Size.new(80, 30))
        local departureMin = api.gui.comp.DoubleSpinBox.new()
        departureMin:setMinimum(0,false)
        departureMin:setMaximum(59,false)
        departureMin:setValue(v[3],false)
        departureMin:onChange(function(value)
            timetable.updateArrDep(lineID, stationID, k, 3, value)
            timetableChanged = true
            timetableGUI.scheduleStationSummaryRefresh()
        end)

        local departureSec = api.gui.comp.DoubleSpinBox.new()
        departureSec:setMinimum(0,false)
        departureSec:setMaximum(59,false)
        departureSec:setValue(v[4],false)
        departureSec:onChange(function(value)
            timetable.updateArrDep(lineID, stationID, k, 4, value)
            timetableChanged = true
            timetableGUI.scheduleStationSummaryRefresh()
        end)


        local deletePlaceholder = api.gui.comp.TextView.new(" ")
        deletePlaceholder:setMinimumSize(api.gui.util.Size.new(12, 30))
        deletePlaceholder:setMaximumSize(api.gui.util.Size.new(12, 30))

        local linetable2 = api.gui.comp.Table.new(5, 'NONE')
        linetable2:addRow({
            departureLabel,
            departureMin,
            api.gui.comp.TextView.new(":"),
            departureSec,
            deletePlaceholder
        })
        menu.constraintTable:addRow({linetable2})


        menu.constraintTable:addRow({api.gui.comp.Component.new("HorizontalLine")})
    end

end

function timetableGUI.makeDebounceWindow(lineID, stationID)
    if not menu.constraintTable then return end
    local condition2 = timetable.getConditions(lineID,stationID, "debounce")

    local debounceTable = api.gui.comp.Table.new(4, 'NONE')
    debounceTable:setColWidth(0,150)
    debounceTable:setColWidth(1,62)
    debounceTable:setColWidth(2,25)
    debounceTable:setColWidth(3,63)

    local debounceMin = api.gui.comp.DoubleSpinBox.new()
    debounceMin:setMinimum(0,false)
    debounceMin:setMaximum(59,false)

    debounceMin:onChange(function(value)
        timetable.updateDebounce(lineID, stationID,  1, value)
        timetableChanged = true
        timetableGUI.scheduleStationSummaryRefresh()
    end)

    if condition2 and condition2[1] then
        debounceMin:setValue(condition2[1],false)
    end


    local debounceSec = api.gui.comp.DoubleSpinBox.new()
    debounceSec:setMinimum(0,false)
    debounceSec:setMaximum(59,false)

    debounceSec:onChange(function(value)
        timetable.updateDebounce(lineID, stationID, 2, value)
        timetableChanged = true
        timetableGUI.scheduleStationSummaryRefresh()
    end)
    if condition2 and condition2[2] then
        debounceSec:setValue(condition2[2],false)
    end

    debounceTable:addRow({api.gui.comp.TextView.new(UIStrings.unbunch_time .. ":"), debounceMin,api.gui.comp.TextView.new(":"), debounceSec})

    menu.constraintTable:addRow({debounceTable})

end

-- Waypoint name editor: [always shown] on the waypoint page, independent of clicking "passing time".
-- Renaming saves immediately (onChange writes the global name _gwNames per keystroke, synced globally across lines) + 1s real-time debounce
-- auto-refreshes the intermediate station table; on focus loss the whole table is rebuilt so the name takes effect on all lines.
function timetableGUI.makeWaypointNameWindow(lineID, wpEntity, gwKey)
    if not menu.constraintTable then return end
    local currentName = ""
    if gwKey then
        currentName = timetable.getGlobalWaypointName(gwKey) or ""
    end
    if currentName == "" then
        currentName = timetable.getWaypointName(lineID, wpEntity) or ""
    end

    local ok, inputField = pcall(function()
        return api.gui.comp.TextInputField.new("")
    end)
    -- Commit the name (only the global name is written): gwKey is based on the waypoint entity (SignalId entity/index), synced globally across lines.
    -- The per-line name store (waypointNames) is no longer written, avoiding divergence of "several names for one entity".
    local function commitName(text)
        pcall(function()
            if gwKey then
                timetable.setGlobalWaypointName(gwKey, text)
            end
            timetableChanged = true
        end)
    end
    -- Refresh immediately: rebuild the intermediate station table + right constraint window so the new name takes effect globally (same rebuild path as +/X)
    local function refreshWaypointUI()
        clearConstraintWindowLaterHACK = function()
            timetableGUI.initStationTable()
            timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            timetableGUI.rebuildConstraintWindow(lineID)
        end
    end

    local nameTable = api.gui.comp.Table.new(2, 'NONE')
    nameTable:setColWidth(0,80)
    local nameLabel = api.gui.comp.TextView.new(UIStrings.name_label)
    if ok and inputField then
        if currentName and #currentName > 0 then
            inputField:setText(currentName, false)
        end
        inputField:onChange(function(text)
            commitName(text)
            timetableGUI.scheduleStationSummaryRefresh()
        end)
        pcall(function()
            inputField:onFocusLost(function()
                refreshWaypointUI()
            end)
        end)
        nameTable:addRow({nameLabel, inputField})
    else
        local showName = api.gui.comp.TextView.new(currentName and #currentName > 0 and currentName or UIStrings.rename_hint)
        showName:setStyleClassList({"timetable-mono-sc"})
        nameTable:addRow({nameLabel, showName})
    end
    menu.constraintTable:addRow({nameTable})
end

function timetableGUI.makePassingWindow(lineID, wpEntity, gwKey)
    if not menu.constraintTable then return end

    -- Passing time editor (multiple entries, supports adding and removing)
    local times = timetable.getWaypointPassingTime(lineID, wpEntity)

    -- Separation row: fill the hour with evenly spaced copies of the first passing time.
    timetableGUI.addSeparationRow(lineID, function(sep)
        local cur = timetable.getWaypointPassingTime(lineID, wpEntity)
        if not cur or #cur < 1 then
            print("[Timetable] Generate: add one passing time as a template first")
            return false
        end
        local template = { cur[1][1] or 0, cur[1][2] or 0 }
        timetable.removeAllWaypointPassingTimes(lineID, wpEntity)
        timetable.addWaypointPassingTime(lineID, wpEntity, template[1], template[2])
        for i = 1, 60 / sep - 1 do
            local t = timetable.shiftTime(template, i * sep * 60)
            timetable.addWaypointPassingTime(lineID, wpEntity, t[1], t[2])
        end
        return true
    end)

    -- header + add button
    local addButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("+"), true)
    addButton:setGravity(1,0)
    addButton:onClick(function()
        timetable.addWaypointPassingTime(lineID, wpEntity, 0, 0)
        timetableChanged = true
        clearConstraintWindowLaterHACK = function()
            timetableGUI.initStationTable()
            timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            timetableGUI.rebuildConstraintWindow(lineID)
        end
    end)

    local headerTable = api.gui.comp.Table.new(4, 'NONE')
    headerTable:setColWidth(0,100)
    headerTable:setColWidth(1,76)
    headerTable:setColWidth(2,76)
    headerTable:setColWidth(3,40)
    headerTable:addRow({api.gui.comp.TextView.new(""), api.gui.comp.TextView.new(UIStrings.min), api.gui.comp.TextView.new(UIStrings.sec), addButton})
    menu.constraintTable:addRow({headerTable})

    if times then
        for k, t in ipairs(times) do
            local rowTable = api.gui.comp.Table.new(4, 'NONE')
            rowTable:setColWidth(0,100)
            rowTable:setColWidth(1,76)
            rowTable:setColWidth(2,76)
            rowTable:setColWidth(3,40)

            local minSpinner = api.gui.comp.DoubleSpinBox.new()
            minSpinner:setMinimum(0,false)
            minSpinner:setMaximum(59,false)
            minSpinner:setValue(t[1], false)
            minSpinner:onChange(function(value)
                timetable.updateWaypointPassingTimeEntry(lineID, wpEntity, k, 1, value)
                timetableChanged = true
                timetableGUI.scheduleStationSummaryRefresh()
            end)

            local secSpinner = api.gui.comp.DoubleSpinBox.new()
            secSpinner:setMinimum(0,false)
            secSpinner:setMaximum(59,false)
            secSpinner:setValue(t[2], false)
            secSpinner:onChange(function(value)
                timetable.updateWaypointPassingTimeEntry(lineID, wpEntity, k, 2, value)
                timetableChanged = true
                timetableGUI.scheduleStationSummaryRefresh()
            end)

            local deleteBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new("X"), true)
            deleteBtn:onClick(function()
                timetable.removeWaypointPassingTime(lineID, wpEntity, k)
                timetableChanged = true
                clearConstraintWindowLaterHACK = function()
                    timetableGUI.initStationTable()
                    timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
                    timetableGUI.rebuildConstraintWindow(lineID)
                end
            end)

            rowTable:addRow({api.gui.comp.TextView.new(string.format(UIStrings.passing_n, k)), minSpinner, secSpinner, deleteBtn})
            menu.constraintTable:addRow({rowTable})
        end
    end
end

-------------------------------------------------------------
--------------------- OTHER ---------------------------------
-------------------------------------------------------------


-- Punctuality detection (engine thread, runs continuously after a save is loaded, independent of whether the diagram window is open):
-- a state machine scans all vehicles, detects the moments of arrival (state->2)/departure (lineStopDepartures becomes non-zero),
-- records the actual arrival/departure times, compares them with the timetable's planned ArrDep times, computes late/on time/early, and stores it in _G._punctuality.
-- What is shown is the arrival/departure verdict of the "previous station" (user request: a train on the way A->B shows station A's punctuality).
--
-- _G._punctuality[vehicleId] = {
--   lineId, lineName, lastStopIndex, lastState,
--   lastArrTime, lastDepTime,          -- actual arrival/departure seconds at the previous station (absolute game seconds)
--   plArr, plDep,                      -- absolute planned arrival/departure seconds of the slot set chosen at the previous station
--   arrDiff, depDiff,                  -- arrival/departure deviation seconds at the previous station (positive = late, negative = early)
--   arrPunct, depPunct,                -- "early"/"late"/"ontime" (previous station)
--   stationName,                       -- previous station name
-- }
local punctualityState = {}

-- From a station's multiple ArrDep slot sets, pick the one the train actually runs on (absolute arrival time closest to the actual arrival),
-- and return that set's absolute planned arrival/departure times. stationNumber starts at 1.
-- The old implementation getPlannedTime hardcoded conds[1] (the first set): on a line with multiple slot sets,
-- a train actually running on set 2 was judged against set 1 (e.g. station 2 set 1 26:30 / set 2 51:00,
-- a train arriving at 26:45 was judged against 51:00, giving bogus delays/early arrivals of tens of minutes).
local function getPlannedArrDep(lineID, stationNumber, actualArrTime)
    local ct = timetable.getConditionType(lineID, stationNumber)
    if ct ~= "ArrDep" then return nil, nil end
    local conds = timetable.getConditions(lineID, stationNumber, "ArrDep")
    if not conds or #conds == 0 then return nil, nil end
    -- Same slot matching as waitingRequired (closest [arr, dep] interval).
    return timetable.assignSlot(conds, actualArrTime)
end

-- Late/on time/early classification: |diff| <= threshold is on time, positive = late, negative = early. Threshold = the diagram setting "punctuality threshold" (seconds, default 10).
local function classify(diff)
    if not diff then return "ontime" end
    local tol = timetable.getPunctThreshold()
    if diff > tol then return "late" end
    if diff < -tol then return "early" end
    return "ontime"
end

function timetableGUI.updatePunctuality()
    if not _G._punctuality then _G._punctuality = {} end
    local now = timetableHelper.getTime()
    if not _G._punctNext then _G._punctNext = 0 end
    if now < _G._punctNext then return end
    _G._punctNext = now + 1  -- scan once per second (getTime whole seconds)

    local okMap, vehicleMap = pcall(_lineVehicleMap)
    if not okMap or not vehicleMap then return end
    for lineID, vehicles in pairs(vehicleMap) do
        local lineName = nil
        local okN, nc = pcall(_getComponent, lineID, api.type.ComponentType.NAME)
        if okN and nc and nc.name then lineName = nc.name end
        if vehicles then
            for _, vehicle in pairs(vehicles) do
                -- The vehicle may have been sold/deleted (the getLine2VehicleMap snapshot may contain invalid IDs):
                -- getComponent on an invalid entity triggers a C++ assert (GetComponentDataIndex, not catchable by pcall).
                local okEv, exists = pcall(_entityExists, tonumber(vehicle))
                if okEv and exists == true then
                    local vId = tostring(vehicle)
                    local okC, vc = pcall(_getComponent, vehicle, 70)
                if okC and vc then
                    local st = punctualityState[vId]
                    if not st then
                        st = {lineId = lineID, lineName = lineName, thisStopIndex = vc.stopIndex,
                              lastState = vc.state, arrTime = nil, depTime = nil, arrDone = false,
                              plArr = nil, plDep = nil,
                              arrDiff = nil, depDiff = nil, arrPunct = nil, depPunct = nil,
                              stationName = nil}
                        punctualityState[vId] = st
                    end

                    -- Arrival detection: state changes from non-2 -> 2 (stopped), record the arrival time at the current station;
                    -- or the stop has changed (fallback when a quick stop missed state 1 / the last scan didn't update thisStopIndex)
                    if vc.state == 2 and (st.lastState ~= 2 or vc.stopIndex ~= st.thisStopIndex) then
                        st.thisStopIndex = vc.stopIndex
                        st.arrTime = now
                        st.depTime = nil
                        st.arrDone = false
                        st.stationName = nil
                        -- Reading the station name: vc.stopIndex is the "stop position index in the line" (int), not a station group entity ID --
                        -- calling getComponent with stopIndex as an entity ID triggers a C++ assert
                        -- (GetComponentDataIndex, not catchable by pcall). Skip after checking with entityExists.
                        local idx = vc.stopIndex
                        if idx ~= nil then
                            local okIe, idxExists = pcall(_entityExists, idx)
                            if okIe and idxExists == true then
                                local okSg, sg = pcall(_getComponent, idx, api.type.ComponentType.NAME)
                                if okSg and sg and sg.name then st.stationName = sg.name end
                            end
                        end
                        -- On arrival, classify immediately by the arrival deviation (early/on time/late), so it can be shown before departure.
                        -- With multiple slot sets, automatically pick the one whose "absolute arrival time is closest to the actual arrival" (getPlannedArrDep),
                        -- so a train running on set 2 isn't judged against set 1.
                        local plArr, plDep = getPlannedArrDep(lineID, vc.stopIndex + 1, now)
                        if plArr and plDep then
                            st.plArr, st.plDep = plArr, plDep
                            st.arrDiff = st.arrTime - plArr
                            st.arrPunct = classify(st.arrDiff)
                        end
                    end

                    -- Departure detection: read the actual departure time at the current stop (lineStopDepartures[thisStopIndex+1]).
                    -- The value is written after the vehicle departs (e.g. departure at time=360 -> value 360), and after departure stopIndex advances
                    -- while the historic value is kept when state becomes 1, so this doesn't depend on state==2; as soon as the station's dep changes from 0/old value to non-zero, it counts as a departure.
                    -- Doesn't depend on st.arrTime: even if the arrival event was missed (short stop/already stopped when loading), the departure event is still captured and classified.
                    -- Key guard (2026-08-05): lineStopDepartures records "the most recent departure from this station" and isn't reset between cycles.
                    -- After a train departed from this station in the previous cycle (e.g. 23:32) and returns in this cycle, the field still holds the old value --
                    -- treating d>0 directly as "just departed now" would subtract this cycle's chosen slot set's planned departure from the previous cycle's old departure time
                    -- (multiple slot sets: old value belongs to set 1, plan to set 2 -> bogus "24 minutes early").
                    -- The decision logic is extracted to timetable.isValidDepartureRecord (unit-testable); only called here.
                    if not st.arrDone then
                        local depTime = nil
                        if vc.lineStopDepartures and st.thisStopIndex then
                            local d = vc.lineStopDepartures[st.thisStopIndex + 1]
                            if timetable.isValidDepartureRecord(d, now, st.arrTime) then
                                depTime = math.floor(d / 1000)
                            end
                        end
                        -- Departure finalized: the engine has provided the actual departure seconds at this station
                        if depTime and depTime ~= st.depTime then
                            st.depTime = depTime
                            st.arrDone = true
                            -- Reuse the slot set chosen on arrival; re-pick as a fallback if arrival wasn't classified
                            local plArr, plDep = st.plArr, st.plDep
                            if not plArr then
                                plArr, plDep = getPlannedArrDep(lineID, st.thisStopIndex + 1, st.arrTime or depTime)
                                st.plArr, st.plDep = plArr, plDep
                            end
                            if plArr and plDep then
                                if st.arrTime then
                                    st.arrDiff = st.arrTime - plArr
                                    st.arrPunct = classify(st.arrDiff)
                                end
                                st.depDiff = depTime - plDep
                                st.depPunct = classify(st.depDiff)
                            end
                        end
                    end

                    -- Station changed (moving on): the current stop changed, start collecting for the new station
                    if vc.stopIndex ~= st.thisStopIndex and vc.state ~= 2 then
                        -- Station changed while running, reset the pending collection state (wait for the next arrival)
                        st.thisStopIndex = vc.stopIndex
                        if st.arrDone then
                            -- Previous station already finalized, keep its verdict; prepare to collect the new station
                        end
                    end

                    st.lastState = vc.state
                    st.lineId = lineID
                    st.lineName = lineName or st.lineName
                end
                end -- if okEv and exists == true then
            end
        end
    end

    -- Sync to _G for the GUI thread (the GUI thread just reads _G, no cross-thread event needed)
    _G._punctuality = punctualityState
end

-- ===== Performance optimization group A (2026-08-16, round 21): three changes to the vehicle control coroutine =====
-- 1) Ticked line list (plain Lua, from timetableObject): only lines with "follow timetable" ticked need vehicle control at all;
--    with an empty list **no scan is needed at all** (the original implementation scanned all vehicles at stations worldwide every frame even with no line ticked).
-- 2) With an empty list, no more "rescan on every resume": update() resumes up to 21 times per frame, and the coroutine body is
--    `while true do scan; for ... yield end; yield end` -- with an empty list every resume rescanned
--    (21 times/frame, each = all vehicles at stations worldwide + 2 engine calls per vehicle + 2 closures). Now a frame number marks it:
--    if already scanned in this frame, just `yield("idle")`; update() ends this frame's resume loop immediately on "idle"
--    -> **the scan frequency is still "once per frame"** (exactly the same response speed to vehicle arrivals), just not repeated 21 times.
-- 3) Only one getTimetableObject() call (engine thread copy), shared by the list and the scan.
-- 4) A vehicle held during the current game second is not re-evaluated until the second
--    changes: waitingRequired works in whole seconds, so the decision can't change before.
--    Hold/release commands are only sent when they change the vehicle's state (setVehicleHeld).
local EMPTY_VEHICLE_LIST = {}
function timetableGUI.timetableCoroutine()
    local scannedFrame = -1        -- frame number of this coroutine's most recent full scan
    local tickedLines = {}         -- IDs of lines with "follow timetable" ticked (>0)
    local heldSecond = nil         -- game second of heldThisSecond
    local heldThisSecond = {}      -- vehicles held during heldSecond (key: vehicle string)
    while true do
        local list = nil
        if scannedFrame == _G._ttCoFrame then
            -- Already scanned in this frame: don't scan again, return this frame's remaining resume quota to the engine
            coroutine.yield("idle")
        else
            scannedFrame = _G._ttCoFrame
            -- Ticked line list (plain Lua, no engine calls)
            local n = 0
            local to = timetable.getTimetableObject()
            if type(to) == "table" then
                for k, e in pairs(to) do
                    local id = tonumber(k)
                    if id and id > 0 and type(e) == "table" and e.hasTimetable == true then
                        n = n + 1
                        tickedLines[n] = id
                    end
                end
            end
            for i = n + 1, #tickedLines do tickedLines[i] = nil end   -- shrink old contents
            if n == 0 then
                list = EMPTY_VEHICLE_LIST      -- no line runs a timetable -> no vehicle control and no scan
            else
                list = timetableHelper.getAllTimetableRailVehicles(timetable.hasTimetable, tickedLines)
            end
        end
        if list then
            for _,vehicle in pairs(list) do
                local vehicleStr = tostring(vehicle)
                local skip = false
                local now = timetableHelper.getTime()
                if now ~= heldSecond then
                    heldSecond = now
                    heldThisSecond = {}
                elseif heldThisSecond[vehicleStr] then
                    skip = true
                end
                -- Train rotation system (TrainRoute mod) hook: hot standbys are force-stopped by the rotation system (permanently via setUserStopped(true))
                -- and bypass the timetable logic; real trains at transfer stations are held/switched separately by the rotation system according to "the next line's departure time".
                -- TrainRoute not installed -> hook is nil -> no vehicles are skipped (original behavior).
                local trHooks = _G._trainRouteHooks
                if trHooks and not skip then
                    local okSB, isSb = pcall(trHooks.isStandby, vehicleStr)
                    if okSB and isSb then skip = true end
                    if not skip then
                        local okMV, isMv = pcall(trHooks.managesVehicle, vehicleStr)
                        if okMV and isMv then skip = true end
                    end
                end
                if not skip then
                    -- Hold/release decision. The forceDeparture on release (setVehicleShouldDepart actually starts the vehicle)
                    -- is already handled unconditionally inside waitingRequired (including the case "departure time passed, delay within tolerance,
                    -- vehicle arriving for the first time and never held"); only setVehicleHeld is needed here.
                    local held = timetable.waitingRequired(vehicleStr)
                    timetableHelper.setVehicleHeld(vehicleStr, held)
                    if held then heldThisSecond[vehicleStr] = true end
                end
                coroutine.yield()
            end
            coroutine.yield()
        end
    end
end

function data()
    return {
        --engine Thread

        handleEvent = function (_, id, _, param)
            if id == "timetableUpdate" then
                if state == nil then state = {timetable = {}} end
                -- Data safety guard (added 2026-08-09): if the GUI thread, due to a module reload/load failure, sends
                -- an object without line entries (only _diagram* settings keys/empty table), or one that lost the saved presets (dp),
                -- while the engine has the complete lines/presets loaded, refuse to overwrite -- otherwise the next save would wipe the saved
                -- timetable/diagram configuration. The rejection log is controlled by _G._diagramDebug (off by default).
                local paramHasLines = timetable.hasLineEntries(param)
                local engineHasLines = timetable.hasLineEntries(state.timetable)
                local paramHasPresets = timetable.hasAnyPreset(param)
                local engineHasPresets = timetable.hasAnyPreset(state.timetable)
                local rejected = (not paramHasLines and engineHasLines)
                    or (engineHasPresets and not paramHasPresets)
                if rejected then
                    if _G._diagramDebug then
                        print("[Timetable] sync REJECTED: paramLines=" .. tostring(paramHasLines)
                            .. " engineLines=" .. tostring(engineHasLines)
                            .. " paramPresets=" .. tostring(paramHasPresets)
                            .. " enginePresets=" .. tostring(engineHasPresets))
                    end
                    -- Catch up with the rejected revision, so the GUI accepts the engine's
                    -- data again instead of waiting forever for a snapshot as new as its own.
                    if type(state.timetable) == "table" then
                        state.timetable._rev = math.max(timetable.getRevision(state.timetable),
                            timetable.getRevision(param))
                    end
                    return
                end
                state.timetable = param
                timetable.setTimetableObject(state.timetable)
            end
        end,

        save = function()
            return state
        end,

        load = function(loadedState)
            if loadedState == nil  or next(loadedState) == nil then  return end
            -- In the GUI thread, load runs every frame with the engine's last saved state.
            -- Only accept it if it is not older than our local data: skip while local edits
            -- are still unsent, or while the engine has not yet processed our last send
            -- (snapshot revision < local revision). Otherwise a stale snapshot overwrites
            -- local edits, and the next edit sends the reverted object to the engine.
            local acceptTimetable = loadedState.timetable
                and not (timetableChanged or _G._diagramForceSync)
                and timetable.getRevision(loadedState.timetable) >= timetable.getRevision()
            if acceptTimetable then
                timetable.setTimetableObject(loadedState.timetable)
            end

            if loadedState.currentlyWaiting then
                timetable.setCurrentlyWaiting(loadedState.currentlyWaiting)
            end
            -- Old save compatibility: currentlyWaiting may contain stop entries missing outboundTime / with the old scalar;
            -- if not cleaned up, waitingRequired crashes when writing outboundTime[vehicle] (coroutine stuck in an endless loop)
            pcall(function() timetable.sanitizeCurrentlyWaiting() end)

            if loadedState.diagramConfig then
                timetable.setDiagramConfig(loadedState.diagramConfig)
            end

            if acceptTimetable and loadedState.timetable._gwNames then
                _G._gwNames = loadedState.timetable._gwNames
            end

            state = loadedState or {timetable = {}}
        end,

        update = function()
            if state == nil then state = {timetable = {}}end
            -- Frame number (performance optimization group A): lets the vehicle control coroutine tell "whether this frame was already scanned", so that with an empty list
            -- not every resume rescans all vehicles worldwide (the original implementation did so up to 21 times/frame).
            _G._ttCoFrame = (_G._ttCoFrame or 0) + 1
            -- Coroutine self-healing (2026-08-16 hardening): a C++ assert (e.g. getComponent hitting an invalid entity,
            -- AGENTS.md lesson) bypasses Lua's yield/return and leaves the coroutine in the "running" state --
            -- status is neither dead nor suspended, resume reports "cannot resume non-suspended coroutine"
            -- and, once printed via throttling, spams every frame and is never rebuilt. Rebuild in every state except suspended:
            -- running = stuck due to an assert; dead = exited normally; normal = shouldn't occur here (rebuild defensively).
            local coStatus = co and coroutine.status(co) or "dead"
            if coStatus ~= "suspended" then
                co = coroutine.create(timetableGUI.timetableCoroutine)
            end
            -- A dead coroutine resumed 20 times per frame printed an error each time -> console spam (player report "the log keeps scrolling").
            -- Fix: break immediately on status==dead; errors are printed at most once per second (throttled).
            -- Performance optimization group A addition: coroutine yields "idle" (already scanned this frame) -> end this frame's resume loop immediately.
            for _ = 0, 20 do
                if coroutine.status(co) == "dead" then break end
                local err, msg = coroutine.resume(co)
                if not err then
                    local now = realTimeNow()
                    if not _G._coErrThrottle or now - _G._coErrThrottle > 1 then
                        _G._coErrThrottle = now
                        print(msg)
                    end
                    break
                end
                if msg == "idle" then break end
            end

            -- Rotation system dispatching moved to the separate mod TrainRoute (it calls tick itself in its game_script's update)
            -- Punctuality detection moved to guiUpdate (GUI thread):
            -- the GUI thread can read the engine API and shares the thread with diagram_gui, so data written to _G._punctuality is directly visible

            -- Leftover hold cleanup (2026-08-16 diagnosis): old mod versions called setVehicleManualDeparture(true) on lines that were "unticked but had leftover time data";
            -- the flag is persisted with the save -> vehicles stay at the station forever
            -- (autoDeparture=false, timeUntilDep frozen, days growing). Cleared once right after loading + self-healing every 30s:
            -- clears manualDeparture on vehicles of lines "with entries but unticked" (only manualDeparture,
            -- userStopped is left alone = TrainRoute hot standby territory).
            local holdNow = rawRealSeconds()
            if holdNow then
                if not _G._ttStaleHoldDue or holdNow >= _G._ttStaleHoldDue then
                    _G._ttStaleHoldDue = holdNow + 30
                    -- Performance optimization group A: clearStaleHolds is now candidate driven (zero engine calls when there are no lines "with data but unticked"),
                    -- so this 30s spike disappears entirely in normal play.
                    pcall(timetable.clearStaleHolds)
                end
            end

            -- 5s maintenance (performance optimization group A: two tasks merged into a single fetch)
            --   (1) clean up orphaned timetable data of deleted lines (the station tab iterates timetableObject; orphaned entries show ERROR);
            --   (2) station/line structure reconciliation (after removing/building stations the stops are renumbered and time data stored by position becomes misaligned).
            -- The original implementation made two separate calls (cleanupOrphanLines fetching getLines internally, reconcileStationData
            -- calling entityExists per line internally) -> now maintainTimetableData() fetches getLines only once,
            -- and surviving lines are reconciled with the same set. Throttled by real time (os.clock): runs while paused too.
            -- The cleanup modifies the engine thread's timetableObject directly and is persisted by state.timetable = to below;
            -- the engine thread's timetableChanged is not shared with the GUI thread, so it doesn't need to be set.
            local rtNow = rawRealSeconds()
            if rtNow then
                if not _G._ttOrphanCleanDue then _G._ttOrphanCleanDue = rtNow + 5 end
                if rtNow >= _G._ttOrphanCleanDue then
                    _G._ttOrphanCleanDue = rtNow + 5
                    pcall(timetable.maintainTimetableData)
                end
            end

            local to = timetable.getTimetableObject()
            if to then
                for _, entry in pairs(to) do
                    if type(entry) == "table" then
                        if not entry.dp then entry.dp = {} end
                        if not entry.stations then entry.stations = {} end
                    end
                end
            end

            state.timetable = to
            state.currentlyWaiting = timetable.getCurrentlyWaiting()
            state.diagramConfig = timetable.getDiagramConfig()

        end,

        guiUpdate = function()
            if not _G._gwNames and state and state.timetable and state.timetable._gwNames then
                _G._gwNames = state.timetable._gwNames
            end
            -- GUI thread orphaned line cleanup (data source side): timetableObject is edited on the GUI thread and synced to the engine thread;
            -- after a line is deleted, the GUI thread's copy keeps orphans (station tab shows ERROR). Cleaned up every ~5s (throttled),
            -- using os.clock (real time) so it runs while paused. After cleanup, timetableChanged is set to trigger the sendScriptEvent sync below.
            -- Key point: after cleaning up orphans, if a station is selected in the station tab, the right line table (stationTabLinesTable) isn't refilled automatically --
            -- the "ERROR" rows rendered before the player deleted the line remain on screen (even though the data is filtered). So the right table is refilled after cleanup.
            local guiRtNow = rawRealSeconds()
            if guiRtNow then
                if not _G._ttGuiOrphanCleanDue then _G._ttGuiOrphanCleanDue = guiRtNow + 5 end
                if guiRtNow >= _G._ttGuiOrphanCleanDue then
                    _G._ttGuiOrphanCleanDue = guiRtNow + 5
                    -- Performance optimization group A: orphan cleanup + station reconciliation merged into a single fetch (originally two separate calls,
                    -- one fetching getLines, the other calling entityExists per line). Same semantics, just one engine round trip less.
                    -- Note: pcall returns two values (ok, result) -- ok is the boolean, result is the stats table;
                    -- taking only the first would index the boolean as a table -> crash with "attempt to index local 'rc' (a boolean value)".
                    local okM, guiRemoved, rc = pcall(timetable.maintainTimetableData)
                    if okM then
                        if guiRemoved and guiRemoved > 0 then
                            timetableChanged = true
                        end
                        if rc and (rc.rekeyed or 0) + (rc.removed or 0) > 0 then
                            timetableChanged = true
                        end
                    end
                    -- Unconditionally refill the station tab's right table (if a station is selected): even if lineExists fails due to a stale engine cache
                    -- and cleanup didn't remove the orphans, the display-layer filtering of fillStationTabLineTable/fillWaypointTabLineTable during the refill
                    -- (lineExists + getLineName=="ERROR") skips orphaned rows and clears leftover ERROR rows.
                    pcall(function()
                        local selIdx = UIState.currentlySelectedStationTabStation
                        local entry = selIdx and menu.stationTabEntryData and menu.stationTabEntryData[selIdx]
                        if entry then
                            if entry.type == "waypoint" then
                                timetableGUI.fillWaypointTabLineTable(entry.gwKey)
                            elseif entry.type == "station" then
                                timetableGUI.fillStationTabLineTable(entry.id)
                            end
                        end
                    end)
                end
            end
            -- Punctuality detection: GUI thread scans once per second, throttled (same thread as diagram_gui, _G data directly visible)
            pcall(timetableGUI.updatePunctuality)
            if timetableChanged or _G._diagramForceSync then
                _G._diagramForceSync = nil
                timetable.bumpRevision()
                pcall(function() game.interface.sendScriptEvent("timetableUpdate", "", timetable.getTimetableObject()) end)
                timetableChanged = false
            end
            if clearConstraintWindowLaterHACK then
                clearConstraintWindowLaterHACK()
                clearConstraintWindowLaterHACK = nil
            end
            -- Delayed refresh of the intermediate station table summary: about 1s after SpinBox/name input stops, rebuild the intermediate table so the condition summary shows the new arrival/departure times
            if stationSummaryRefreshDue and realTimeNow() >= stationSummaryRefreshDue then
                stationSummaryRefreshDue = nil
                pcall(function()
                    if UIState.currentlySelectedLineTableIndex ~= nil and menu.stationTable then
                        timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
                    end
                end)
            end

            if not clockstate then
                -- Module reload guard (approach 2, idempotency check): clockstate is a module-level local and becomes nil after a Lua VM module reload,
                -- so this block runs again and would add the separator/clock/buttons to the gameInfo toolbar again -- which also makes other mods adding icons
                -- to the same toolbar (e.g. Copy It!) show "two icons". Before creating, getById checks whether the button already exists in the engine:
                -- after a reload the components survive in the engine (getById hits) -> don't create again, just restore the clock reference from _G;
                -- components destroyed (getById returns nil) -> create again, self-healing.
                local existingTtBtn = nil
                pcall(function() existingTtBtn = api.gui.util.getById("gameInfo.timetables.button") end)
                if existingTtBtn then
                    -- Reload case: the button is still alive in the engine, don't create again; restore the clock reference from _G (the clock keeps running).
                    -- In the extreme case that the _G reference is lost too, the clock stops updating but the button stays usable.
                    clockstate = _G._timetableClockLabel
                else
                    -- element for the divider
                    local line = api.gui.comp.Component.new("VerticalLine")
                    -- element for the icon
                    local icon = api.gui.comp.ImageView.new("ui/clock_small.tga")
                    -- element for the time
                    clockstate = api.gui.comp.TextView.new("gameInfo.time.label")
                    _G._timetableClockLabel = clockstate

                    local buttonLabel = gui.textView_create("gameInfo.timetables.label", UIStrings.timetable)

                    local button = gui.button_create("gameInfo.timetables.button", buttonLabel)
                    button:onClick(function ()
                        local err, msg = pcall(timetableGUI.showLineMenu)
                        if not err then
                            menu.window = nil
                            print(msg)
                        end
                    end)
                    game.gui.boxLayout_addItem("gameInfo.layout", button.id)

                    -- Add the diagram button
                    local diagramButtonLabel = gui.textView_create("gameInfo.diagram.label", UIStrings.title_short)
                    local diagramButton = gui.button_create("gameInfo.diagram.button", diagramButtonLabel)
                    diagramButton:onClick(function ()
                        local err, msg = pcall(diagramGUI.showDiagram)
                        if not err then
                            print(msg)
                        end
                    end)
                    game.gui.boxLayout_addItem("gameInfo.layout", diagramButton.id)

                    -- The rotation system button moved to the separate mod TrainRoute (created in its game_script's guiUpdate)

                    -- add elements to ui
                    local gameInfo = api.gui.util.getById("gameInfo")
                    if gameInfo then
                        local gameInfoLayout = gameInfo:getLayout()
                        gameInfoLayout:addItem(line)
                        gameInfoLayout:addItem(icon)
                        gameInfoLayout:addItem(clockstate)
                    end
                end
            end

            local time = timetableHelper.getTime()

            if clockstate and time then
                clockstate:setText(os.date('%M:%S', time))
            end
        end
    }
end

return timetableGUI
