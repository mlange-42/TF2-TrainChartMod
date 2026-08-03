local timetable = require "celmi/timetables/timetable"
local timetableHelper = require "celmi/timetables/timetable_helper"
local diagramGUI = require "celmi/timetables/diagram_gui"

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
local stationSummaryRefreshDue = nil  -- 中间站表摘要延迟刷新的游戏时间（秒）

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
	}

local local_styles = {
    zh_CN = "timetable-mono-sc",
    zh_TW = "timetable-mono-tc",
    ja = "timetable-mono-ja",
    kr = "timetable-mono-kr"
}
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
    menu.stationTabScrollArea = api.gui.comp.ScrollArea.new(stationOverview, "timetable.stationTabStationOverviewScrollArea")
    menu.stationTabStationTable = api.gui.comp.Table.new(1, 'SINGLE')
    menu.stationTabScrollArea:setMinimumSize(api.gui.util.Size.new(300, 700))
    menu.stationTabScrollArea:setMaximumSize(api.gui.util.Size.new(300, 700))
    menu.stationTabScrollArea:setContent(menu.stationTabStationTable)
    timetableGUI.fillStationTabStationTable()
    if UIState.floatingLayoutStationTab then UIState.floatingLayoutStationTab:addItem(menu.stationTabScrollArea,0,0) end

    menu.stationTabLinesScrollArea = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('LineOverview'), "timetable.stationTabLinesScrollArea")
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
        local lineName = timetableHelper.getLineName(k)
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
        local lineName = timetableHelper.getLineName(lineStr)
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
    end

    local order = timetableHelper.getOrderOfArray(lineNames)
    menu.stationTabLinesTable:setOrder(order)
end

-------------------------------------------------------------
---------------------- SETUP --------------------------------
-------------------------------------------------------------

function timetableGUI.initLineTable()
    -- removeItem 前确保组件属于当前布局：重开路径（showLineMenu）已重置 menu.scrollArea=nil，
    -- 这里仅在实际存在且属于当前布局时移除（正常运行中 initLineTable 被重复调用时避免重复 addItem）。
    if menu.scrollArea then
        pcall(function()
            local tmp = menu.scrollArea:getScrollOffset()
            lineTableScrollOffset = api.type.Vec2i.new(tmp.x, tmp.y)
        end)
        pcall(function() UIState.boxlayout2:removeItem(menu.scrollArea) end)
    else
        lineTableScrollOffset = api.type.Vec2i.new()
    end

    menu.scrollArea = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('LineOverview'), "timetable.LineOverview")
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
    -- removeItem 前确保组件属于当前布局：重开路径（showLineMenu）已重置引用为 nil。
    if menu.stationScrollArea then
        pcall(function()
            local tmp = menu.stationScrollArea:getScrollOffset()
            stationTableScrollOffset = api.type.Vec2i.new(tmp.x, tmp.y)
        end)
        pcall(function() UIState.boxlayout2:removeItem(menu.stationScrollArea) end)
    else
        stationTableScrollOffset = api.type.Vec2i.new()
    end

    menu.stationScrollArea = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('stationScrollArea'), "timetable.stationScrollArea")
    menu.stationTable = api.gui.comp.Table.new(4, 'SINGLE')
    menu.stationTable:setColWidth(0,40)
    menu.stationTable:setColWidth(1,120)
    menu.stationScrollArea:setMinimumSize(api.gui.util.Size.new(500, 700))
    menu.stationScrollArea:setMaximumSize(api.gui.util.Size.new(500, 700))
    menu.stationScrollArea:setContent(menu.stationTable)
    UIState.boxlayout2:addItem(menu.stationScrollArea,0.5,0)
end

