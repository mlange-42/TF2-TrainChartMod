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
		title_short = _("diagram_title_short_i18n"),
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
                timetableGUI.makePassingWindow(lineID, stopInfo.id, stopInfo.gwKey)
            else
                timetableGUI.clearConstraintWindow()
            end
        end)

        local infoImage = api.gui.comp.ImageView.new("ui/info_small.tga")
        infoImage:setTooltip(UIStrings.wp_tooltip)
        infoImage:setName("timetable-info-icon")

        local table = api.gui.comp.Table.new(2, 'NONE')
        table:addRow({infoImage, comboBox})
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

            timetableGUI.clearConstraintWindow()
            if i == 1 then
                timetableGUI.makeArrDepWindow(lineID, stopInfo.stopIndex)
            elseif i == 2 then
                timetableGUI.makeDebounceWindow(lineID, stopInfo.stopIndex)
            end
        end)

        local infoImage = api.gui.comp.ImageView.new("ui/info_small.tga")
        infoImage:setTooltip(UIStrings.tooltip)
        infoImage:setName("timetable-info-icon")

        local table = api.gui.comp.Table.new(2, 'NONE')
        table:addRow({infoImage, comboBox})
        menu.constraintTable:addRow({table})
        comboBox:setSelected(constraintIndex, true)
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
            timetableGUI.clearConstraintWindow()
            timetableGUI.makeArrDepWindow(lineID, stationID)
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
        end)

        local deleteButton = api.gui.comp.Button.new(api.gui.comp.TextView.new("X") ,true)
        deleteButton:onClick(function()
            timetable.removeCondition(lineID, stationID, "ArrDep", k)
            timetableChanged = true
            clearConstraintWindowLaterHACK = function()
                timetableGUI.initStationTable()
                timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
                timetableGUI.clearConstraintWindow()
                timetableGUI.makeArrDepWindow(lineID, stationID)
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
        end)

        local departureSec = api.gui.comp.DoubleSpinBox.new()
        departureSec:setMinimum(0,false)
        departureSec:setMaximum(59,false)
        departureSec:setValue(v[4],false)
        departureSec:onChange(function(value)
            timetable.updateArrDep(lineID, stationID, k, 4, value)
            timetableChanged = true
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
    if ok and inputField then
        nameInput = inputField
        if currentName and #currentName > 0 then
            nameInput:setText(currentName, false)
        end
        nameInput:onChange(function(text)
            pcall(function()
                timetable.setWaypointName(lineID, wpEntity, text)
                if gwKey then
                    timetable.setGlobalWaypointName(gwKey, text)
                end
                timetableChanged = true
            end)
        end)
        pcall(function()
            nameInput:onFocusLost(function()
                clearConstraintWindowLaterHACK = function()
                    timetableGUI.initStationTable()
                    timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
                    timetableGUI.clearConstraintWindow()
                    timetableGUI.makePassingWindow(lineID, wpEntity, gwKey)
                end
            end)
        end)
    end
    local nameTable = api.gui.comp.Table.new(2, 'NONE')
    nameTable:setColWidth(0,80)
    local nameLabel = api.gui.comp.TextView.new(UIStrings.name_label)
    if nameInput then
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
            timetableGUI.clearConstraintWindow()
            timetableGUI.makePassingWindow(lineID, wpEntity, gwKey)
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
            end)

            local secSpinner = api.gui.comp.DoubleSpinBox.new()
            secSpinner:setMinimum(0,false)
            secSpinner:setMaximum(59,false)
            secSpinner:setValue(t[2], false)
            secSpinner:onChange(function(value)
                timetable.updateWaypointPassingTimeEntry(lineID, wpEntity, k, 2, value)
                timetableChanged = true
            end)

            local deleteBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new("X"), true)
            deleteBtn:onClick(function()
                timetable.removeWaypointPassingTime(lineID, wpEntity, k)
                timetableChanged = true
                clearConstraintWindowLaterHACK = function()
                    timetableGUI.initStationTable()
                    timetableGUI.fillStationTable(UIState.currentlySelectedLineTableIndex, false)
                    timetableGUI.clearConstraintWindow()
                    timetableGUI.makePassingWindow(lineID, wpEntity, gwKey)
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


function timetableGUI.timetableCoroutine()
    while true do
        local vehiclesWithLines = timetableHelper.getAllTimetableRailVehicles(timetable.hasTimetable)
        for _,vehicle in pairs(vehiclesWithLines) do
            --if timetableHelper.isInStation(vehicle) then
                if timetable.waitingRequired(tostring(vehicle)) then
                    timetableHelper.stopVehicle(tostring(vehicle))
                else
                    timetableHelper.startVehicle(tostring(vehicle))
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
            if timetableChanged or _G._diagramForceSync then
                _G._diagramForceSync = nil
                pcall(function() game.interface.sendScriptEvent("timetableUpdate", "", timetable.getTimetableObject()) end)
                timetableChanged = false
            end
            if clearConstraintWindowLaterHACK then
                clearConstraintWindowLaterHACK()
                clearConstraintWindowLaterHACK = nil
            end

            if not clockstate then
				-- element for the divider
				local line = api.gui.comp.Component.new("VerticalLine")
				-- element for the icon
                local icon = api.gui.comp.ImageView.new("ui/clock_small.tga")
                -- element for the time
				clockstate = api.gui.comp.TextView.new("gameInfo.time.label")

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

            local time = timetableHelper.getTime()

            if clockstate and time then
                clockstate:setText(os.date('%M:%S', time))
            end
        end
    }
end

return timetableGUI
