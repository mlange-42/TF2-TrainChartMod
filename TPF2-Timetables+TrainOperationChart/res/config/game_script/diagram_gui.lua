local timetable = require "celmi/timetables/timetable"
local timetableHelper = require "celmi/timetables/timetable_helper"

local diagramGUI = {}
local menu = {window = nil, lineRenderViews = {}}

local D = { title = _("diagram_title_i18n") }

-- 窗口尺寸常量
local WINDOW_WIDTH = 1000
local WINDOW_HEIGHT = 600
local STATION_LABEL_WIDTH = 120
local TIME_LABEL_HEIGHT = 30

-- 当前选中的线路索引
local selectedLineIndex = nil

-- 颜色配置（延迟初始化）
local LINE_COLORS = {
    {1.0, 0.2, 0.2, 1.0},   -- 红色
    {0.2, 0.6, 1.0, 1.0},   -- 蓝色
    {0.2, 1.0, 0.4, 1.0},   -- 绿色
    {1.0, 0.8, 0.2, 1.0},   -- 黄色
    {0.8, 0.2, 1.0, 1.0},   -- 紫色
    {1.0, 0.6, 0.2, 1.0},   -- 橙色
    {0.6, 0.8, 0.2, 1.0},   -- 浅绿色
    {0.2, 0.8, 0.8, 1.0},   -- 青色
}

