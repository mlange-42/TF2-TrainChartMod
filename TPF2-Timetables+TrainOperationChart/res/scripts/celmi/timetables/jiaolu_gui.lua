local timetable = require "celmi/timetables/timetable"
local timetableHelper = require "celmi/timetables/timetable_helper"
local jiaolu = require "celmi/timetables/jiaolu"

-- 交路系统 GUI：主窗口（交路系统运行图开关 / 设置 / 左侧列车列表 / 右侧热备车列表）
-- + 设置弹窗（上半热备车勾选，下半交路配置增删改）。
-- 展示数据全部从"交路配置 + 车辆组件实时状态"派生（jiaolu.computeOverview），
-- 不依赖引擎线程回传，规避 GUI/引擎线程 _G 不共享的问题。
local jiaoluGUI = {}

local menu = { window = nil, trainScroll = nil, standbyScroll = nil, lastRefresh = nil }
local settingsState = nil -- 设置弹窗的编辑态（副本），确定才写回
local lastSig = nil

-- 前向声明：openSettings 在 showWindow（定义在其之前）的按钮闭包里被引用，
-- rebuildConfigList / scheduleCfgRebuild 在设置弹窗多处闭包里被引用，
-- 都以赋值形式定义（见 AGENTS.md 前向引用教训）。
local openSettings
local rebuildConfigList
local scheduleCfgRebuild

local UIStrings = {
    title = _("jr_title_i18n"),
    title_short = _("jr_title_short_i18n"),
    run_diagram = _("jr_run_diagram_i18n"),
    settings = _("jr_settings_i18n"),
    confirm = _("jr_confirm_i18n"),
    cancel = _("jr_cancel_i18n"),
    train_list = _("jr_train_list_i18n"),
    cur_line = _("jr_cur_line_i18n"),
    next_line = _("jr_next_line_i18n"),
    switch_time = _("jr_switch_time_i18n"),
    standby_alloc = _("jr_standby_alloc_i18n"),
    standby_list = _("jr_standby_list_i18n"),
    cur_standby_line = _("jr_cur_standby_line_i18n"),
    next_standby_line = _("jr_next_standby_line_i18n"),
    occupy_time = _("jr_occupy_time_i18n"),
    occupy_duration = _("jr_occupy_duration_i18n"),
    none = _("jr_none_i18n"),
    shortage = _("jr_shortage_i18n"),
    assign_fail = _("jr_assign_fail_i18n"),
    switch_fail = _("jr_switch_fail_i18n"),
    standby_setting = _("jr_standby_setting_i18n"),
    is_standby = _("jr_is_standby_i18n"),
    jiaolu_config = _("jr_jiaolu_config_i18n"),
    add = _("jr_add_i18n"),
    search = _("jr_search_i18n"),
    sort = _("jr_sort_i18n"),
    confirm_delete = _("jr_confirm_delete_i18n"),
    warning = _("jr_warning_i18n"),
    invalid_time = _("jr_invalid_time_i18n"),
    invalid_station = _("jr_invalid_station_i18n"),
    invalid_order = _("jr_invalid_order_i18n"),
    invalid_dup = _("jr_invalid_dup_i18n"),
    idle = _("jr_idle_i18n"),
    train_name = _("jr_train_name_i18n"),
    current_line = _("jr_current_line_i18n"),
    no_config = _("jr_no_config_i18n"),
}

-- 组件名计数器：必须跨刷新周期唯一（AGENTS.md 经验）
local function nextName()
    if not _G._jrNameCounter then _G._jrNameCounter = 0 end
    _G._jrNameCounter = _G._jrNameCounter + 1
    return _G._jrNameCounter
end

-- 触发跨线程同步（guiUpdate 里检测 _G._jrlForceSync 发 sendScriptEvent 到引擎线程）
local function sync()
    _G._jrlForceSync = true
end