function timetableGUI.initConstraintTable()
    -- removeItem 前确保组件属于当前布局：重开路径（showLineMenu）已重置引用为 nil。
    if menu.scrollAreaConstraint then
        pcall(function()
            local tmp = menu.scrollAreaConstraint:getScrollOffset()
            constraintTableScrollOffset = api.type.Vec2i.new(tmp.x, tmp.y)
        end)
        pcall(function() UIState.boxlayout2:removeItem(menu.scrollAreaConstraint) end)
    else
        constraintTableScrollOffset = api.type.Vec2i.new()
    end

    menu.scrollAreaConstraint = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('scrollAreaConstraint'), "timetable.scrollAreaConstraint")
    menu.constraintTable = api.gui.comp.Table.new(1, 'NONE')
    menu.scrollAreaConstraint:setMinimumSize(api.gui.util.Size.new(300, 700))
    menu.scrollAreaConstraint:setMaximumSize(api.gui.util.Size.new(300, 700))
    menu.scrollAreaConstraint:setContent(menu.constraintTable)
    UIState.boxlayout2:addItem(menu.scrollAreaConstraint,1,0)
end

function timetableGUI.showLineMenu()
    if menu.window ~= nil then
        -- 重开路径：窗口通过 addHideOnCloseHandler 隐藏而非销毁，其布局/组件仍存活。
        -- 直接显示即可，绝不重建布局（新建布局未挂到窗口、对旧组件 removeItem 都会出问题）。
        local ok = pcall(function()
            menu.window:setVisible(true, true)
        end)
        if ok then
            _G._timetableVisible = true
            return
        end
        -- setVisible 失败说明窗口已失效，重置后走全新创建
        menu.window = nil
        menu.lineTableItems = {}
        menu.scrollArea = nil
        menu.lineHeader = nil
        menu.stationScrollArea = nil
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

    -- 设置 Tab：晚点判定标准（全局设置，随存档永久保存；0=无）
    local wrapper3 = api.gui.comp.Component.new("wrapper3")
    local settingsLayout = api.gui.layout.BoxLayout.new("VERTICAL")
    wrapper3:setLayout(settingsLayout)
    local tolRow = api.gui.comp.Component.new("delayTolRow")
    local tolRowLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
    tolRow:setLayout(tolRowLayout)
    local tolLabel = api.gui.comp.TextView.new(UIStrings.delay_tol)
    tolLabel:setStyleClassList({"timetable-mono-sc"})
    tolRowLayout:addItem(tolLabel)
    -- 选项：无 / 5:00 / 10:00 / 20:00 / 30:00（秒数）
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
    menu.tabWidget:addTab(api.gui.comp.TextView.new(UIStrings.settings), wrapper3)

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
        menu.scrollAreaConstraint = nil
        menu.lineHeader = nil
        menu.stationTabScrollArea = nil
        menu.stationTabLinesScrollArea = nil
        clearConstraintWindowLaterHACK = nil
        stationSummaryRefreshDue = nil
        timetableChanged = false
        _G._timetableVisible = false
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

    local header1 = api.gui.comp.TextView.new(UIStrings.frequency .. " " .. timetableHelper.getFrequency(lineID))
    local header2 = api.gui.comp.TextView.new("")
    local header3 = api.gui.comp.TextView.new("")
    local header4 = api.gui.comp.TextView.new("")
    menu.stationTable:setHeader({header1,header2, header3, header4})

    local stationLegTime = timetableHelper.getLegTimes(lineID)
    menu.allStops = timetableHelper.getAllStops(lineID)

    -- 为路径点覆盖自定义名称
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
                end
            end
        end
    end

    for flatIdx, stopInfo in ipairs(menu.allStops) do
        if stopInfo.type == "station" then
            local origIdx = stopInfo.stopIndex
            local vehiclePositions = timetableHelper.getTrainLocations(lineID)
            if vehiclePositions[tostring(origIdx-1)] then
                if vehiclePositions[tostring(origIdx-1)].atTerminal then
                    if vehiclePositions[tostring(origIdx-1)].countStr == "MANY" then
                        menu.lineImage[flatIdx] = api.gui.comp.ImageView.new("ui/timetable_line_train_in_station_many.tga")
                    else
                        menu.lineImage[flatIdx] = api.gui.comp.ImageView.new("ui/timetable_line_train_in_station.tga")
                    end
                else
                    if vehiclePositions[tostring(origIdx-1)].countStr == "MANY" then
                        menu.lineImage[flatIdx] = api.gui.comp.ImageView.new("ui/timetable_line_train_en_route_many.tga")
                    else
                        menu.lineImage[flatIdx] = api.gui.comp.ImageView.new("ui/timetable_line_train_en_route.tga")
                    end
                end
            else
                menu.lineImage[flatIdx] = api.gui.comp.ImageView.new("ui/timetable_line.tga")
            end
            local x = menu.lineImage[flatIdx]
            menu.lineImage[flatIdx]:onStep(function()
                if not x then print("ERRROR") return end
                local vp2 = timetableHelper.getTrainLocations(lineID)
                if vp2[tostring(origIdx-1)] then
                    if vp2[tostring(origIdx-1)].atTerminal then
                        if vp2[tostring(origIdx-1)].countStr == "MANY" then
                            x:setImage("ui/timetable_line_train_in_station_many.tga", false)
                        else
                            x:setImage("ui/timetable_line_train_in_station.tga", false)
                        end
                    else
                        if vp2[tostring(origIdx-1)].countStr == "MANY" then
                            x:setImage("ui/timetable_line_train_en_route_many.tga", false)
                        else
                            x:setImage("ui/timetable_line_train_en_route.tga", false)
                        end
                    end
                else
                    x:setImage("ui/timetable_line.tga", false)
                end
            end)
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
        if stopInfo.type == "station" and stationLegTime and stationLegTime[stopInfo.stopIndex] then
            jurneyTime = api.gui.comp.TextView.new(UIStrings.journey_time .. ": " .. os.date('%M:%S', stationLegTime[stopInfo.stopIndex]))
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

