# 开发进度 — 运行图预设系统

## 已修复（2026-07-31 本轮）

### 刷新/展开后"内容在顶、滚动条在底"错位（setScrollOffset 同值 no-op）
- **现象**：刷新或展开列表底部配置（如配置11）后，列表内容回到最上面，但滚动条仍停在原位置（底部）——继续下滑滑不动（滚动条已到最大值），往上滑一下让滚动条动起来后又能正常下滑。全部收起时展开正常，一旦展开过上面的配置再滚动到底部展开就触发
- **根因**：`setContent` 把内容视图**复位到顶部，但保留了旧的滚动条值**（底部）。`restoreScrollOffset` 再 `setScrollOffset(旧值)` 时值没变 → 引擎视为 no-op 不重新同步 → 内容与滚动条错位。用户手动滑动改变滚动值后才会重新同步，故"往上滑一下再往下滑就正常"
- **修复**：`restoreScrollOffset` 先 `setScrollOffset(0,0)` 归零再设目标值，强制引擎重新同步内容与滚动条；初始捕获失败时布局完成后补捕获
- **涉及**：`diagram_gui.lua:823-841`

### 切换预设后线路勾选"全部恢复勾选"（applyPreset 未重置未覆盖线路）
- **现象**：勾选/取消勾选线路后，展开其他铁路线再展开刚才修改的配置，线路又全部勾选上；车站勾选正常
- **根因**：`applyPresetToStations()` 应用 `lineData` 时**只覆盖 lineData 里存在的线路**，未被覆盖的线路继承上一预设（或默认全勾选）的 `checked` 状态。车站勾选是显式赋值（`else st.selected = false`）所以正常；线路没有对应 `else` 分支 → 状态残留
- **修复**：`applyPresetToStations()` 先 `for _, ld in pairs(allLines) do ld.checked = true end` 整体重置，再按 `preset.lineData` 覆盖——线路状态与车站一样**确定化**（lineData 未覆盖的线路默认勾选）
- **日志实锤（2026-07-31）**：取消勾选线路 52008/55277 后，`saveCurrentPreset` 的日志**完全没出现** → `saveCurrentPreset()` 在 pcall 内**静默抛异常**，lineData 从未写入 → 切换预设回来全勾选
- **根因实锤（SAVE ERROR 日志）**：`attempt to call global 'saveCurrentPreset' (a nil value)`——`updateLineList`（:828）定义在 `saveCurrentPreset`（:929）**之前**，Lua 局部变量只在声明之后可见，`updateLineList` 线路 checkbox 闭包里的引用被解析为**全局 nil**。车站/排序保存都在 `rebuildPresetList` 里（定义在 saveCurrentPreset 之后），所以正常——这就是"车站正常线路不正常"的原因
- **修复**：文件顶部加 `local saveCurrentPreset` 前向声明（:29），定义改为 `saveCurrentPreset = function() ... end`（:929）——与 AGENTS.md 已记录的 `rebuildPresetList` 前向引用 bug 完全同类
- **诊断日志清理**：移除 `lineCheck toggled`、`applyPreset lineData=set/nil`、`saveCurrentPreset unchecked=` 等临时日志；保留三条 `SAVE ERROR` 错误捕获（仅在保存失败时输出，作防御）
- **涉及**：`diagram_gui.lua:29,866,929`

### 刷新后滚动位置复位 / 车次列表乱序 / 新预设勾选继承（体验修复）
- **现象1（滚动复位）**：每次点刷新，铁路线列表/车次列表内容回到最上面，滚动条却停在原位置，用户继续改动很受影响
- **根因1**：`updateLineList()` / `rebuildPresetList()` 调用 `ScrollArea:setContent()` 重建内容会重置滚动条到顶部
- **修复1**：新增 `restoreScrollOffset(area, offset)`——`setContent` 前用 `getScrollOffset()` 记录，`setContent` 后用双重 `invokeLater` 等布局完成再 `setScrollOffset()` 恢复（复用 timetable_gui 的恢复模式）
- **现象2（勾选线路"消失"）**：勾选完线路点刷新，刚才勾选的线路好像丢了；用户认为是保存问题
- **根因2**：`getRelevantLines()` 遍历 `allLines`（来自 `pairs(lineSystem.getLines())`），**跨调用顺序不确定**——每次刷新线路随机跳位 + 列表滚回顶部，造成"线路消失"的视觉假象。另有数据面：`getAllTimetableData()` 重建 allLines 默认全勾选，勾选状态只经 `applyPresetToStations` 从 preset.lineData 恢复，未展开预设时的改动会丢
- **修复2**：
  1. `getRelevantLines()` 返回前按线路 ID 稳定排序（:412-418）
  2. `doRefreshData()` 开头记录 `prevChecks`（当前 allLines 勾选），重建并 applyPreset 后恢复（:1178-1181, 1211-1214）——即时保存与它一致，未展开预设的改动刷新后也保留
- **现象3（新预设只勾选第一个）**：新增铁路线配置后默认应全部线路勾选，实际只有第一个勾选
- **根因3**：新预设 `lineData = nil`，`applyPresetToStations` 不触碰 allLines.checked → 继承上一预设经 allLines 传递的勾选状态；用户首次操作触发 auto-save 时把旧勾选写进新预设
- **修复3**：`addNewPreset()` 显式 `for _, ld in pairs(allLines) do ld.checked = true end`（:1124-1126）
- **现象4（新增预设看不到）**：点 + 添加铁路线后，列表停在原滚动位置（或顶部），新预设追加在列表末尾且自动展开，玩家看不到
- **修复4**：`addNewPreset()` 设置 `pendingScrollPresetId`，`rebuildPresetList()` 记录该预设表头行，随后双重 `invokeLater` 等布局完成调用 `psa:ensureVisible(targetRow)`——**最小滚动**露出新预设表头，保留上方已有配置（如配置11）仍在视口内，同时能看到新增的配置12。不能滚到顶部也不能滚到底部（新预设已展开，底部只有它的最后一个车站行）
- **试错记录**：最初用像素计算 `rowRect.y - contentRect.y` 再 `setScrollOffset` 滚到新预设表头顶部——会滚过上方配置，且 `getContentRect` 在嵌套布局下时序不稳可能算出 0 导致回到顶部。改用 `ScrollArea:ensureVisible`（"Ensures a child component is visible"）语义正确
- **清理**：移除已无引用的 `diagram_save_i18n`（strings.lua 7 语言）+ `D.save` + description.txt 中"点击保存"描述改为"展开即绘/自动保存/刷新重绘"
- **涉及**：`diagram_gui.lua`、`strings.lua`、`description.txt`

### 即时保存 + 展开即绘制 + 移除保存按钮（重构）
- **需求**：勾选车站/输入排序序号后立即保存铁路线配置；展开预设立即展开车次列表并绘制运行图，切换预设即切换图形；改动后点刷新立即刷新列表并重绘；保存按钮冗余，删除
- **改动**（`diagram_gui.lua`）：
  1. **车站 checkbox 勾选后立即保存**：`saveCurrentPreset()` + `savePresetsToTimetableObject()`（:1065-1075）
  2. **排序 DoubleSpinBox onChange 立即保存**：只写数据不重建 UI（onChange 逐位触发，重建会打断输入焦点——复用 AGENTS.md 时刻表 SpinBox 丢值经验）（:1088-1098）
  3. **展开预设即绘制**：`displayedLines = getRelevantLines(...)` + `updateLineList()` + `refreshDiagram()`（:993-997）
  4. **刷新按钮**：`doRefreshData()` 无条件更新车次列表 + 重绘（:1159-1164）
  5. **新增 `clearDiagramViews()`**：清除折线视图 + 站名/时间标签，全部 pcall；`refreshDiagram()` 在勾选车站少于1个时调用它清除旧图而非静默返回（:496-516, 521-528）——解决"展开空预设不绘制但残留上一预设图形"
  6. **移除保存按钮 UI + `menu.saveButton` 引用 + 死代码 `doSaveAndDraw()`**
  7. **`addNewPreset()` 自动展开** + 清空车次列表/运行图（新预设无勾选车站，先勾选再点刷新绘制）（:1111-1124）
  8. **删除正在展开的预设**时同步清空车次列表/运行图（:1041-1052）
- **数据安全**：所有改动（车站勾选、序号、线路勾选）均即时保存并触发 `_diagramForceSync`，不再依赖保存按钮；关窗 `persistConfig` 仍兜底保存
- **涉及**：`diagram_gui.lua`

### 未展开预设时点保存导致车站勾选/序号被清空（数据丢失）
- **现象**：未展开任何铁路线预设时直接点保存，预设的车站列表**有概率**全部变成默认未勾选、序号变 256（旧版排序哨兵值被"幽灵"写回）
- **根因**：`doSaveAndDraw()` 在 `currentPresetRef == nil` 时回退 `if not p and #localPresets > 0 then p = localPresets[1] end`，随后 `saveCurrentPreset()` 把 `allStations` 的**当前内存状态**写回该预设。未展开时 `allStations` 是未加载的默认状态（全部 selected=false、sort=256），直接覆盖用户已保存的配置。**概率性**：展开过再收起时 `allStations` 仍持有已应用数据（写回幂等不丢），只有从未加载过的状态被清空
- **修复**：`doSaveAndDraw()` 移除 `localPresets[1]` 回退；`currentPresetRef` 与 `expandedPresetId` 均空时直接 return，不做任何操作
- **加固**：`saveCurrentPreset()` 不再回退 `getActivePreset()`，只允许保存当前展开的预设（所有调用点均已前置 `if currentPresetRef` 守卫），彻底封死"默认状态写回预设"路径
- **涉及**：`diagram_gui.lua:899-909`、`:868-870`