-- 游戏时间秒 → "MM:SS"（取小时内的分秒显示）
local function fmtTime(sec)
    if not sec then return "--" end
    local s = sec % 3600
    return string.format("%02d:%02d", math.floor(s / 60), s % 60)
end

local function fmtDur(sec)
    if not sec then return "--" end
    local mm = math.floor(sec / 60)
    local ss = sec % 60
    if mm >= 60 then
        return string.format("%dh%02d'", math.floor(mm / 60), mm % 60)
    end
    return string.format("%02d'%02d''", mm, ss)
end

-- 表头行：固定宽度 TextView 组成的横向 BoxLayout（与运行图"车次列表"表头同款——
-- 该模式在 BoxLayout 里可正常渲染；Table 表头在 BoxLayout 里高度会坍缩为 0）
local function makeHeaderRow(w, h, widths, labels)
    local hc = api.gui.comp.Component.new("jrHdr_" .. nextName())
    local hl = api.gui.layout.BoxLayout.new("HORIZONTAL")
    hc:setLayout(hl)
    for i, lbl in ipairs(labels) do
        local tv = api.gui.comp.TextView.new(lbl)
        tv:setMinimumSize(api.gui.util.Size.new(widths[i], h))
        tv:setMaximumSize(api.gui.util.Size.new(widths[i], h))
        hl:addItem(tv)
    end
    hc:setMinimumSize(api.gui.util.Size.new(w, h))
    hc:setMaximumSize(api.gui.util.Size.new(w, h))
    return hc
end

------------------------------------------------------------
--------------------- 主窗口：左右两栏刷新 -------------------
------------------------------------------------------------