-- 整表重建右侧约束窗口（新建 Table + 重新填充）。旧组件清除靠"重建新 Table"而非
-- deleteRows/deleteAll——引擎对表格 deleteRows/deleteAll 可能未完全释放嵌套的
-- DoubleSpinBox 组件，导致时间输入框"重影"（旧值叠在新值上）。仅重建 UI，不改数据；
-- 当前选中站由 UIState.currentlySelectedStationIndex 决定。
function timetableGUI.rebuildConstraintWindow(lineID)
    if not lineID then return end
    timetableGUI.initConstraintTable()
    timetableGUI.fillConstraintTable(UIState.currentlySelectedStationIndex or 0, lineID)
end

-- 手动"刷新"按钮：保存当前所有输入（时间/路径点名/通过时间——onChange 已逐位写入数据）
-- 并整表重建 中间站表 + 右侧约束窗口，让界面各处立即显示最新值，同时触发跨线程同步。
-- 用 HACK 延迟到下一帧执行，避免在按钮点击事件内重建自身组件。
function timetableGUI.refreshTimetableUI(lineID)
    if not lineID then return end
    timetableChanged = true
    clearConstraintWindowLaterHACK = function()
        timetableGUI.initStationTable()
        timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
        timetableGUI.rebuildConstraintWindow(lineID)
    end
end