### 线路勾选状态"保存不上"（首次保存清空 lineData）
- **现象**：有用户反映勾选线路选择性绘制保存不上，下次打开又是全勾选；但另一些环境保存正常
- **根因**：`saveCurrentPreset()` 保存 `lineData` 时遍历 `displayedLines`——它是"当前选中车站相关的线路"子集，且**首次打开窗口时 `displayedLines = {}`**（`showDiagram` 初始化、展开预设也不刷新它）。展开预设后**第一次**点保存会把已保存的 `lineData` 写成空表 → 勾选状态丢失。非首次保存时 `displayedLines` 已由 `getRelevantLines` 填充所以正常（故复现不了）
- **修复**：
  1. `saveCurrentPreset()` 改从 `allLines` 保存线路勾选状态（完整集合，与应用侧 `applyPresetToStations` 同样遍历 allLines 一致）
  2. 展开预设时同步 `displayedLines = getRelevantLines(sel)` + `updateLineList()`，首次打开即可看到上次勾选的线路
  3. 线路 checkbox 勾选后立即 `saveCurrentPreset()` + `savePresetsToTimetableObject()`（内部置 `_G._diagramForceSync` 触发同步），避免直接退出游戏/关窗丢状态
- **涉及**：`diagram_gui.lua:883-896`、`:806-818`、`:992-998`

### 跨线车次在单线运行图上错误直连（方案A·折线断开）
- **现象**：1234线+5678线两条铁路线，中间有联络线。跨线车次 1→6→7→4 在 5678 图上正常绘制，但在 1234 图上直接从 1 连到 4，跨越 2、3 车站参考线（车次实际不经过 2、3）
- **根因**：`refreshDiagram()` 画线循环只处理 `yMap[st.uniqueKey]` 存在的停站，不在当前预设纵轴上的停站（6、7）被静默跳过，pts 数组从 1 站出发点直接连到 4 站到达点
- **方案A（采纳）**：遇到不在纵轴上的**车站**时**断开折线**，后续到发点成为独立折线。跨线车次在 1234 图上只显示 1、4 两个孤立到发点（带十字标记），不再直连。真实铁路运行图中跨线车在每条线图上只画线内区段
- **判定依据**：相邻两个停站都在图内才连线，中间有不在图内的停站就断。不会误伤"同线车次中间站未勾选"的情形（那种车次 1、4 之间没有别的停站，仍正常连线）
- **关键修正（路径点不断线）**：断开条件限定为 `not y and st.stopType == "station"`。TPF2 线路中"不停站经过"的中间站是**路径点**（waypoint），它们不在纵轴上但只是轨道经过点，**不得触发断开**——同线不停站车次（如只停1、5）应画斜线穿过2、3、4参考线。若对路径点也断开，会导致"1→5 段断、5→1 段连"的异常（5→1 是循环闭合画出来的所以看起来连）
- **二次修正（离轴路径点静默跳过防崩溃）**：最初实现 `if not y and st.stopType == "station" then 断开 else 处理停站 end`，**逻辑漏洞**——离轴路径点（`not y` 且 `stopType=="waypoint"`）会落入 else 分支，用 `y=nil` 插入折线点，绘制时 `api.type.Vec2f.new(x, nil)` 抛 **Lua 异常**。现象链：点保存（`doSaveAndDraw` 有 pcall）→ 错误被捕获只打日志、折线全不画；再点线路勾选（`refreshDiagram()` 无 pcall）→ 同错误直接**游戏崩溃**。改为三层分支：`not y` 时车站断开 / 路径点静默跳过；`y` 存在才正常处理
- **防御加固**：`refreshDiagram()` 全部 5 个调用点（勾选 checkbox、点击线路名、保存、刷新、改色）统一包 `pcall`
- **循环闭合调整**：`pts` 单数组 → `polylines` 折线数组，循环闭合（`nextG = g % maxG + 1`）改为追加到最后一折线；闭合条件保持原语义 `firstY 非 nil 且 firstY ~= lastY`
- **涉及**：`diagram_gui.lua:649-750`

### 运行图站名/时间标签跨刷新周期组件名重复
- **现象**：运行图纵轴 4 个车站（1,2,3,4），但站名标签只显示 1、4，中间 2、3 不显示
- **根因**：站名/时间标签组件名 `"stCont_" .. sv .. "_" .. tag` / `"tmCont_" .. m .. "_" .. tag` 中 `tag` 是 `refreshDiagram()` 内局部变量，**每次刷新从 0 重新计数**。跨刷新周期组件名重复，违反 AGENTS.md 已记录的经验"组件名必须跨刷新周期唯一"（removeItem 移除的组件名可能未被引擎即时释放，同名重建会冲突，addItem 静默失败）
- **修复**：新增 `nextLabelName()` 从 `_G._diagramLabelCounter` 取单调递增序号，存 `_G` 而非 `local`（模块级 local 不抗 Lua VM 重载，_G 可跨模块重载存活，同项目 `_G._diagramForceSync` / `_G._gwNames` 先例）
- **涉及**：`diagram_gui.lua:24-33`（nextLabelName）、`:546,587`（标签创建）

### 站名标签中间站丢失（真正的根因：Rect.new 浮点参数）
- **现象**：站名标签只显示首尾站（sort 最大、最小的组），中间站标签不显示；时间标签正常
- **根因**（日志实锤）：诊断日志显示 sort 2、3 组**确实是车站**（`station:2-2[55785]`），标签逻辑也找到了名字（`label=2-2`），但 `sll:addItem(cont, rect)` 抛 `sol: no matching function call takes this number of arguments`。原因是 `stationToY` 用浮点除法，中间站的 `y` 是浮点数（480.0、240.0），`rectY = y - labelH/2` 也是浮点 → `api.gui.util.Rect.new(0, 浮点, ...)` 的 Sol2 绑定找不到匹配重载 → addItem 失败。**首尾站恰好因 clamp 边界返回整数**（sort=4 → `max(0, -9)=0`；sort=1 → `min(702, 711)=702`）所以成功。时间标签正常是因为它用了 `math.floor`，站名标签没用
- **修复**：站名标签 `rectY` 加 `math.floor`（`:577`），与时间标签（`:616-617`）保持一致
- **经验**：所有传给 `api.gui.util.Rect.new` 的坐标必须 `math.floor` 取整，浮点参数会导致 Sol2 "no matching function call" 静默失败（被外围 pcall 吞掉 → 表现为"标签偶尔只显示部分"）

### doSaveAndDraw 调用 rebuildPresetList 前向引用 nil
- **现象**：日志 `Save error: ... attempt to call global 'rebuildPresetList' (a nil value)`——保存按钮因 pcall 捕获只打日志，预设列表未刷新
- **根因**：`doSaveAndDraw`（:892）定义在 `rebuildPresetList`（:943）**之前**，Lua 的 `local function` 只在声明之后可见，运行时 `rebuildPresetList` 解析为全局 nil
- **修复**：文件顶部加 `local rebuildPresetList` 前向声明（:24），函数体改为 `rebuildPresetList = function() ... end`
- **涉及**：`diagram_gui.lua:24,943`

### 车站列表只保留火车站和路径点（过滤公交站）
- **需求**：用户反馈运行图的车站列表出现公交站站名，希望只保留火车站和路径点
- **根因**：车站列表来源有两个，均混入公交站：
  1. `getAllRailLines()` 名字带 Rail 但**实际不过滤**——返回所有线路（含公交线），公交线的停站进入列表
  2. `getAllStationEntities()` 返回地图**所有**站（含公交站、货运站）用于补充"无线路经过的车站"
- **方案（用户选定）**：地图所有火车站 + 路径点，过滤公交站
- **API 研究结论**：
  - `enum.Carrier`: ROAD=0, RAIL=1, TRAM=2（判断线路车辆）
  - `enum.TransportMode`: PERSON=0 CARGO=1 CAR=2 BUS=3 TRUCK=4 TRAM=5 ELECTRIC_TRAM=6 TRAIN=7 ELECTRIC_TRAIN=8 AIRCRAFT=9 SHIP=10 SMALL_AIRCRAFT=11 SMALL_SHIP=12（判断线路可用的运输模式，**不依赖线路已有车辆**）
  - **关键**：`Line` 组件（type 63）有 `vehicleInfo LineVehicleInfo` 字段，其 `transportModes {int,...}` 是"线路可用的运输模式"——新建空线路也能判断类型，比原版 `lineHasType`（依赖 `getLineVehicles` 的 carrier）更可靠
  - `LineVehicleInfo` 的 `transportModes` 可能是数组或位掩码，代码两种都兼容（位掩码用 `math.floor(modes / 2^w) % 2` 判断，兼容 Lua 5.1/5.2）
  - `ComponentType`: BASE_EDGE=5, BASE_EDGE_STREET=6, BASE_EDGE_TRACK=7（边有 BASE_EDGE_TRACK 组件 = 铁轨）
  - `stationSystem.getStation2edgesMap()` 返回 `{[stationEntity]={{EdgeId,int},...}}`，EdgeId 有 `.edgeId`（TRANSPORT_NETWORK 实体）和 `.index`（edges 数组下标）
  - `TRANSPORT_NETWORK` 组件的 `edges {Edge,...}` 数组，`edges[index]` 是 TransportEdge
  - `lineSystem.getLineStops(stationGroupEntity)` 返回 `{{lineEntity,int},...}`（停靠该站组的线路）