local function refreshOverview()
    if not (menu.trainScroll and menu.standbyScroll) then return end
    local ov = jiaolu.computeOverview()

    -- 内容签名：未变化不重建（避免滚动条/焦点被无谓重置）
    local parts = {}
    for _, tr in ipairs(ov.trains) do
        parts[#parts + 1] = tr.id .. "|" .. tr.lineId .. "|" .. tostring(tr.nextLineId) .. "|" ..
            tostring(tr.switchTime) .. "|" .. tostring(tr.standbyAlloc) .. "|" .. tostring(ov.shortage[tr.lineId])
    end
    parts[#parts + 1] = "#"
    for _, sb in ipairs(ov.standbys) do
        parts[#parts + 1] = sb.id .. "|" .. tostring(sb.curLineId) .. "|" .. tostring(sb.idle) .. "|" ..
            tostring(sb.nextLineName) .. "|" .. tostring(sb.occupyFrom) .. "|" .. tostring(sb.occupyTo)
    end
    local sig = table.concat(parts, ";")
    if sig == lastSig then return end
    lastSig = sig

    -- 左侧：列车列表（非热备车辆）
    local tt = api.gui.comp.Table.new(5, 'NONE')
    tt:setColWidth(0, 150)
    tt:setColWidth(1, 120)
    tt:setColWidth(2, 120)
    tt:setColWidth(3, 70)
    tt:setColWidth(4, 120)
    for _, tr in ipairs(ov.trains) do
        local allocText = UIStrings.none
        if tr.isConfig then
            if ov.assignFail[tr.lineId] then
                allocText = UIStrings.assign_fail
            elseif tr.standbyAlloc then
                allocText = tr.standbyAlloc
            elseif ov.shortage[tr.lineId] then
                allocText = UIStrings.shortage
            end
        end
        local nameTv = api.gui.comp.TextView.new(tr.name)
        local lineTv = api.gui.comp.TextView.new(tr.lineName)
        local nextTv = api.gui.comp.TextView.new(tr.nextLineName or UIStrings.none)
        local timeTv = api.gui.comp.TextView.new(fmtTime(tr.switchTime))
        local allocTv = api.gui.comp.TextView.new(allocText)
        if ov.assignFail[tr.lineId] or (tr.isConfig and ov.shortage[tr.lineId]) then
            allocTv:setStyleClassList({"timetable-punct-late"})
        end
        tt:addRow({nameTv, lineTv, nextTv, timeTv, allocTv})
    end
    menu.trainScroll:setContent(tt)

    -- 右侧：热备车列表
    local st = api.gui.comp.Table.new(5, 'NONE')
    st:setColWidth(0, 150)
    st:setColWidth(1, 120)
    st:setColWidth(2, 120)
    st:setColWidth(3, 130)
    st:setColWidth(4, 90)
    for _, sb in ipairs(ov.standbys) do
        local nextTxt = UIStrings.none
        if sb.idle then
            nextTxt = UIStrings.idle
        elseif sb.nextLineName then
            nextTxt = sb.nextLineName
        end
        local occTxt = "--"
        if not sb.idle and sb.occupyFrom and sb.occupyTo then
            occTxt = fmtTime(sb.occupyFrom) .. " - " .. fmtTime(sb.occupyTo)
        end
        st:addRow({
            api.gui.comp.TextView.new(sb.name),
            api.gui.comp.TextView.new(sb.curLineName),
            api.gui.comp.TextView.new(nextTxt),
            api.gui.comp.TextView.new(occTxt),
            api.gui.comp.TextView.new(fmtDur(sb.occupyDur)),
        })
    end
    menu.standbyScroll:setContent(st)
end

------------------------------------------------------------
--------------------- 主窗口 --------------------------------
------------------------------------------------------------

function jiaoluGUI.showWindow()
    if menu.window ~= nil then
        local ok = pcall(function()
            menu.window:setVisible(true, true)
            refreshOverview()
        end)
        if ok then return end
        menu.window = nil
        menu.trainScroll = nil
        menu.standbyScroll = nil
    end

    local mainLayout = api.gui.layout.BoxLayout.new("VERTICAL")
    local wrapper = api.gui.comp.Component.new("jrWrapper_" .. nextName())
    wrapper:setLayout(mainLayout)

    -- 第一行：交路系统运行图（复选框，仅控制运行图绘制模式）
    local topRow = api.gui.comp.Component.new("jrTop_" .. nextName())
    local trl = api.gui.layout.BoxLayout.new("HORIZONTAL")
    topRow:setLayout(trl)
    local runCk = api.gui.comp.ImageView.new(jiaolu.getDiagramMode() and "ui/checkbox1.tga" or "ui/checkbox0.tga")
    local runBtn = api.gui.comp.Button.new(runCk, true)
    runBtn:onClick(function()
        jiaolu.setDiagramMode(not jiaolu.getDiagramMode())
        pcall(function()
            runCk:setImage(jiaolu.getDiagramMode() and "ui/checkbox1.tga" or "ui/checkbox0.tga", false)
        end)
        sync()
    end)
    local runLbl = api.gui.comp.TextView.new(UIStrings.run_diagram)
    runLbl:setStyleClassList({"timetable-mono-sc"})
    trl:addItem(runBtn)
    trl:addItem(runLbl)
    mainLayout:addItem(topRow)

    -- 第二行：设置按钮
    local setRow = api.gui.comp.Component.new("jrSet_" .. nextName())
    local srl = api.gui.layout.BoxLayout.new("HORIZONTAL")
    setRow:setLayout(srl)
    local setBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(UIStrings.settings), true)
    setBtn:onClick(function()
        local ok, err = pcall(openSettings)
        if not ok then print("[JiaoLuGUI] settings ERROR: " .. tostring(err)) end
    end)
    srl:addItem(setBtn)
    mainLayout:addItem(setRow)

    -- 大区域：左（列车）/ 右（热备车）
    local bigRow = api.gui.comp.Component.new("jrBig_" .. nextName())
    local brl = api.gui.layout.BoxLayout.new("HORIZONTAL")
    bigRow:setLayout(brl)

    local W = 600
    local H = 560
    local HEADER_H = 32

    -- 左面板
    local leftPanel = api.gui.comp.Component.new("jrLeft_" .. nextName())
    local ll = api.gui.layout.BoxLayout.new("VERTICAL")
    leftPanel:setLayout(ll)
    leftPanel:setMinimumSize(api.gui.util.Size.new(W, H))
    leftPanel:setMaximumSize(api.gui.util.Size.new(W, H))
    -- 表头（Component+BoxLayout，避免 Table 表头在 BoxLayout 里坍缩）
    local lhdr = makeHeaderRow(W, HEADER_H, {150, 120, 120, 70, 120},
        {UIStrings.train_list, UIStrings.cur_line, UIStrings.next_line, UIStrings.switch_time, UIStrings.standby_alloc})
    ll:addItem(lhdr)
    local lsa = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new("jrTrainOverview_" .. nextName()), "jr.trainOverview")
    lsa:setMinimumSize(api.gui.util.Size.new(W, H - HEADER_H - 12))
    lsa:setMaximumSize(api.gui.util.Size.new(W, H - HEADER_H - 12))
    menu.trainScroll = lsa
    ll:addItem(lsa)
    brl:addItem(leftPanel)

    -- 右面板
    local rightPanel = api.gui.comp.Component.new("jrRight_" .. nextName())
    local rl = api.gui.layout.BoxLayout.new("VERTICAL")
    rightPanel:setLayout(rl)
    rightPanel:setMinimumSize(api.gui.util.Size.new(W, H))
    rightPanel:setMaximumSize(api.gui.util.Size.new(W, H))
    local rhdr = makeHeaderRow(W, HEADER_H, {150, 120, 120, 130, 90},
        {UIStrings.standby_list, UIStrings.cur_standby_line, UIStrings.next_standby_line, UIStrings.occupy_time, UIStrings.occupy_duration})
    rl:addItem(rhdr)
    local rsa = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new("jrStandbyOverview_" .. nextName()), "jr.standbyOverview")
    rsa:setMinimumSize(api.gui.util.Size.new(W, H - HEADER_H - 12))
    rsa:setMaximumSize(api.gui.util.Size.new(W, H - HEADER_H - 12))
    menu.standbyScroll = rsa
    rl:addItem(rsa)
    brl:addItem(rightPanel)

    mainLayout:addItem(bigRow)

    local okW, newWin = pcall(function() return api.gui.comp.Window.new(UIStrings.title, wrapper) end)
    if not okW or not newWin then print("[JiaoLuGUI] Window.new failed"); return end
    menu.window = newWin
    menu.window:addHideOnCloseHandler()
    menu.window:setMovable(true)
    menu.window:setResizable(true)
    menu.window:setSize(api.gui.util.Size.new(1210, 700))
    menu.window:setPosition(150, 100)
    -- 每 ~2s 刷新左右两栏（内容签名未变化则不重建）
    menu.window:onStep(function()
        pcall(function()
            local t = timetableHelper.getTime()
            if not menu.lastRefresh or t - menu.lastRefresh >= 2 then
                menu.lastRefresh = t
                refreshOverview()
            end
        end)
    end)
    menu.window:onClose(function()
        menu.window = nil
        menu.trainScroll = nil
        menu.standbyScroll = nil
        menu.lastRefresh = nil
        lastSig = nil
    end)
    refreshOverview()