-- 中间站表摘要延迟刷新：onChange 逐位触发时不断重置计时，输入停顿约 1s（游戏时间）后
-- 才重建中间站表，让该行条件摘要（到发时间等）显示新值。只刷中间表、不重建右侧约束窗口，
-- 避免打断 SpinBox 输入焦点（AGENTS.md "13:30 变 00:30" 教训）。
function timetableGUI.scheduleStationSummaryRefresh()
    stationSummaryRefreshDue = timetableHelper.getTime() + 1
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
            if i == 1 then
                -- 先清残留行再构建，避免反复切换 None/Passing 时旧输入框叠加"重影"
                timetableGUI.clearConstraintWindow()
                timetableGUI.makePassingWindow(lineID, stopInfo.id, stopInfo.gwKey)
            else
                timetableGUI.clearConstraintWindow()
            end
        end)

        local infoImage = api.gui.comp.ImageView.new("ui/info_small.tga")
        infoImage:setTooltip(UIStrings.wp_tooltip)
        infoImage:setName("timetable-info-icon")

        -- 刷新按钮：一键保存所有时间/路径点名/通过时间并刷新时刻表界面（含路径点）
        local refreshBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(UIStrings.refresh), true)
        refreshBtn:onClick(function()
            timetableGUI.refreshTimetableUI(lineID)
        end)

        local table = api.gui.comp.Table.new(3, 'NONE')
        table:addRow({infoImage, comboBox, refreshBtn})
        menu.constraintTable:addRow({table})
        comboBox:setSelected(selectedIdx, false)

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
            -- 整表重建右侧约束窗口（新建 Table + 重新填充），彻底清除旧 DoubleSpinBox，
            -- 避免 deleteRows/deleteAll 未完全释放组件导致时间输入框"重影"
            local rebuildIdx = (stopInfo and stopInfo.flatIndex and stopInfo.flatIndex - 1)
                              or UIState.currentlySelectedStationIndex or 0
            timetableGUI.initConstraintTable()
            timetableGUI.fillConstraintTable(rebuildIdx, lineID)
        end)

        local infoImage = api.gui.comp.ImageView.new("ui/info_small.tga")
        infoImage:setTooltip(UIStrings.tooltip)
        infoImage:setName("timetable-info-icon")

        -- 刷新按钮：一键保存所有到发/间隔时间并刷新时刻表界面
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
            -- 注意：不要在 onChange 里重建 UI（initStationTable/fillStationTable）。
            -- 输入过程中每次重建会打断 SpinBox 焦点/值，导致"13:30 变 00:30"的概率性丢值。
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

