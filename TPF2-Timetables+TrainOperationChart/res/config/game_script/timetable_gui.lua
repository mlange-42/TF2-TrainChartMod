local timetable = require "celmi/timetables/timetable"
local timetableHelper = require "celmi/timetables/timetable_helper"
local diagramGUI = require "celmi/timetables/diagram_gui"

-- 交路系统已独立为 TrainRoute mod（res/scripts/trainroute）。本 mod 不再 require 它，
-- 而是读取 TrainRoute 注册的 _G._trainRouteHooks（引擎线程）/ _G._trainRouteDiagramHook（GUI 线程）：
-- 未安装 TrainRoute → 钩子为 nil → 行为与无交路系统时完全一致。

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
local stationSummaryRefreshDue = nil  -- 中间站表摘要延迟刷新的真实时间（os.clock 秒，暂停时也走）

-- 真实时间钟（os.clock，CPU 秒，单调递增）：游戏暂停（getTime 冻结）时 debounce 也能触发，
-- 用于"输入完自动刷新中间站表"，不依赖游戏世界时间推进。
local function realTimeNow()
    local ok, t = pcall(os.clock)
    if ok and t then return t end
    return 0
end

-- ===== 性能优化 A 组（2026-08-16 第 21 轮）：热路径 pcall 目标提到模块级 =====
-- 每秒的准点扫描 / 槽位镜像会对"每条线路 × 每辆车"各调若干次 pcall(function() … end)，
-- 每次执行都新建闭包 → 每秒上万次分配 → Lua GC 周期变短 → 玩家可感的周期性掉帧。
-- 改成 pcall(fn, args…) 复用模块级函数：错误保护语义不变，只去掉垃圾。
-- （函数体只在调用时访问 api —— 模块顶层不碰 api，遵守 AGENTS 铁律。）
local function _entityExists(id) return api.engine.entityExists(id) end
local function _getComponent(id, ctype) return api.engine.getComponent(id, ctype) end
local function _lineVehicleMap() return api.engine.system.transportVehicleSystem.getLine2VehicleMap() end
local function _slotMode(lineID) return timetable.getLineSlotMode(lineID) end
local function _vehCountCfg(lineID) return timetable.getLineVehicleCount(lineID) end
-- 真实时间秒；取不到返回 nil（保留"时钟不可用则本次不执行"的原语义）
local function rawRealSeconds()
    local ok, t = pcall(os.clock)
    if ok and type(t) == "number" then return t end
    return nil
end

-- 组件名计数器：ScrollArea 等组件名必须跨刷新周期唯一（AGENTS.md：removeItem 移除的
-- 组件名可能未被引擎即时释放，下次创建同名组件会冲突/addItem 静默失败，进而后续访问 nil）。
-- 窗口被运行图 Window.new() 销毁后重建时刻表时，若用固定名（"timetable.LineOverview" 等）
-- 会与残留旧名冲突 → 崩溃（attempt to index a nil value）。存 _G 抗 Lua VM 重载。
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