end

------------------------------------------------------------
--------------------- 设置弹窗 ------------------------------
------------------------------------------------------------

local function deepCopyConfigs(configs)
    local out = {}
    for _, cfg in ipairs(configs or {}) do
        local lines = {}
        if cfg.lines then
            for k, v in pairs(cfg.lines) do lines[k] = v end
        end
        out[#out + 1] = { id = cfg.id, name = cfg.name, lines = lines }
    end
    return out
end

local function rebuildVehicleList()
    local scroll = settingsState and settingsState.vehScroll
    if not scroll then return end
    local lines = jiaolu.getRailLines()
    local t = api.gui.comp.Table.new(3, 'NONE')
    t:setColWidth(0, 260)
    t:setColWidth(1, 200)
    t:setColWidth(2, 200)
    for _, ln in ipairs(lines) do
        local vehs = timetableHelper.getVehiclesOnLine(ln.id)
        for _, veh in ipairs(vehs) do
            local vid = tostring(veh)
            local name = jiaolu.getVehicleName(veh)
            local isSb = settingsState.standby[vid] ~= nil
            local ck = api.gui.comp.ImageView.new(isSb and "ui/checkbox1.tga" or "ui/checkbox0.tga")
            local btn = api.gui.comp.Button.new(ck, true)
            btn:onClick(function()
                if settingsState.standby[vid] then
                    settingsState.standby[vid] = nil
                    pcall(function() ck:setImage("ui/checkbox0.tga", false) end)
                else
                    settingsState.standby[vid] = {
                        parkingLine = timetableHelper.getCurrentLine(veh),
                        parkingStop = timetableHelper.getCurrentStation(veh),
                        name = name,
                    }
                    pcall(function() ck:setImage("ui/checkbox1.tga", false) end)
                end
            end)
            t:addRow({
                api.gui.comp.TextView.new(name),
                api.gui.comp.TextView.new(ln.name),
                btn,
            })
        end
    end
    scroll:setContent(t)
end

-- 延迟重建交路配置列表：点击回调内同步 setContent 会把正在被点击的组件/父级销毁
-- （C++ assert，pcall 抓不住 → 游戏崩溃，运行图预设展开即此教训）。用 invokeLater 推迟
-- 到下一帧，且合并多次请求为一次。
local cfgRebuildPending = false
scheduleCfgRebuild = function()
    local scroll = settingsState and settingsState.cfgScroll
    if not scroll then return end
    if cfgRebuildPending then return end
    cfgRebuildPending = true
    scroll:invokeLater(function()
        cfgRebuildPending = false
        pcall(function() rebuildConfigList() end)
    end)
end

rebuildConfigList = function()
    local scroll = settingsState and settingsState.cfgScroll
    if not scroll then return end
    local nc = api.gui.comp.Component.new("jrCfgList_" .. nextName())
    local nl = api.gui.layout.BoxLayout.new("VERTICAL")
    nc:setLayout(nl)

    if #settingsState.configs == 0 then
        local lbl = api.gui.comp.TextView.new(UIStrings.no_config)
        lbl:setStyleClassList({"timetable-mono-sc"})
        nl:addItem(lbl)
        scroll:setContent(nc)
        return
    end

    for _, cfg in ipairs(settingsState.configs) do
        local isExpanded = (settingsState.expandedId == cfg.id)

        -- 配置表头行：展开三角形 + 名称输入 + 删除
        local row = api.gui.comp.Component.new("jrCfg_" .. nextName())
        local rl = api.gui.layout.BoxLayout.new("HORIZONTAL")
        row:setLayout(rl)
        local tglIcon = api.gui.comp.TextView.new(isExpanded and "▽" or "▶")
        -- the default UI font (Lato) has no triangles; the Noto font has
        tglIcon:setStyleClassList({"timetable-mono-sc"})
        local tgl = api.gui.comp.Button.new(tglIcon, true)
        tgl:onClick(function()
            settingsState.expandedId = (settingsState.expandedId == cfg.id) and nil or cfg.id
            scheduleCfgRebuild()
        end)
        local nameInput = nil
        local okTI, tiField = pcall(function() return api.gui.comp.TextInputField.new("") end)
        if okTI and tiField then
            nameInput = tiField
            tiField:setText(cfg.name, false)
            tiField:onChange(function(text)
                if text and #text > 0 then cfg.name = text end
            end)
        end
        local delBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new("X"), true)
        delBtn:onClick(function()
            local targetId = cfg.id
            local targetName = cfg.name
            local cc2 = api.gui.comp.Component.new("jrCfgConfirm_" .. nextName())
            local cl2 = api.gui.layout.BoxLayout.new("VERTICAL")
            cc2:setLayout(cl2)
            cl2:addItem(api.gui.comp.TextView.new(string.format(UIStrings.confirm_delete, targetName)))
            local blc2 = api.gui.comp.Component.new("jrCfgConfirmBtns_" .. nextName())
            local bll2 = api.gui.layout.BoxLayout.new("HORIZONTAL")
            blc2:setLayout(bll2)
            local okW, cw2 = pcall(function() return api.gui.comp.Window.new(UIStrings.warning, cc2) end)
            if not okW or not cw2 then return end
            cw2:addHideOnCloseHandler()
            cw2:setMovable(true)
            cw2:setSize(api.gui.util.Size.new(350, 120))
            cw2:setPosition(400, 300)
            local ok2 = api.gui.comp.Button.new(api.gui.comp.TextView.new(UIStrings.confirm), true)
            ok2:onClick(function()
                pcall(function() cw2:setVisible(false, false) end)
                for i, p in ipairs(settingsState.configs) do
                    if p.id == targetId then table.remove(settingsState.configs, i); break end
                end
                if settingsState.expandedId == targetId then settingsState.expandedId = nil end
                scheduleCfgRebuild()
            end)
            local cancel2 = api.gui.comp.Button.new(api.gui.comp.TextView.new(UIStrings.cancel), true)
            cancel2:onClick(function() pcall(function() cw2:setVisible(false, false) end) end)
            bll2:addItem(ok2)
            bll2:addItem(cancel2)
            cl2:addItem(blc2)
        end)
        rl:addItem(tgl)
        if nameInput then rl:addItem(nameInput) else rl:addItem(api.gui.comp.TextView.new(cfg.name)) end
        rl:addItem(delBtn)
        nl:addItem(row)

        -- 展开：线路列表（勾选 + 序号）
        if isExpanded then
            local lines = jiaolu.getRailLines()
            local filter = settingsState.filterText or ""
            local nextOrder = 1
            for _, ln in ipairs(lines) do
                local ord = cfg.lines and cfg.lines[tostring(ln.id)]
                if ord then nextOrder = math.max(nextOrder, ord + 1) end
            end
            for _, ln in ipairs(lines) do
                if #filter == 0 or string.find(string.lower(tostring(ln.name)), string.lower(filter), 1, true) then
                    local lrow = api.gui.comp.Component.new("jrLine_" .. nextName())
                    local lrl = api.gui.layout.BoxLayout.new("HORIZONTAL")
                    lrow:setLayout(lrl)
                    local key = tostring(ln.id)
                    local isIn = cfg.lines and cfg.lines[key] ~= nil
                    local ord = cfg.lines and cfg.lines[key]
                    local ck = api.gui.comp.ImageView.new(isIn and "ui/checkbox1.tga" or "ui/checkbox0.tga")
                    local cb = api.gui.comp.Button.new(ck, true)
                    cb:onClick(function()
                        if cfg.lines and cfg.lines[key] then
                            cfg.lines[key] = nil
                            pcall(function() ck:setImage("ui/checkbox0.tga", false) end)
                        else
                            if not cfg.lines then cfg.lines = {} end
                            cfg.lines[key] = nextOrder
                            nextOrder = nextOrder + 1
                            pcall(function() ck:setImage("ui/checkbox1.tga", false) end)
                        end
                        scheduleCfgRebuild()
                    end)
                    local nameTv = api.gui.comp.TextView.new(ln.name)
                    nameTv:setStyleClassList({"timetable-mono-sc"})
                    local sortLbl = api.gui.comp.TextView.new(UIStrings.sort)
                    sortLbl:setStyleClassList({"timetable-mono-sc"})
                    local sp = api.gui.comp.DoubleSpinBox.new()
                    sp:setMinimum(1, false)
                    sp:setMaximum(99, false)
                    pcall(function() sp:setValue(ord or 1, false) end)
                    sp:onChange(function(v)
                        -- onChange 逐位触发：只写数据，不重建 UI（避免打断输入焦点）
                        if not cfg.lines then cfg.lines = {} end
                        cfg.lines[key] = math.floor(v + 0.5)
                    end)
                    lrl:addItem(cb)
                    lrl:addItem(nameTv)
                    lrl:addItem(sortLbl)
                    lrl:addItem(sp)
                    nl:addItem(lrow)
                end
            end
        end
    end
    scroll:setContent(nc)