- **实现**（`timetable_helper.lua`）：
  - `lineHasType` 增强：优先读 `lineObject.vehicleInfo.transportModes` 判断（不依赖车辆），回退到车辆 carrier
  - `getAllRailLines` **不过滤**，返回所有线路（时刻表需要全部线路）；运行图的铁路筛选在 `diagram_gui.lua:getAllTimetableData` 侧自行做
  - 新增 `isRailStation(stationEntity)`：优先 `getStation2edgesMap` + TRANSPORT_NETWORK 边 + `BASE_EDGE_TRACK` 判断，回退 `getLineStops` 反向判断（有明确非铁路线且无铁路线 → 非铁路站；无法判断保守保留）
  - `getAllStationEntities` 过滤非铁路站（`isRailStation`）
- **关键修正（正向过滤误删线路）**：最初 `getAllRailLines` 用 `lineHasType(l,"RAIL")` **正向过滤**——若 `transportModes` 字段读取失败回退到车辆判断，**空线路（无车辆）被误判为非铁路而过滤**，导致多条真实铁路线及其**路径点**一起从车次列表/车站列表消失（日志 `allStations=10` 从 22 跌、`lineList names` 只剩1条）。改为反向过滤后空线路保留，路径点恢复
- **崩溃修复（userdata 字段访问未 pcall 保护）**：`lineHasType` 直接访问 `lineObject.vehicleInfo.transportModes`——lineObject 是 userdata，若无 `vehicleInfo` 字段会抛 Sol2 错误（错误值为**函数对象**如 `function: 0x...`），且 `getAllStationEntities` 的 `stationSystem.forEach` 内部崩溃会导致遍历中断、后续站全部丢失（表现为"车站3被过滤"，实际是 forEach 崩在第4个站）。修复：字段读取链整个包进 pcall；`isRailStation` 主链路/回退遍历包 pcall；`getAllStationEntities` 单站 `isRailStation` 包 pcall，失败保守保留
- **涉及**：`timetable_helper.lua`（lineHasType、getAllRailLines、isRailStation、getAllStationEntities）
- **风险**：`getStation2edgesMap` 边→base edge 的字段名（`edge.edge/entity/baseEdge`）未在文档明确，已用 pcall 保护 + 回退逻辑，并加 `filteredStation` 诊断日志；`transportModes` 字段路径 `lineObject.vehicleInfo.transportModes` 同样待日志验证
- **迭代进度（2026-07-31）**：
  - 修复崩溃后 `filteredBus=0`（公交站未过滤）——怀疑 `getStation2edgesMap` key 不匹配 stationEntity（日志 `hasEdgesEntry=false`）导致主链路失效，回退 `getLineStops` 返回空导致全部保守保留
  - 已改进：`isRailStation` 主链路同时尝试 `edges[stationEntity]` 和 `edges[sgEntity]` 两种 key；新增 `railStationGroupCache`（遍历明确铁路线停站收集站组集合，作为最可靠判定）；回退改用 `getLineStopsForStation(stationEntity)` 优先
  - **关键发现（日志实锤）**：`transportModes` 实际是 **userdata**（非数组/数字）。**注意**：对 userdata 做 `#`/索引操作有 C++ 异常风险（pcall 可能无法捕获），最终方案是**跳过 transportModes 的 userdata 处理，直接回退到车辆 carrier 判断**（见"时刻表/运行图筛选分离"条目）。公交1线能被 `lineHasType(公交1,"ROAD")` 识别（`line filtered (non-rail)`），但公交站的 `isRailStation` 回退 `getLineStops` 解析不出线路实体（`lineStops=()` 表示 entry[1] 取不到 line）导致走 `unknown -> RAIL(keep)` 漏网
  - **解决**：新增 `nonRailStationGroupCache`（遍历明确非铁路线停站收集站组集合），`isRailStation` 在铁路站组判定后、铁轨边判断前，若站组只在非铁路线停站中 → 直接判 NONRAIL 过滤。绕开 `getLineStops` 结构不确定问题
  - **验证通过（日志实锤）**：公交站全部过滤成功（`filteredBus=6`，过滤了 Fasil Road / Ma Tau Chung Raoad / Granville Road 等），纯铁路站3保留（`lineStops=0 -> RAIL(keep)`），车站列表 22→14。`getLineStops` 返回 `entry=number`（直接是线路实体，非 `{line,int}`），line 提取逻辑已兼容


### 时刻表时间输入丢值（13:30 变 00:30）
- **现象**：用户输入时间（如 13:30）后点其它地方，概率出现未保存/值被重置（00:30）
- **根因**：`timetable_gui.lua` 中所有 `DoubleSpinBox:onChange` 回调里都调用了 `timetableGUI.initStationTable()` + `fillStationTable()` 重建车站表。`onChange` 在输入过程中**逐位触发**（输入"1"→"3"→"0"→"3"各触发一次），每次触发都重建整个车站表 → 打断 SpinBox 输入焦点/值，导致概率性丢值
- **修复**：`onChange` 里移除 `initStationTable()`/`fillStationTable()` 重建调用，只保留数据写入（`updateArrDep`/`updateDebounce`/`updateWaypointPassingTimeEntry`）+ `timetableChanged = true`。车站表摘要改在切换约束类型/添加删除时刷新（这些操作本身就该重建）
- **涉及**：`timetable_gui.lua`（makeArrDepWindow 4 处 SpinBox、makeDebounceWindow 2 处、makePassingWindow 2 处）
- **经验**：`DoubleSpinBox:onChange` 逐位触发，回调里绝不能做 UI 重建（打断输入）；数据保存和 UI 刷新分离

### getOrderOfArray 稀疏哈希表排序崩溃
- **现象**：时刻表弹窗打不开，`timetable_helper.lua:833: attempt to index local 'a' (a nil value)`
- **根因**：`getOrderOfArray` 用 `pairs(arr)` 构建 `toSort[k] = {key=k, value=v}`，k 不连续（`getAllRailLines` 过滤后 key 更稀疏）。`table.sort` 要求连续数组，遇到 nil 元素比较函数里 `a.value` 崩溃。此前正常是因为未过滤时 key 缺口小/碰巧连续
- **修复**：`toSort` 改为连续数组（`toSort[#toSort+1] = {key=k, value=v}`），比较函数加 nil 保护 + `tostring`，返回语义不变（`res[k-1] = v.key - 1`）
- **涉及**：`timetable_helper.lua:getOrderOfArray`

### 时刻表/运行图筛选分离（getAllRailLines 恢复不过滤）
- **用户需求**：时刻表展示**所有**线路（公交/铁路/汽车/电车都显示），只有运行图才筛选铁路线。两者筛选独立
- **根因**：之前为运行图过滤公交线，把 `getAllRailLines()` 也过滤了，但时刻表（`timetable_gui.lua:403,560,568`）也用该函数 → 时刻表里公交/汽车线路消失，用户点汽车筛选按钮报 Internal error
- **修复**：
  1. `getAllRailLines()` 恢复为**返回所有线路**（不过滤）——时刻表用
  2. 运行图 `getAllTimetableData` 里**自行反向过滤**（排除明确 ROAD/TRAM/WATER/AIR 的线，空线路保守保留）——只在运行图侧生效，用 `goto continueLine` 跳过非铁路线
- **补充（userdata 处理）**：`lineHasType` 对 `transportModes=userdata` 不再做 `#`/索引操作——对 userdata 的 `#` 可能触发 C++ 异常（pcall 无法捕获，导致点汽车筛选按钮 Internal error）。改为跳过 transportModes 判断，直接回退到车辆 carrier 判断（原版可靠方式）
- **涉及**：`timetable_helper.lua:getAllRailLines、lineHasType`、`diagram_gui.lua:getAllTimetableData`
- **经验**：共享工具函数被多个 UI 使用时要区分各自的数据需求，筛选应放在使用侧而非公共函数里；对 userdata 的 `#`/索引操作有 C++ 异常风险，pcall 不一定能捕获