-- 获取颜色的Vec4f对象（延迟初始化）
local function getColor(index)
    local color = LINE_COLORS[(index - 1) % #LINE_COLORS + 1]
    return api.type.Vec4f.new(color[1], color[2], color[3], color[4])
end

-- 调试输出函数
local function debugPrint(msg)
    print("[DiagramGUI] " .. msg)
end

-- 获取所有线路的时刻表数据
local function getAllTimetableData()
    local data = {}
    local lines = timetableHelper.getAllRailLines()
    
    debugPrint("Found " .. #lines .. " rail lines")
    
    for _, lineInfo in pairs(lines) do
        local lineID = lineInfo.id
        if timetable.hasTimetable(lineID) then
            local stations = timetableHelper.getAllStations(lineID)
            debugPrint("Line " .. lineInfo.name .. " has timetable with " .. #stations .. " stations")
            
            local lineData = {
                id = lineID,
                name = lineInfo.name,
                stations = {},
                color = getColor(#data + 1)
            }
            
            for stationIdx, stationID in pairs(stations) do
                local stationName = timetableHelper.getStationName(stationID)
                local conditionType = timetable.getConditionType(lineID, stationIdx)
                
                if conditionType == "ArrDep" then
                    local conditions = timetable.getConditions(lineID, stationIdx, "ArrDep")
                    lineData.stations[stationIdx] = {
                        id = stationID,
                        name = stationName,
                        times = conditions
                    }
                    debugPrint("  Station " .. stationIdx .. ": " .. stationName .. " - " .. #conditions .. " conditions")
                else
                    lineData.stations[stationIdx] = {
                        id = stationID,
                        name = stationName,
                        times = {}
                    }
                end
            end
            
            table.insert(data, lineData)
        end
    end
    
    debugPrint("Total timetable lines: " .. #data)
    return data
end

-- 将时间（分:秒）转换为秒数
local function timeToSeconds(min, sec)
    return min * 60 + sec
end

-- 将秒数转换为X坐标
local function secondsToX(seconds, diagramWidth, useNormalizedCoords)
    local normalizedTime = seconds % 3600
    local normalizedX = normalizedTime / 3600
    
    if useNormalizedCoords then
        return normalizedX  -- 归一化坐标 0-1
    else
        return normalizedX * diagramWidth  -- 像素坐标
    end
end

-- 将车站索引转换为Y坐标
local function stationToY(stationIndex, totalStations, diagramHeight, useNormalizedCoords)
    if totalStations <= 1 then
        local y = 0.5
        if not useNormalizedCoords then
            y = y * diagramHeight
        end
        return y
    end
    
    local normalizedY = (stationIndex - 1) / (totalStations - 1)
    normalizedY = 1 - normalizedY  -- 反转Y轴
    
    if useNormalizedCoords then
        return normalizedY
    else
        return normalizedY * diagramHeight
    end
end

-- 获取所有唯一的车站（用于纵轴）
local function getAllUniqueStations(lineDataList)
    local stationMap = {}
    local stationList = {}
    
    for _, lineData in pairs(lineDataList) do
        for stationIdx, station in pairs(lineData.stations) do
            if not stationMap[station.id] then
                stationMap[station.id] = {
                    id = station.id,
                    name = station.name,
                    index = #stationList + 1
                }
                table.insert(stationList, stationMap[station.id])
            end
        end
    end
    
    return stationList
end

-- 绘制运行图（单一颜色版本）
local function drawDiagramSimple(lineRenderView, lineDataList, stationList, useNormalizedCoords)
    lineRenderView:clear()
    
    -- 获取实际尺寸
    local rect = lineRenderView:getContentRect()
    local diagramWidth = rect.w
    local diagramHeight = rect.h
    
    debugPrint("Diagram size: " .. diagramWidth .. "x" .. diagramHeight)
    debugPrint("Using " .. (useNormalizedCoords and "normalized" or "pixel") .. " coordinates")
    
    local totalStations = #stationList
    
    -- 创建车站ID到索引的映射
    local stationIdToIndex = {}
    for idx, station in pairs(stationList) do
        stationIdToIndex[station.id] = idx
    end
    
    -- 设置颜色（单一颜色）
    lineRenderView:setColor(api.type.Vec4f.new(0.2, 0.6, 1.0, 1.0))  -- 蓝色
    lineRenderView:setWidth(2)
    
    -- 测试线：从左上角到右下角
    if useNormalizedCoords then
        lineRenderView:addLine(api.type.Vec2f.new(0, 0), api.type.Vec2f.new(1, 1))
    else
        lineRenderView:addLine(api.type.Vec2f.new(0, 0), api.type.Vec2f.new(diagramWidth, diagramHeight))
    end
    debugPrint("Test line added")
    
    -- 绘制每个线路的运行折线
    for lineIdx, lineData in pairs(lineDataList) do
        local points = {}
        
        for stationIdx, station in pairs(lineData.stations) do
            local stationIndex = stationIdToIndex[station.id]
            if stationIndex and station.times and #station.times > 0 then
                local time = station.times[1]
                if time then
                    -- 到达时间点
                    local arrSeconds = timeToSeconds(time[1], time[2])
                    local arrX = secondsToX(arrSeconds, diagramWidth, useNormalizedCoords)
                    local arrY = stationToY(stationIndex, totalStations, diagramHeight, useNormalizedCoords)
                    table.insert(points, {x = arrX, y = arrY})
                    
                    -- 出发时间点
                    local depSeconds = timeToSeconds(time[3], time[4])
                    local depX = secondsToX(depSeconds, diagramWidth, useNormalizedCoords)
                    local depY = stationToY(stationIndex, totalStations, diagramHeight, useNormalizedCoords)
                    table.insert(points, {x = depX, y = depY})
                    
                    debugPrint("  Point: " .. station.name .. " arr=" .. time[1] .. ":" .. time[2] .. " (" .. arrX .. "," .. arrY .. ")")
                end
            end
        end
        
        -- 按X坐标排序点
        table.sort(points, function(a, b)
            return a.x < b.x
        end)
        
        -- 绘制折线
        for i = 1, #points - 1 do
            local from = api.type.Vec2f.new(points[i].x, points[i].y)
            local to = api.type.Vec2f.new(points[i+1].x, points[i+1].y)
            lineRenderView:addLine(from, to)
        end
        
        debugPrint("Line " .. lineData.name .. ": " .. #points .. " points drawn")
    end
end

-- 创建运行图窗口
function diagramGUI.showDiagram()
    debugPrint("Showing diagram...")
    
    if menu.window ~= nil then
        debugPrint("Window already exists, showing it")
        return menu.window:setVisible(true, true)
    end
    
    -- 获取时刻表数据
    local lineDataList = getAllTimetableData()
    local stationList = getAllUniqueStations(lineDataList)
    
    if #lineDataList == 0 then
        debugPrint("No timetable data available")
        return
    end
    
    debugPrint("Total stations: " .. #stationList)
    
    -- 创建主布局
    local mainLayout = api.gui.layout.FloatingLayout.new(0, 1)
    
    -- 创建车站名称标签（左侧）
    local stationLayout = api.gui.layout.BoxLayout.new("VERTICAL")
    local stationComponent = api.gui.comp.Component.new("stationLabels")
    stationComponent:setLayout(stationLayout)
    stationComponent:setMinimumSize(api.gui.util.Size.new(STATION_LABEL_WIDTH, WINDOW_HEIGHT - TIME_LABEL_HEIGHT))
    stationComponent:setMaximumSize(api.gui.util.Size.new(STATION_LABEL_WIDTH, WINDOW_HEIGHT - TIME_LABEL_HEIGHT))
    
    for _, station in pairs(stationList) do
        local stationLabel = api.gui.comp.TextView.new(station.name)
        stationLabel:setStyleClassList({"timetable-mono-sc"})
        stationLabel:setGravity(1, 0.5)
        stationLayout:addItem(stationLabel)
    end
    
    mainLayout:addItem(stationComponent, 0, 0)
    
    -- 创建时间刻度标签（底部）
    local timeLayout = api.gui.layout.BoxLayout.new("HORIZONTAL")
    local timeComponent = api.gui.comp.Component.new("timeLabels")
    timeComponent:setLayout(timeLayout)
    timeComponent:setMinimumSize(api.gui.util.Size.new(WINDOW_WIDTH - STATION_LABEL_WIDTH, TIME_LABEL_HEIGHT))
    timeComponent:setMaximumSize(api.gui.util.Size.new(WINDOW_WIDTH - STATION_LABEL_WIDTH, TIME_LABEL_HEIGHT))
    
    -- 添加时间刻度（每10分钟一个刻度）
    for min = 0, 59, 10 do
        local timeLabel = api.gui.comp.TextView.new(string.format("%02d:00", min))
        timeLabel:setStyleClassList({"timetable-mono-sc"})
        timeLabel:setGravity(0, 0.5)
        timeLayout:addItem(timeLabel)
    end
    
    mainLayout:addItem(timeComponent, 0.5, 1)
    
    -- 创建LineRenderView（中央图表区域）
    local lineRenderView = api.gui.comp.LineRenderView.new()
    
    -- 创建图表容器
    local diagramComponent = api.gui.comp.Component.new("diagramArea")
    diagramComponent:setLayout(api.gui.layout.FloatingLayout.new(0, 1))
    diagramComponent:setMinimumSize(api.gui.util.Size.new(WINDOW_WIDTH - STATION_LABEL_WIDTH, WINDOW_HEIGHT - TIME_LABEL_HEIGHT))
    diagramComponent:setMaximumSize(api.gui.util.Size.new(WINDOW_WIDTH - STATION_LABEL_WIDTH, WINDOW_HEIGHT - TIME_LABEL_HEIGHT))
    
    -- 将LineRenderView添加到容器布局中（修复：使用getLayout()）
    diagramComponent:getLayout():addItem(lineRenderView, 0.5, 0)
    
    mainLayout:addItem(diagramComponent, 0.5, 0)
    
    -- 创建窗口
    local okW, newWin = pcall(function() return api.gui.comp.Window.new(D.title, diagramComponent) end)
    if not okW or not newWin then return end
    menu.window = newWin
    menu.window:addHideOnCloseHandler()
    menu.window:setMovable(true)
    menu.window:setResizable(true)
    menu.window:setSize(api.gui.util.Size.new(WINDOW_WIDTH, WINDOW_HEIGHT))
    menu.window:setPosition(300, 200)
    
    -- 设置窗口内容
    local wrapper = api.gui.comp.Component.new("diagramWrapper")
    wrapper:setLayout(mainLayout)
    menu.window:setContent(wrapper)
    
    -- 使用invokeLater延迟绘制，确保组件已布局完成
    -- 先测试归一化坐标（0-1），如果看不到线条再尝试像素坐标
    lineRenderView:invokeLater(function()
        debugPrint("Invoking drawDiagramSimple")
        drawDiagramSimple(lineRenderView, lineDataList, stationList, true)
    end)
    
    debugPrint("Diagram window created successfully")
end

return diagramGUI