end

local function showValidationWarning(vres)
    local cc = api.gui.comp.Component.new("jrValidate_" .. nextName())
    local cl = api.gui.layout.BoxLayout.new("VERTICAL")
    cc:setLayout(cl)
    cc:setMinimumSize(api.gui.util.Size.new(480, 260))
    cc:setMaximumSize(api.gui.util.Size.new(480, 260))
    cl:addItem(api.gui.comp.TextView.new(UIStrings.warning .. ":"))
    for _, e in ipairs(vres.errors) do
        local msg = ""
        if e.reason == "station" then
            msg = string.format(UIStrings.invalid_station, tostring(e.cfgName), tostring(e.lineA), tostring(e.lineB))
        elseif e.reason == "time" then
            msg = string.format(UIStrings.invalid_time, tostring(e.cfgName), tostring(e.lineA), tostring(e.lineB))
        elseif e.reason == "order" then
            msg = string.format(UIStrings.invalid_order, tostring(e.cfgName), tostring(e.lineA))
        elseif e.reason == "dup" then
            msg = string.format(UIStrings.invalid_dup, tostring(e.lineA))
        end
        local tv = api.gui.comp.TextView.new(msg)
        tv:setStyleClassList({"timetable-punct-late"})
        cl:addItem(tv)
    end
    local blc = api.gui.comp.Component.new("jrValidateBtns_" .. nextName())
    local bll = api.gui.layout.BoxLayout.new("HORIZONTAL")
    blc:setLayout(bll)
    local okBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(UIStrings.confirm), true)
    local okW, vw = pcall(function() return api.gui.comp.Window.new(UIStrings.warning, cc) end)
    if not okW or not vw then return end
    vw:addHideOnCloseHandler()
    vw:setMovable(true)
    vw:setSize(api.gui.util.Size.new(480, 280))
    vw:setPosition(350, 200)
    okBtn:onClick(function() pcall(function() vw:setVisible(false, false) end) end)
    bll:addItem(okBtn)
    cl:addItem(blc)