### 时刻表窗口重开 FloatingLayout::RemoveItem assert 崩溃
- **现象**：时刻表窗口被运行图窗口顶掉后重开，`FloatingLayout.cpp:113: RemoveItem: Assertion 'it != m_vecItems.end()' failed` 崩溃
- **根因**：重开路径新建 `UIState.boxlayout2` 后，`initLineTable`/`initStationTable`/`initConstraintTable` 里 `UIState.boxlayout2:removeItem(menu.scrollArea/stationScrollArea/...)`——旧组件属于**旧布局**（可能已随窗口销毁），在新布局中 removeItem 找不到 → C++ assert。**pcall 无法捕获 C++ assert**（AGENTS.md 关键经验），必须阻止代码路径被执行
- **修复**：
  1. `showLineMenu` 重开路径先**重置所有旧组件引用为 nil**（scrollArea/lineHeader/stationScrollArea/stationTable/scrollAreaConstraint/constraintTable），再新建布局 → init 系列走 `else` 分支（直接新建，不 removeItem）
  2. 重开路径补齐 `initStationTable()`/`initConstraintTable()`（原代码只调了 initLineTable）
  3. init 系列保留 removeItem（正常运行中重复调用时避免重复 addItem），依赖重开路径重置引用
- **涉及**：`timetable_gui.lua`（showLineMenu、initLineTable、initStationTable、initConstraintTable）
- **经验**：C++ assert 无法被 pcall 捕获，防止崩溃唯一方法是**不让触发 assert 的代码路径执行**（重置旧组件引用，使其不进入 removeItem 分支）

### 诊断日志清理
- 本轮调试加的临时诊断日志已清理：`lineHasType transportModes`、`getStation2edgesMap keys`、`isRailStation` 详细路径、`filteredStation` 逐条、`getAllStationsFlat selected`、`getYMap groups`、`stationLabel sort`
- 保留：`getAllStationEntities stations=... filteredBus=...` 汇总行、`getAllRailLines` 预存日志、`getAllStops` 预存分类日志

### 清理日志时误加 local function 前缀导致加载崩溃
- **现象**：进存档崩溃 `error loading module 'celmi/timetables/timetable_helper' ... :215: '(' expected near ''`；同时时刻表弹窗打不开（require 失败链）
- **根因**：清理诊断日志时，把 `function timetableHelper.lineHasType(...)` 误改成 `local function timetableHelper.lineHasType(...)`——`local function` 后面只能跟局部变量名，不能跟带点的成员表达式（`timetableHelper.lineHasType`），触发语法错误 `'(' expected`
- **修复**：去掉误加的 `local` 前缀，恢复 `function timetableHelper.lineHasType(...)`
- **经验**：清理代码时逐文件跑语法检查；改模块成员函数时用 `function table.member()` 而非 `local function table.member()`

## 已完成功能
### 路径点检测（`timetable_helper.lua`）
- `getAllStops()` — 展平车站+路径点为顺序列表
- 路径点存储在 `Line.Stop.waypoints`（userdata 类型），用 `#` 取长度、数字索引取值
- 每个路径点 ID 格式 `"wp_K_I"`（K=停站索引，I=该站后第几个路径点）

### 数据存储（`timetable.lua`）
- `waypointTimes[wpKey]` — 通过时间数组
- `waypointNames[wpKey]` — 自定义名称
- `diagramConfig` — 运行时配置，不再用于持久化

### 时刻表 UI（`timetable_gui.lua`）
- 路径点显示与通过时间编辑
- 到发时间 / 防聚集条件编辑
- 添加了 `_G._diagramForceSync` 标志 + `guiUpdate` 同步钩子

### 运行图 UI（`diagram_gui.lua`）
- **预设系统**：第一级为"铁路线"配置列表，支持 + 添加 / 行末 X 删除（带确认弹窗）
- **车站/路径点排序**：展开预设后显示所有车站/路径点，含勾选框 + 排序输入框（1-256）
- **Y 轴合并**：相同排序数字的站/路径点合并到同一水平参考线
- **"保存"按钮**：保存预设 + 绘制运行图 + 显示相关线路
- **默认收起**：打开窗口时所有预设折叠，需手动展开
- **车次列表**：滚动条可滚动查看所有相关线路，每项固定高度确保显示完整

### 持久化方案（关键实现）
- 预设数据和线路颜色存储在 `timetableObject[hostLineId].dp` 中
- 通过 `_G._diagramForceSync` 标志在 `guiUpdate` 中触发 `sendScriptEvent("timetableUpdate")` 同步到引擎线程
- 引擎线程的 `update` 每帧确保所有线路条目有 `dp` 字段（防止被深拷贝丢弃）
- 存档时 `state.timetable` 包含了 `dp` 数据，读档时恢复

### 数据存储结构
```
timetableObject[hostLineId].dp = {
    presetList = {
        { id = "1", name = "京沪高铁",
          stationData = { [stableKey] = { selected = bool, sort = int }, ... },
          lineData = { [lineId] = bool, ... },
        },
    },
    activePresetId = "1",
    colorList = {
        { i = "35110", r = 1.0, g = 0.2, b = 0.2, a = 1.0 },
    },
}
```

stableKey 格式：车站 → `"s_实体ID"`，路径点 → `"wp_K_I_lineID"`（K=停站索引，I=路径点序号，lineID=线路实体ID）

## 待办
（暂无）

## 已完成功能（2026-07-29 本轮新增）

### 多套时刻表折线连接修复
- **需求**：一条线路往返多个周期，每个站配了多套到发时间（如3套=3个来回）。旧逻辑按数组索引 g=1,2,3 分组绘制，终点站第一套到达值（如59:00）是循环槽位，画出一条44.5分钟的漫长线段。
- **方案1·闭合段改连下一套**：`nextG = (g % maxG) + 1` → 第 g 套轨迹终点连接到第 g+1 套的到达时间。单套时 `(1%1)+1 = 1` 保持原有行为。
- **方案2·套间停靠线**：`g < maxG` 时追加 `nextG` 的出发点 → 相邻轨迹在终点站形成水平驻站线，最后一套不循环回第一套。
- **方案3·终点判定修正**：旧 `fIdx < #ld.stations` 假定最后一站总是终端回归，但线路可能只有4站（stn1→stn2→stn3→stn2），此时 stn2 返程被误当终点跳过出发。改为 `isTerminalReturn = (key == firstKey and fIdx == #ld.stations)`，只有真正同站回归才跳过出发。
- 涉及：`diagram_gui.lua:578-632`(refreshDiagram 绘制循环)

### 车次列表勾选控制 + 统一颜色按钮
- **勾选控制**：每条线路名前增加 checkbox，默认全勾选。取消勾选 → `refreshDiagram` 跳过该线不画。状态通过 `preset.lineData = { [lineId] = bool }` 持久化，存读均深拷贝。
- **统一颜色按钮**：去掉每条线路的独立颜色按钮，在"车次列表"标题旁增加统一点击 → 如果有选中（加粗）线路，弹颜色盘同时修改所有选中线路颜色，双写即时保存（`diagramConfig` + `timetableObject.dp.colorList` + `api.cmd.make.setColor` 同步游戏线路色）。无选中线路则无反应。
- **选中高亮**：点击线路名称选中后，名称显示为 `[线路名]` 方括号包裹。
- **涉及文件**：`diagram_gui.lua`
  - `getAllTimetableData()` — lineData 增加 `checked = true`
  - `refreshDiagram()` — 跳过 `ld.checked == false` 的线路
  - `updateLineList()` — checkbox + nameView + 彩色方块
  - `toggleLineSelection()` — 点击后更新 nameView 文本（方括号高亮）
  - `showDiagram()` — 标题栏统一颜色按钮
  - `saveCurrentPreset()` — 保存 `displayedLines` check 状态到 `preset.lineData`
  - `applyPresetToStations()` — 应用 `preset.lineData` 到 `allLines`
  - `loadPresetsFromTimetableObject()` / `savePresetsToTimetableObject()` — lineData 深拷贝读写

### 彩色线路方块（运行图 + 时刻表）
- **运行图**：每条线路名后用 `LineRenderView` + 堆叠水平线段渲染填充方块（14×14 容器内 10×10 方块，线宽2，间距2），颜色通过 `setColor(Vec4f)` 直接使用图表自定义 RGB，支持任意颜色。
- **时刻表**：同款 `LineRenderView` 方块（28×28 容器内 20×20 方块，线宽4，间距2），颜色通过 `getLineColourVec4(lineId)` 从引擎 COLOR 组件（`api.engine.getComponent(line, api.type.ComponentType.COLOR)` → `.color: Vec3f`）直接读取线路管理器的实际颜色，不依赖 CSS 预设色。
- **新增**：`timetable_helper.getLineColourVec4(line)` — 返回 `Vec4f` 供 `LineRenderView.setColor` 使用。
- 涉及：`timetable_gui.lua` 三处（`fillLineTable`、`fillStationTabLineTable`、`fillWaypointTabLineTable`），`diagram_gui.lua:updateLineList`

## 已修复的崩溃（历史）
- 涉及：`diagram_gui.lua:578-632`(refreshDiagram 绘制循环)

## 已修复（2026-07-29）

