--[[
编组调试工具（独立测试项目）
====================================================
工具栏"编组"按钮打开独立窗口，用于实验 make.replaceVehicle 换编组：
  1. 选择列车：列出地图上所有列车（仅 RAIL，不含汽车/飞机/轮船）——下拉框
  2. 选择补机：列出"地图上已出现车型"中的动力车（modelId + 功率）——下拉框
  3. 补机位置：车头（插到编组最前） / 车尾（追加到编组最后）
  4. 保存：把补机加进所选列车编组 → replaceVehicle

本模块完全自包含：不 require 时刻表/运行图相关模块，不改动主项目任何数据，
只读引擎 API + 发 replaceVehicle 命令。字段结构（modelRep/metadata 功率等）
文档未列全，全部 pcall 保护 + 日志输出，供实测迭代。
====================================================
]]

local consistDebug = {}

-- 窗口/选区状态（模块级 local，窗口重建时重新收集）
local win = nil
local trainList = {}          -- { {id=vehicle, name=..., count=...}, ... }
local helperList = {}         -- { {modelId=..., name=..., power=...}, ... }
local selectedTrainId = nil
local selectedHelperModelId = nil
local helperPosition = "front"  -- "front" 车头 / "back" 车尾
local dumpedModelDump = false
local purchaseSeq = 0  -- 每次加挂自增，保证新增 part 的 purchaseTime 互不相同（仅收费模式用）
-- 加挂补机是否收费：
--   false=免费：purchaseTime 复制源值 → replaceVehicle 不扣钱（实测）；
--   true =收费：purchaseTime=当前游戏时刻+自增 → 游戏按"新买"记账扣钱。
-- 后续做"玩家选择免费/收费"的 UI 开关时改这个值即可（也可存 timetableObject 持久化）。
local CHARGE_MONEY = false

local function dbg(msg) print("[ConsistDebug] " .. tostring(msg)) end

-- enum.Carrier.RAIL 值（读不到 enum 时兜底 = 1）
local CARRIER_RAIL = 1
pcall(function()
    local e = api.type.enum.Carrier.RAIL
    if e ~= nil then CARRIER_RAIL = e end
end)

-------------------------------------------------------------
-- 安全遍历：兼容 Lua 表与 userdata。
-- 对 userdata 做 # / 索引有 C++ 异常风险（AGENTS.md 教训），逐次 pcall 取，
-- 取不到/越界即停。
-------------------------------------------------------------
local function forEachIndexed(t, fn)
    if t == nil then return end
    if type(t) == "table" then
        for i = 1, #t do
            local v = t[i]
            if v == nil then break end
            fn(i, v)
        end
        return
    end
    local i = 1
    while i <= 10000 do
        local ok, v = pcall(function() return t[i] end)
        if not ok or v == nil then break end
        fn(i, v)
        i = i + 1
    end
end

-- 深拷贝：表递归复制，userdata/数字/字符串等原样传回（替换配置要拿"纯 Lua 表"结构）
local function copyDeep(v)
    if type(v) == "table" then
        local r = {}
        for k, w in pairs(v) do r[k] = copyDeep(w) end
        return r
    end
    return v
end