end

openSettings = function()
    local jrl = jiaolu.getData()
    settingsState = {
        configs = deepCopyConfigs(jrl.configs),
        standby = {},
        expandedId = nil,
        filterText = "",
        window = nil,
        vehScroll = nil,
        cfgScroll = nil,
    }
    for k, v in pairs(jrl.standby or {}) do
        settingsState.standby[k] = { parkingLine = v.parkingLine, parkingStop = v.parkingStop, name = v.name }
    end

    local content = api.gui.comp.Component.new("jrSettings_" .. nextName())
    local cl = api.gui.layout.BoxLayout.new("VERTICAL")
    content:setLayout(cl)
    -- 内容高度必须 < 窗口高度 - 标题栏（~30px），否则最底部（确定/取消按钮行）会被裁掉
    content:setMinimumSize(api.gui.util.Size.new(720, 540))
    content:setMaximumSize(api.gui.util.Size.new(720, 540))

    -- 分区1：热备车设置
    local h1 = api.gui.comp.TextView.new(UIStrings.standby_setting)
    h1:setStyleClassList({"timetable-settings-header"})
    cl:addItem(h1)

    local vehScroll = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new("jrVehList_" .. nextName()), "jr.vehList")
    vehScroll:setMinimumSize(api.gui.util.Size.new(720, 195))
    vehScroll:setMaximumSize(api.gui.util.Size.new(720, 195))
    settingsState.vehScroll = vehScroll
    rebuildVehicleList()
    cl:addItem(vehScroll)

    -- 分区2：交路配置
    local h2 = api.gui.comp.TextView.new(UIStrings.jiaolu_config)
    h2:setStyleClassList({"timetable-settings-header"})
    cl:addItem(h2)

    -- 配置区表头：+ 添加 / 搜索框（搜索框不随列表重建，保持输入焦点）
    local cfgHdr = api.gui.comp.Component.new("jrCfgHdr_" .. nextName())
    local chl = api.gui.layout.BoxLayout.new("HORIZONTAL")
    cfgHdr:setLayout(chl)
    local addBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new("+"), true)
    addBtn:onClick(function()
        local newId = tostring(#settingsState.configs + 1)
        table.insert(settingsState.configs, { id = newId, name = UIStrings.title_short .. " " .. newId, lines = {} })
        settingsState.expandedId = newId
        scheduleCfgRebuild()
    end)
    local searchLbl = api.gui.comp.TextView.new(UIStrings.search)
    searchLbl:setStyleClassList({"timetable-mono-sc"})
    local okSF, searchInput = pcall(function() return api.gui.comp.TextInputField.new("") end)
    if okSF and searchInput then
        searchInput:onChange(function(text)
            settingsState.filterText = text or ""
            scheduleCfgRebuild()
        end)
    end
    chl:addItem(addBtn)
    chl:addItem(searchLbl)
    if okSF and searchInput then chl:addItem(searchInput) end
    cl:addItem(cfgHdr)

    local cfgScroll = api.gui.comp.ScrollArea.new(api.gui.comp.TextView.new("jrCfgList_" .. nextName()), "jr.cfgList")
    cfgScroll:setMinimumSize(api.gui.util.Size.new(720, 225))
    cfgScroll:setMaximumSize(api.gui.util.Size.new(720, 225))
    settingsState.cfgScroll = cfgScroll
    rebuildConfigList()
    cl:addItem(cfgScroll)

    -- 确定 / 取消
    local btnRow = api.gui.comp.Component.new("jrSettingsBtns_" .. nextName())
    local brl = api.gui.layout.BoxLayout.new("HORIZONTAL")
    btnRow:setLayout(brl)
    local okBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(UIStrings.confirm), true)
    local cancelBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new(UIStrings.cancel), true)
    brl:addItem(okBtn)
    brl:addItem(cancelBtn)
    cl:addItem(btnRow)

    local okW, w = pcall(function() return api.gui.comp.Window.new(UIStrings.settings, content) end)
    if not okW or not w then return end
    settingsState.window = w
    w:addHideOnCloseHandler()
    w:setMovable(true)
    w:setSize(api.gui.util.Size.new(720, 600))
    w:setPosition(240, 100)
    w:onClose(function()
        settingsState = nil
    end)

    okBtn:onClick(function()
        local myState = settingsState
        pcall(function() if w then w:setVisible(false, false) end end)
        -- 应用热备车变更（对比旧/新，逐个 setStandby）
        local jrl = jiaolu.getData()
        local oldStandby = jrl.standby or {}
        local allIds = {}
        for k in pairs(oldStandby) do allIds[k] = true end
        for k in pairs(myState.standby) do allIds[k] = true end
        for vid in pairs(allIds) do
            local was = oldStandby[vid] ~= nil
            local is = myState.standby[vid] ~= nil
            if was ~= is then
                pcall(function()
                    local v = tonumber(vid)
                    if v and v > 0 then
                        if is then jiaolu.setStandby(v, true) else jiaolu.setStandby(v, false) end
                    end
                end)
            end
        end
        -- 写入交路配置
        jrl.configs = myState.configs
        -- 校验并提示不合理项
        local vres = jiaolu.validateConfigs()
        if not vres.ok and vres.errors and #vres.errors > 0 then
            showValidationWarning(vres)
        end
        sync()
        settingsState = nil
    end)

    cancelBtn:onClick(function()
        pcall(function() if w then w:setVisible(false, false) end end)
        settingsState = nil
    end)
end

return jiaoluGUI