### 路径点实体级去重
- **问题**：同一路径点实体在多条线路中都出现时，运行图预设配置里会显示多个同名路径点
- **根因**：`getAllStops()` 用位置拼接 `"wp_K_I"` 作为 ID，`uniqueKey` 又拼入 `lineID`，导致同实体的路径点 key 不同，`getAllStationsFlat()` 的 `stableKey` 去重失效
- **修复**：
  1. `timetable_helper.lua`: 新增 `wpEntityIdCache`（userdata→counter 映射）用于去重，`getWpPersistentKey()`（`"gwpk_sgEntity_i_name"`）生成持久化全局名 key，确保跨存档跨线路名字一致；`id` 保持旧格式 `"wp_K_I"` 兼容已存时间数据
  2. `diagram_gui.lua`:
     - `stableKey()` 签名扩展为 `(stopType, id, uniqueKey, entityId)`，路径点用 `"wp_" .. entityId` 去重
     - `getAllStationsFlat()`: 传递 entityId，仅第一条计入列表
     - `getYMap()`: 路径点匹配改用 `st.entityId == s.entityId` 遍历所有线路映射
     - `getRelevantLines()`: 新增 `wpEntityIds` 集合，路径点按 entityId 匹配
     - `saveCurrentPreset()` / `applyPresetToStations()`: stableKey 调用补上 entityId
     - label dedup 的 stableKey 调用同步更新
- **影响**：旧 preset 中路径点的勾选/排序会重置，车站配置不受影响
- **涉及**：`timetable_helper.lua:1-15,392-445`；`diagram_gui.lua:276-278,299-323,329-370,396-437,756-788`

### 运行图站名/时间标签只渲染一个
- **问题**：左侧站名标签 + 底部时间刻度偶尔只显示第一个，其余不显示
- **根因**：`refreshDiagram()` 中所有标签组件共享同名（`"stCont"` / `"tmCont"`），TPF2 组件系统可能因重名忽略后续 `addItem`，被外围 `pcall` 静默吞掉
- **修复**：站名标签 → `"stCont_" .. idx`，时间标签 → `"tmCont_" .. m`，确保唯一
- **涉及**：`diagram_gui.lua:507,533`

### 时刻表窗口 X 按钮有时关不掉
- **根因**：`onClose` 只清理了 `menu.lineTableItems`，没有清除 `clearConstraintWindowLaterHACK`。用户编辑时间数据后立即关窗 → `onClose` 触发 → 下一帧 `guiUpdate` 执行残留 HACK → 重建 UI → 干扰关闭流程
- **修复**：`onClose` 中新增 `clearConstraintWindowLaterHACK = nil` + `timetableChanged = false`
- **重要**：不能设 `menu.window = nil`，时刻表窗口依赖 `menu.window ~= nil` 走 `setVisible(true, true)` 重开路径（不走 `Window.new()`），设 nil 会切断重开路径导致按钮卡住
- 涉及：`timetable_gui.lua:332-339`

### 时间数据改后关窗重开偶尔变回 0:00（u<unk>值 0 静默丢弃）
- **根因**：`updateArrDep` / `updateDebounce` / `updateWaypointPassingTimeEntry` 参数校验用 `if not (... and value) then return -1`。Lua 中 `0` 是 falsy，用户把分/秒设为 0 时校验失败，数据**静默丢弃未写入 `timetableObject`**。下次重建 UI 读回旧值
- **修复**：三处全部改为显式 `== nil` 比对：`if line == nil or station == nil or ... or value == nil then return -1 end`
- 涉及：`timetable.lua:170-171, 185-186, 243-244`

### `getConditions` 返回 -1 导致 `or {}` 回退失效
- **根因**：`getConditions` 失败返回 `-1`（数字），是 truthy，`diagram_gui.lua:274` 的 `getConditions(...) or {}` 退化为 `-1`，不是 `{}`
- **修复**：两个 `return -1` 改为 `return nil`；`waitingRequired` 中增加 `if not condition then return false end` nil 保护
- 涉及：`timetable.lua:122-131, 397-398`

### 运行图窗口强制带出/复位时刻表窗口
- **根因 1**：`showDiagram()` 创建窗口后无条件 `_G._timetableWindow:setVisible(true, true)`，即使时刻表本来关着
- **根因 2**：`setVisible(true, true)` 会重新计算默认位置，把已打开的时刻表窗口移回原位
- **修复**：
  1. 新增 `_G._timetableVisible` 标志（在 `showLineMenu` 两处路径和 `onClose` 中维护）
  2. `showDiagram()` 创建窗口前保存 `ttWasVisible = _G._timetableVisible`，只在 true 时恢复
  3. 恢复调用改为 `setVisible(true, false)` 避免位置重置
- 涉及：`timetable_gui.lua:282,327,338`；`diagram_gui.lua:1124-1129`

## 已修复（本轮 2026-07-27）

### 路径点 key 碰撞导致新路径点不显示
- **根因**：`uniqueKey` 对路径点只有 `"wp_K_I"`（不含 `lineID`），不同线路相同索引的路径点 key 碰撞。加上 `stableKey` 对路径点再加一层 `"wp_"` 前缀，实际 key 为 `"wp_wp_K_I"`（双前缀），与 AGENTS.md 记录的协议 `"wp_唯一标识"` 不一致
- `getAllTimetableData`：路径点 `uk` 统一加 `lineID` → `"wp_K_I_lineID"`
- `stableKey`：去掉冗余的 `"wp_"` 前缀，路径点直接返回 `uniqueKey`
- **影响**：旧 preset 中路径点的勾选/排序会重置（需重新勾选一次），车站配置完全不受影响
- 涉及：`diagram_gui.lua:207-209`, `:233-235`

### 无时刻表数据时运行图窗口打不开
- **根因**：`getAllTimetableData()` 只收集 `hasTimetable == true` 的线路，`showDiagram()` 在 `#lineDataList == 0` 时提前 return
- `getAllTimetableData`：移除 `if timetable.hasTimetable(lineID) then` 过滤，改为收集所有线路（无时刻表时 entry.times 为空）
- `showDiagram`：删除 `if #lineDataList == 0 then return end`
- **影响**：新图无时刻表数据也可以打开运行图窗口，正常管理预设，展开预设后车站列表为空
- 涉及：`diagram_gui.lua:189-227`, `:793`

## 已修复（2026-07-26）

### 排序号 DoubleSpinBox 崩溃
- **根因**：Lua 中 `0 or 1 = 0`（0 是真值），排序号 0 不触发 `or` 回退
- `applyPresetToStations` / `saveCurrentPreset` 中 `d.sort or 1` → 改为 `(type(d.sort) == "number" and d.sort > 0 and d.sort <= 256) and d.sort or 1`
- `rebuildPresetList` 中 `sp:setValue(st.sort, false)` → 加值范围校验 + `pcall` 包裹
- 涉及：`diagram_gui.lua:542-543`, `:556`, `:725-726`

### 双重存储 → 唯一数据源
- **根因**：`diagramConfig._dpPresetList` 和 `timetableObject[hostLineId].dp` 双副本，游戏深拷贝后两副本独立不同步，读档时 `diagramConfig._dpPresetList` 优先读取 → 读到旧数据
- `loadPresetsFromTimetableObject`：删除优先读 `cfg._dpPresetList` 的分支，统一从 `timetableObject[hostLineId].dp` 加载
- `savePresetsToTimetableObject`：删除写入 `cfg._dpPresetList` / `cfg._dpColorList` 的冗余副本代码
- 涉及：`diagram_gui.lua:91-114`, `:116-146`

### 深拷贝防引用串流（全线配置被覆盖）
- **根因**：`localPresets[i].stationData` 和 `dp.presetList[i].stationData` 共享同一 Lua 表引用。当 `guiUpdate → sendScriptEvent → handleEvent` 触发跨线程深拷贝时，共享引用被破坏，不同 preset 的拷贝可能指向相同深层对象，快速连续保存导致所有配置串成一份
- `savePresetsToTimetableObject`：写入 `dp.presetList` 时逐条深拷贝 `stationData`
- `loadPresetsFromTimetableObject`：读取 `dp.presetList` 时逐条深拷贝 `stationData`
- 存和取均做深拷贝，每个 preset 的 `stationData` 全程独立
- 涉及：`diagram_gui.lua:98-105`, `:135-143`

### 线路点击崩溃防御
- **根因**：运行图未成功渲染时 `displayedLines` 残留旧按钮引用，`updateLineList` 的 `setContent` 销毁旧按钮后引用悬空，`setEnabled` 调用触发 C++ 类型校验失败
- `toggleLineSelection`：`colorButton:setEnabled` 用 `pcall` 包裹
- `refreshDiagram`：新增 `menu.renderLayout` 为 nil 的提前返回
- 涉及：`diagram_gui.lua:496`, `:345`

## 已完成（本轮）
### 运行图标注系统
- **站名标签**（仅站名，过滤路径点，与参考线对齐）：`diagram_gui.lua:refreshDiagram`
  - 使用 `AbsoluteLayout` 做容器，每个站名包一层固定尺寸 Component→BoxLayout
  - 通过 `addItem(cont, Rect.new(x, y, w, h))` 按 `stationToY` 精确 Y 坐标放置
  - 逆序遍历 sorts（与参考线方向一致），每次 `deleteAll()` 后重建