-- 打印表的一级字段名+类型（诊断用，只遍历 Lua 表）
local function dumpKeys(obj, label)
    if type(obj) ~= "table" then
        dbg(label .. " is NOT a table (type=" .. type(obj) .. ")")
        return
    end
    local parts = {}
    local count = 0
    for k, v in pairs(obj) do
        count = count + 1
        if count <= 40 then parts[#parts + 1] = tostring(k) .. "=" .. type(v) end
    end
    dbg(label .. " keys(" .. count .. "): " .. table.concat(parts, ", "))
end

-- 遍历 userdata 可访问的字段/方法名（Sol2 的 metatable.__index 通常是完整清单）
local function dumpUserdata(ud, label)
    if ud == nil then dbg(label .. " = nil"); return end
    local mt = nil
    pcall(function() mt = getmetatable(ud) end)
    if type(mt) ~= "table" then
        dbg(label .. " type=" .. type(ud) .. " no metatable")
        return
    end
    local mtKeys = {}
    for k, v in pairs(mt) do mtKeys[#mtKeys + 1] = tostring(k) .. "=" .. type(v) end
    dbg(label .. " type=" .. type(ud) .. " metatable: " .. table.concat(mtKeys, ", "))
    local idx = mt.__index
    if type(idx) == "table" then
        local idxKeys = {}
        local count = 0
        for k, v in pairs(idx) do
            count = count + 1
            if count <= 120 then idxKeys[#idxKeys + 1] = tostring(k) .. "=" .. type(v) end
        end
        dbg(label .. " __index(" .. count .. "): " .. table.concat(idxKeys, ", "))
    else
        dbg(label .. " __index type=" .. type(idx))
    end
    local ni = mt.__newindex
    if ni ~= nil then dbg(label .. " __newindex type=" .. type(ni)) end
end

-------------------------------------------------------------
-- 数据收集
-------------------------------------------------------------

-- 枚举地图上所有列车（RAIL；carrier 读不到时按铁路算——调试工具宁可多显示）
local function collectTrains()
    local res = {}
    local seen = {}
    local ok, vmap = pcall(function()
        return api.engine.system.transportVehicleSystem.getLine2VehicleMap()
    end)
    if not ok or not vmap then
        dbg("collectTrains: getLine2VehicleMap failed")
        return res
    end
    for _, vehicles in pairs(vmap) do
        for _, veh in pairs(vehicles) do
            local key = tostring(veh)
            if not seen[key] then
                seen[key] = true
                local carrier = nil
                pcall(function()
                    local c = api.engine.getComponent(veh, 70) -- TRANSPORT_VEHICLE
                    if c and c.carrier ~= nil then carrier = c.carrier end
                end)
                if carrier == nil then carrier = CARRIER_RAIL end
                if carrier == CARRIER_RAIL then
                    local name = nil
                    pcall(function()
                        local nc = api.engine.getComponent(veh, api.type.ComponentType.NAME)
                        if nc and nc.name then name = nc.name end
                    end)
                    if not name then
                        pcall(function()
                            local c = api.engine.getComponent(veh, 70)
                            if c and c.line then
                                local nc = api.engine.getComponent(c.line, api.type.ComponentType.NAME)
                                if nc and nc.name then name = nc.name end
                            end
                        end)
                    end
                    if not name then name = "Train " .. key end
                    -- 编组节数（用于验证替换是否生效）
                    local count = 0
                    pcall(function()
                        local c = api.engine.getComponent(veh, 70)
                        if c and c.transportVehicleConfig then
                            local vv = nil
                            pcall(function() vv = c.transportVehicleConfig.vehicles end)
                            if type(vv) == "table" then count = #vv end
                        end
                    end)
                    table.insert(res, { id = veh, name = name, count = count })
                end
            end
        end
    end
    table.sort(res, function(a, b) return a.name < b.name end)
    return res
end

-- 递归在表里找"功率"类数值字段（只遍历 Lua 表，跳过 userdata；深度/访问表双上限）
local function scanForPower(obj, depth, visited)
    if depth > 8 or type(obj) ~= "table" or visited[obj] then return nil end
    visited[obj] = true
    local keys = { "power", "maxPower", "maximumPower", "enginePower", "kW", "powerKw", "motorPower", "drivingPower", "maxSpeed", "speed", "mass", "weight" }
    for _, n in ipairs(keys) do
        local v = obj[n]
        if type(v) == "number" and v > 0 then return v end
    end
    for _, v in pairs(obj) do
        if type(v) == "table" then
            local r = scanForPower(v, depth + 1, visited)
            if r then return r end
        end
    end
    return nil
end

local function prettyName(fn)
    if not fn then return nil end
    local base = tostring(fn):match("[^/\\]+$") or tostring(fn)
    base = base:gsub("%.mdl$", ""):gsub("%.mul$", "")
    return base
end

-- 枚举动力车：从现有列车 config 收集去重 modelId，再经 modelRep 读功率/名字。
-- 只覆盖"地图上出现过/在用的车型"（modelId 保证有效）。功率读不到时标 "?"（仍可选）。
local function collectHelpers()
    local res = {}
    local seenModel = {}
    for _, tr in ipairs(collectTrains()) do
        local cfg = nil
        pcall(function()
            local c = api.engine.getComponent(tr.id, 70)
            if c then cfg = c.transportVehicleConfig end
        end)
        local vehicles = nil
        pcall(function() if cfg then vehicles = cfg.vehicles end end)
        if vehicles then
            forEachIndexed(vehicles, function(_, part)
                local mid = nil
                pcall(function()
                    if part and part.part then mid = part.part.modelId end
                end)
                if type(mid) == "number" and not seenModel[mid] then
                    seenModel[mid] = true
                    local power, name = nil, nil
                    pcall(function()
                        local mres = api.res.modelRep.get(mid)
                        if mres then
                            power = scanForPower(mres, 0, {})
                            if type(mres) == "table" then
                                name = mres.name or mres.model or mres.fileName
                            end
                        end
                    end)
                    if not name then
                        pcall(function() name = api.res.modelRep.getName(mid) end)
                    end
                    name = prettyName(name)
                    if not name then name = "Model " .. tostring(mid) end
                    table.insert(res, { modelId = mid, name = name, power = power })
                    if not power then
                        dbg("helper modelId=" .. mid .. " name='" .. name .. "' power=? (modelRep 未读到功率字段)")
                        -- 首个功率读取失败的模型：dump 结构一次（userdata 走 metatable），定位功率字段名
                        if not dumpedModelDump then
                            dumpedModelDump = true
                            pcall(function()
                                local mres = api.res.modelRep.get(mid)
                                if mres then
                                    if type(mres) == "table" then dumpKeys(mres, "modelRep.get(" .. mid .. ")")
                                    else dumpUserdata(mres, "modelRep.get(" .. mid .. ")") end
                                end
                            end)
                        end
                    end
                end
            end)
        end
    end
    -- 有功率的按功率降序，未知的排最后
    table.sort(res, function(a, b)
        local pa, pb = a.power or 0, b.power or 0
        if (a.power ~= nil) ~= (b.power ~= nil) then return a.power ~= nil end
        return pa > pb
    end)
    return res
end

-------------------------------------------------------------
-- 换编组（构造/复制 + 容器 add + 安全校验）
-------------------------------------------------------------

-- 统计 cfg.vehicles 节数（兼容表 / userdata）
local function readVehiclesCount(cfg)
    local vehTbl = nil
    pcall(function() if cfg then vehTbl = cfg.vehicles end end)
    if not vehTbl then return 0 end
    if type(vehTbl) == "table" then return #vehTbl end
    local n = nil
    pcall(function() n = vehTbl:size() end)
    if n then return n end
    n = 0
    while n < 10000 do
        local ok, v = pcall(function() return vehTbl[n + 1] end)
        if not ok or v == nil then break end
        n = n + 1
    end
    return n
end

-- 容器大小（get size，兼容 :size() 与 #）
local function containerSize(c)
    if not c then return 0 end
    local n = nil
    pcall(function() n = c:size() end)
    if n == nil then pcall(function() n = #c end) end
    return n or 0
end

-- VehiclePart.loadConfig 大小（崩溃相关字段：每车厢一项，-1=自动选择）
local function vehicleLoadConfigSize(p)
    local vp = nil
    pcall(function() vp = p.part end)
    if not vp then return 0 end
    local c = nil
    pcall(function() c = vp.loadConfig end)
    return containerSize(c)
end

-- 读取容器第 i 项（0 基 / 1 基兼容）
local function containerGet(c, i)
    local v = nil
    pcall(function() v = c:get(i) end)
    if v == nil then pcall(function() v = c[i + 1] end) end
    return v
end

-- 把 src 容器的元素复制进 dst（依次尝试 add / set；随后由调用方 re-read 验证）
local function copyContainerInto(src, dst)
    if not src or not dst then return false end
    local n = containerSize(src)
    if n == 0 then return false end
    local ok = false
    for i = 0, n - 1 do
        local v = containerGet(src, i)
        if v ~= nil then
            if pcall(function() dst:add(v) end) then ok = true
            elseif pcall(function() dst:set(i, v) end) then ok = true end
        end
    end
    return ok
end

-- 整份复制一个 part（手工复制；关键：loadConfig / autoLoadConfig 必须整体赋值，
-- 逐元素 add 不落盘——读取返回副本。整体赋值对 loadConfig 已验证有效）
local function copyPartFrom(srcPart)
    local mt = nil
    pcall(function() mt = getmetatable(srcPart) end)
    if not mt then return nil end

    local np = nil
    pcall(function() np = mt.new() end)
    if not np then return nil end

    -- 标量字段：maintenanceState / targetMaintenanceState 复制源。
    -- purchaseTime 按收费模式决定：
    --   免费(默认)：复制源值 → replaceVehicle 不扣钱；但源值可能与目标原车相同，
    --     引擎/编辑器不靠它判显示（显示靠 vehicleGroups），故无副作用。
    --   收费：purchaseTime=当前游戏时刻+自增 → 每节都是独立"新买"，游戏记账扣钱。
    for _, f in ipairs({ "maintenanceState", "targetMaintenanceState" }) do
        local v = nil
        pcall(function() v = srcPart[f] end)
        if v ~= nil then pcall(function() np[f] = v end) end
    end
    local srcPT = nil
    pcall(function() srcPT = srcPart.purchaseTime end)
    local newPT = srcPT
    if CHARGE_MONEY then
        local nowMs = nil
        pcall(function()
            local w = api.engine.util.getWorld()
            local gt = api.engine.getComponent(w, api.type.ComponentType.GAME_TIME)
            if gt and gt.gameTime then nowMs = gt.gameTime end
        end)
        purchaseSeq = purchaseSeq + 1
        newPT = (nowMs or (srcPT or 0)) + (purchaseSeq * 1000)
    end
    local okPT = pcall(function() np.purchaseTime = newPT end)
    dbg("copyPartFrom: purchaseTime src=" .. tostring(srcPT) .. " charge=" .. tostring(CHARGE_MONEY)
        .. " -> new=" .. tostring(newPT) .. " set=" .. tostring(okPT))

    -- VehiclePart：默认构造 + modelId/reversed + loadConfig 整体赋值
    local svp = nil
    pcall(function() svp = srcPart.part end)
    if svp then
        local vmt = nil
        pcall(function() vmt = getmetatable(svp) end)
        local vp = nil
        if vmt then pcall(function() vp = vmt.new() end) end
        if vp then
            local mid, rev = nil, nil
            pcall(function() mid = svp.modelId end)
            pcall(function() rev = svp.reversed end)
            if mid ~= nil then pcall(function() vp.modelId = mid end) end
            if rev ~= nil then pcall(function() vp.reversed = rev end) end
            local srcC = nil
            pcall(function() srcC = svp.loadConfig end)
            if srcC then
                local okLc = pcall(function() vp.loadConfig = srcC end)
                dbg("copyPartFrom: vp.loadConfig assign ok=" .. tostring(okLc)
                    .. " size=" .. tostring(containerSize(vp.loadConfig)))
            end
            pcall(function() np.part = vp end)
        end
    end

    -- autoLoadConfig 整体赋值（必须与 loadConfig 同大小，否则引擎 assert）
    local srcAlc = nil
    pcall(function() srcAlc = srcPart.autoLoadConfig end)
    if srcAlc then
        local okAlc = pcall(function() np.autoLoadConfig = srcAlc end)
        dbg("copyPartFrom: autoLoadConfig assign ok=" .. tostring(okAlc)
            .. " size=" .. tostring(containerSize(np.autoLoadConfig)))
    end

    dbg("copyPartFrom: newPart vp.loadConfig=" .. tostring(vehicleLoadConfigSize(np))
        .. " autoLoadConfig=" .. tostring(containerSize(np.autoLoadConfig)))
    return np
end

-- 在所有现有列车里找一个 modelId 匹配的 part（复制源）
local function findPartByModelId(modelId)
    for _, tr in ipairs(collectTrains()) do
        local comp = nil
        pcall(function() comp = api.engine.getComponent(tr.id, 70) end)
        local cfg = nil
        pcall(function() if comp then cfg = comp.transportVehicleConfig end end)
        local vehTbl = nil
        pcall(function() if cfg then vehTbl = cfg.vehicles end end)
        if vehTbl then
            local n = readVehiclesCount(cfg)
            for i = 1, n do
                local p = nil
                pcall(function() p = vehTbl[i] end)
                local mid = nil
                pcall(function() if p and p.part then mid = p.part.modelId end end)
                if mid == modelId then
                    return p, tr.name
                end
            end
        end
    end
    return nil
end

-- 保存后延迟重读（replaceVehicle 在 GUI 线程下一模拟步才生效，双 invokeLater 等更久）
local function verifyConsist(tag)
    pcall(function()
        local comp = api.engine.getComponent(selectedTrainId, 70)
        if not comp then dbg("verify(" .. tag .. "): read comp failed"); return end
        local cfg = nil
        pcall(function() cfg = comp.transportVehicleConfig end)
        dbg("verify(" .. tag .. "): vehicles=" .. readVehiclesCount(cfg))
    end)
end

-- 选列车时做只读诊断（读取是安全路径）：确认 getComponent/cfg/vehicles 读不崩、
-- 首个 part 的 modelId + cargo 大小——若这里就崩，问题在读取而非修改/发送
local function probeTrain(vehicleId)
    dbg("PROBE train=" .. tostring(vehicleId))
    local comp = nil
    pcall(function() comp = api.engine.getComponent(vehicleId, 70) end)
    dbg("PROBE comp=" .. type(comp))
    if comp then
        local cfg = nil
        pcall(function() cfg = comp.transportVehicleConfig end)
        dbg("PROBE cfg=" .. type(cfg))
        if cfg then
            local vehTbl = nil
            pcall(function() vehTbl = cfg.vehicles end)
            dbg("PROBE vehTbl=" .. type(vehTbl) .. " size=" .. tostring(readVehiclesCount(cfg)))
            pcall(function()
                local p1 = vehTbl[1]
                if p1 then
                    local mid = nil
                    pcall(function() mid = p1.part.modelId end)
                    dbg("PROBE part1 modelId=" .. tostring(mid)
                        .. " vp.loadConfig=" .. tostring(vehicleLoadConfigSize(p1))
                        .. " autoLoadConfig=" .. tostring(containerSize(p1.autoLoadConfig)))
                end
            end)
        end
    end
end

local function applyConsist()
    dbg("apply step: begin")
    if not selectedTrainId then dbg("no train selected"); return end
    if not selectedHelperModelId then dbg("no helper selected"); return end

    local comp = nil
    pcall(function() comp = api.engine.getComponent(selectedTrainId, 70) end)
    dbg("apply step: comp type=" .. type(comp))
    if not comp then dbg("getComponent failed"); return end

    local cfg = nil
    pcall(function() cfg = comp.transportVehicleConfig end)
    dbg("apply step: cfg type=" .. type(cfg))
    if not cfg then dbg("read transportVehicleConfig failed"); return end

    local vehTbl = nil
    pcall(function() vehTbl = cfg.vehicles end)
    dbg("apply step: vehTbl type=" .. type(vehTbl))
    if not vehTbl then dbg("cfg.vehicles nil"); return end

    local oldCount = readVehiclesCount(cfg)
    dbg("old vehicles=" .. oldCount)

    -- 找该车型的复制源 part（它自带与该车型匹配的 cargo 配置，避免引擎 assert 崩溃）
    local srcPart, srcName = findPartByModelId(selectedHelperModelId)
    if not srcPart then
        dbg("no source part for modelId=" .. selectedHelperModelId .. " in any train; abort (avoid crash)")
        return
    end
    dbg("source part from train: " .. tostring(srcName) .. " modelId=" .. selectedHelperModelId
        .. " vp.loadConfig=" .. vehicleLoadConfigSize(srcPart))

    -- 整份复制
    local newPart = copyPartFrom(srcPart)
    if not newPart then dbg("copyPartFrom failed; abort"); return end

    -- 安全校验：modelId 对上 + VehiclePart.loadConfig 非空 + autoLoadConfig 与 loadConfig 同大小
    -- （缺失/不一致会触发引擎 assert 崩溃）
    local okMid, okPart, cargoOk = false, false, false
    pcall(function() okMid = (newPart.part and newPart.part.modelId == selectedHelperModelId) end)
    pcall(function() okPart = (newPart.part ~= nil) end)
    local newCargo = vehicleLoadConfigSize(newPart)
    local srcCargo = vehicleLoadConfigSize(srcPart)
    local newAlc = 0
    pcall(function() newAlc = containerSize(newPart.autoLoadConfig) end)
    cargoOk = (newCargo > 0 and newCargo == srcCargo and newAlc == newCargo)
    dbg("copy check: modelIdMatch=" .. tostring(okMid) .. " partSet=" .. tostring(okPart)
        .. " vp.loadConfig " .. newCargo .. "/" .. srcCargo
        .. " autoLoadConfig=" .. tostring(newAlc))
    if not (okMid and okPart and cargoOk) then
        dbg("copy validation FAILED; abort (do NOT send, avoid crash)")
        return
    end

    -- 发送（传回 cfg userdata）。当前为干跑调试：SEND_ENABLED=false 只构造+校验+日志，
    -- 不 add、不发命令（若 cfg.vehicles 是真实车辆活引用，add 会直接污染实车→引擎 Internal error）。
    local SEND_ENABLED = true
    if SEND_ENABLED then
        local okAdd = false
        if helperPosition == "back" then
            okAdd = pcall(function() vehTbl:add(newPart) end)
        else
            -- 车头：read 现有 parts → clear → 先 add 补机 → 再按序 add 回原 parts。
            -- 不用 insert（签名未测，尝试多种都失败）；add/clear 已验证可靠。
            local parts = {}
            local n = readVehiclesCount(cfg)
            local readOk = true
            for i = 1, n do
                local p = nil
                pcall(function() p = vehTbl[i] end)
                if p == nil then readOk = false; break end
                parts[#parts + 1] = p
            end
            if readOk then
                local okClr = pcall(function() vehTbl:clear() end)
                dbg("front: cleared=" .. tostring(okClr) .. " savedParts=" .. #parts)
                if okClr then
                    okAdd = pcall(function() vehTbl:add(newPart) end)
                    if okAdd then
                        for _, p in ipairs(parts) do
                            if not pcall(function() vehTbl:add(p) end) then okAdd = false; break end
                        end
                    end
                end
            else
                dbg("front: read existing parts failed")
            end
            if not okAdd then
                dbg("front via clear+re-add failed; fallback append at back")
                okAdd = pcall(function() vehTbl:add(newPart) end)
            end
        end
        local sz = nil
        pcall(function() sz = vehTbl:size() end)
        dbg("vehicles add=" .. tostring(okAdd) .. " size=" .. tostring(sz) .. " (was " .. oldCount .. ")")
        if not okAdd then dbg("add failed; abort"); return end

        -- vehicleGroups：编辑器的分组依据（{3,1}=3节动车组+1节车厢）。加车厢必须同步，
        -- 否则编辑器仍按旧分组（如{1}）只显示 1 节。
        local vg = nil
        pcall(function() vg = cfg.vehicleGroups end)
        if vg then
            local vgSize = containerSize(vg)
            dbg("vehicleGroups before: size=" .. tostring(vgSize))
            -- 尝试在现有分组后追加 1（每节新增车厢一组）
            local okVg = pcall(function() vg:add(1) end)
            dbg("vehicleGroups add1: ok=" .. tostring(okVg) .. " size=" .. tostring(containerSize(vg)))
            if not okVg or containerSize(vg) == vgSize then
                dbg("vehicleGroups: elementwise add not persisting, try set at index")
                pcall(function() vg:set(vgSize, 1) end)
                dbg("vehicleGroups set: size=" .. tostring(containerSize(vg)))
            end
        else
            dbg("vehicleGroups: nil (cfg has no groups field)")
        end

        local okSend, err = pcall(function()
            api.cmd.sendCommand(api.cmd.make.replaceVehicle(selectedTrainId, cfg), function(_, success)
                dbg("replaceVehicle callback success=" .. tostring(success))
            end)
        end)
        dbg("replaceVehicle sent: " .. tostring(okSend) .. (okSend and "" or " err=" .. tostring(err)))
        if win then
            win:invokeLater(function()
                win:invokeLater(function() pcall(function() verifyConsist("C") end) end)
            end)
        end
    else
        dbg("DRY-RUN: build OK, would add 1 part (target currently " .. oldCount
            .. " vehicles, helper at " .. helperPosition .. "), NOT added/sent")
    end
end

-------------------------------------------------------------
-- UI（ComboBox 下拉选择，布局同"晚点判定标准"：label 在前、下拉框在后）
-------------------------------------------------------------
function consistDebug.showWindow()
    if win ~= nil then
        pcall(function() win:setVisible(true, true) end)
        return
    end

    -- 打开时刷新数据
    trainList = collectTrains()
    helperList = collectHelpers()
    selectedTrainId = nil
    selectedHelperModelId = nil
    helperPosition = "front"
    dbg("open: trains=" .. #trainList .. " helpers=" .. #helperList)

    local content = api.gui.comp.Component.new("consistContent")
    local cl = api.gui.layout.BoxLayout.new("VERTICAL")
    content:setLayout(cl)
    content:setMinimumSize(api.gui.util.Size.new(460, 180))
    content:setMaximumSize(api.gui.util.Size.new(460, 180))

    -- ---- 选择列车 ----
    local trRow = api.gui.comp.Component.new("trainRow")
    local trl = api.gui.layout.BoxLayout.new("HORIZONTAL")
    trRow:setLayout(trl)
    local trLbl = api.gui.comp.TextView.new("选择列车")
    trLbl:setStyleClassList({"timetable-mono-sc"})
    trl:addItem(trLbl)
    local trainCombo = api.gui.comp.ComboBox.new()
    for _, tr in ipairs(trainList) do
        local cnt = tr.count and (tr.count .. "节") or "?"
        trainCombo:addItem(tr.name .. "  (" .. cnt .. ")")
    end
    if #trainList == 0 then trainCombo:addItem("（未找到列车）") end
    trainCombo:onIndexChanged(function(i)
        if i < 0 or i >= #trainList then return end
        selectedTrainId = trainList[i + 1].id
        dbg("selected train: " .. trainList[i + 1].name .. " (" .. tostring(selectedTrainId) .. ")")
        probeTrain(selectedTrainId)
    end)
    trl:addItem(trainCombo)
    cl:addItem(trRow)

    -- ---- 选择补机 ----
    local hpRow = api.gui.comp.Component.new("helperRow")
    local hpl = api.gui.layout.BoxLayout.new("HORIZONTAL")
    hpRow:setLayout(hpl)
    local hpLbl = api.gui.comp.TextView.new("选择补机")
    hpLbl:setStyleClassList({"timetable-mono-sc"})
    hpl:addItem(hpLbl)
    local helperCombo = api.gui.comp.ComboBox.new()
    for _, h in ipairs(helperList) do
        local pw = h.power and (string.format("%.0f", h.power) .. " kW") or "功率?"
        helperCombo:addItem(h.name .. "  [" .. pw .. "]")
    end
    if #helperList == 0 then helperCombo:addItem("（未收集到动力车，看日志）") end
    helperCombo:onIndexChanged(function(i)
        if i < 0 or i >= #helperList then return end
        selectedHelperModelId = helperList[i + 1].modelId
        dbg("selected helper: " .. helperList[i + 1].name .. " modelId=" .. tostring(selectedHelperModelId)
            .. " power=" .. tostring(helperList[i + 1].power))
    end)
    hpl:addItem(helperCombo)
    cl:addItem(hpRow)

    -- ---- 补机位置（车头/车尾） ----
    local posRow = api.gui.comp.Component.new("posRow")
    local posl = api.gui.layout.BoxLayout.new("HORIZONTAL")
    posRow:setLayout(posl)
    local posLbl = api.gui.comp.TextView.new("补机位置")
    posLbl:setStyleClassList({"timetable-mono-sc"})
    posl:addItem(posLbl)
    local posCombo = api.gui.comp.ComboBox.new()
    posCombo:addItem("车头")
    posCombo:addItem("车尾")
    posCombo:setSelected(0, false)
    posCombo:onIndexChanged(function(i)
        if i == 0 then helperPosition = "front"
        elseif i == 1 then helperPosition = "back" end
        dbg("helper position: " .. helperPosition)
    end)
    posl:addItem(posCombo)
    cl:addItem(posRow)

    -- ---- 保存 / 关闭 ----
    local br = api.gui.comp.Component.new("consistBtns")
    local brl = api.gui.layout.BoxLayout.new("HORIZONTAL")
    br:setLayout(brl)
    local saveBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new("保存"), true)
    saveBtn:onClick(function()
        local ok, err = pcall(applyConsist)
        if not ok then dbg("applyConsist ERROR: " .. tostring(err)) end
    end)
    local closeBtn = api.gui.comp.Button.new(api.gui.comp.TextView.new("关闭"), true)
    closeBtn:onClick(function()
        if win then pcall(function() win:setVisible(false, false) end) end
    end)
    brl:addItem(saveBtn); brl:addItem(closeBtn)
    cl:addItem(br)

    local okW, w = pcall(function() return api.gui.comp.Window.new("编组", content) end)
    if not okW or not w then dbg("Window.new failed"); return end
    win = w
    w:addHideOnCloseHandler()
    w:setMovable(true)
    w:setResizable(true)
    w:setSize(api.gui.util.Size.new(460, 200))
    w:setPosition(250, 150)
    w:onClose(function()
        win = nil
        trainList = {}; helperList = {}
        selectedTrainId = nil; selectedHelperModelId = nil
        helperPosition = "front"
    end)
end

return consistDebug