function timetableGUI.makePassingWindow(lineID, wpEntity, gwKey)
    if not menu.constraintTable then return end
    local currentName = ""
    if gwKey then
        currentName = timetable.getGlobalWaypointName(gwKey) or ""
    end
    if currentName == "" then
        currentName = timetable.getWaypointName(lineID, wpEntity) or ""
    end

    -- 名称编辑
    local nameInput = nil
    local ok, inputField = pcall(function()
        return api.gui.comp.TextInputField.new("")
    end)
    -- 提交名字（全局改名：_G._gwNames + timetableObject 双写，含 per-line 覆盖），不要破坏全局语义
    local function commitName(text)
        pcall(function()
            timetable.setWaypointName(lineID, wpEntity, text)
            if gwKey then
                timetable.setGlobalWaypointName(gwKey, text)
            end
            timetableChanged = true
        end)
    end
    -- 立即刷新：重建中间站表 + 右侧约束窗口，让新名字全局生效（与 +/X 同款重建路径）
    local function refreshWaypointUI()
        clearConstraintWindowLaterHACK = function()
            timetableGUI.initStationTable()
            timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
            timetableGUI.rebuildConstraintWindow(lineID)
        end
    end
    if ok and inputField then
        nameInput = inputField
        if currentName and #currentName > 0 then
            nameInput:setText(currentName, false)
        end
        nameInput:onChange(function(text)
            commitName(text)
        end)
        pcall(function()
            nameInput:onFocusLost(function()
                refreshWaypointUI()
            end)
        end)
    end
    local nameTable = api.gui.comp.Table.new(2, 'NONE')
    nameTable:setColWidth(0,80)
    local nameLabel = api.gui.comp.TextView.new(UIStrings.name_label)
    if nameInput then
        -- 名字由 onChange 逐字写入 + 顶部"刷新"按钮统一保存重建，不再单独设保存按钮
        nameTable:addRow({nameLabel, nameInput})
    else
        local showName = api.gui.comp.TextView.new(currentName and #currentName > 0 and currentName or UIStrings.rename_hint)
        showName:setStyleClassList({"timetable-mono-sc"})
        nameTable:addRow({nameLabel, showName})
    end
    menu.constraintTable:addRow({nameTable})

    -- 通过时间编辑(多组，支持添加删除)
    local times = timetable.getWaypointPassingTime(lineID, wpEntity)

    -- header + 添加按钮
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


-- 准点检测（引擎线程，存档加载后持续运行，不依赖运行图窗口打开）：
-- 状态机扫描所有车辆，检测 进站(state→2)/发车(lineStopDepartures 变非0) 瞬间，
-- 记录实际到发时间，与时刻表 ArrDep 计划时间对比，算晚点/正点/早点，存 _G._punctuality。
-- 显示的是"上一站"的到发判定（用户需求：列车在 A→B 途中显示 A 站的早晚点）。
--
-- _G._punctuality[vehicleId] = {
--   lineId, lineName, lastStopIndex, lastState,
--   lastArrTime, lastDepTime,          -- 上一站实际到/发秒（game 绝对秒）
--   plArr, plDep,                      -- 上一站选定的那套时刻表 绝对计划到/发秒
--   arrDiff, depDiff,                  -- 上一站 到/发 偏差秒（正=晚 负=早）
--   arrPunct, depPunct,                -- "early"/"late"/"ontime"（上一站）
--   stationName,                       -- 上一站站名
-- }
local punctualityState = {}

-- 从该站的多套 ArrDep 时刻中选出列车实际运行的那一套（绝对到达时刻离实际到达最近），
-- 返回该套的绝对计划到/发时刻。stationNumber 从 1 开始。
-- 旧实现 getPlannedTime 硬编码取 conds[1]（第一套）：一条线路配多套时刻表时，
-- 列车实际跑第二套也拿第一套判正晚点（如站2 第一套 26:30 / 第二套 51:00，
-- 列车 26:45 到会按 51:00 判，出现几十分钟的假晚点/假早点）。
local function getPlannedArrDep(lineID, stationNumber, actualArrTime)
    local ct = timetable.getConditionType(lineID, stationNumber)
    if ct ~= "ArrDep" then return nil, nil end
    local conds = timetable.getConditions(lineID, stationNumber, "ArrDep")
    if not conds or #conds == 0 then return nil, nil end
    local bestArr, bestDep = nil, nil
    local bestDist = math.huge
    for _, c in ipairs(conds) do
        local arr = (c[1] * 60 + c[2]) % 3600
        local dep = (c[3] * 60 + c[4]) % 3600
        -- 周期取"到达时刻离实际到达最近"的那一趟（与 waitingRequired 槽位分配一致）
        local k = math.floor((actualArrTime - arr + 1800) / 3600)
        local absArr = arr + 3600 * k
        local absDep = dep + 3600 * k
        if absDep < absArr then absDep = absDep + 3600 end
        local dist = math.abs(actualArrTime - absArr)
        if dist < bestDist then
            bestDist = dist
            bestArr, bestDep = absArr, absDep
        end
    end
    return bestArr, bestDep
end

-- 晚点/正点/早点判定：|diff|<=10s 正点，正=晚 负=早
local function classify(diff)
    if not diff then return "ontime" end
    if diff > 10 then return "late" end
    if diff < -10 then return "early" end
    return "ontime"
end

function timetableGUI.updatePunctuality()
    if not _G._punctuality then _G._punctuality = {} end
    local now = timetableHelper.getTime()
    if not _G._punctNext then _G._punctNext = 0 end
    if now < _G._punctNext then return end
    _G._punctNext = now + 1  -- 每秒扫一次（getTime 整秒）

    local vehicleMap = api.engine.system.transportVehicleSystem.getLine2VehicleMap()
    for lineID, vehicles in pairs(vehicleMap) do
        local lineName = nil
        pcall(function()
            local nc = api.engine.getComponent(lineID, api.type.ComponentType.NAME)
            if nc and nc.name then lineName = nc.name end
        end)
        if vehicles then
            for _, vehicle in pairs(vehicles) do
                local vId = tostring(vehicle)
                local okC, vc = pcall(function()
                    return api.engine.getComponent(vehicle, 70)
                end)
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

                    -- 进站检测：state 从 非2 → 2（停稳）记录当前站到达时间；
                    -- 或 停靠站已变化（快速进出站漏拍 state 1/上次扫描未更新 thisStopIndex 时兜底）
                    if vc.state == 2 and (st.lastState ~= 2 or vc.stopIndex ~= st.thisStopIndex) then
                        st.thisStopIndex = vc.stopIndex
                        st.arrTime = now
                        st.depTime = nil
                        st.arrDone = false
                        st.stationName = nil
                        pcall(function()
                            local sg = api.engine.getComponent(vc.stopIndex, api.type.ComponentType.NAME)
                            if sg and sg.name then st.stationName = sg.name end
                        end)
                        -- 进站立即用到达偏差判定（早到/正点/晚点），发车前即可显示。
                        -- 多套时刻表时自动选"绝对到达时刻离实际到达最近"的那一套（getPlannedArrDep），
                        -- 避免列车跑第二套却拿第一套判正晚点。
                        local plArr, plDep = getPlannedArrDep(lineID, vc.stopIndex + 1, now)
                        if plArr and plDep then
                            st.plArr, st.plDep = plArr, plDep
                            st.arrDiff = st.arrTime - plArr
                            st.arrPunct = classify(st.arrDiff)
                        end
                    end

                    -- 发车检测：读当前停靠站的实际发车时间（lineStopDepartures[thisStopIndex+1]）。
                    -- 该值在车发车后写入（如 time=360 发车 → 值 360），且发车后 stopIndex 前进、
                    -- state 变 1 时仍保留历史值，故不依赖 state==2，只要该站 dep 从 0/旧值变非 0 即判定发车。
                    -- 不依赖 st.arrTime：即使到站事件漏拍（短停站/加载时已停稳），发车事件也能被捕获并给出发车判定。
                    if not st.arrDone then
                        local depTime = nil
                        if vc.lineStopDepartures and st.thisStopIndex then
                            local d = vc.lineStopDepartures[st.thisStopIndex + 1]
                            if d and d > 0 then depTime = math.floor(d / 1000) end
                        end
                        -- 发车定案：引擎已给出该站实际发车秒
                        if depTime and depTime ~= st.depTime then
                            st.depTime = depTime
                            st.arrDone = true
                            -- 复用进站时选定的那套时刻表；进站未判定的兜底重选
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

                    -- 站变化（前进）：当前停靠站改变，重新开始新站采集
                    if vc.stopIndex ~= st.thisStopIndex and vc.state ~= 2 then
                        -- 行驶中换站，重置待采集状态（等下次进站）
                        st.thisStopIndex = vc.stopIndex
                        if st.arrDone then
                            -- 上一站已定案，保留其判定；准备采新站
                        end
                    end

                    st.lastState = vc.state
                    st.lineId = lineID
                    st.lineName = lineName or st.lineName
                end
            end
        end
    end

    -- 同步到 _G 供 GUI 线程读取（GUI 线程读 _G 即可，无需跨线程事件）
    _G._punctuality = punctualityState
end

function timetableGUI.timetableCoroutine()
    while true do
        local vehiclesWithLines = timetableHelper.getAllTimetableRailVehicles(timetable.hasTimetable)
        for _,vehicle in pairs(vehiclesWithLines) do
            --if timetableHelper.isInStation(vehicle) then
                local vehicleStr = tostring(vehicle)
                -- 记录"等待→放行"瞬间：放行时若之前正被扣车，则调 forceDeparture
                -- 真正启动车辆（否则仅 setVehicleManualDeparture(false) 可能不立即发车）。
                local wasWaiting = timetable.isVehicleWaiting(vehicleStr)
                if timetable.waitingRequired(vehicleStr) then
                    timetableHelper.stopVehicle(vehicleStr)
                else
                    timetableHelper.startVehicle(vehicleStr)
                    if wasWaiting then timetableHelper.forceDeparture(vehicleStr) end
                end
            --end
            coroutine.yield()
        end
        coroutine.yield()
    end
end

function data()
    return {
        --engine Thread

        handleEvent = function (_, id, _, param)
            if id == "timetableUpdate" then
                if state == nil then state = {timetable = {}} end
                state.timetable = param
                timetable.setTimetableObject(state.timetable)
                timetableChanged = true
            end
        end,

        save = function()
            return state
        end,

        load = function(loadedState)
            if loadedState == nil  or next(loadedState) == nil then  return end
            if loadedState.timetable then
                timetable.setTimetableObject(loadedState.timetable)
            end

            if loadedState.currentlyWaiting then
                timetable.setCurrentlyWaiting(loadedState.currentlyWaiting)
            end

            if loadedState.diagramConfig then
                timetable.setDiagramConfig(loadedState.diagramConfig)
            end

            if loadedState.timetable and loadedState.timetable._gwNames then
                _G._gwNames = loadedState.timetable._gwNames
            end

            state = loadedState or {timetable = {}}
        end,

        update = function()
            if state == nil then state = {timetable = {}}end
            if co == nil or coroutine.status(co) == "dead" then
                co = coroutine.create(timetableGUI.timetableCoroutine)
            end
            for _ = 0, 20 do
                local err, msg = coroutine.resume(co)
                if not err then print(msg) end
            end

            -- 准点检测移到 guiUpdate（GUI 线程）执行：
            -- GUI 线程能读引擎 API，且与 diagram_gui 同线程，数据写 _G._punctuality 直接可见
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
            -- 准点检测：GUI 线程每秒节流扫描（与 diagram_gui 同线程，_G 数据直接可见）
            pcall(function() timetableGUI.updatePunctuality() end)
            if timetableChanged or _G._diagramForceSync then
                _G._diagramForceSync = nil
                pcall(function() game.interface.sendScriptEvent("timetableUpdate", "", timetable.getTimetableObject()) end)
                timetableChanged = false
            end
            if clearConstraintWindowLaterHACK then
                clearConstraintWindowLaterHACK()
                clearConstraintWindowLaterHACK = nil
            end
            -- 中间站表摘要延迟刷新：SpinBox 输入停止约 1s 后重建中间表，让条件摘要显示新到发时间
            if stationSummaryRefreshDue and timetableHelper.getTime() >= stationSummaryRefreshDue then
                stationSummaryRefreshDue = nil
                pcall(function()
                    if UIState.currentlySelectedLineTableIndex ~= nil and menu.stationTable then
                        timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
                    end
                end)
            end

            if not clockstate then
                -- 模块重载防御（改法2·幂等检查）：clockstate 是模块级 local，Lua VM 重载模块后归 nil，
                -- 本块会重跑，向 gameInfo 工具栏重复添加分割线/时钟/按钮——也会连带其它往同一工具栏
                -- 加图标的 mod（如 Copy It!）出现"两个图标"。创建前先 getById 查引擎中是否已有按钮：
                -- 重载后组件在引擎中存活（getById 命中）→ 不重复创建，只从 _G 恢复时钟引用；
                -- 组件被销毁（getById 返回 nil）→ 重新创建，自愈。
                local existingTtBtn = nil
                pcall(function() existingTtBtn = api.gui.util.getById("gameInfo.timetables.button") end)
                if existingTtBtn then
                    -- 重载场景：引擎中按钮仍存活，不重复创建；从 _G 恢复时钟引用（时钟继续走）。
                    -- 极端情况若 _G 引用也丢失，时钟停止更新但按钮保持可用。
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

                    -- 添加运行图按钮
                    local diagramButtonLabel = gui.textView_create("gameInfo.diagram.label", UIStrings.title_short)
                    local diagramButton = gui.button_create("gameInfo.diagram.button", diagramButtonLabel)
                    diagramButton:onClick(function ()
                        local err, msg = pcall(diagramGUI.showDiagram)
                        if not err then
                            print(msg)
                        end
                    end)
                    game.gui.boxLayout_addItem("gameInfo.layout", diagramButton.id)

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