- **时间刻度**（0-60分钟，每5分钟）：`diagram_gui.lua:refreshDiagram`
  - 同 AbsoluteLayout + 固定 Component 包装方案
  - 通过 `invokeLater` 延迟取 `ra:getContentRect()` 和 `tlc:getContentRect()` 获取真实屏幕坐标
  - X 偏移 = `raRect.x - tlcRect.x`，分布宽度 = `dw`（与网格线一致），Y = `raRect.y + raRect.h - tlcRect.y + 14`
  - 每次 `deleteAll()` 重建

### API 发现
- `FloatingLayout.addItem(x, y)` 参数是**对齐值**（0/0.5/1），不是坐标
- `AbsoluteLayout.new()` 无参数可用（文档写 `new(orientation)` 但传参导致崩溃）
- `AbsoluteLayout.addItem(comp, Rect)` 签名匹配 C++ `addItem(ILayoutItem*, CRect)`
- `AbsoluteLayout.deleteAll()`、`setPosition(idx, x, y)` 均可正常使用
- `removeItem` 属于 `layout.ILayout` 基类，所有布局均可用
- `getContentRect()` 在 `invokeLater` 后才能拿到非零值（布局完成后）

### 布局修正
- 窗口标题栏占 ~30px，引入 `TITLE_BAR_H=30`，所有高度计算 `WINDOW_HEIGHT - TITLE_BAR_H - TIME_LABEL_HEIGHT`
- 时间标签栏 `tlc` 宽度设为 `da` 同宽（920px），标签 X 用 `offsetX` 对齐渲染区

### 持久化修复
- 并存 `diagramConfig._dpPresetList/_dpActivePresetId/_dpColorList`，解决脚本线程和 game_script 线程 `timetableObject` 不同实例导致的存档丢失
- `loadPresetsFromTimetableObject` 优先从 `diagramConfig` 读取

## 已修复（本轮 2026-07-28）

### 跨周期运行图绘制（核心重构）
- **需求**：列车往返超过60分钟周期时，运行图正确显示跨边界折线（标准铁路运行图样式）
- **根因**：旧代码按 X 坐标排序所有点后连线，跨边界点被错误排序，57→5 分行程段丢失；同站内 arr>dep 的跨周期停站产生反向水平线
- **解决方案**：
  1. **时间递推展开**：按 `getAllStops()` 路线顺序遍历，维护累计 `timeOffset`。检测 `(timeOffset + arr) < prevDep` 时 +3600 跨周期
  2. **站内跨周期**：`uwDep < uwArr` 时自动 +3600（处理 45分到/0分发 场景）
  3. **跨边界线段劈开**：`drawWrappedSegment(lv, t1, y1, t2, y2, dw)` 按 `floor(t/3600)` 检测周期跨越，Y 按时间比例线性插值分段绘制
  4. **边界 X 坐标修正**：用 `s - c*3600` 替代 `s % 3600`，确保 60:00（3600s）正确映射到右边界 X=dw，而非 0
  5. **首尾站处理**：fIdx=1 不画 arrival（只画出发圆点），fIdx=N 不画 departure（只画到达圆点）
  6. **循环闭合**：首尾不同 Y 水平时加 cyclic wrap（只补 arrival 不补 departure），同 Y 时跳过避免水平拖尾线
  7. **移除排序依赖**：不再 `table.sort(pts, ...)`，改为按 `ipairs(ld.stations)` 路线顺序遍历
- **涉及**：`diagram_gui.lua` `refreshDiagram()` 画线核心逻辑 (~100行重写)

### 颜色双写持久化
- **根因**：改颜色只写 `diagramConfig.lineColors`，不写 `timetableObject.dp.colorList`。`diagramConfig` 是模块级 `local`，Lua VM 重载模块时丢失 → 刷新/重开窗口颜色变回旧值
- **解决方案**：
  - 颜色选择器 `onColorChanged`：同时写 `diagramConfig.lineColors` + `timetableObject.dp.colorList` + 触发 `_diagramForceSync`
  - `doRefreshData()` 和重开路径：先从 `timetableObject.dp.colorList` 复载到 `diagramConfig`，再 `getAllTimetableData`
- **涉及**：`diagram_gui.lua:354-371`（双写）、`:901-922`（doRefreshData）、`:969-981`（重开路径）

### 颜色选择崩溃修复
- **根因**：`timetable_helper.lua:getLineColour()` 无 pcall 保护，已删除线路调用 `getComponent` 触发 "Invalid entity" 崩溃
- **修复**：用 `pcall(function() return api.engine.getComponent(...) end)` 包裹
- **涉及**：`timetable_helper.lua:191-200`

### 刷新按钮
- **需求**：用户改完时间数据后想实时看运行图，不必关窗口/点保存
- **新增** `doRefreshData()`：重取 `getAllTimetableData()` + 重载颜色 + 重绘运行图，不修改预设
- **UI**：刷新按钮放在保存按钮右侧，共用一行 `BoxLayout("HORIZONTAL")`
- **翻译**：`strings.lua` 新增 `diagram_refresh_i18n`（7 语言）
- **涉及**：`diagram_gui.lua:901-922`、`:1002-1008`

### 时刻表与运行图窗口共存
- **根因**：先开时刻表窗口再开运行图窗口 → `Window.new()` 创建新窗口时 TPF2 引擎把已有窗口顶掉
- **解决方案**：
  1. `timetable_gui.lua` 创建时刻表窗口后保存到 `_G._timetableWindow`
  2. `diagram_gui.lua:showDiagram()` 首次创建窗口后 `invokeLater` 调用 `_G._timetableWindow:setVisible(true, true)` 恢复时刻表窗口
  3. 重开时不再 `close()` 重建，改为 `setVisible(true, true)` + 刷新数据
- **涉及**：`timetable_gui.lua:324-325`、`diagram_gui.lua:969-981,1108-1112`

### 预设管理修复
- **删除预设后复活**：删除只改 `localPresets` 未持久化 → 加 `savePresetsToTimetableObject()` 即时落盘
- **重开时预设被覆盖**：重开路径调了 `loadPresetsFromTimetableObject()` → 把内存中已删/已改预设从旧存档读回 → 移除该调用，只复载颜色
- **未展开但有车次列表**：窗口重开时 `getActivePresetId()` → `applyPresetToStations()` 偷偷应用了上次的预设 → 移除自动应用逻辑
- **涉及**：`diagram_gui.lua:828`（删除时保存）、`:969-981`（重开不载预设）、`:963-964`（移除自动应用）

### 车站 Tab 路径点显示
- **需求**：时刻表窗口车站 Tab 中同时显示车站和路径点，点击路径点查看通过时间
- **新增** `timetable.getAllWaypointData()`：遍历所有线路的 `waypointTimes`，按 `gwKey` 分组
- **UI**：`fillStationTabStationTable` 合并车站+路径点（路径点前缀 `▶`），字母排序
- **新增** `fillWaypointTabLineTable(gwKey)`：显示经过该路径点的线路及通过时间
- **涉及**：`timetable.lua:511-537`、`timetable_gui.lua:96-205`

### 路径点名粘贴崩溃修复
- **场景**：用户在游戏外输入名称 → Ctrl+C → 游戏内 Ctrl+V 粘贴，游戏崩溃
- **崩溃链**：
  1. 粘贴触发 `TextInputField.onChange` → 写入 `timetableChanged = true`
  2. 粘贴可能触发短暂失焦 → `onFocusLost` 设置 `clearConstraintWindowLaterHACK`
  3. 下一帧 `guiUpdate` 执行 HACK → 调用 `makePassingWindow()` 重建 UI → `fillStationTable()` → `getAllStops(lineID)` 
  4. 在重建过程中 `lineID` 对应的线路实体可能已被删除 → `api.engine.getComponent()` 无 pcall 保护 → Sol2 "Invalid entity" 崩溃
- **修复**：
  1. `nameInput:onChange` 回调体加 `pcall` 包裹（`timetable_gui.lua:956-964`）
  2. `onFocusLost` 移除 `if clearConstraintWindowLaterHACK then return end` 竞态检查，允许覆盖旧 HACK（`:965-974`）
  3. `getAllStops()` 的 `api.engine.getComponent(line, ...)` 加 `pcall` 包裹，line 被删除时安全返回 `{}`（`timetable_helper.lua:314-317`）
- **涉及**：`timetable_gui.lua:956-974`、`timetable_helper.lua:314-317`

### 运行图站名渲染崩溃修复
- **场景**：在运行图窗口点击车次列表中某条线路 → `toggleLineSelection` → `refreshDiagram()` → 站名标签 `AbsoluteLayout` 重建过程中崩溃
- **根因**：`refreshDiagram()` 执行 `sll:deleteAll()` 清空布局，同时在 line 496 注册了 `invokeLater` 回调延迟操作 `menu.timeLabels.component`。若快速连续点击多条线路，旧 `invokeLater` 回调在布局已被清空后触发，`getContentRect()` 返回脏数据，传入 `Rect.new()` 导致 Sol2 类型异常
- **修复**：
  1. 站名标签整段（line 459-493）加 `pcall` 包裹
  2. `invokeLater` 回调体加 `pcall` 包裹 + 注册前检查 `menu.stationLabels.component` 有效性