-- 数据同步结果弹窗：按线路分组列出"哪些站、每站新增几套到发时刻"。
-- report = { lines = { [lineKey] = { [stationNumber] = 新增套数 } }, totalSlots = N }
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
            parts[#parts + 1] = string.format(UIStrings.data_sync_line, lineName) .. table.concat(stationParts, "、")
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
        -- 孤儿线路（已被玩家删除）三重拦截：
        -- 1) lineExists 用 lineSystem.getLines() 当前线路集合判断（最可靠，删除的线路绝不在其中）；
        -- 2) getLineName 返回 "ERROR" 兜底（覆盖 getLines 调用失败的极端情况）。
        -- 注意：对已删除线路调 getComponent 可能触发 C++ assert（AGENTS.md），
        -- 故先用 lineExists 拦截再调 getLineName，避免走到 getComponent。
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
        -- 孤儿线路（已被玩家删除）双重拦截：先用 getLines 集合判断（可靠），
        -- 再以 getLineName 返回 "ERROR" 兜底。
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
    -- removeItem 前确保组件属于当前布局：重开路径（showLineMenu）已重置引用为 nil。
    -- 线路控车开关行（stationHeaderRow）先于滚动区移除（每次 init 重建，防堆积）。
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
    -- 高度 670：顶部让出 34px 给"线路控车开关行"（refreshStationHeaderRow 置于 (0.5,0)），
    -- 滚动区放 (0.5,1)——与左栏"排序行在上/列表在下"同款 FloatingLayout 锚点布局；总高保持 ~700。
    menu.stationScrollArea:setMinimumSize(api.gui.util.Size.new(500, 670))
    menu.stationScrollArea:setMaximumSize(api.gui.util.Size.new(500, 670))
    menu.stationScrollArea:setContent(menu.stationTable)
    UIState.boxlayout2:addItem(menu.stationScrollArea,0.5,1)
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

    menu.scrollAreaConstraint = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new('scrollAreaConstraint'), "timetable.scrollAreaConstraint_" .. nextScrollName())
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

    -- 数据同步：把旧版 mod（number 格式）时刻数据迁移到本 mod（string 格式），追加不覆盖。
    -- 由用户显式点击触发（不做读档自动迁移，保证用户知情）。同步后弹结果窗并刷新界面。
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
            -- 同步后刷新当前打开的时刻表界面（线路表 + 中间站表 + 右侧约束窗口），让新增时刻立即可见
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

    -- 说明页（"设置"Tab 右侧，与"设置"并列的独立界面——用户定稿，不用弹窗）：
    -- 讲解线路控车开关（到点发车 / 最小 / 最大停站时间）的组合逻辑。长帮助文本按语言内联
    -- （zh_CN/zh_TW 中文各一份，其余语言用英文），不逐行走 strings.lua（i18n 惯例：非中文=英文）。
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
        -- 本窗口已销毁/关闭，清掉全局引用：运行图 showDiagram 的 invokeLater 会对
        -- _G._timetableWindow 调 setVisible(true,false) 尝试恢复时刻表窗口——
        -- 若该引用指向已销毁窗口，会操作无效组件（崩溃）。清空后 restore 逻辑自然跳过。
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