- **涉及**：`diagram_gui.lua:459-532`

### 全量 pcall 防御强化
- **背景**：此前多次崩溃均因 `api.engine.getComponent()` 无 pcall 保护。`timetable_helper.lua` 中有 20 处该调用，仅 5 处于此前有 pcall
- **修复**：剩余 15 处全部加 `pcall` 包裹：
  - GUI 线程函数：`getTrainLocations`、`getLegTimes`、`getStation`、`getAllRailLines`、`getAllStations`、`getStationID`、`getTime`、`getAllStops`（waypoint name lookup）
  - 引擎线程函数：`getCurrentStation`、`getCurrentLine`、`isInStation`、`getPreviousDepartureTime`（2 处）、`getTimeUntilDeparture`、`lineHasType`
- **涉及**：`timetable_helper.lua`（全文件 20 处 `getComponent` 全部 pcall 化）

## 关键经验教训

### `_()` 翻译函数的使用规范
1. **只能在模块加载时调用**（表构造器中），运行时用局部变量
2. **禁止在任何调用 `_()` 的函数内使用 `_` 做 throwaway 循环变量**（`for _, x in`）
3. 引擎线程和 GUI 线程的 `_()` 上下文不同，加载时捕获最安全
4. **strings.lua 只在游戏启动时加载**，热重载模块不会更新翻译 → 新增 i18n key 需完全重启游戏

### UI 组件创建时机
1. `TextInputField` 在 `showDiagram()` 同步流程中不可用，需通过 `invokeLater` 延迟到下一帧
2. `TextInputField.new("")` 必须传参，无参会触发 Sol2 绑定错误
3. `setContent` 替换布局内容会同步影响 UI 树，需注意执行顺序

### 数据持久化
1. `pairs` 遍历顺序不确定，涉及 key 选择必须显式排序
2. 跨线程数据同步只有 `timetableObject`（通过 `timetableUpdate` 事件），`diagramConfig` 不同步
3. 垃圾数据会跨存档累积，需在保存时主动清理
4. **双写原则**：关键数据（颜色、名称）应同时写入 `diagramConfig` + `timetableObject`，前者供运行时快速读取，后者抗模块重载和跨线程同步

### Entity 在 Sol2 中的类型坑
1. **Entity 未必是数字**：`v.stationGroup` 返回数字，但 `v.waypoints[i]` 返回 userdata。`tonumber(userdata)` = `nil`，`tostring(userdata)` 含内存地址每次变化
2. **用 entity 做 key 不可靠**：应使用程序可计算的稳定标识符（如 `stationGroup + waypointIndex`）
3. **模块级 `local` 变量不抗重置**：Lua VM 可能每帧重载模块，导致 `local diagramConfig = {}` 重新执行 → 数据丢失。全局变量 `_G.xxx` 可跨模块重载存活

### 跨周期时间计算
1. **比较时要用提议值而非 raw 值**：`(timeOffset + arr) < prevDep`，不是 `arr < prevDep`。后者在已跨周期后仍会错误触发 +3600
2. **模块运算用减法不用取模**：`(t - c*3600) / 3600` 正确映射边值，`(t % 3600) / 3600` 在 60:00 处得到 0 而非 1.0
3. **站内跨周期检测**：`uwDep < uwArr` 用 `<` 而非 `<=`，避免路径点（arr==dep）误触发

### TPF2 窗口生命周期
1. **`Window.new()` 会销毁已有窗口**：引擎只允许一个 Window 实例存在，创建新窗口会强制销毁旧的
2. **`addHideOnCloseHandler()` 让窗口隐藏而非销毁**：用户点 X 只是隐藏，C++ 对象和所有子组件仍在引擎中存活
3. **`onClose` 在隐藏和销毁时都会触发**：无法在回调中区分是用户关闭还是引擎强制销毁
4. **永远不要给布局设全局 ID 来跨窗口复用**：隐藏窗口的旧布局在引擎中存活，`getById` 会拿到旧引用 → 往旧布局加新组件 → `Window.new()` 销毁旧窗口时连带销毁旧布局 → 新窗口引用已销毁布局 → 崩溃
5. **C++ `assert()` 无法被 Lua `pcall` 捕获**：`assert` 直接 `abort()` 进程，不抛 C++ 异常 → Sol2 无法转换为 Lua error → pcall 形同虚设。防止崩溃的唯一方法是不让可能触发 assert 的代码路径被执行

### AbsoluteLayout 与布局替换
1. **`setLayout()` 只能调用一次**：`CComponent::SetLayout` 有 `assert(!m_layout)` 保护，组件一旦绑定布局就永久不变。想刷新内容只能操作现有布局的 items（`removeItem`/`addItem`），不能整体替换布局对象
2. **`deleteAll()` 不可靠**：`AbsoluteLayout:deleteAll()` 可能不完全清除布局内部状态或组件名注册，导致后续 `addItem` 部分失败。优先用**逐项 `removeItem()`** 清除旧组件
3. **组件名必须跨刷新周期唯一**：`removeItem` 移除的组件名可能未被引擎即时释放，下次创建同名组件会有冲突。附加递增计数器（如 `"stCont_3_1"`, `"stCont_3_2"`）确保永远不重名
4. **布局循环不要包在最外层 `pcall` 中**：一旦某个 item 创建失败，外层 `pcall` 会终止全部后续 item 的渲染。改为每个 item 独立 `pcall`，一个失败不影响其余

## 已修复（2026-07-29 本轮）

### 时刻表/运行图窗口被顶掉后打不开（MemoryManager assertion 崩溃）
- **崩溃信息**：`UI::MemoryManager::Remove<UI::ILayout>: Assertion 'it != m_data.end() && "Item is still owned by UI code."' failed.`
- **根因链**：
  1. `showDiagram()` 调用 `Window.new()` → 引擎销毁已有时刻表窗口 → 时刻表 `onClose` 触发但 `menu.window` 保持非 nil
  2. 时刻表窗口被销毁时其内部布局（`timetable.floatingLayout`）也被引擎清理
  3. `invokeLater` 尝试 `_G._timetableWindow:setVisible(true, false)` 恢复窗口（半恢复/无效）
  4. 用户再次点击时刻表按钮 → `showLineMenu()` 检测 `menu.window ~= nil` 走重开路径
  5. `initLineTable()` 调用 `UIState.boxlayout2:removeItem(menu.scrollArea)` → 旧组件已不在新布局中 → `MemoryManager::Remove` 找不到 item → assertion 崩溃
- **修复**（4 处）：
  1. `timetable_gui.lua:showLineMenu()` — 重开路径加 `pcall`，重开前刷新 `UIState.boxlayout2` 引用。失败则清 `menu.window = nil` 走全新创建流程
  2. `timetable_gui.lua:initLineTable/initStationTable/initConstraintTable` — 所有 `getScrollOffset()` 和 `removeItem()` 调用包裹 `pcall`
  3. `diagram_gui.lua:showDiagram()` — 重开路径整段加 `pcall`，失败则清理状态走新建
  4. `diagram_gui.lua:invokeLater` 恢复时刻表窗口 — `_G._timetableWindow:setVisible` 加 `pcall` 包裹
- **涉及**：`timetable_gui.lua:222-310`、`diagram_gui.lua:1036-1073,1262-1268`

### 关键发现：C++ assert 无法被 Lua pcall 捕获
- **现象**：`UI::MemoryManager::Remove` 的 C++ `assert()` 直接调用 `abort()`，不抛 C++ 异常。Lua 的 `pcall` 依赖于 C++ 异常被 Sol2 转换为 Lua error，因此 **pcall 捕获不到 C++ assert 崩溃**。
- **教训**：pcall 只能防御 Lua 层错误和部分 Sol2 转换的 C++ 异常，对引擎内部的 assert 崩溃无能为力。防止 crash 的唯一方法是**不让引发 assert 的代码路径被执行到**。
- **对策**：`onClose` 中彻底 nil 掉所有对已销毁 UI 组件的引用（`menu.scrollArea = nil` 等），确保后续重开时不会有任何代码尝试操作旧组件。

### 全量 pcall 防御强化（2026-07-29）
- **背景**：此前多次崩溃均因缺少 pcall 保护导致。经过全面审计后，对所有未保护的 crash-prone API 调用批量加 pcall。
- `timetable_helper.lua`：
  - `startVehicle`/`stopVehicle` 中 `api.cmd.sendCommand`（3 处）→ pcall
  - `getFrequency` 中 `game.interface.getEntity`（1 处）→ pcall
  - `getTrainLocations`/`getVehiclesOnLine`/`lineHasType` 中 `getLineVehicles`（3 处）→ pcall
- `timetable_gui.lua`：
  - `initStationTab`：修复了错误的 nil 检查（检查了 `menu.stationTabScrollArea` 却 remove 了 `menu.scrollArea`），改为分别检查正确对象 + pcall；`addItem` 加 `UIState.floatingLayoutStationTab` nil 检查
  - `showLineMenu` 创建路径：`getById` 返回 nil 时不再调用 `setGravity`
  - `showLineMenu` 创建路径：`Window.new` 加 pcall 保护
  - 6 个线路过滤 `onToggle` 回调（18 处 `setVisible`）：整段回调体包裹 pcall
  - 3 处 `invokeLater` 中的 `setScrollOffset`：包裹 pcall
  - `guiUpdate` 中 `sendScriptEvent`：包裹 pcall
  - `gameInfo` 布局从 `getById("gameInfo"):getLayout()` 改为先 nil-check `getById` 结果
- `diagram_gui.lua`（scripts）：
  - `refreshDiagram` 中 `menu.renderLayout:removeItem(v)` → pcall + nil check
  - 3 处 `Window.new`（创建颜色选择器 ×2 + 确认弹窗 ×1）→ pcall
  - `showDiagram` 创建路径 `Window.new` → pcall
  - `updateStationVisibility` 中 `rd.comp:setVisible` → pcall
  - `rebuildPresetList` 中 `menu.presetScrollArea:invokeLater` 回调体 → pcall
  - `refreshDiagram` 中 nil check：修正为检查 `menu.timeLabels.component`（之前误检查了 `menu.stationLabels.component`）
- `diagram_gui.lua`（config）：`Window.new` → pcall

### 布局 ID 复用导致关闭后再打开崩溃（本轮 2026-07-29）
- **现象**：时刻表第一次能打开，关闭后再打开 → `MemoryManager::Remove<ILayout>` assertion 崩溃
- **根因链**：
  1. 首次打开时创建 `FloatingLayout` 并 `setId("timetable.floatingLayout")`，添加到窗口
  2. 关闭时 `addHideOnCloseHandler` 导致窗口**仅隐藏不销毁**，旧布局仍在引擎中存活
  3. 再次打开时 `getById('timetable.floatingLayout')` 拿到**旧布局**引用
  4. `initLineTable` 等函数把新创建的组件**添加到了旧布局上**
  5. `Window.new()` 创建新窗口时引擎先销毁旧隐藏窗口 → 旧布局被销毁 → 新窗口的组件树引用已销毁的布局 → crash
- **修复**：移除布局的全局 `setId`/`getById` 复用机制，`showLineMenu()` 每次打开都 `FloatingLayout.new()` 全新创建，存储在 `UIState.boxlayout2` / `UIState.floatingLayoutStationTab` 中。新旧布局完全隔离，互不影响。
- **涉及**：`timetable_gui.lua:301-332`

## 已修复（2026-07-30 本轮#2）

### 预设列表只显示 2 个车站（其余 5 个消失）
- **现象**：展开预设后，18 条条目中只看到 2 条，其余全部不显示
- **根因**：`rebuildPresetList()` 为所有 5 个预设都创建了全部 18 条车站行（90 行），通过 `setVisible(false)` 隐藏非展开预设的行。TPF2 的 BoxLayout 对不可见行仍分配布局空间，展开预设的车站行被推到极远处（内容总高远超 270px 的 scroll 区域）
- **修复**：
  1. 车站行创建包裹在 `if isExpanded then` 内，折叠的预设跳过创建
  2. 折叠操作从 `updateStationVisibility()` 改为 `rebuildPresetList()` 彻底移除行
  3. 新增 `rebuildPresetList` 日志输出 `expanded=` + `allStations=` 计数
- **涉及**：`diagram_gui.lua:893-1009`

### 地图所有车站获取（不只是有线经过的站）
- **需求**：运行图预设应显示地图上所有火车站（含无线路经过的），用户先画空骨架再填车次
- **实现**：
  1. `timetable_helper.lua` 新增 `getAllStationEntities()` — 使用 `api.engine.system.stationSystem.forEach()` 遍历地图所有站台实体，经 `stationGroupSystem.getStationGroup()` 去重后返回 `{id, name}` 列表
  2. `diagram_gui.lua:getAllStationsFlat()` — 先收集线路车站，再遍历地图车站补充遗漏的（`uniqueKey = "map_" .. sgEntity`）
  3. 地图车站优先使用线路数据中的名字（同名时合并）
- **涉及**：`timetable_helper.lua:362-388`, `diagram_gui.lua:337-354`

### 地图车站名称显示为默认名而非用户改名
- **根因**：`getAllStationEntities()` 用 `stationEntity`（站台实体）查 NAME 组件，但改名存在 `stationGroup`（站组实体）上
- **修复**：改用 `sgEntity`（站组实体）查询 NAME
- **涉及**：`timetable_helper.lua:373`

### 路径点勾选/排序保存后关窗丢失
- **根因**：`getAllStops()` 中路径点的 `entityId` 由 `getWpEntityId(wpRef)` 生成，该函数用 userdata 指针做缓存 key。`v.waypoints[i]` 每次调用返回新的 userdata 对象，缓存命中失败 → 每轮 `getAllStops()` 分配不同的 `entityId` → 预设中的 `stableKey` 对不上 → 勾选/排序丢失
- **修复**：路径点的 `entityId` 改为使用 `getWpPersistentKey(wpRef, sgEntity, i)`（格式 `"gwpk_父站ID_序号_路径点名"`）— 基于父站实体 ID + 序号 + 引擎 NAME 组件，跨调用稳定
- **涉及**：`timetable_helper.lua:483`

### 空运行图（无线路时）点击车次复选框崩溃
- **根因**：`refreshDiagram()` 中 `drawDebug` 变量声明在 `if #displayedLines > 0 then` 块内。当只勾选纯地图车站、无相关线路时，块跳过 → `drawDebug` 为 nil → `table.concat(nil)` 崩溃
- **修复**：`drawDebug` 声明移到 `if` 块外面
- **涉及**：`diagram_gui.lua:605`

### 支持无车次线时绘制运行图网格
- **需求**：允许用户在没有线路时刻表数据时也能看到站名标签 + 水平参考线 + 时间刻度，方便先规划整体结构
- **修复**：
  1. `refreshDiagram()` 移除 `#displayedLines == 0` 早期退出，折线绘制用 `if #displayedLines > 0 then` 包裹
  2. `doSaveAndDraw()` / `doRefreshData()` / reopen 路径移除 `#displayedLines == 0 then return end`
  3. `updateLineList()` 始终调用（空列表正常渲染）
- **涉及**：`diagram_gui.lua:477, 605, 859, 1072, 1104`

### 诊断日志增强
- `getAllStops()`：输出 `rawStops / stations / waypoints` 计数 + 分类异常提示
- `getAllTimetableData()`：每线路输出 stops 数 + stations 数 + waypoints 数
- `getAllStationsFlat()`：输出 `uniqueStations / uniqueWaypoints / mapOnlyAdded`
- **涉及**：`timetable_helper.lua:396-407,471`, `diagram_gui.lua:263,352,882`

## 已修复（2026-07-30 本轮）

### AbsoluteLayout 站名/时间标签只显示第一个
- **现象**：运行图左侧站名标签和底部时间刻度偶尔只显示第一个，其余全部消失（用户场景：3 个车站只显示排序号最大的站名）
- **根因链**：
  1. 旧代码用 `sll:deleteAll()` 清空 `AbsoluteLayout` 后重新 `addItem`。`deleteAll()` 可能不完全重置布局内部状态，或 TPF2 组件名注册机制未即时释放已删除组件名，导致后续 `addItem` 静默失败
  2. 整个标签循环在最外层 `pcall` 内，一旦某个 `addItem` 失败抛错 → `pcall` 终止 → 后续所有标签都不会被创建
- **试错·方案1（失败）**：创建新 `AbsoluteLayout` 然后 `slc:setLayout(newSll)` 替换
  - **崩溃**：`CComponent::SetLayout: Assertion '!m_layout' failed.`
  - **原因**：`setLayout()` 在 TPF2 引擎中只能对每个 Component 调用一次，重复调用触发 C++ assert
- **最终修复**（3 处改进）：
  1. **`deleteAll()` → 逐项 `removeItem()`**：用 `menu.stationLabelViews` 跟踪已创建组件，每次重绘时对旧组件逐个 `pcall(function() sll:removeItem(oldCont) end)` 清除，确保布局内部状态干净
  2. **组件名唯一化**：每次 `refreshDiagram` 附加递增 `tag` 计数器 → 组件名 `"stCont_3_1"`, `"stCont_2_2"`, `"stCont_1_3"`，避免引擎组件名注册冲突
  3. **去外层 `pcall` / 单标签独立 `pcall`**：站名标签循环改为每个标签单独 `pcall` 包裹创建+添加逻辑，一个失败不影响其余标签渲染，并输出 `"stationLabel add failed: ..."` 错误日志
- **涉及**：`diagram_gui.lua:486-572`（站名标签 + 时间标签两段）

### 关键发现：Component:setLayout() 只能调用一次
- **现象**：对已有布局的 Component 再次 `setLayout()` → `CComponent::SetLayout: Assertion '!m_layout' failed.`
- **根因**：C++ 端 `CComponent::SetLayout` 有 `assert(!m_layout)` 断言保护，组件一旦被赋布局就永久绑定。想在运行时"替换"布局唯一的方式是操作现有布局的 item（`removeItem` / `addItem`），不能替换布局对象本身
- **教训**：`setLayout()` 是**一次性初始化**操作，布局内容（items）可动态增删，但布局对象不可替换