-- 线路控车开关行（2026-08-16 功能）：频率 + 到点发车 / 最小停站时间 / 最大停站时间。
-- 独立固定行，置于中间站表滚动区上方 (0.5,0)——**不放进 Table:setHeader**：表头单元格
-- 引擎层不可点击、行高受限还会裁切文字（玩家实测 2026-08-16：默认勾选但点不了、频率底边被遮）。
-- 复用左栏"排序按钮行在列表上方"的同款模式：同一线路不重建（防刷新闪烁），换线路才
-- removeItem 旧行 + addItem 新行。勾选交互与左栏"遵循时刻表"复选框同构（Button 换图，实测可点）。
function timetableGUI.refreshStationHeaderRow(lineID)
    if menu.stationHeaderRow and menu.stationHeaderRowLineID == lineID then
        return  -- 同一线路：行已在布局中，不重建（fillStationTable 每次刷新都进来）
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
    -- 互斥语义（2026-08-16 玩家拍板）：到点发车 = "到点强发"模式，与 最小/最大停站时间 互斥。
    -- 勾选到点发车 → 清空 min/max 勾选（不再"置灰保留"——三格全勾太误导）；这里顺带自愈
    -- 旧版/旧档残留的 "force✓ + min/max✓" 状态（此前被置灰保留过）。清空要同步引擎（timetableChanged）。
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
            clearMinMax()  -- 勾选到点发车 = 切到点强发模式：清掉互斥的 min/max 勾选
        end
        updateMinMaxEnabled()
        timetableChanged = true
    end)
    local function makeToggle(btn, img, getter, setter)
        btn:onClick(function()
            if timetable.getForceDepartureEnabled(lineID) then return end  -- force 勾选时不可选（双保险）
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
    -- 行高 34：给足高度防止文字/复选框被裁（玩家反馈"频率下五分之一被遮"的根因是表头单元格行高太矮）。
    headerRow:setMinimumSize(api.gui.util.Size.new(460, 34))
    headerRow:setMaximumSize(api.gui.util.Size.new(460, 34))
    menu.stationHeaderRow = headerRow
    pcall(function() UIState.boxlayout2:addItem(headerRow, 0.5, 0) end)
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

    -- 线路控车开关（频率 + 到点发车/最小/最大停站时间）由 refreshStationHeaderRow 维护为
    -- 站表上方的独立固定行（不进 setHeader——表头单元格不可点击且会裁切文字，玩家实测）。
    timetableGUI.refreshStationHeaderRow(lineID)
    local header1 = api.gui.comp.TextView.new("")
    local header2 = api.gui.comp.TextView.new("")
    local header3 = api.gui.comp.TextView.new("")
    local header4 = api.gui.comp.TextView.new("")
    menu.stationTable:setHeader({header1,header2, header3, header4})

    local stationLegTime = timetableHelper.getLegTimes(lineID)
    menu.allStops = timetableHelper.getAllStops(lineID)

    -- 为路径点覆盖自定义名称（全局名优先；旧存档 per-line 名仅作一次性迁移来源）
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
                    -- 自愈迁移：旧存档的 per-line 名字提升为全局名（写 _G + timetableObject 双份），
                    -- 之后所有线路都显示同一个名字；触发同步持久化。
                    if stopInfo.gwKey then
                        timetable.setGlobalWaypointName(stopInfo.gwKey, customName)
                        timetableChanged = true
                    end
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

-- 中间站表摘要延迟刷新：onChange 逐位触发时不断重置计时，输入停顿约 1s（真实时间，暂停也触发）
-- 后才重建中间站表，让该行条件摘要（到发时间/路径点名/通过时间）显示新值。只刷中间表、不重建
-- 右侧约束窗口，避免打断 SpinBox 输入焦点（AGENTS.md "13:30 变 00:30" 教训）。
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
            -- 名称输入始终显示；"通过时间"选择态决定是否展开通过时间编辑器
            timetableGUI.clearConstraintWindow()
            timetableGUI.makeWaypointNameWindow(lineID, stopInfo.id, stopInfo.gwKey)
            if i == 1 then
                timetableGUI.makePassingWindow(lineID, stopInfo.id, stopInfo.gwKey)
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

        -- 名称输入框始终显示（不依赖点击"通过时间"）
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


local SEPARATION_LIST = {30, 20, 15, 12, 10, 7.5, 6, 5, 4, 3, 2.5, 2, 1.5, 1.2, 1}

-- Adds the "Separation [interval] Generate" row to the constraint window.
---@param generate function(sep) writes the generated times (sep in minutes, divides 60);
---  returns false if there is nothing to generate from
function timetableGUI.addSeparationRow(lineID, generate)
    local separationCombo = api.gui.comp.ComboBox.new()
    for _, sep in ipairs(SEPARATION_LIST) do
        separationCombo:addItem(string.format("%g min (%g/h)", sep, 60 / sep))
    end
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

-- 路径点名称编辑窗口：路径点页面【始终显示】，不依赖点击"通过时间"。
-- 改名即时保存（onChange 逐字写入全局名 _gwNames，跨线路全局同步）+ 1s 真实时间 debounce
-- 自动刷新中间站表；失焦整表重建让名字在所有线路生效。
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
    -- 提交名字（只写全局名）：gwKey 基于路径点实体（SignalId entity/index），跨线路全局同步。
    -- per-line 名字仓库（waypointNames）不再写入，避免"同一实体多名字"分歧。
    local function commitName(text)
        pcall(function()
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

    -- 通过时间编辑(多组，支持添加删除)
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
    -- Same slot matching as waitingRequired (closest [arr, dep] interval).
    return timetable.assignSlot(conds, actualArrTime)
end

-- 晚点/正点/早点判定：|diff|<=阈值 正点，正=晚 负=早。阈值 = 运行图设置"准点判定阈值"（秒，默认10）。
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
    _G._punctNext = now + 1  -- 每秒扫一次（getTime 整秒）

    local okMap, vehicleMap = pcall(_lineVehicleMap)
    if not okMap or not vehicleMap then return end
    for lineID, vehicles in pairs(vehicleMap) do
        local lineName = nil
        local okN, nc = pcall(_getComponent, lineID, api.type.ComponentType.NAME)
        if okN and nc and nc.name then lineName = nc.name end
        if vehicles then
            for _, vehicle in pairs(vehicles) do
                -- 车辆可能已被卖出/删除（getLine2VehicleMap 快照可能含失效 ID）：
                -- getComponent 对失效实体触发 C++ assert（GetComponentDataIndex，pcall 抓不住）。
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

                    -- 进站检测：state 从 非2 → 2（停稳）记录当前站到达时间；
                    -- 或 停靠站已变化（快速进出站漏拍 state 1/上次扫描未更新 thisStopIndex 时兜底）
                    if vc.state == 2 and (st.lastState ~= 2 or vc.stopIndex ~= st.thisStopIndex) then
                        st.thisStopIndex = vc.stopIndex
                        st.arrTime = now
                        st.depTime = nil
                        st.arrDone = false
                        st.stationName = nil
                        -- 站名读取：vc.stopIndex 是"线路停站位置索引"（int），不是站组实体 ID——
                        -- 直接用 stopIndex 当实体 ID 调 getComponent 会触发 C++ assert
                        -- （GetComponentDataIndex，pcall 抓不住）。用 entityExists 校验后跳过。
                        local idx = vc.stopIndex
                        if idx ~= nil then
                            local okIe, idxExists = pcall(_entityExists, idx)
                            if okIe and idxExists == true then
                                local okSg, sg = pcall(_getComponent, idx, api.type.ComponentType.NAME)
                                if okSg and sg and sg.name then st.stationName = sg.name end
                            end
                        end
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
                    -- 关键守卫（2026-08-05）：lineStopDepartures 记录的是"该站最近一次发车"，跨周期不清零。
                    -- 列车上一周期从本站发车（如 23:32）后、本周期再回到本站时，该字段仍留着旧值——
                    -- 若直接把 d>0 当成"本次刚发车"，会拿上一周期的旧发车时刻去减本周期选定那套时刻表的
                    -- 计划发车（多套时刻表：旧值对应第一套、计划对应第二套 → 假"早24分钟"）。
                    -- 判定逻辑抽到 timetable.isValidDepartureRecord（可单测），此处只调用。
                    if not st.arrDone then
                        local depTime = nil
                        if vc.lineStopDepartures and st.thisStopIndex then
                            local d = vc.lineStopDepartures[st.thisStopIndex + 1]
                            if timetable.isValidDepartureRecord(d, now, st.arrTime) then
                                depTime = math.floor(d / 1000)
                            end
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
                end -- if okEv and exists == true then
            end
        end
    end

    -- 同步到 _G 供 GUI 线程读取（GUI 线程读 _G 即可，无需跨线程事件）
    _G._punctuality = punctualityState
end

-- ===== 性能优化 A 组（2026-08-16 第 21 轮）：控车协程的三处改造 =====
-- 1) 勾选线路清单（纯 Lua，从 timetableObject 取）：本来只有"勾选了遵循时刻表"的线路才需要控车，
--    清单为空时**整个扫描都不用做**（原实现即使一条线都没勾选，也每帧扫全世界停站车辆）。
-- 2) 列表为空时不再"每个 resume 重扫一遍"：update() 每帧最多 resume 21 次，而协程体是
--    `while true do 扫描; for … yield end; yield end` —— 列表为空时每次 resume 都会重新扫描
--    （21 次/帧，每次 = 全世界停站车辆 + 每辆 2 次引擎调用 + 2 个闭包）。现在用帧号标记：
--    同一帧内已经扫过就直接 `yield("idle")`，update() 收到 "idle" 立即结束本帧的 resume 循环
--    → **扫描频率仍是"每帧一次"**（与车辆到站响应速度完全一致），只是不再重复 21 遍。
-- 3) 只做一次 getTimetableObject()（引擎线程副本），供清单与扫描共用。
local EMPTY_VEHICLE_LIST = {}
function timetableGUI.timetableCoroutine()
    local scannedFrame = -1        -- 本协程最近一次全量扫描所在的帧号
    local tickedLines = {}         -- 勾选"遵循时刻表"的线路 ID（>0）
    while true do
        local list = nil
        if scannedFrame == _G._ttCoFrame then
            -- 本帧已经扫过：不再重复扫描，把本帧剩余的 resume 配额交还给引擎
            coroutine.yield("idle")
        else
            scannedFrame = _G._ttCoFrame
            -- 勾选线路清单（纯 Lua，无引擎调用）
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
            for i = n + 1, #tickedLines do tickedLines[i] = nil end   -- 收缩旧内容
            if n == 0 then
                list = EMPTY_VEHICLE_LIST      -- 没有任何线路在跑时刻表 → 不控车、也不扫描
            else
                list = timetableHelper.getAllTimetableRailVehicles(timetable.hasTimetable, tickedLines)
            end
        end
        if list then
            for _,vehicle in pairs(list) do
                local vehicleStr = tostring(vehicle)
                local skip = false
                -- 交路系统（TrainRoute mod）钩子：热备车由交路系统强制停车管理（setUserStopped(true) 常停），
                -- 不走时刻表逻辑；换乘站真车由交路系统按"下一线路发车时刻"单独扣车/换线。
                -- 未安装 TrainRoute → 钩子 nil → 不跳过任何车（保持原行为）。
                local trHooks = _G._trainRouteHooks
                if trHooks then
                    local okSB, isSb = pcall(trHooks.isStandby, vehicleStr)
                    if okSB and isSb then skip = true end
                    if not skip then
                        local okMV, isMv = pcall(trHooks.managesVehicle, vehicleStr)
                        if okMV and isMv then skip = true end
                    end
                end
                if not skip then
                    -- 扣车/放行判定。放行时的 forceDeparture（setVehicleShouldDepart 真启动）
                    -- 已由 waitingRequired 内部无条件处理（含"已过发车时刻、晚点在容差内、
                    -- 车首次到站从未被扣"的场景）；这里只需 stopVehicle / startVehicle。
                    if timetable.waitingRequired(vehicleStr) then
                        timetableHelper.stopVehicle(vehicleStr)
                    else
                        timetableHelper.startVehicle(vehicleStr)
                    end
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
                -- 数据安全防御（2026-08-09 补）：GUI 线程若因模块重载/加载失败发出
                -- 不含线路条目的对象（只剩 _diagram* 设置键/空表），或丢了已存预设(dp)，
                -- 而引擎已加载完整线路/预设，拒绝用它覆盖——否则下次存档会把已保存的
                -- 时刻表/运行图配置清空。拒绝日志受 _G._diagramDebug 控制（默认关闭）。
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
            -- 兼容旧存档：currentlyWaiting 里可能有缺失 outboundTime / 旧版标量的停站条目，
            -- 不清理会在 waitingRequired 写 outboundTime[vehicle] 时崩溃（协程死循环）
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
            -- 帧号（性能优化 A 组）：供控车协程判断"本帧是否已经扫描过"，避免列表为空时
            -- 每次 resume 都重扫一遍全世界车辆（原实现最多 21 次/帧）。
            _G._ttCoFrame = (_G._ttCoFrame or 0) + 1
            -- 协程自愈（2026-08-16 加固）：C++ assert（如 getComponent 打到无效实体，
            -- AGENTS.md 教训）会绕过 Lua 的 yield/return 把协程留在 "running" 状态——
            -- status 既非 dead 也非 suspended，resume 报 "cannot resume non-suspended coroutine"
            -- 且被节流打印后每帧刷屏，永不重建。除 suspended 外一律重建：
            -- running=被 assert 卡死；dead=正常退出；normal=本场景不应出现（防御重建）。
            local coStatus = co and coroutine.status(co) or "dead"
            if coStatus ~= "suspended" then
                co = coroutine.create(timetableGUI.timetableCoroutine)
            end
            -- 死协程每帧 resume 20 次会各打印一次错误 → 控制台刷屏（玩家反馈"日志一直刷新"）。
            -- 修复：status==dead 直接 break；错误只节流打印一次/秒。
            -- 性能优化 A 组追加：协程 yield "idle"（本帧已扫描过）→ 立即结束本帧的 resume 循环。
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

            -- 交路系统调度已移到独立 mod TrainRoute（其 game_script 的 update 内自行调用 tick）
            -- 准点检测移到 guiUpdate（GUI 线程）执行：
            -- GUI 线程能读引擎 API，且与 diagram_gui 同线程，数据写 _G._punctuality 直接可见

            -- 残留扣车清理（2026-08-16 诊断结论）：旧版 mod 对"未勾选但残留时刻数据"的线路
            -- 设置过 setVehicleManualDeparture(true)，标志随存档持久化 → 车永远停站
            -- （autoDeparture=false、timeUntilDep 冻结、days 增长）。进档立即清一次 + 每 30s
            -- 自愈一次：清"有条目但未勾选"线路车辆上的 manualDeparture（只清 manualDeparture，
            -- 不动 userStopped=TrainRoute 热备车领域）。
            local holdNow = rawRealSeconds()
            if holdNow then
                if not _G._ttStaleHoldDue or holdNow >= _G._ttStaleHoldDue then
                    _G._ttStaleHoldDue = holdNow + 30
                    -- 性能优化 A 组：clearStaleHolds 已改为候选驱动（无"有数据但未勾选"的线路
                    -- 时零引擎调用），这笔 30s 尖峰在正常玩法下直接消失。
                    pcall(timetable.clearStaleHolds)
                end
            end

            -- 5s 维护（性能优化 A 组：两件事合并为一次取数）
            --   ① 清理已删除线路的孤儿时刻表数据（车站 Tab 会遍历 timetableObject，孤儿条目显示 ERROR）；
            --   ② 车站/线路结构对账（拆/建站后停站重新编号，时刻数据按位置存储会错位）。
            -- 原实现是两次独立调用（cleanupOrphanLines 内部取一次 getLines、reconcileStationData
            -- 内部逐线 entityExists）→ 现在 maintainTimetableData() 只取一次 getLines，
            -- 幸存线路用同一份集合对账。用真实时间（os.clock）节流：暂停时也走。
            -- 清理直接改引擎线程的 timetableObject，由下方 state.timetable = to 持久化；
            -- 引擎线程的 timetableChanged 与 GUI 线程不共享，无需设置。
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
            -- GUI 线程孤儿线路清理（数据源侧）：timetableObject 在 GUI 线程被编辑并同步到引擎线程，
            -- 删除线路后 GUI 线程的副本会残留孤儿（车站 Tab 显示 ERROR）。每 ~5s 节流清理一次，
            -- 用 os.clock（真实时间）暂停也走。清理后置 timetableChanged 触发下方 sendScriptEvent 同步。
            -- 关键：清理孤儿后若车站 Tab 有选中站，右侧线路表（stationTabLinesTable）不会自动重填——
            -- 玩家删线路前渲染的 "ERROR" 行仍显示在屏幕上（即使数据已过滤）。故清理后重填右侧表。
            local guiRtNow = rawRealSeconds()
            if guiRtNow then
                if not _G._ttGuiOrphanCleanDue then _G._ttGuiOrphanCleanDue = guiRtNow + 5 end
                if guiRtNow >= _G._ttGuiOrphanCleanDue then
                    _G._ttGuiOrphanCleanDue = guiRtNow + 5
                    -- 性能优化 A 组：孤儿清理 + 车站对账合并为一次取数（原为两次独立调用，
                    -- 一次取 getLines、另一次逐线 entityExists）。语义不变，只是少一轮引擎往返。
                    -- 注意：pcall 返回 (ok, result) 两个值——ok 才是布尔，result 才是 stats 表，
                    -- 只接第一个会把布尔当表索引 → "attempt to index local 'rc' (a boolean value)" 崩溃。
                    local okM, guiRemoved, rc = pcall(timetable.maintainTimetableData)
                    if okM then
                        if guiRemoved and guiRemoved > 0 then
                            timetableChanged = true
                        end
                        if rc and (rc.rekeyed or 0) + (rc.removed or 0) > 0 then
                            timetableChanged = true
                        end
                    end
                    -- 无条件重填车站 Tab 右侧表（若选中站）：即使 lineExists 因引擎缓存失效、
                    -- cleanup 未删孤儿，重填时 fillStationTabLineTable/fillWaypointTabLineTable 的
                    -- 显示层过滤（lineExists + getLineName=="ERROR"）也会跳过孤儿行，清除残留 ERROR。
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
            -- 准点检测：GUI 线程每秒节流扫描（与 diagram_gui 同线程，_G 数据直接可见）
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
            -- 中间站表摘要延迟刷新：SpinBox/名称输入停止约 1s 后重建中间表，让条件摘要显示新到发时间
            if stationSummaryRefreshDue and realTimeNow() >= stationSummaryRefreshDue then
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

                    -- 交路系统按钮已移到独立 mod TrainRoute（其 game_script 的 guiUpdate 内创建）

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
