# Development progress — diagram preset system

## Observations, not changed for now (recorded 2026-08-02, for later consideration)
- **Suspicious type**: the `sgEntity==0` branch of `getAllStops` (timetable_helper.lua:724) uses `api.engine.getComponent(tostring(k), NAME)` -- passing the string `tostring(k)` as an entity ID to getComponent. It is only used to get a fallback name and is wrapped in pcall, so it hasn't caused problems yet, but the type is wrong; should later be changed to the real waypoint entity
- **Cache never refreshed**: `stationEdgesCache` (timetable_helper.lua:440) is a module-level local caching the result of `getStation2edgesMap()` once; after the player builds new railways/changes stations mid-game it **is not updated without reloading the module** -> new stations may be misclassified as "non-rail stations" and filtered out. Incremental/per-station invalidation/periodic refresh would need a performance evaluation
- **Punctuality data propagation pattern**: `_G` is not shared between the engine thread's `update` and the GUI thread's `guiUpdate` (already recorded in AGENTS.md); `_punctuality` currently works around this by "writing `_G` directly on the GUI thread" -- meaning any live data shown on the diagram (punctuality, vehicle positions etc.) can only be produced by the GUI thread; if the engine thread should ever provide data to the diagram, it must go through the `sendScriptEvent`/`timetableObject` channel

## Fixed (2026-08-03, this round)

### Unstable stopping at stations ("sometimes waits for the departure time, sometimes stops briefly and departs right away")
- **Symptom**: user reported unstable behavior after trains arrive -- sometimes they correctly wait for the timetable departure time, sometimes they depart right after stopping without waiting for the timetable. The timetable was "not strict"
- **Root cause 1 (main cause, the waitingRequired gate released held vehicles)**: the first line of `waitingRequired`, `if getTimeUntilDeparture(vehicle) >= 5 then return false end`, returned "don't wait" **in every case**. `getTimeUntilDeparture` returns the engine field `timeUntilCloseDoors` (door-closing countdown, seconds). After a train is held via `setVehicleManualDeparture(true)`, the engine often keeps/resets the door-closing timer to a large value (passengers keep boarding/alighting, the timer restarts) -> next frame the gate hits `>=5` -> `return false` -> the coroutine calls `startVehicle` (`setVehicleManualDeparture(false)`) -> **hold released -> train departs immediately**. This is the deterministic source of "stops briefly and departs right away" (good or bad with the same config depending on whether the engine resets the door timer)
- **Root cause 2 (wrong release of multiple vehicles at the same station, shared outboundTime)**: `stopData.outboundTime` for "don't interfere within 40s after departure" was **one timestamp shared by the whole station**. After one vehicle of a line was released (late/within tolerance), **other vehicles at the same station that should wait for their departure time** also hit this guard within 40s and were released too -> departed immediately
- **Fix** (`timetable.lua:waitingRequired`):
  1. Moved the `currentlyWaiting` structure initialization before the gate, and the gate now **only applies to vehicles "not yet held"**: `if stopData.currentlyWaiting[vehicle] == nil and getTimeUntilDeparture(vehicle) >= 5 then return false end` -- held vehicles are only released by the ArrDep decision (departure time reached/beyond tolerance); the engine resetting the door timer no longer releases them by mistake
  2. `stopData.outboundTime` is now **recorded per vehicle** (`outboundTime[vehicle] = time`), so vehicles released at the same station no longer affect other waiting vehicles
- **Verification**: lupa simulation of 9 scenarios all pass -- early vehicle held, **held vehicle stays held after the door timer resets to >=5**, released at departure time + forceDeparture, late (tol 0) released immediately, **a vehicle released first at a station doesn't affect a later one that should wait** (multiple slots + 30s tolerance scenario) etc.; existing `tests/*` all pass; the three changed files pass the `lua.compile` syntax check
- **Files**: `timetable.lua`
- **Remaining note**: the default delay tolerance = none (0), and releasing all late vehicles immediately is the intended "restore old behavior" design; if players still feel trains "stop briefly and leave", they can raise the delay tolerance in the settings tab (e.g. 5/10 minutes) so late vehicles keep waiting for the next slot

### Inaccurate punctuality info (still showing "on time" when 5 minutes late)
- **Symptom**: a vehicle actually 5 minutes late was shown as "on time"
- **Root cause**: the punctuality display in `diagram_gui.lua` **after departure (arrDone) only considered the departure verdict and only showed "late"** -- `if pv.depPunct == "late" then diff = pv.depDiff end`, so early departures were treated as "on time" too; and departure detection depended on `st.arrTime`, so when the arrival event was missed (short stop/already stopped when loading) the departure event was missed as well -> showed the old station's verdict/"on time"
- **Fix (Chinese railway logic, two-stage verdict, explicitly requested by the user)**:
  1. **Display** (punctuality display section in `diagram_gui.lua`): **before departure, arrival is judged by the "stopped at station" event** (early/on time/late all shown until departure); **after departure, the "departure" event takes precedence** -- late departure -> late, on-time departure -> on time, early departure -> early. **Late arrival but on-time departure = delay recovered -> shows "on time" after departure** (not late); early departure shows "early", so an abnormal departure from the previous station is visible while running
  2. **Hardened departure event capture** (`timetable_gui.lua:updatePunctuality`): departure detection no longer depends on `st.arrTime` (`if not st.arrDone then`), so a departure verdict is given even if the arrival was missed; `arrDiff/arrPunct` are only computed when the arrival was recorded
- **Files**: `diagram_gui.lua`, `timetable_gui.lua`

### "Ghosting" of the time input fields on the right (random overlapping text)
- **Symptom**: after opening a line, all time input fields (DoubleSpinBox) in the right constraint window randomly showed "ghosting" (old values overlapping new ones/the whole window overlapping)
- **Root cause (presumed, unreliable release of engine components)**: the right constraint window rebuild path is `comboBox:setSelected(..., true)` triggering `onIndexChanged` -> `initStationTable + fillStationTable + clearConstraintWindow + makeArrDepWindow`. `clearConstraintWindow` uses `deleteRows(1, getNumRows())`, analogous to `AbsoluteLayout:deleteAll()` already recorded in AGENTS.md -- the engine's table `deleteRows/deleteAll` may **not fully release nested DoubleSpinBox components**, so old input fields remain and overlap the new ones -> "ghosting"; and every station switch calls `initConstraintTable` (removeItem of the old scrollArea); if removeItem silently fails, two constraint tables overlap -> "all input fields ghosted". Both match the "random" behavior
- **Fix** (`timetable_gui.lua`):
  1. New `rebuildConstraintWindow(lineID)`: every rebuild of the constraint window goes through **`initConstraintTable` (new Table) + `fillConstraintTable`** -- old components are cleared by "rebuilding the whole table", not relying on deleteRows releasing them reliably
  2. Station branch of `fillConstraintTable`: `comboBox:setSelected(constraintIndex, true)` changed to `false` + **build directly by type** (`makeArrDepWindow`/`makeDebounceWindow`), no longer relying on the signal callback to build (avoids signal reentrancy + duplicate rebuilds of the intermediate table)
  3. Station combobox `onIndexChanged`: now rebuilds the whole table via `initConstraintTable + fillConstraintTable` (fresh table, no leftovers)
  4. All 5 uses of `clearConstraintWindowLaterHACK` (add/remove arr/dep slot, waypoint rename focus loss, add/remove passing time) changed to `initStationTable + fillStationTable + rebuildConstraintWindow(lineID)`
  5. The waypoint branch keeps the original behavior (`setSelected(selectedIdx,false)` already builds directly; the "None/Passing" switch still goes through clearConstraintWindow/makePassingWindow, because Passing's selection state is derived from "whether there are passing times", and a full table rebuild would lose a temporary "None" selection)
- **Files**: `timetable_gui.lua`

### "Refresh" button in the timetable UI (saves all times/waypoint names/passing times in one click and rebuilds the whole table)
- **Requirement (final design)**: for the problem of the intermediate station table summary not refreshing, the user wanted **no waiting** -- add a "Refresh" button next to the combobox (arr/dep times/interval control) in the right constraint window; one click **saves all time data, waypoint names and passing times and refreshes the whole timetable UI**; waypoint renaming no longer has its own save button, it's merged into the refresh button
- **Background (trial and error)**: first tried "delayed refresh after 1s without changes" (`scheduleStationSummaryRefresh` with game time `getTime()+1`) -- **getTime is frozen while the game is paused, so the refresh never fires**; user testing: "still doesn't change". A manual refresh button is the most reliable (independent of time progressing)
- **Fix** (`timetable_gui.lua`):
  1. `timetableGUI.refreshTimetableUI(lineID)`: `timetableChanged = true` + HACK (`initStationTable + fillStationTable + rebuildConstraintWindow`) -- **rebuilds the whole intermediate station table + right constraint window**; data is already written per keystroke by onChange, so the rebuild shows the latest values + triggers cross-thread sync
  2. The combobox row of both the station and waypoint branches of `fillConstraintTable` changed from 2 to 3 columns: `{infoImage, comboBox, refresh button}`, button onClick -> `refreshTimetableUI(lineID)`
  3. **Removed the waypoint rename save button** (nameTable back to 2 columns); renaming relies on onChange double-writing + the refresh button at the top to commit and rebuild; `commitName`/`refreshWaypointUI` are kept for onChange/onFocusLost
  4. Kept `scheduleStationSummaryRefresh` as an extra convenience (auto-refreshes the intermediate table while the game runs; when paused, use the manual button)
- **i18n**: reuses the existing `diagram_refresh_i18n` (present in all 7 languages); removed `diagram_wp_save_i18n` added earlier this round (7 languages, no longer referenced)
- **Files**: `timetable_gui.lua`, `strings.lua`

### Intermediate station table not refreshing after entering timetable times (after typing and clicking elsewhere, the right side has the value but the middle summary isn't updated)
- **Symptom**: after changing values in the arr/dep/unbunch/passing time input fields of the right constraint window and clicking elsewhere -- the right input fields have saved the new values, but **the condition summary of that row in the intermediate station table** (e.g. `Arr: 46:00|Dep: 25:00|`) doesn't refresh; only reopening the timetable window updates it
- **Root cause**: `DoubleSpinBox:onChange` only writes data + `timetableChanged`, **it doesn't rebuild the UI** (AGENTS.md lesson "13:30 becomes 00:30": onChange fires per keystroke, rebuilding interrupts input focus). The intermediate station table summary is only recomputed on a "rebuild path" (station selection/+/X/reopening the window)
- **Solution (user chose the manual refresh button, see the previous entry "Refresh button in the timetable UI")**:
  1. New `stationSummaryRefreshDue` (game time seconds) + `timetableGUI.scheduleStationSummaryRefresh()`: every onChange sets `stationSummaryRefreshDue = getTime() + 1` -- keeps being reset while typing, only refreshes after about 1s of no input (**extra convenience while the game runs**)
  2. `guiUpdate` checks every frame: when `getTime() >= stationSummaryRefreshDue`, call `fillStationTable(UIState.currentlySelectedLineTableIndex, false)` to **only rebuild the intermediate station table**, so the condition summary shows the new arr/dep times
  3. All 8 SpinBox onChange handlers (arr/dep 4 + unbunch 2 + passing time 2) call `timetableGUI.scheduleStationSummaryRefresh()`
  4. Key: **only refresh the intermediate table, don't rebuild the right constraint window** (no initStationTable/rebuildConstraintWindow), so the right SpinBox focus/values are completely unaffected and the old "13:30 becomes 00:30" can't recur
  5. `onClose` resets `stationSummaryRefreshDue = nil`
- **Limitation (covered by the refresh button)**: DoubleSpinBox has no focus loss callback (the API only has TextInputField:OnFocusChange); "1s without changes" approximates "the cursor has left the input field"; **this auto refresh doesn't fire while the game is paused (getTime frozen)**; then click the "Refresh" button on the right to rebuild the whole table manually
- **Files**: `timetable_gui.lua`

## Fixed (2026-08-02, round #3)

### Diagram left column layout refactor (settings/railway lines/station search in separate rows)
- **Requirement**: in the English diagram popup the word "Search" was too long and the space reserved in the left column too small, pushing the search input field back where it was hidden
- **Changes (left panel of `showDiagram` in diagram_gui.lua)**:
  1. The settings button row stays at the very top (right below the window title)
  2. The "Railway lines" title + "+" button get their own row (previously shared with "Search")
  3. The "Station search" title (new text `diagram_station_search_i18n`) + input field get their own row; the input field is added to that row's layout `shl` via `invokeLater`
- **i18n**: added `diagram_station_search_i18n` (7 languages); removed the unused `D.search`
- **Files**: `diagram_gui.lua`, `strings.lua`

### Waypoints restored (removed the NAME component check in getAllStops)
- **Symptom**: waypoints of all lines disappeared from the timetable/diagram
- **Root cause**: the round #2 fix in AGENTS.md "lines without waypoints randomly get extra waypoints" used a `getComponent(wpRef, NAME)` check + `break` to truncate, assuming "real waypoints all have a NAME component". But **unnamed waypoints have no NAME component**, so the first waypoint failing the check `break`s -> all waypoints disappear
- **Fix**: removed the NAME component check, only truncating when `v.waypoints[i]` yields nil/throws (that's the correct way to guard against an inflated `#`); the waypoint name is read separately via pcall, falling back to `UIStrings.waypoint .. flatIdx`, without breaking the loop
- **Files**: `timetable_helper.lua:getAllStops`

### Diagram settings popup refactor (refresh rate + time label position)
- **Requirement**: the settings popup has two top-level headings -- "Refresh rate" (10s auto refresh/manual refresh, mutually exclusive) + "Time label position" (top/bottom, default bottom); only applied and refreshed on "OK"
- **Changes (settings button popup in diagram_gui.lua)**:
  1. Both section headings use the new style class `timetable-settings-header`
  2. Refresh rate / time label position both use **pending values** (`selAuto`/`selPos`), only written on OK to `_G._diagramAutoRefresh` + `timetable.setTimeLabelPos()` + `applyTimeLabelPosition()` + `doRefreshData()` (cancel has no effect)
  3. Popup made taller (window 320x280, content component fixed at 300x240) so the "OK/Cancel" buttons aren't pushed out
- **i18n**: added `diagram_settings_refresh_rate/time_label/top/bottom_i18n` (7 languages)
- **Files**: `diagram_gui.lua`, `strings.lua`, `timetable_stylesheet.lua`

### Time label position switching (top/bottom) -- trial and error with three layout approaches
- **Requirement**: when the player drags the diagram window down so only its upper part is visible, time labels at the bottom can't be seen; switching to "top" should move the time labels to the top, with the diagram and station labels moving down to make room, redrawn on OK
- **Persistence**: `timetable.getTimeLabelPos()/setTimeLabelPos()`, stored in `timetableObject._diagramTimeLabelPos` + `_G` (same pattern as the delay tolerance, kept with the save)
- **Trial and error (key)**:
  1. **Dynamic rearranging via BoxLayout removeItem+addItem -> doesn't work**: `da` (diagramArea) used a VERTICAL BoxLayout holding ca/tlc; after switching to "top", rearranging with `dl2:removeItem`+`addItem` failed silently (log `tlc y=1060`: still at the bottom after applying top)
  2. **AbsoluteLayout Rect positioning -> broken coordinates**: changed `da` to an AbsoluteLayout; after `addItem(ca, Rect.new(0,0,...))` renderArea ended up at `y=-311` (render coordinates don't match AbsoluteLayout logical coordinates), the whole chart misplaced
  3. **FloatingLayout setAlignment -> index not obtainable**: changed `da` to a FloatingLayout (same as renderLayout); the initial layout with `addItem(ca, 0.5, 0)`/`addItem(tlc, 0.5, 1)` was fine, but when switching, the index for `setAlignment(index, x, y)` couldn't be obtained -- `layout:getItem(i):getComponent()` doesn't exist (ILayoutItem only has `getId()`), `findLayoutIndex` returned nil, setAlignment never ran
- **Final approach (works)**: FloatingLayout + switching via **removeItem + addItem(comp, alignX, alignY) again**:
  - bottom: `addItem(ca, 0.5, 0)` top + `addItem(tlc, 0.5, 1)` bottom
  - top: `addItem(tlc, 0.5, 0)` top + `addItem(ca, 0.5, 1)` bottom
  - addItem with alignment values is the form renderLayout has always used (verified in AGENTS.md), protected by pcall
- **Lesson**: the alignment of the initial FloatingLayout addItem works; for dynamic switching use removeItem + addItem again (don't use setAlignment, the index is unreliable); BoxLayout dynamic rearranging and AbsoluteLayout coordinate positioning are both unreliable
- **Files**: `diagram_gui.lua` (da build section + applyTimeLabelPosition + settings popup + applying the saved position when the window opens + onClose cleanup of daLayout/chartArea/appliedTimeLabelPos)

### Bottom border disappearing with time labels (shrinking the bottom of renderArea)
- **Symptom**: after switching time labels to "top", the diagram's bottom border touched the popup's bottom edge and disappeared (same problem as "draw area's right edge overflowing", already recorded in AGENTS.md)
- **Fix**: added a **vertical version** of the `dw/dh` shrinking logic in `refreshDiagram` -- `visH = (winRect.y + winRect.h) - rr.y - 2` shrinks `dh` into the window; with time labels at "top" it shrinks an extra 16px (`bottomPad`) to move everything up, keeping the bottom border visible; at "bottom" it doesn't shrink, keeping it flush
- **Diagnostic log**: `refreshDiagram rects: rr=(...) win=(...) visH=... -> dw=... dh=...` prints the actual pixels of the render area/window, for later adjustments
- **Files**: `diagram_gui.lua:refreshDiagram`

### Moving the time label text down by half a character (explicit TextView size + gravity)
- **Requirement**: with time labels at the bottom, the text touched the diagram's bottom border, making both the diagram and the times hard to read; should move down by about half a character
- **Trial and error**: (1) adding an empty spacer component to the label container -> **all time labels disappeared** (adding a component to the BoxLayout broke the layout); (2) only changing `label:setGravity(0.5, 1)` -> **no effect, back in the original position** (a TextView without explicit size sizes itself to the text height, about 10px, so gravity has nothing to act on)
- **Final approach**: give the label an explicit `setMinimumSize/setMaximumSize(labelW, TIME_LABEL_HEIGHT)` filling 22px, then combine with gravity -- bottom `(0.5, 1)` bottom-aligned (text moves down about half a character), top `(0.5, 0.5)` centered
- **Lesson**: **a TextView must have an explicit size for setGravity to work** (otherwise it sizes itself to the text height and gravity has no effect)
- **Files**: time label section of `diagram_gui.lua:refreshDiagram`

## Fixed (2026-08-02, round #2)

### Line list: ticked lines first + natural sort by line name
- **Requirement**: after ticking the lines to show and clicking refresh, all ticked lines move to the top; line names are naturally sorted by "number of digits + value" (G1,G2,G10,G21,G111); Chinese sorted by pinyin initials (dropped after evaluation)
- **Changes (`getRelevantLines` in diagram_gui.lua)**: replaced the original "sort by line ID" with a three-level sort:
  1. **Ticked first** (`a.checked ~= b.checked -> return a.checked`)
  2. **Natural sort by letter+digit prefix**: `lineSortKey` extracts `^(%a+)(%d+)` -> compares by (letters, number) (G123/G34 -> 34 first; purely numeric names also by value); names with a prefix come before names without
  3. **Everything else (including Chinese) sorted stably by UTF-8 code point**; same name/same key falls back to the line ID
- **No Chinese pinyin initial sorting**: would need a built-in pinyin table of thousands of characters; TPF2 has no such library, embedding is unreliable (the user agreed to "only move ticked lines up if it's hard")
- **Files**: `diagram_gui.lua:getRelevantLines` (sorting replaced with lineSortKey/compareLines)

### Lines without waypoints randomly get extra waypoints (waypoint entity validation in getAllStops)
- **Symptom/report**: a player's line had only stations and no waypoints, but a few waypoint rows randomly appeared overlapping at some station on the timetable page
- **Root cause (presumed)**: when `getAllStops` (timetable_helper.lua) flattens `Line.Stop.waypoints`, `v.waypoints` is userdata whose `#` may return an **inflated** value for empty objects (stations without waypoints randomly get extra waypoints), or entities may have been deleted; the old code `for i=1,wpCount` still tried to create waypoints for out-of-range/invalid indices
- **Fix**: validate one by one and truncate -- `break` as soon as `v.waypoints[i]` is nil/unreadable or `getComponent(wpRef, NAME)` fails (real waypoints all have a NAME component), no more fake waypoints; fixed the summary log: waypoints from `v.waypoints` are now counted in `waypoints=` (previously only misclassified waypoints with stationGroup==0 were counted)
- **To confirm**: if it still happens randomly after the fix, the player needs to provide the `getAllStops line=... rawStops=... stations=... waypoints=...` log, to distinguish between stationGroup misread as nil (`-> classified as WAYPOINT` is logged) and a rendering layer issue (deleteAll not clearing properly)
- **Files**: `timetable_helper.lua:getAllStops`

### Punctuality judged against the wrong slot set with multiple slot sets (getPlannedArrDep aware of multiple sets)
- **Requirement/report**: a station of a player's line had two slot sets (e.g. station 2 set 1 arr/dep 26:30/27:30, set 2 51:00/52:30); the train actually arrived at 26:45 running on set 1, but was judged about 24-25 minutes late -- obviously judged against set 2 (51:00)
- **Root cause**: `getPlannedTime` in `updatePunctuality` (timetable_gui.lua) **hardcoded `conds[1]` (the first set)**. Which set a train actually runs on is unrelated to the storage order, so lines with multiple sets were bound to pick the wrong one; the old phase mechanism (single `st.phase` value reused across stations) also couldn't align to the right cycle with multiple sets
- **Fix**: new `getPlannedArrDep(lineID, stationNumber, actualArrTime)` -- iterates over all ArrDep sets of the station and picks "the set whose **absolute arrival time is closest to the actual arrival**" (`k = floor((actual-arr+1800)/3600)` for the nearest cycle, consistent with the slot assignment logic of waitingRequired), returning that set's absolute planned arr/dep seconds. Chosen on arrival and stored in `st.plArr/st.plDep`; the departure verdict reuses the same set; if the arrival was missed, the arrival/departure time is used to re-pick as a fallback
- **Verification**: 9 simulated cases (26:45 -> set 1, 15 seconds late; 50:00 -> set 2, 1 minute early; on time/across cycles/multiple hours) all correct; equivalent to the old phase logic with a single set. Note the in-cycle format is min:sec; 26:45 and 26:30 differ by 15 seconds (shown as "late 00:15")
- **Files**: `timetable_gui.lua` (getPlannedArrDep replaces getPlannedTime, both arrival/departure verdicts in updatePunctuality, punctualityState structure drops phase and adds plArr/plDep)

### Punctuality info layout in the line list ("●On time" as one unit + natural width + horizontal scrolling)
- **Requirement**: the filled circle (●) of the punctuality info was too far from the text ("●     On time"); the left column is narrow and should be compacted; when line names are too long the punctuality info gets pushed out, so add a horizontal scroll bar to scroll over
- **Changes (diagram_gui.lua `updateLineList` + showDiagram)**:
  1. **● and text merged into one TextView (`"●" .. text`, a single unit "●On time")**: there can't be a gap inside one string; the color uses the punctuality style class (on time white/early green/late red); no separate dot TextView needed anymore
  2. **No manual width estimate, natural rendered width**: `ptv`/`pvCont` set to `min 0 / max 600` with height 24/rowH; the width is left to the layout based on the actual text width -- the previous version's own `estimateMonoWidth` (CJK ~10px/ASCII ~6px) estimated inaccurately, so long texts (German/Russian "Verspätet/Опоздание 05:30") were clipped, and the row didn't really get wider so the scroll bar didn't appear
  3. **Row width can grow**: `lineItem` changed from a fixed `220xrowH` to `min 220 / max 600`; long punctuality text or long line names make the row wider -> content `nc` gets wider -> horizontal scroll bar appears (verified: the scroll bar appears with overly long line names)
  4. **Horizontal scroll bar**: best-effort call of `setHorizontalScrollBarPolicy(ScrollBarAsNeeded)` on `lineScrollArea` (the `ScrollBarPolicy` enum path isn't listed in the official API docs; pcall protected, skipped if unavailable)
- **Player test feedback**: the horizontal scroll bar works with overly long line names; still to confirm whether "●On time" is tight and unclipped, and whether rows get wider with long punctuality text
- **Files**: `diagram_gui.lua` (punctuality section of updateLineList, horizontal scrolling policy in showDiagram)

## Fixed (2026-08-02, this round)

### Trains held until the next cycle when just 1 second late (waitingRequired rewrite + delay tolerance setting)
- **Requirement**: a foreign player reported "as soon as a train arrives just 1 second late, it doesn't continue and is held until the next departure slot, causing huge extra delays"; the user also observed "after arrival it doesn't really stop and restart on time". Requested restoring the old behavior (late trains depart too), or adding a configurable 3-5 minute tolerance
- **Root cause (proven by tests)**: **copy-paste bug** in `timetable.beforeDepature` (timetable.lua): `arrivalTimeSec = (60*constraint[3])+constraint[4]` used the departure fields [3][4] instead of the arrival fields [1][2]. For a **single slot** (one train per cycle, the most common case) `getTimeUntilNextConstraint` returns 3600 -> `nextArrival = (3600+departure time)%3600 = departure time` -> the departure dead zone `[dep, nextArr)` is an **empty interval** -> the formula always decides "wait" -> any train arriving after the departure time (even 1 second) is held until the next cycle. The existing test `tests/timetable_tests.lua:76` was already failing because of this
- **Decision model (rewrite of the ArrDep branch of waitingRequired)**: per slot, compute "the run whose arrival time is closest to the current time" (`k = floor((time-arrTime+1800)/3600)` rounded to the nearest cycle, so early arrivals aren't misjudged as late for the previous run):
  1. **Early/on time** (`time < the slot's absolute departure time`) -> stop and wait until the departure time
  2. **Late within tolerance or tolerance = none** -> **release immediately** (no longer held for being 1 second late)
  3. **Late beyond the tolerance** -> **held until the departure time of the next run/next cycle** (multiple slots = next time slot, single slot = next hour)
- **Behavior of early trains and "none"**: with "none", early/on-time trains still wait for their departure time (they don't leave early); only **late** trains are released immediately -- exactly the "restore old behavior" the comment asked for
- **Delay tolerance setting (new "Settings" tab in the timetable window)**: dropdown options none/5:00/10:00/20:00/30:00. Stored in `timetableObject._delayTolerance` (seconds, 0 = none), **saved permanently** with `state.timetable` (kept across closing the window/quitting and reloading), synced from the GUI thread to the engine thread via `timetableChanged`+`sendScriptEvent` (`waitingRequired` reads it on the engine thread via `timetable.getDelayTolerance()`). Added 7 languages x 2 keys (`diagram_delay_tol_i18n`/`diagram_delay_none_i18n`)
- **Real stop, real start**: new `timetableHelper.forceDeparture()` (`api.cmd.make.setVehicleShouldDepart`) -- `timetableCoroutine` uses `timetable.isVehicleWaiting()` to detect the moment of "waiting -> released" and forces the vehicle to start at the actual departure time (`setVehicleManualDeparture(false)` alone may not depart immediately). **Must not go into the generic `startVehicle`**: that would force all AT_TERMINAL vehicles (including lines without timetables) to depart every frame, breaking the game
- **Verification**: all 13 tests related to `beforeDepature`/`getNextConstraint` pass (2 failed before the fix); lupa simulation of 19 scenarios (single slot/two slots/across midnight/each tolerance level/waiting -> released transition) all as expected, `forceCalls=1` confirms the forced start fires; all 6 Lua files pass the `lua.compile` syntax check
- **Kept**: the early return on `getTimeUntilDeparture >= 5` (the user chose the conservative option -- don't interfere during the engine's default stopping procedure after arrival, only step in when the door-closing countdown is <5s); `getNextConstraint`/`getTimeDifference`/`getTimeUntilNextConstraint` unchanged (only referenced by tests); debounce branch untouched
- **Files**: `timetable.lua` (waitingRequired ArrDep branch, isVehicleWaiting, get/setDelayTolerance, beforeDepature), `timetable_helper.lua` (forceDeparture), `timetable_gui.lua` (timetableCoroutine transition + settings tab), `strings.lua`

## Fixed (2026-08-01, this round)

### Train punctuality info feature (late/on time/early classification)
- **Requirement**: determine the actual arrival time of trains and classify late/on time/early (±10s threshold); show the arrival/departure verdict of the "previous station" (a train on the way A->B shows station A's punctuality, refreshed at B); show the arrival verdict before departure and the departure verdict after departure
- **Rules**: `|diff|<=10s` is on time, positive = late, negative = early. **Before departure, use the arrival verdict** (early arrival -> early); **after departure, use the departure verdict** (late departure -> late, on-time departure -> on time). Display format `late MM:SS`/`early MM:SS`. Dot and text in the same color: on time white/early green/late red
- **Data source (proven by logs)**: `lineStopDepartures[stopIndex+1]` receives the **actual departure seconds** after the vehicle departs (e.g. departure at time=360 -> value 360), = 0 while waiting at the stop, and keeps the historic value after stopIndex advances; `state=2` means stopped, `stopIndex` is 0-based
- **Where detection runs**: **GUI thread `guiUpdate`, scanning once per second (throttled)** (`timetableGUI.updatePunctuality`, game_script/timetable_gui.lua). Key lesson: **the engine thread's `update` and the GUI thread's `guiUpdate` don't share `_G`** (two separate Lua VMs) -- detection was first put on the engine thread, and the GUI read nil from `_G._punctuality` (punctuality rows not shown); after moving it to the GUI thread it's directly visible on the same thread
- **State machine**: on arrival (state->2) record `arrTime=getTime()` + immediately compute the arrival verdict (`arrTime - planned arr`); while stopped/after departure, when `lineStopDepartures[thisStopIndex+1]` becomes non-zero -> finalize that station's departure verdict; phase alignment `phase = (depTime - planned dep) rounded to the nearest multiple of 3600`; if the phase isn't known on arrival, the arrival time is used for alignment too
- **Data flow**: detection results are stored in `_G._punctuality[vehicleId]` (shared within the GUI thread, read directly by diagram_gui)
- **UI (diagram_gui.lua)**:
  1. Settings button (top of leftPanel) + popup with 10s auto refresh/manual refresh (mutually exclusive checkboxes), stored in `_G._diagramAutoRefresh`
  2. A small "Punctuality" title (timetable-mono-sc 10px) right of the "Color" button in the line list title
  3. **Punctuality info shown right of the color swatch** (inside the line row, not a separate row): one `[● dot][punctuality text]` row per vehicle, stacked vertically; line row height adapts as `max(42, vehicle count x 24)`, `totalHeight` summed exactly
  4. **Auto refresh is equivalent to the refresh button**: `menu.window:onStep` (called on every GUI update) calls `doRefreshData()` every 10s (game world time `getTime()`) -- fully re-reads the timetable + redraws the diagram + refreshes punctuality. Initially it only called `updateLineList()`, so timetable changes weren't refreshed (bug)
  5. Dot colors use style classes (not hardcoded RGB): `!timetable-punct-ontime/early/late` (on time white/early green/late red); `setStyleClassList` must use classes with the `!` prefix
- **Performance**: the GUI thread scans all vehicles once per second (`getLine2VehicleMap`), reading only 3 component fields; when the state doesn't change it's pure comparisons, negligible cost
- **API notes**: `setFontSize` **is not a valid API** (not in the docs), use style classes for font size; `onStep` works (every GUI update); `setStyleClassList` uses style classes with the `!` prefix; string literals **can't use `\u{25CF}`** (not supported in Lua 5.1), write the UTF-8 bytes directly
- **Crash lesson**: refactoring `updateLineList` accidentally deleted the `end` of a `for` loop -> `require diagram_gui.lua` failed to load -> crash on loading a save (`Lua exception: error loading module`). **After every Lua change, run a `lua.compile` syntax check with lupa (Python Lua 5.1 binding) before starting the game**
- **Files**: `timetable_gui.lua` (updatePunctuality + guiUpdate call), `diagram_gui.lua` (settings popup/punctuality rows/onStep auto refresh/dots), `timetable_stylesheet.lua` (3 punctuality color classes), `strings.lua` (7 languages x 7 keys)

### Diagram only filling part of the window/border not flush (LineRenderView uses actual rendered pixel coordinates)
- **Symptom**: the diagram's grey border only reached about 80% of the drawing component (large blank areas at the right and bottom), and "a big gap between the bottom border and the time labels"
- **Root cause (proven by logs)**: `LineRenderView:addLine` uses the **component's actual rendered pixel coordinates** (affected by the game's UI scale factor 1.25), while the code used the **logical constants** `dw=870/dh=728` (= difference of the window's logical sizes); the component actually rendered at 1088x910 -> drawing at (870,728) only reached 80% (870/1088 ≈ 0.8). Unlike AbsoluteLayout -- AbsoluteLayout's `Rect` coordinates don't scale (time label `Rect.x=122` landed at x=122 inside tlc, verified), while LineRenderView renders in actual pixels. This inconsistency between the two coordinate systems was the key to the investigation
- **Fix**:
  1. `refreshDiagram` takes the **actual rendered size** from `menu.renderArea:getContentRect()` at runtime as `dw/dh` (non-zero after layout, falls back to the logical size on failure)
  2. Measured: renderArea's right edge 1714 exceeded the window's right edge 1700 (layout offset 14px) -> dynamically compute `window right edge - renderArea left edge - 2` to shrink `dw` into the window, so the right ends of the border/polylines/grid are visible and the four lines meet at the bottom right corner
  3. The border view **bv is created last** (on top): the original order border -> grid -> polylines put the polyline view on top of the border, and the cross marker of an arrival at 59:59 covered the right border; changed to grid -> polylines -> border, polyline index `li+2` -> `li+1`
  4. Removed the dead code `secondsToX`/`timeToSeconds` (leftovers of the failed normalized approach)
- **Trial and error**: first tried "normalized coordinates 0~1" (`addLine(0,0)-(1,1)`) -> everything squeezed into the top left corner as a single pixel -- **LineRenderView doesn't support normalized coordinates**, actual pixel coordinates are required; then tried "only pulling in the right border line" -> the bottom right corner endpoints were misaligned (right border bottom end at 1072, bottom border right end at 1088), and an arrival at 59:59 beyond the window still covered the border -- **shrinking dw as a whole + border on top** is required
- **Lesson**: the LineRenderView coordinate system = the component's actual rendered pixels (scaled with the UI), neither logical nor normalized coordinates; container sizes use logical values (the engine scales the display), drawing coordinates must use the actual values from `getContentRect()`. When layering drawings on a LineRenderView, later views cover earlier ones; "outline" elements like the border must be added last
- **Files**: `diagram_gui.lua` (refreshDiagram dw/dh retrieval + layer reordering), `diagram_gui.lua:40-45` (layout constants STATION_PANEL_WIDTH 280->220, STATION_LABEL_WIDTH 150->110, TIME_LABEL_HEIGHT 30->22)

### Enlarged diagram window layout (layout constants adjusted, diagram +13% width)
- **Requirement**: in the default diagram window the drawing area only took 64% of the width; there was room to widen it
- **Basis** (getContentRect log): window 1200x780 (1500x975 scaled), renderArea logical 870x720 taking 64% of the width and 92% of the height; the left panel 280 + station label column 150 + time scale bar 30 could all be compacted
- **Fix**: `STATION_PANEL_WIDTH` 280->220, `STATION_LABEL_WIDTH` 150->110, `TIME_LABEL_HEIGHT` 30->22 -> renderArea logical 770x720 -> 870x728 (width +13%). All references go through the constants, `dw/dh` are recomputed automatically
- **Files**: `diagram_gui.lua:43-45`

## Fixed (2026-07-31, this round)

### Copy It! icon doubled after updating the mod (duplicate additions to the gameInfo toolbar, module-level guard doesn't survive reloads)
- **Symptom**: a foreign player reported "after updating this mod, okeating's Copy It! shows two icons in the game; after uninstalling this mod it's back to one"
- **Root cause**: `guiUpdate` in `timetable_gui.lua` (game_script) used `if not clockstate then` to add the separator/clock/timetable button/diagram button to the shared `gameInfo` toolbar. `clockstate` is a **module-level local** and becomes nil after a Lua VM module reload (e.g. a mod update) -> the creation block runs again and **adds this mod's components again** to the same toolbar; other mods in the same toolbar (Copy It! etc.) also often add their icons again because the same kind of "module-level local guard" is reset. This mod's update was the **trigger** for that script reload, but the root cause of the doubled Copy It! icon is that it also lacks a reload-proof guard itself (fixing this mod is necessary but not sufficient)
- **Fix (approach 2, idempotency check)**: on entering the creation block, first check with `api.gui.util.getById("gameInfo.timetables.button")` whether the button already exists in the engine --
  1. **Exists** (module reload case): don't rebuild any components, only restore the clock reference via `clockstate = _G._timetableClockLabel`; the clock keeps updating
  2. **Doesn't exist** (first load/engine components really destroyed): run the original creation logic and store the clock reference in `_G` via `_G._timetableClockLabel = clockstate` (_G survives module reloads, so it can be restored on the next reload)
- **Advantage**: more robust than "just switching to a `_G` guard flag" -- a pure flag makes the button never appear when "the engine UI was destroyed but the flag remains"; the getById idempotency check self-heals by recreating. The clock reference must also be stored in `_G`, otherwise `clockstate` is lost after a reload and the clock in the top right stops
- **Verification**: after stripping comments/strings, keyword pairing is balanced (if102+for24+while1+function89=216==end216); Chinese comments confirmed to be written as valid UTF-8
- **Lesson**: adding components to shared toolbars like `gameInfo` requires a "getById idempotency check before creating" or a `_G` flag, never a module-level local as the guard -- confirms the AGENTS.md lesson "module-level locals don't survive reloads" once again
- **Files**: `timetable_gui.lua` (game_script) `guiUpdate` (formerly the block at :1198, now the getById idempotency branch)

### "Content at top, scroll bar at bottom" mismatch after refresh/expand (setScrollOffset with the same value is a no-op)
- **Symptom**: after refreshing or expanding a configuration at the bottom of the list (e.g. config 11), the list content jumped back to the top, but the scroll bar stayed at its old position (bottom) -- scrolling down further didn't work (the scroll bar was already at its maximum); after scrolling up a little to move the scroll bar, scrolling down worked normally again. Expanding worked fine with everything collapsed; it was triggered once a configuration above had been expanded and you scrolled to the bottom and expanded
- **Root cause**: `setContent` **resets the content view to the top but keeps the old scroll bar value** (bottom). When `restoreScrollOffset` then calls `setScrollOffset(old value)`, the value hasn't changed -> the engine treats it as a no-op and doesn't resync -> content and scroll bar mismatch. Only after the user scrolls manually and changes the scroll value does it resync, hence "scroll up a little and then down works normally"
- **Fix**: `restoreScrollOffset` first resets to zero via `setScrollOffset(0,0)` and then sets the target value, forcing the engine to resync content and scroll bar; if the initial capture failed, capture again after layout
- **Files**: `diagram_gui.lua:823-841`

### Line ticks "all restored to ticked" after switching presets (applyPreset didn't reset lines not overridden)
- **Symptom**: after ticking/unticking lines, expanding another railway line and then expanding the configuration just changed, all lines were ticked again; station ticks were fine
- **Root cause**: when applying `lineData`, `applyPresetToStations()` **only overrode lines present in lineData**; lines not overridden inherited the `checked` state of the previous preset (or the default all ticked). Station ticks are assigned explicitly (`else st.selected = false`) so they were fine; lines had no corresponding `else` branch -> leftover state
- **Fix**: `applyPresetToStations()` first resets everything via `for _, ld in pairs(allLines) do ld.checked = true end`, then overrides by `preset.lineData` -- line state is as **deterministic** as station state (lines not covered by lineData are ticked by default)
- **Proven by logs (2026-07-31)**: after unticking lines 52008/55277, `saveCurrentPreset`'s log **never appeared** -> `saveCurrentPreset()` **threw silently** inside pcall, lineData was never written -> switching back to the preset showed everything ticked
- **Root cause proven (SAVE ERROR log)**: `attempt to call global 'saveCurrentPreset' (a nil value)` -- `updateLineList` (:828) was defined **before** `saveCurrentPreset` (:929); Lua locals are only visible after their declaration, so the reference in `updateLineList`'s line checkbox closure resolved to a **nil global**. Station/sort saving all lives in `rebuildPresetList` (defined after saveCurrentPreset), so it worked -- this is why "stations work but lines don't"
- **Fix**: added the forward declaration `local saveCurrentPreset` at the top of the file (:29), definition changed to `saveCurrentPreset = function() ... end` (:929) -- exactly the same kind of bug as the `rebuildPresetList` forward reference already recorded in AGENTS.md
- **Diagnostic log cleanup**: removed temporary logs like `lineCheck toggled`, `applyPreset lineData=set/nil`, `saveCurrentPreset unchecked=`; kept the three `SAVE ERROR` error captures (only printed when saving fails, as a safeguard)
- **Files**: `diagram_gui.lua:29,866,929`

### Scroll position reset after refresh / line list in random order / new presets inheriting ticks (UX fixes)
- **Symptom 1 (scroll reset)**: on every refresh, the content of the railway line list/line list jumped back to the top while the scroll bar stayed in place, severely disrupting further edits
- **Root cause 1**: `updateLineList()` / `rebuildPresetList()` call `ScrollArea:setContent()`, and rebuilding the content resets the scroll bar to the top
- **Fix 1**: new `restoreScrollOffset(area, offset)` -- record via `getScrollOffset()` before `setContent`, and after `setContent` wait for the layout with a double `invokeLater` before restoring via `setScrollOffset()` (reuses timetable_gui's restore pattern)
- **Symptom 2 (ticked lines "disappearing")**: after ticking lines and clicking refresh, the lines just ticked seemed lost; the user thought it was a saving problem
- **Root cause 2**: `getRelevantLines()` iterates `allLines` (from `pairs(lineSystem.getLines())`), whose **order is not deterministic across calls** -- on every refresh lines jumped to random positions + the list scrolled back to the top, creating the visual illusion of "lines disappearing". There was also a data side: `getAllTimetableData()` rebuilds allLines with everything ticked by default, and tick state is only restored from preset.lineData via `applyPresetToStations`, so changes made without an expanded preset were lost
- **Fix 2**:
  1. `getRelevantLines()` sorts stably by line ID before returning (:412-418)
  2. `doRefreshData()` records `prevChecks` (current allLines ticks) at the start and restores them after rebuilding and applyPreset (:1178-1181, 1211-1214) -- consistent with immediate saving; changes made without an expanded preset survive the refresh too
- **Symptom 3 (new preset only ticks the first line)**: after adding a railway line configuration, all lines should be ticked by default, but only the first one was
- **Root cause 3**: a new preset has `lineData = nil`, and `applyPresetToStations` doesn't touch allLines.checked -> inherits the tick state passed on via allLines from the previous preset; the user's first action triggered an auto-save that wrote the old ticks into the new preset
- **Fix 3**: `addNewPreset()` explicitly runs `for _, ld in pairs(allLines) do ld.checked = true end` (:1124-1126)
- **Symptom 4 (newly added preset not visible)**: after clicking + to add a railway line, the list stayed at its old scroll position (or the top); the new preset was appended at the end of the list and expanded automatically, so the player couldn't see it
- **Fix 4**: `addNewPreset()` sets `pendingScrollPresetId`, `rebuildPresetList()` records that preset's header row, then after a double `invokeLater` waiting for the layout calls `psa:ensureVisible(targetRow)` -- **minimal scrolling** to reveal the new preset's header, keeping existing configurations above (e.g. config 11) in the viewport while the new config 12 is visible too. Must scroll neither to the top nor to the bottom (the new preset is expanded; the bottom only shows its last station row)
- **Trial and error**: first computed pixels `rowRect.y - contentRect.y` and then `setScrollOffset` to scroll to the top of the new preset's header -- this scrolled past the configurations above, and `getContentRect` is timing-unstable in nested layouts and may return 0, jumping back to the top. Switched to `ScrollArea:ensureVisible` ("Ensures a child component is visible"), which has the right semantics
- **Cleanup**: removed the no longer referenced `diagram_save_i18n` (strings.lua, 7 languages) + `D.save`; changed the "click save" description in description.txt to "draws on expand/auto-save/refresh redraws"
- **Files**: `diagram_gui.lua`, `strings.lua`, `description.txt`

### Immediate saving + draw on expand + save button removed (refactor)
- **Requirement**: save the railway line configuration immediately after ticking stations/entering sort numbers; expanding a preset immediately expands the line list and draws the diagram, switching presets switches the graphics; after changes, clicking refresh immediately refreshes the list and redraws; the save button is redundant, remove it
- **Changes** (`diagram_gui.lua`):
  1. **Save immediately after ticking a station checkbox**: `saveCurrentPreset()` + `savePresetsToTimetableObject()` (:1065-1075)
  2. **Save immediately in the sort DoubleSpinBox onChange**: only write data, don't rebuild the UI (onChange fires per keystroke, rebuilding interrupts input focus -- reuses the AGENTS.md lesson on timetable SpinBox value loss) (:1088-1098)
  3. **Draw on expanding a preset**: `displayedLines = getRelevantLines(...)` + `updateLineList()` + `refreshDiagram()` (:993-997)
  4. **Refresh button**: `doRefreshData()` unconditionally updates the line list + redraws (:1159-1164)
  5. **New `clearDiagramViews()`**: clears the polyline view + station/time labels, all with pcall; `refreshDiagram()` calls it with fewer than 1 ticked station to clear the old diagram instead of returning silently (:496-516, 521-528) -- fixes "expanding an empty preset doesn't draw but leaves the previous preset's graphics"
  6. **Removed the save button UI + the `menu.saveButton` reference + the dead code `doSaveAndDraw()`**
  7. **`addNewPreset()` expands automatically** + clears the line list/diagram (a new preset has no ticked stations; tick first, then click refresh to draw) (:1111-1124)
  8. **Deleting the currently expanded preset** also clears the line list/diagram (:1041-1052)
- **Data safety**: all changes (station ticks, sort numbers, line ticks) are saved immediately and trigger `_diagramForceSync`, no longer relying on the save button; `persistConfig` on window close still saves as a fallback
- **Files**: `diagram_gui.lua`

### Clicking save without an expanded preset cleared station ticks/sort numbers (data loss)
- **Symptom**: clicking save directly without any railway line preset expanded **sometimes** turned all of the preset's stations into the default unticked state with sort number 256 (the old sort sentinel value written back "like a ghost")
- **Root cause**: when `currentPresetRef == nil`, `doSaveAndDraw()` fell back via `if not p and #localPresets > 0 then p = localPresets[1] end`, and then `saveCurrentPreset()` wrote the **current in-memory state** of `allStations` back into that preset. Without an expanded preset, `allStations` is in its unloaded default state (all selected=false, sort=256), overwriting the user's saved configuration. **Random**: after expanding and collapsing, `allStations` still held the applied data (writing back is idempotent, nothing lost); only the never-loaded state cleared it
- **Fix**: removed the `localPresets[1]` fallback in `doSaveAndDraw()`; when both `currentPresetRef` and `expandedPresetId` are empty, just return without doing anything
- **Hardening**: `saveCurrentPreset()` no longer falls back to `getActivePreset()`, only the currently expanded preset may be saved (all call sites already have an `if currentPresetRef` guard), completely closing the "write default state back to a preset" path
- **Files**: `diagram_gui.lua:899-909`, `:868-870`

### Line tick state "doesn't save" (first save cleared lineData)
- **Symptom**: some users reported that ticking lines for selective drawing didn't save; next time everything was ticked again; but saving worked in other environments
- **Root cause**: `saveCurrentPreset()` iterated `displayedLines` when saving `lineData` -- the subset "of lines related to the currently selected stations", and **`displayedLines = {}` when the window is first opened** (initialized in `showDiagram`, and expanding a preset didn't refresh it either). The **first** save after expanding a preset wrote the saved `lineData` as an empty table -> tick state lost. On later saves `displayedLines` had been filled by `getRelevantLines`, so it worked (hence hard to reproduce)
- **Fix**:
  1. `saveCurrentPreset()` now saves line tick state from `allLines` (the complete set, consistent with the applying side `applyPresetToStations`, which also iterates allLines)
  2. Expanding a preset also sets `displayedLines = getRelevantLines(sel)` + `updateLineList()`, so the last ticked lines are visible right after opening
  3. After ticking a line checkbox, immediately `saveCurrentPreset()` + `savePresetsToTimetableObject()` (internally sets `_G._diagramForceSync` to trigger sync), so state isn't lost when quitting the game/closing the window directly
- **Files**: `diagram_gui.lua:883-896`, `:806-818`, `:992-998`

### Through runs wrongly connected straight on a single-line diagram (option A, break the polyline)
- **Symptom**: two railway lines 1234 and 5678 with a connecting line in between. A through run 1->6->7->4 was drawn correctly on the 5678 diagram, but on the 1234 diagram it was connected directly from 1 to 4, crossing the reference lines of stations 2 and 3 (the run doesn't actually pass 2 and 3)
- **Root cause**: the drawing loop in `refreshDiagram()` only handled stops with `yMap[st.uniqueKey]`; stops not on the current preset's vertical axis (6, 7) were silently skipped, so the pts array connected the departure point at station 1 directly to the arrival point at station 4
- **Option A (adopted)**: **break the polyline** when encountering a **station** not on the vertical axis; subsequent arr/dep points start a separate polyline. On the 1234 diagram the through run only shows two isolated arr/dep points at 1 and 4 (with cross markers), no longer connected. On real railway diagrams, through trains are only drawn for the section within each line
- **Criterion**: connect only if two adjacent stops are both in the diagram; break if there's a stop in between that isn't. Doesn't affect "runs of the same line with unticked intermediate stations" (such runs have no other stops between 1 and 4, so they're still connected)
- **Key correction (waypoints don't break)**: the break condition is limited to `not y and st.stopType == "station"`. In TPF2 lines, intermediate stations "passed without stopping" are **waypoints**; they're not on the vertical axis but are just points the track passes, so they **must not trigger a break** -- runs of the same line that skip stops (e.g. only stopping at 1, 5) should be drawn as a slanted line crossing the 2, 3, 4 reference lines. Breaking on waypoints too would cause the anomaly "1->5 broken, 5->1 connected" (5->1 is drawn by the loop closure, so it looks connected)
- **Second correction (silently skip off-axis waypoints to prevent crashes)**: the initial implementation `if not y and st.stopType == "station" then break else handle stop end` had a **logic hole** -- off-axis waypoints (`not y` and `stopType=="waypoint"`) fell into the else branch and inserted polyline points with `y=nil`; when drawing, `api.type.Vec2f.new(x, nil)` threw a **Lua exception**. Chain of symptoms: clicking save (`doSaveAndDraw` has pcall) -> the error was caught and only logged, no polylines drawn at all; then clicking a line checkbox (`refreshDiagram()` without pcall) -> the same error **crashed the game** directly. Changed to three branches: with `not y`, stations break / waypoints are silently skipped; only with `y` is the stop handled normally
- **Defensive hardening**: all 5 call sites of `refreshDiagram()` (ticking a checkbox, clicking a line name, save, refresh, color change) are uniformly wrapped in `pcall`
- **Loop closure adjustment**: single `pts` array -> `polylines` array of polylines; the loop closure (`nextG = g % maxG + 1`) now appends to the last polyline; the closure condition keeps its original semantics `firstY non-nil and firstY ~= lastY`
- **Files**: `diagram_gui.lua:649-750`

### Duplicate component names of diagram station/time labels across refresh cycles
- **Symptom**: the diagram's vertical axis had 4 stations (1,2,3,4), but station labels only showed 1 and 4, not 2 and 3 in between
- **Root cause**: in the station/time label component names `"stCont_" .. sv .. "_" .. tag` / `"tmCont_" .. m .. "_" .. tag`, `tag` was a local variable inside `refreshDiagram()` that **restarted from 0 on every refresh**. Component names repeated across refresh cycles, violating the lesson already recorded in AGENTS.md "component names must be unique across refresh cycles" (names of components removed via removeItem may not be released by the engine immediately; recreating with the same name conflicts and addItem fails silently)
- **Fix**: new `nextLabelName()` takes a monotonically increasing number from `_G._diagramLabelCounter`, stored in `_G` rather than a `local` (module-level locals don't survive Lua VM reloads, _G survives module reloads; precedents in this project: `_G._diagramForceSync` / `_G._gwNames`)
- **Files**: `diagram_gui.lua:24-33` (nextLabelName), `:546,587` (label creation)

### Station labels of intermediate stations missing (the real root cause: float arguments to Rect.new)
- **Symptom**: station labels only showed the first and last stations (groups with the largest and smallest sort), intermediate station labels weren't shown; time labels were fine
- **Root cause** (proven by logs): the diagnostic log showed the sort 2 and 3 groups **were indeed stations** (`station:2-2[55785]`), and the label logic found the names (`label=2-2`), but `sll:addItem(cont, rect)` threw `sol: no matching function call takes this number of arguments`. The reason: `stationToY` uses float division, so the intermediate stations' `y` were floats (480.0, 240.0), and `rectY = y - labelH/2` was a float too -> the Sol2 binding of `api.gui.util.Rect.new(0, float, ...)` found no matching overload -> addItem failed. **The first and last stations happened to return integers due to clamping** (sort=4 -> `max(0, -9)=0`; sort=1 -> `min(702, 711)=702`), so they worked. Time labels were fine because they used `math.floor`, station labels didn't
- **Fix**: added `math.floor` to the station label `rectY` (`:577`), consistent with the time labels (`:616-617`)
- **Lesson**: all coordinates passed to `api.gui.util.Rect.new` must be rounded with `math.floor`; float arguments make Sol2 fail silently with "no matching function call" (swallowed by an outer pcall -> shows up as "labels sometimes only partially shown")

### doSaveAndDraw calling rebuildPresetList: forward reference to nil
- **Symptom**: log `Save error: ... attempt to call global 'rebuildPresetList' (a nil value)` -- the save button only logged because pcall caught it; the preset list wasn't refreshed
- **Root cause**: `doSaveAndDraw` (:892) was defined **before** `rebuildPresetList` (:943); a Lua `local function` is only visible after its declaration, so at runtime `rebuildPresetList` resolved to a nil global
- **Fix**: added the forward declaration `local rebuildPresetList` at the top of the file (:24), function body changed to `rebuildPresetList = function() ... end`
- **Files**: `diagram_gui.lua:24,943`

### Station list only keeps train stations and waypoints (bus stops filtered)
- **Requirement**: users reported bus stop names in the diagram's station list; only train stations and waypoints should be kept
- **Root cause**: the station list has two sources, both mixing in bus stops:
  1. `getAllRailLines()` has Rail in its name but **doesn't actually filter** -- it returns all lines (including bus lines), so bus line stops end up in the list
  2. `getAllStationEntities()` returns **all** stations on the map (including bus stops and cargo stations) to add "stations not served by any line"
- **Approach (chosen by the user)**: all train stations on the map + waypoints, bus stops filtered out
- **API research results**:
  - `enum.Carrier`: ROAD=0, RAIL=1, TRAM=2 (determines a line's vehicles)
  - `enum.TransportMode`: PERSON=0 CARGO=1 CAR=2 BUS=3 TRUCK=4 TRAM=5 ELECTRIC_TRAM=6 TRAIN=7 ELECTRIC_TRAIN=8 AIRCRAFT=9 SHIP=10 SMALL_AIRCRAFT=11 SMALL_SHIP=12 (determines the transport modes a line can use, **independent of the line having vehicles**)
  - **Key**: the `Line` component (type 63) has a `vehicleInfo LineVehicleInfo` field whose `transportModes {int,...}` are "the transport modes usable by the line" -- works for new empty lines too, more reliable than the original `lineHasType` (relying on the carrier from `getLineVehicles`)
  - `transportModes` of `LineVehicleInfo` may be an array or a bitmask; the code supports both (bitmask checked via `math.floor(modes / 2^w) % 2`, compatible with Lua 5.1/5.2)
  - `ComponentType`: BASE_EDGE=5, BASE_EDGE_STREET=6, BASE_EDGE_TRACK=7 (edge has a BASE_EDGE_TRACK component = track)
  - `stationSystem.getStation2edgesMap()` returns `{[stationEntity]={{EdgeId,int},...}}`; EdgeId has `.edgeId` (TRANSPORT_NETWORK entity) and `.index` (index into the edges array)
  - The `TRANSPORT_NETWORK` component's `edges {Edge,...}` array; `edges[index]` is a TransportEdge
  - `lineSystem.getLineStops(stationGroupEntity)` returns `{{lineEntity,int},...}` (lines stopping at that station group)
- **Implementation** (`timetable_helper.lua`):
  - `lineHasType` enhanced: prefers `lineObject.vehicleInfo.transportModes` (independent of vehicles), falls back to the vehicle carrier
  - `getAllRailLines` **doesn't filter** and returns all lines (the timetable needs all lines); the diagram's rail filtering is done on the `diagram_gui.lua:getAllTimetableData` side
  - New `isRailStation(stationEntity)`: prefers `getStation2edgesMap` + TRANSPORT_NETWORK edges + `BASE_EDGE_TRACK`, falls back to a reverse check via `getLineStops` (definitely non-rail lines and no rail lines -> non-rail station; undecidable -> kept conservatively)
  - `getAllStationEntities` filters out non-rail stations (`isRailStation`)
- **Key correction (positive filtering wrongly removed lines)**: initially `getAllRailLines` **filtered positively** with `lineHasType(l,"RAIL")` -- if reading the `transportModes` field failed and it fell back to the vehicle check, **empty lines (no vehicles) were misclassified as non-rail and filtered out**, so several real railway lines and their **waypoints** disappeared from the line list/station list (log: `allStations=10` dropped from 22, `lineList names` only 1 left). With reverse filtering, empty lines are kept and waypoints are back
- **Crash fix (userdata field access without pcall)**: `lineHasType` accessed `lineObject.vehicleInfo.transportModes` directly -- lineObject is userdata; without a `vehicleInfo` field it throws a Sol2 error (the error value is a **function object** like `function: 0x...`), and a crash inside `stationSystem.forEach` of `getAllStationEntities` aborts the traversal, losing all following stations (showed up as "station 3 filtered out", while actually forEach crashed at the 4th station). Fix: the whole field access chain wrapped in pcall; `isRailStation`'s main path/fallback traversal wrapped in pcall; each station's `isRailStation` in `getAllStationEntities` wrapped in pcall, kept conservatively on failure
- **Files**: `timetable_helper.lua` (lineHasType, getAllRailLines, isRailStation, getAllStationEntities)
- **Risk**: the field name for edge -> base edge in `getStation2edgesMap` (`edge.edge/entity/baseEdge`) isn't documented clearly; protected with pcall + fallback logic, with a `filteredStation` diagnostic log added; the `transportModes` field path `lineObject.vehicleInfo.transportModes` likewise needs verification via logs
- **Iteration progress (2026-07-31)**:
  - After the crash fix, `filteredBus=0` (bus stops not filtered) -- suspected that the `getStation2edgesMap` keys don't match stationEntity (log `hasEdgesEntry=false`), breaking the main path, and the `getLineStops` fallback returned nothing, so everything was kept conservatively
  - Improved: `isRailStation`'s main path tries both keys `edges[stationEntity]` and `edges[sgEntity]`; new `railStationGroupCache` (collects the set of station groups by iterating stops of definitely-rail lines, as the most reliable criterion); the fallback now prefers `getLineStopsForStation(stationEntity)`
  - **Key finding (proven by logs)**: `transportModes` is actually **userdata** (not an array/number). **Note**: `#`/indexing on userdata risks a C++ exception (pcall may not catch it); the final approach **skips handling transportModes userdata and falls back directly to the vehicle carrier check** (see the entry "Timetable/diagram filtering separated"). Bus line 1 is recognized by `lineHasType(bus1,"ROAD")` (`line filtered (non-rail)`), but the `getLineStops` fallback of `isRailStation` couldn't extract line entities for bus stops (`lineStops=()` means entry[1] didn't yield a line), so they slipped through via `unknown -> RAIL(keep)`
  - **Solution**: new `nonRailStationGroupCache` (collects the set of station groups by iterating stops of definitely non-rail lines); after the rail station group check and before the track edge check, `isRailStation` classifies a station group that only appears in non-rail line stops as NONRAIL and filters it. Sidesteps the uncertain structure of `getLineStops`
  - **Verified (proven by logs)**: all bus stops filtered successfully (`filteredBus=6`, filtered Fasil Road / Ma Tau Chung Raoad / Granville Road etc.), the pure rail station 3 kept (`lineStops=0 -> RAIL(keep)`), station list 22 -> 14. `getLineStops` returns `entry=number` (the line entity directly, not `{line,int}`); the line extraction logic already supports it


### Timetable time input losing values (13:30 becomes 00:30)
- **Symptom**: after the user entered a time (e.g. 13:30) and clicked elsewhere, it sometimes wasn't saved/was reset (00:30)
- **Root cause**: all `DoubleSpinBox:onChange` callbacks in `timetable_gui.lua` called `timetableGUI.initStationTable()` + `fillStationTable()` to rebuild the station table. `onChange` **fires per keystroke** while typing (typing "1" -> "3" -> "0" -> "3" fires once each), and each time the whole station table was rebuilt -> interrupting the SpinBox input focus/value, causing random value loss
- **Fix**: removed the `initStationTable()`/`fillStationTable()` rebuild calls from `onChange`, keeping only the data writes (`updateArrDep`/`updateDebounce`/`updateWaypointPassingTimeEntry`) + `timetableChanged = true`. The station table summary is now refreshed when switching constraint types/adding/removing (operations that should rebuild anyway)
- **Files**: `timetable_gui.lua` (makeArrDepWindow 4 SpinBoxes, makeDebounceWindow 2, makePassingWindow 2)
- **Lesson**: `DoubleSpinBox:onChange` fires per keystroke; never rebuild the UI in the callback (interrupts input); separate data saving from UI refreshing

### getOrderOfArray crash sorting a sparse hash table
- **Symptom**: the timetable popup wouldn't open, `timetable_helper.lua:833: attempt to index local 'a' (a nil value)`
- **Root cause**: `getOrderOfArray` built `toSort[k] = {key=k, value=v}` with `pairs(arr)`, where k is non-contiguous (even sparser after filtering in `getAllRailLines`). `table.sort` requires a contiguous array; with nil elements the comparison function crashed on `a.value`. It had worked before because without filtering the key gaps were small/happened to be contiguous
- **Fix**: `toSort` is now a contiguous array (`toSort[#toSort+1] = {key=k, value=v}`), the comparison function got nil protection + `tostring`; return semantics unchanged (`res[k-1] = v.key - 1`)
- **Files**: `timetable_helper.lua:getOrderOfArray`

### Timetable/diagram filtering separated (getAllRailLines back to not filtering)
- **User requirement**: the timetable shows **all** lines (bus/rail/road/tram all shown); only the diagram filters for rail lines. The two filters are independent
- **Root cause**: to filter bus lines for the diagram, `getAllRailLines()` had been made to filter too, but the timetable (`timetable_gui.lua:403,560,568`) also uses it -> bus/road lines disappeared from the timetable, and clicking the road filter button gave an Internal error
- **Fix**:
  1. `getAllRailLines()` back to **returning all lines** (unfiltered) -- used by the timetable
  2. The diagram's `getAllTimetableData` **does its own reverse filtering** (excludes lines that are definitely ROAD/TRAM/WATER/AIR, empty lines kept conservatively) -- only effective on the diagram side, skipping non-rail lines via `goto continueLine`
- **Addition (userdata handling)**: `lineHasType` no longer does `#`/indexing on `transportModes=userdata` -- `#` on userdata may trigger a C++ exception (not catchable by pcall, causing the Internal error when clicking the road filter button). Changed to skip the transportModes check and fall back directly to the vehicle carrier check (the original, reliable way)
- **Files**: `timetable_helper.lua:getAllRailLines, lineHasType`, `diagram_gui.lua:getAllTimetableData`
- **Lesson**: when shared utility functions are used by several UIs, distinguish their data needs; filtering belongs on the using side, not in the shared function; `#`/indexing on userdata risks C++ exceptions that pcall can't necessarily catch

### Timetable window reopen crash: FloatingLayout::RemoveItem assert
- **Symptom**: reopening the timetable window after it was displaced by the diagram window crashed with `FloatingLayout.cpp:113: RemoveItem: Assertion 'it != m_vecItems.end()' failed`
- **Root cause**: after the reopen path created a new `UIState.boxlayout2`, `initLineTable`/`initStationTable`/`initConstraintTable` called `UIState.boxlayout2:removeItem(menu.scrollArea/stationScrollArea/...)` -- the old components belonged to the **old layout** (possibly destroyed with the window), so removeItem couldn't find them in the new layout -> C++ assert. **pcall can't catch C++ asserts** (key lesson in AGENTS.md); the code path must be prevented from running
- **Fix**:
  1. The reopen path of `showLineMenu` first **resets all old component references to nil** (scrollArea/lineHeader/stationScrollArea/stationTable/scrollAreaConstraint/constraintTable), then creates the new layout -> the init functions take the `else` branch (create directly, no removeItem)
  2. The reopen path now also calls `initStationTable()`/`initConstraintTable()` (the original code only called initLineTable)
  3. The init functions keep removeItem (avoids duplicate addItem on repeated calls during normal operation), relying on the reopen path resetting the references
- **Files**: `timetable_gui.lua` (showLineMenu, initLineTable, initStationTable, initConstraintTable)
- **Lesson**: C++ asserts can't be caught by pcall; the only way to prevent the crash is to **not let the code path that triggers the assert run** (reset old component references so the removeItem branch isn't entered)

### Diagnostic log cleanup
- Temporary diagnostic logs added for debugging this round were removed: `lineHasType transportModes`, `getStation2edgesMap keys`, detailed `isRailStation` paths, per-entry `filteredStation`, `getAllStationsFlat selected`, `getYMap groups`, `stationLabel sort`
- Kept: the `getAllStationEntities stations=... filteredBus=...` summary line, the pre-existing `getAllRailLines` log, the pre-existing `getAllStops` classification log

### Load crash from a wrongly added local function prefix during log cleanup
- **Symptom**: crash on loading a save, `error loading module 'celmi/timetables/timetable_helper' ... :215: '(' expected near ''`; the timetable popup also wouldn't open (require failure chain)
- **Root cause**: while cleaning up diagnostic logs, `function timetableHelper.lineHasType(...)` was accidentally changed to `local function timetableHelper.lineHasType(...)` -- `local function` can only be followed by a local variable name, not a dotted member expression (`timetableHelper.lineHasType`), triggering the syntax error `'(' expected`
- **Fix**: removed the wrongly added `local` prefix, restoring `function timetableHelper.lineHasType(...)`
- **Lesson**: run the syntax check file by file when cleaning up code; module member functions use `function table.member()`, not `local function table.member()`

## Completed features
### Waypoint detection (`timetable_helper.lua`)
- `getAllStops()` -- flattens stations + waypoints into an ordered list
- Waypoints are stored in `Line.Stop.waypoints` (userdata); length via `#`, values via numeric index
- Each waypoint ID has the format `"wp_K_I"` (K = stop index, I = number of the waypoint after that stop)

### Data storage (`timetable.lua`)
- `waypointTimes[wpKey]` -- array of passing times
- `waypointNames[wpKey]` -- custom names
- `diagramConfig` -- runtime configuration, no longer used for persistence

### Timetable UI (`timetable_gui.lua`)
- Waypoint display and passing time editing
- Arr/dep time / unbunch condition editing
- Added the `_G._diagramForceSync` flag + `guiUpdate` sync hook

### Diagram UI (`diagram_gui.lua`)
- **Preset system**: the first level is a list of "railway line" configurations, with + to add / X at the end of a row to delete (with confirmation popup)
- **Station/waypoint sorting**: an expanded preset shows all stations/waypoints, each with a checkbox + sort input (1-256)
- **Y axis merging**: stations/waypoints with the same sort number are merged onto the same horizontal reference line
- **"Save" button**: saves the preset + draws the diagram + shows the related lines
- **Collapsed by default**: all presets are collapsed when the window opens and must be expanded manually
- **Line list**: a scroll bar allows viewing all related lines; each item has a fixed height to be shown completely

### Persistence approach (key implementation)
- Preset data and line colors are stored in `timetableObject[hostLineId].dp`
- The `_G._diagramForceSync` flag triggers `sendScriptEvent("timetableUpdate")` in `guiUpdate` to sync to the engine thread
- The engine thread's `update` makes sure every frame that all line entries have a `dp` field (so it isn't dropped by deep copies)
- When saving, `state.timetable` includes the `dp` data, restored on load

### Data storage structure
```
timetableObject[hostLineId].dp = {
    presetList = {
        { id = "1", name = "Beijing-Shanghai HSR",
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

stableKey format: station -> `"s_<entityID>"`, waypoint -> `"wp_K_I_lineID"` (K = stop index, I = waypoint number, lineID = line entity ID)

## To do
(nothing for now)

## Completed features (added 2026-07-29, this round)

### Polyline connections with multiple slot sets fixed
- **Requirement**: a line makes several round trips per cycle, and each station has several arr/dep slot sets (e.g. 3 sets = 3 round trips). The old logic drew groups by array index g=1,2,3; the first set's arrival at the terminus (e.g. 59:00) is a loop slot, drawing a long segment of 44.5 minutes.
- **Approach 1, closing segment connects to the next set**: `nextG = (g % maxG) + 1` -> the end of set g's track connects to the arrival time of set g+1. With a single set, `(1%1)+1 = 1` keeps the original behavior.
- **Approach 2, dwell line between sets**: for `g < maxG`, append `nextG`'s departure point -> adjacent tracks form a horizontal dwell line at the terminus; the last set doesn't loop back to the first.
- **Approach 3, terminus detection fixed**: the old `fIdx < #ld.stations` assumed the last station is always the terminal return, but a line may have only 4 stops (stn1->stn2->stn3->stn2), in which case stn2 on the way back was wrongly treated as the terminus and its departure skipped. Changed to `isTerminalReturn = (key == firstKey and fIdx == #ld.stations)`, so the departure is only skipped on a real return to the same station.
- Files: `diagram_gui.lua:578-632` (refreshDiagram drawing loop)

### Line list tick control + shared color button
- **Tick control**: a checkbox before each line name, all ticked by default. Unticking -> `refreshDiagram` skips that line. State is persisted via `preset.lineData = { [lineId] = bool }`, deep-copied on both save and load.
- **Shared color button**: removed the separate color button of each line; a shared button next to the "Line list" title -> if there are selected (bold) lines, opens the color picker and changes the color of all selected lines at once, double-written and saved immediately (`diagramConfig` + `timetableObject.dp.colorList` + `api.cmd.make.setColor` to sync the game's line color). Does nothing without selected lines.
- **Selection highlight**: after clicking a line name to select it, the name is shown wrapped in brackets as `[line name]`.
- **Files**: `diagram_gui.lua`
  - `getAllTimetableData()` -- lineData gets `checked = true`
  - `refreshDiagram()` -- skips lines with `ld.checked == false`
  - `updateLineList()` -- checkbox + nameView + colored swatch
  - `toggleLineSelection()` -- updates the nameView text after a click (bracket highlight)
  - `showDiagram()` -- shared color button in the title bar
  - `saveCurrentPreset()` -- saves the check state of `displayedLines` to `preset.lineData`
  - `applyPresetToStations()` -- applies `preset.lineData` to `allLines`
  - `loadPresetsFromTimetableObject()` / `savePresetsToTimetableObject()` -- deep-copied read/write of lineData

### Colored line swatches (diagram + timetable)
- **Diagram**: after each line name, a filled swatch rendered with a `LineRenderView` + stacked horizontal line segments (10x10 swatch in a 14x14 container, line width 2, spacing 2); the color is set directly to the chart's custom RGB via `setColor(Vec4f)`, supporting any color.
- **Timetable**: the same kind of `LineRenderView` swatch (20x20 swatch in a 28x28 container, line width 4, spacing 2); the color is read via `getLineColourVec4(lineId)` directly from the engine's COLOR component (`api.engine.getComponent(line, api.type.ComponentType.COLOR)` -> `.color: Vec3f`), i.e. the actual color from the line manager, not relying on CSS preset colors.
- **New**: `timetable_helper.getLineColourVec4(line)` -- returns a `Vec4f` for `LineRenderView.setColor`.
- Files: three places in `timetable_gui.lua` (`fillLineTable`, `fillStationTabLineTable`, `fillWaypointTabLineTable`), `diagram_gui.lua:updateLineList`

## Fixed crashes (history)
- Files: `diagram_gui.lua:578-632` (refreshDiagram drawing loop)

## Fixed (2026-07-29)

### Entity-level deduplication of waypoints
- **Problem**: when the same waypoint entity appeared on several lines, the diagram preset configuration showed several waypoints with the same name
- **Root cause**: `getAllStops()` used the positional concatenation `"wp_K_I"` as ID, and `uniqueKey` also included `lineID`, so waypoints of the same entity got different keys and the `stableKey` deduplication in `getAllStationsFlat()` didn't work
- **Fix**:
  1. `timetable_helper.lua`: new `wpEntityIdCache` (userdata -> counter mapping) for deduplication, `getWpPersistentKey()` (`"gwpk_sgEntity_i_name"`) generates a persistent global name key so names are consistent across saves and lines; `id` keeps the old format `"wp_K_I"` for compatibility with saved time data
  2. `diagram_gui.lua`:
     - `stableKey()` signature extended to `(stopType, id, uniqueKey, entityId)`; waypoints are deduplicated via `"wp_" .. entityId`
     - `getAllStationsFlat()`: passes entityId, only the first one goes into the list
     - `getYMap()`: waypoint matching now uses `st.entityId == s.entityId`, iterating over all line mappings
     - `getRelevantLines()`: new `wpEntityIds` set, waypoints matched by entityId
     - `saveCurrentPreset()` / `applyPresetToStations()`: stableKey calls now pass entityId
     - stableKey calls of the label dedup updated accordingly
- **Impact**: waypoint ticks/sort numbers in old presets are reset; station configuration is unaffected
- **Files**: `timetable_helper.lua:1-15,392-445`; `diagram_gui.lua:276-278,299-323,329-370,396-437,756-788`

### Only one diagram station/time label rendered
- **Problem**: the station labels on the left + time scale at the bottom sometimes only showed the first one, the others not
- **Root cause**: in `refreshDiagram()` all label components shared the same name (`"stCont"` / `"tmCont"`); the TPF2 component system may ignore later `addItem`s due to the duplicate name, silently swallowed by the outer `pcall`
- **Fix**: station labels -> `"stCont_" .. idx`, time labels -> `"tmCont_" .. m`, ensuring uniqueness
- **Files**: `diagram_gui.lua:507,533`

### Timetable window X button sometimes doesn't close it
- **Root cause**: `onClose` only cleared `menu.lineTableItems`, not `clearConstraintWindowLaterHACK`. The user edits time data and closes the window right away -> `onClose` fires -> in the next frame `guiUpdate` runs the leftover HACK -> rebuilds the UI -> interferes with closing
- **Fix**: `onClose` now also sets `clearConstraintWindowLaterHACK = nil` + `timetableChanged = false`
- **Important**: must not set `menu.window = nil`; the timetable window relies on `menu.window ~= nil` to take the `setVisible(true, true)` reopen path (instead of `Window.new()`); setting it to nil cuts off the reopen path and the button gets stuck
- Files: `timetable_gui.lua:332-339`

### Time data occasionally back to 0:00 after editing, closing and reopening (value 0 silently dropped)
- **Root cause**: the parameter checks of `updateArrDep` / `updateDebounce` / `updateWaypointPassingTimeEntry` used `if not (... and value) then return -1`. That fails when the user sets minutes/seconds to 0 (the check treated 0 like a missing value), and the data was **silently dropped without being written to `timetableObject`**. The next UI rebuild read back the old value
- **Fix**: all three changed to explicit `== nil` comparisons: `if line == nil or station == nil or ... or value == nil then return -1 end`
- Files: `timetable.lua:170-171, 185-186, 243-244`

### `getConditions` returning -1 breaks the `or {}` fallback
- **Root cause**: on failure `getConditions` returned `-1` (a number), which is truthy, so `getConditions(...) or {}` in `diagram_gui.lua:274` degraded to `-1` instead of `{}`
- **Fix**: both `return -1` changed to `return nil`; `waitingRequired` got an `if not condition then return false end` nil guard
- Files: `timetable.lua:122-131, 397-398`

### Diagram window forcing the timetable window open/resetting it
- **Root cause 1**: after creating its window, `showDiagram()` unconditionally called `_G._timetableWindow:setVisible(true, true)`, even if the timetable was closed
- **Root cause 2**: `setVisible(true, true)` recomputes the default position, moving an already open timetable window back to its original position
- **Fix**:
  1. New `_G._timetableVisible` flag (maintained in both paths of `showLineMenu` and in `onClose`)
  2. `showDiagram()` saves `ttWasVisible = _G._timetableVisible` before creating the window and only restores if true
  3. The restore call changed to `setVisible(true, false)` to avoid resetting the position
- Files: `timetable_gui.lua:282,327,338`; `diagram_gui.lua:1124-1129`

## Fixed (this round, 2026-07-27)

### Waypoint key collision made new waypoints not show up
- **Root cause**: `uniqueKey` for waypoints was only `"wp_K_I"` (without `lineID`), so waypoints with the same index on different lines collided. On top of that, `stableKey` added another `"wp_"` prefix for waypoints, so the actual key was `"wp_wp_K_I"` (double prefix), inconsistent with the protocol `"wp_<unique id>"` recorded in AGENTS.md
- `getAllTimetableData`: waypoint `uk` now always includes `lineID` -> `"wp_K_I_lineID"`
- `stableKey`: removed the redundant `"wp_"` prefix; waypoints return `uniqueKey` directly
- **Impact**: waypoint ticks/sort numbers in old presets are reset (need to be ticked again once); station configuration is completely unaffected
- Files: `diagram_gui.lua:207-209`, `:233-235`

### Diagram window wouldn't open without timetable data
- **Root cause**: `getAllTimetableData()` only collected lines with `hasTimetable == true`, and `showDiagram()` returned early when `#lineDataList == 0`
- `getAllTimetableData`: removed the `if timetable.hasTimetable(lineID) then` filter, now collects all lines (entry.times is empty without a timetable)
- `showDiagram`: removed `if #lineDataList == 0 then return end`
- **Impact**: the diagram window can be opened on a new map without timetable data, presets can be managed normally; an expanded preset shows an empty station list
- Files: `diagram_gui.lua:189-227`, `:793`

## Fixed (2026-07-26)

### Sort number DoubleSpinBox crash
- **Root cause**: in Lua `0 or 1 = 0` (0 is truthy), so a sort number of 0 doesn't trigger the `or` fallback
- `d.sort or 1` in `applyPresetToStations` / `saveCurrentPreset` -> changed to `(type(d.sort) == "number" and d.sort > 0 and d.sort <= 256) and d.sort or 1`
- `sp:setValue(st.sort, false)` in `rebuildPresetList` -> added a range check + wrapped in `pcall`
- Files: `diagram_gui.lua:542-543`, `:556`, `:725-726`

### Double storage -> single source of truth
- **Root cause**: two copies, `diagramConfig._dpPresetList` and `timetableObject[hostLineId].dp`; after the game's deep copy the two copies were independent and out of sync, and on load `diagramConfig._dpPresetList` was read first -> stale data
- `loadPresetsFromTimetableObject`: removed the branch preferring `cfg._dpPresetList`, always loads from `timetableObject[hostLineId].dp`
- `savePresetsToTimetableObject`: removed the code writing the redundant copies `cfg._dpPresetList` / `cfg._dpColorList`
- Files: `diagram_gui.lua:91-114`, `:116-146`

### Deep copies prevent reference leakage (all line configurations overwritten)
- **Root cause**: `localPresets[i].stationData` and `dp.presetList[i].stationData` shared the same Lua table reference. When `guiUpdate -> sendScriptEvent -> handleEvent` triggered the cross-thread deep copy, the shared references broke, copies of different presets could point to the same nested objects, and quick successive saves merged all configurations into one
- `savePresetsToTimetableObject`: deep-copies each `stationData` when writing `dp.presetList`
- `loadPresetsFromTimetableObject`: deep-copies each `stationData` when reading `dp.presetList`
- Deep copies on both save and load keep each preset's `stationData` independent throughout
- Files: `diagram_gui.lua:98-105`, `:135-143`

### Crash protection for clicking lines
- **Root cause**: when the diagram failed to render, `displayedLines` kept references to old buttons; `updateLineList`'s `setContent` destroyed the old buttons, leaving dangling references, and calling `setEnabled` failed the C++ type check
- `toggleLineSelection`: `colorButton:setEnabled` wrapped in `pcall`
- `refreshDiagram`: added an early return when `menu.renderLayout` is nil
- Files: `diagram_gui.lua:496`, `:345`

## Completed (this round)
### Diagram labeling system
- **Station name labels** (station names only, waypoints filtered, aligned with the reference lines): `diagram_gui.lua:refreshDiagram`
  - Uses an `AbsoluteLayout` as container; each station name is wrapped in a fixed-size Component -> BoxLayout
  - Placed at the exact Y coordinate from `stationToY` via `addItem(cont, Rect.new(x, y, w, h))`
  - Iterates sorts in reverse (consistent with the reference line direction), rebuilt after `deleteAll()` each time
- **Time scale** (0-60 minutes, every 5 minutes): `diagram_gui.lua:refreshDiagram`
  - Same AbsoluteLayout + fixed Component wrapper approach
  - Uses `invokeLater` to defer `ra:getContentRect()` and `tlc:getContentRect()` to get the real screen coordinates
  - X offset = `raRect.x - tlcRect.x`, distribution width = `dw` (consistent with the grid lines), Y = `raRect.y + raRect.h - tlcRect.y + 14`
  - Rebuilt after `deleteAll()` each time

### API discoveries
- The parameters of `FloatingLayout.addItem(x, y)` are **alignment values** (0/0.5/1), not coordinates
- `AbsoluteLayout.new()` works without parameters (the docs say `new(orientation)`, but passing a parameter crashes)
- The `AbsoluteLayout.addItem(comp, Rect)` signature matches C++ `addItem(ILayoutItem*, CRect)`
- `AbsoluteLayout.deleteAll()` and `setPosition(idx, x, y)` both work normally
- `removeItem` belongs to the `layout.ILayout` base class and is available on all layouts
- `getContentRect()` only returns non-zero values after `invokeLater` (once the layout is done)

### Layout corrections
- The window title bar takes ~30px; introduced `TITLE_BAR_H=30`, all height computations use `WINDOW_HEIGHT - TITLE_BAR_H - TIME_LABEL_HEIGHT`
- The time label bar `tlc` has the same width as `da` (920px); label X is aligned to the render area via `offsetX`

### Persistence fixes
- Also store `diagramConfig._dpPresetList/_dpActivePresetId/_dpColorList`, fixing save loss caused by the script thread and the game_script thread having different `timetableObject` instances
- `loadPresetsFromTimetableObject` reads from `diagramConfig` first

## Fixed (this round, 2026-07-28)

### Drawing the diagram across cycles (core refactor)
- **Requirement**: when a train's round trip exceeds the 60-minute cycle, the diagram correctly shows polylines crossing the boundary (standard railway diagram style)
- **Root cause**: the old code sorted all points by X coordinate before connecting them, so points across the boundary were sorted wrongly and the 57->5 minute leg was lost; stops crossing the cycle within a station (arr>dep) produced reversed horizontal lines
- **Solution**:
  1. **Unrolling time**: iterate in route order of `getAllStops()`, maintaining a cumulative `timeOffset`. When `(timeOffset + arr) < prevDep` is detected, +3600 for the next cycle
  2. **Cycle crossing within a station**: automatically +3600 when `uwDep < uwArr` (handles arrival at 45 / departure at 0)
  3. **Splitting segments at the boundary**: `drawWrappedSegment(lv, t1, y1, t2, y2, dw)` detects cycle crossings via `floor(t/3600)` and draws the pieces with Y linearly interpolated by time
  4. **Boundary X coordinate fix**: use `s - c*3600` instead of `s % 3600`, so 60:00 (3600s) maps correctly to the right edge X=dw, not 0
  5. **First/last station handling**: fIdx=1 draws no arrival (only the departure dot), fIdx=N draws no departure (only the arrival dot)
  6. **Loop closure**: when the first and last stations have different Y, add a cyclic wrap (only the arrival, not the departure); skipped with the same Y to avoid a trailing horizontal line
  7. **No more dependence on sorting**: no more `table.sort(pts, ...)`, iterate in route order via `ipairs(ld.stations)` instead
- **Files**: core line drawing logic in `diagram_gui.lua` `refreshDiagram()` (~100 lines rewritten)

### Colors persisted by double-writing
- **Root cause**: changing a color only wrote `diagramConfig.lineColors`, not `timetableObject.dp.colorList`. `diagramConfig` is a module-level `local` and is lost when the Lua VM reloads the module -> after refreshing/reopening the window, colors went back to old values
- **Solution**:
  - Color picker `onColorChanged`: writes `diagramConfig.lineColors` + `timetableObject.dp.colorList` at the same time + triggers `_diagramForceSync`
  - `doRefreshData()` and the reopen path: first reload from `timetableObject.dp.colorList` into `diagramConfig`, then `getAllTimetableData`
- **Files**: `diagram_gui.lua:354-371` (double write), `:901-922` (doRefreshData), `:969-981` (reopen path)

### Color picker crash fix
- **Root cause**: `timetable_helper.lua:getLineColour()` had no pcall protection; calling `getComponent` on a deleted line crashed with "Invalid entity"
- **Fix**: wrapped in `pcall(function() return api.engine.getComponent(...) end)`
- **Files**: `timetable_helper.lua:191-200`

### Refresh button
- **Requirement**: after changing time data, the user wants to see the diagram live without closing the window/clicking save
- **New** `doRefreshData()`: re-fetches `getAllTimetableData()` + reloads colors + redraws the diagram, without modifying presets
- **UI**: the refresh button sits right of the save button, sharing a `BoxLayout("HORIZONTAL")` row
- **Translation**: added `diagram_refresh_i18n` to `strings.lua` (7 languages)
- **Files**: `diagram_gui.lua:901-922`, `:1002-1008`

### Timetable and diagram windows coexisting
- **Root cause**: opening the timetable window first and then the diagram window -> when `Window.new()` creates the new window, the TPF2 engine displaces the existing one
- **Solution**:
  1. `timetable_gui.lua` saves the timetable window to `_G._timetableWindow` after creating it
  2. After first creating its window, `diagram_gui.lua:showDiagram()` calls `_G._timetableWindow:setVisible(true, true)` via `invokeLater` to restore the timetable window
  3. Reopening no longer calls `close()` and rebuilds, but `setVisible(true, true)` + refreshes the data
- **Files**: `timetable_gui.lua:324-325`, `diagram_gui.lua:969-981,1108-1112`

### Preset management fixes
- **Deleted presets coming back**: deleting only changed `localPresets` without persisting -> added `savePresetsToTimetableObject()` to persist immediately
- **Presets overwritten on reopen**: the reopen path called `loadPresetsFromTimetableObject()` -> read deleted/changed presets in memory back from the old save -> removed that call, only colors are reloaded
- **Line list shown without an expanded preset**: on reopening the window, `getActivePresetId()` -> `applyPresetToStations()` silently applied the last preset -> removed the auto-apply logic
- **Files**: `diagram_gui.lua:828` (save on delete), `:969-981` (no preset loading on reopen), `:963-964` (auto-apply removed)

### Waypoints shown in the station tab
- **Requirement**: the station tab of the timetable window shows both stations and waypoints; clicking a waypoint shows its passing times
- **New** `timetable.getAllWaypointData()`: iterates over the `waypointTimes` of all lines, grouped by `gwKey`
- **UI**: `fillStationTabStationTable` merges stations + waypoints (waypoints prefixed with `▶`), sorted alphabetically
- **New** `fillWaypointTabLineTable(gwKey)`: shows the lines passing that waypoint and their passing times
- **Files**: `timetable.lua:511-537`, `timetable_gui.lua:96-205`

### Crash fix for pasting waypoint names
- **Scenario**: the user types a name outside the game -> Ctrl+C -> Ctrl+V in the game, and the game crashes
- **Crash chain**:
  1. Pasting triggers `TextInputField.onChange` -> sets `timetableChanged = true`
  2. Pasting may cause a brief focus loss -> `onFocusLost` sets `clearConstraintWindowLaterHACK`
  3. In the next frame `guiUpdate` runs the HACK -> calls `makePassingWindow()` to rebuild the UI -> `fillStationTable()` -> `getAllStops(lineID)`
  4. During the rebuild the line entity for `lineID` may have been deleted -> `api.engine.getComponent()` without pcall protection -> Sol2 "Invalid entity" crash
- **Fix**:
  1. The body of the `nameInput:onChange` callback wrapped in `pcall` (`timetable_gui.lua:956-964`)
  2. `onFocusLost` no longer has the `if clearConstraintWindowLaterHACK then return end` race check, allowing it to overwrite an old HACK (`:965-974`)
  3. `api.engine.getComponent(line, ...)` in `getAllStops()` wrapped in `pcall`, safely returning `{}` when the line was deleted (`timetable_helper.lua:314-317`)
- **Files**: `timetable_gui.lua:956-974`, `timetable_helper.lua:314-317`

### Diagram station label rendering crash fix
- **Scenario**: clicking a line in the line list of the diagram window -> `toggleLineSelection` -> `refreshDiagram()` -> crash while rebuilding the station label `AbsoluteLayout`
- **Root cause**: `refreshDiagram()` runs `sll:deleteAll()` to clear the layout and at the same time registers an `invokeLater` callback at line 496 that later operates on `menu.timeLabels.component`. When clicking several lines in quick succession, old `invokeLater` callbacks fire after the layout was cleared, `getContentRect()` returns garbage, and passing it to `Rect.new()` causes a Sol2 type exception
- **Fix**:
  1. The whole station label section (lines 459-493) wrapped in `pcall`
  2. The `invokeLater` callback body wrapped in `pcall` + `menu.stationLabels.component` validity checked before registering
- **Files**: `diagram_gui.lua:459-532`

### Full pcall hardening
- **Background**: several earlier crashes were all caused by `api.engine.getComponent()` without pcall protection. `timetable_helper.lua` had 20 such calls, only 5 of them with pcall before
- **Fix**: all 15 remaining ones wrapped in `pcall`:
  - GUI thread functions: `getTrainLocations`, `getLegTimes`, `getStation`, `getAllRailLines`, `getAllStations`, `getStationID`, `getTime`, `getAllStops` (waypoint name lookup)
  - Engine thread functions: `getCurrentStation`, `getCurrentLine`, `isInStation`, `getPreviousDepartureTime` (2 places), `getTimeUntilDeparture`, `lineHasType`
- **Files**: `timetable_helper.lua` (all 20 `getComponent` calls in the file now use pcall)

## Key lessons learned

### Rules for using the `_()` translation function
1. **Only call it at module load time** (in table constructors); at runtime use local variables
2. **Never use `_` as a throwaway loop variable inside any function that calls `_()`** (`for _, x in`)
3. The `_()` context differs between the engine thread and the GUI thread; capturing at load time is safest
4. **strings.lua is only loaded at game start**; hot-reloading modules doesn't update translations -> new i18n keys require a full game restart

### When to create UI components
1. `TextInputField` isn't usable in the synchronous flow of `showDiagram()`; it must be deferred to the next frame via `invokeLater`
2. `TextInputField.new("")` requires an argument; without one it triggers a Sol2 binding error
3. Replacing layout content via `setContent` affects the UI tree synchronously; mind the execution order

### Data persistence
1. `pairs` iteration order is not deterministic; anything involving key selection must sort explicitly
2. The only cross-thread data sync is `timetableObject` (via the `timetableUpdate` event); `diagramConfig` is not synced
3. Garbage data accumulates across saves and must be cleaned up actively when saving
4. **Double-write principle**: key data (colors, names) should be written to both `diagramConfig` + `timetableObject`; the former for fast reads at runtime, the latter survives module reloads and syncs across threads

### Entity type pitfalls in Sol2
1. **Entities aren't necessarily numbers**: `v.stationGroup` returns a number, but `v.waypoints[i]` returns userdata. `tonumber(userdata)` = `nil`, and `tostring(userdata)` contains a memory address that changes every time
2. **Using entities as keys is unreliable**: use stable identifiers the program can compute (e.g. `stationGroup + waypointIndex`)
3. **Module-level `local` variables don't survive resets**: the Lua VM may reload the module every frame, re-running `local diagramConfig = {}` -> data loss. Globals `_G.xxx` survive module reloads

### Time computations across cycles
1. **Compare the proposed value, not the raw value**: `(timeOffset + arr) < prevDep`, not `arr < prevDep`. The latter still wrongly triggers +3600 after a cycle has already been crossed
2. **Use subtraction, not modulo**: `(t - c*3600) / 3600` maps boundary values correctly, while `(t % 3600) / 3600` yields 0 instead of 1.0 at 60:00
3. **Detecting cycle crossings within a station**: `uwDep < uwArr` uses `<`, not `<=`, so waypoints (arr==dep) don't trigger it

### TPF2 window lifecycle
1. **`Window.new()` destroys existing windows**: the engine only allows one Window instance; creating a new window forcibly destroys the old one
2. **`addHideOnCloseHandler()` hides the window instead of destroying it**: when the user clicks X it's only hidden; the C++ object and all child components stay alive in the engine
3. **`onClose` fires on both hiding and destruction**: the callback can't tell whether the user closed it or the engine destroyed it
4. **Never give layouts a global ID to reuse them across windows**: the hidden window's old layout stays alive in the engine, `getById` returns the old reference -> new components are added to the old layout -> when `Window.new()` destroys the old window it destroys the old layout with it -> the new window references a destroyed layout -> crash
5. **C++ `assert()` can't be caught by Lua `pcall`**: `assert` calls `abort()` directly instead of throwing a C++ exception -> Sol2 can't convert it into a Lua error -> pcall is useless. The only way to prevent the crash is to not let code paths that may trigger the assert run

### AbsoluteLayout and replacing layouts
1. **`setLayout()` can only be called once**: `CComponent::SetLayout` is guarded by `assert(!m_layout)`; once a component is bound to a layout it's permanent. To refresh content, only operate on the existing layout's items (`removeItem`/`addItem`); the layout object can't be replaced as a whole
2. **`deleteAll()` is unreliable**: `AbsoluteLayout:deleteAll()` may not fully clear the layout's internal state or component name registrations, making later `addItem`s partially fail. Prefer clearing old components **item by item with `removeItem()`**
3. **Component names must be unique across refresh cycles**: names of components removed via `removeItem` may not be released by the engine immediately, and creating a component with the same name next time conflicts. Append an increasing counter (e.g. `"stCont_3_1"`, `"stCont_3_2"`) so names never repeat
4. **Don't wrap layout loops in an outermost `pcall`**: once one item fails to be created, the outer `pcall` aborts rendering of all following items. Give each item its own `pcall` instead, so one failure doesn't affect the rest

## Fixed (2026-07-29, this round)

### Timetable/diagram window wouldn't open after being displaced (MemoryManager assertion crash)
- **Crash message**: `UI::MemoryManager::Remove<UI::ILayout>: Assertion 'it != m_data.end() && "Item is still owned by UI code."' failed.`
- **Root cause chain**:
  1. `showDiagram()` calls `Window.new()` -> the engine destroys the existing timetable window -> the timetable's `onClose` fires but `menu.window` stays non-nil
  2. When the timetable window is destroyed, its internal layout (`timetable.floatingLayout`) is cleaned up by the engine too
  3. `invokeLater` tries `_G._timetableWindow:setVisible(true, false)` to restore the window (half restored/invalid)
  4. The user clicks the timetable button again -> `showLineMenu()` sees `menu.window ~= nil` and takes the reopen path
  5. `initLineTable()` calls `UIState.boxlayout2:removeItem(menu.scrollArea)` -> the old component isn't in the new layout -> `MemoryManager::Remove` can't find the item -> assertion crash
- **Fix** (4 places):
  1. `timetable_gui.lua:showLineMenu()` -- reopen path wrapped in `pcall`, refreshing the `UIState.boxlayout2` reference before reopening. On failure, clear `menu.window = nil` and take the fresh creation path
  2. `timetable_gui.lua:initLineTable/initStationTable/initConstraintTable` -- all `getScrollOffset()` and `removeItem()` calls wrapped in `pcall`
  3. `diagram_gui.lua:showDiagram()` -- the whole reopen path wrapped in `pcall`; on failure, clean up state and create new
  4. `diagram_gui.lua:invokeLater` restoring the timetable window -- `_G._timetableWindow:setVisible` wrapped in `pcall`
- **Files**: `timetable_gui.lua:222-310`, `diagram_gui.lua:1036-1073,1262-1268`

### Key finding: C++ asserts can't be caught by Lua pcall
- **Observation**: the C++ `assert()` in `UI::MemoryManager::Remove` calls `abort()` directly instead of throwing a C++ exception. Lua's `pcall` relies on C++ exceptions being converted into Lua errors by Sol2, so **pcall can't catch C++ assert crashes**.
- **Lesson**: pcall only protects against Lua-level errors and some C++ exceptions converted by Sol2; it is powerless against assert crashes inside the engine. The only way to prevent the crash is to **never reach the code path that triggers the assert**.
- **Countermeasure**: in `onClose`, nil out all references to destroyed UI components (`menu.scrollArea = nil` etc.), so no code tries to operate on old components when reopening later.

### Full pcall hardening (2026-07-29)
- **Background**: several earlier crashes were all caused by missing pcall protection. After a full audit, pcall was added in bulk to all unprotected crash-prone API calls.
- `timetable_helper.lua`:
  - `api.cmd.sendCommand` in `startVehicle`/`stopVehicle` (3 places) -> pcall
  - `game.interface.getEntity` in `getFrequency` (1 place) -> pcall
  - `getLineVehicles` in `getTrainLocations`/`getVehiclesOnLine`/`lineHasType` (3 places) -> pcall
- `timetable_gui.lua`:
  - `initStationTab`: fixed a wrong nil check (checked `menu.stationTabScrollArea` but removed `menu.scrollArea`), now checks the right objects separately + pcall; `addItem` got a nil check for `UIState.floatingLayoutStationTab`
  - `showLineMenu` creation path: no longer calls `setGravity` when `getById` returns nil
  - `showLineMenu` creation path: `Window.new` protected with pcall
  - 6 line filter `onToggle` callbacks (18 `setVisible` calls): the whole callback bodies wrapped in pcall
  - `setScrollOffset` in 3 `invokeLater`s: wrapped in pcall
  - `sendScriptEvent` in `guiUpdate`: wrapped in pcall
  - the `gameInfo` layout changed from `getById("gameInfo"):getLayout()` to nil-checking the `getById` result first
- `diagram_gui.lua` (scripts):
  - `menu.renderLayout:removeItem(v)` in `refreshDiagram` -> pcall + nil check
  - 3 `Window.new` calls (creating the color picker x2 + confirmation popup x1) -> pcall
  - `Window.new` in the `showDiagram` creation path -> pcall
  - `rd.comp:setVisible` in `updateStationVisibility` -> pcall
  - the `menu.presetScrollArea:invokeLater` callback body in `rebuildPresetList` -> pcall
  - nil check in `refreshDiagram`: corrected to check `menu.timeLabels.component` (previously checked `menu.stationLabels.component` by mistake)

### Reused layout ID caused a crash when reopening after closing (this round, 2026-07-29)
- **Symptom**: the timetable opened the first time, but reopening it after closing -> `MemoryManager::Remove<ILayout>` assertion crash
- **Root cause chain**:
  1. On first open a `FloatingLayout` was created with `setId("timetable.floatingLayout")` and added to the window
  2. On close, `addHideOnCloseHandler` makes the window **only hidden, not destroyed**, so the old layout stays alive in the engine
  3. On reopening, `getById('timetable.floatingLayout')` returned the **old layout** reference
  4. `initLineTable` etc. **added the newly created components to the old layout**
  5. When `Window.new()` creates the new window, the engine first destroys the old hidden window -> the old layout is destroyed -> the new window's component tree references a destroyed layout -> crash
- **Fix**: removed the global `setId`/`getById` reuse mechanism for the layout; `showLineMenu()` creates a fresh `FloatingLayout.new()` on every open, stored in `UIState.boxlayout2` / `UIState.floatingLayoutStationTab`. Old and new layouts are completely isolated from each other.
- **Files**: `timetable_gui.lua:301-332`

## Fixed (2026-07-30, round #2)

### Preset list showing only 2 stations (the other 5 disappeared)
- **Symptom**: after expanding a preset, only 2 of 18 entries were visible, the rest weren't shown
- **Root cause**: `rebuildPresetList()` created all 18 station rows for all 5 presets (90 rows), hiding the rows of non-expanded presets via `setVisible(false)`. TPF2's BoxLayout still allocates layout space for invisible rows, so the expanded preset's station rows were pushed far away (total content height far beyond the 270px scroll area)
- **Fix**:
  1. Station row creation wrapped in `if isExpanded then`, so collapsed presets skip it
  2. Collapsing changed from `updateStationVisibility()` to `rebuildPresetList()`, removing the rows completely
  3. Added a `rebuildPresetList` log printing `expanded=` + `allStations=` counts
- **Files**: `diagram_gui.lua:893-1009`

### Getting all stations on the map (not just those served by lines)
- **Requirement**: diagram presets should show all train stations on the map (including those not served by any line), so users can draw an empty skeleton first and fill in runs later
- **Implementation**:
  1. New `getAllStationEntities()` in `timetable_helper.lua` -- iterates all station entities on the map via `api.engine.system.stationSystem.forEach()`, deduplicates via `stationGroupSystem.getStationGroup()` and returns a `{id, name}` list
  2. `diagram_gui.lua:getAllStationsFlat()` -- first collects line stations, then iterates map stations to add missing ones (`uniqueKey = "map_" .. sgEntity`)
  3. Map stations prefer the name from the line data (merged when names match)
- **Files**: `timetable_helper.lua:362-388`, `diagram_gui.lua:337-354`

### Map station names shown as default names instead of the user's renames
- **Root cause**: `getAllStationEntities()` looked up the NAME component on `stationEntity` (the station entity), but renames are stored on `stationGroup` (the station group entity)
- **Fix**: look up NAME on `sgEntity` (the station group entity) instead
- **Files**: `timetable_helper.lua:373`

### Waypoint ticks/sort numbers lost after saving and closing the window
- **Root cause**: the waypoint `entityId` in `getAllStops()` was generated by `getWpEntityId(wpRef)`, which used the userdata pointer as cache key. `v.waypoints[i]` returns a new userdata object on every call, so the cache never hit -> every `getAllStops()` round assigned a different `entityId` -> the `stableKey`s in the preset didn't match -> ticks/sort numbers lost
- **Fix**: the waypoint `entityId` now uses `getWpPersistentKey(wpRef, sgEntity, i)` (format `"gwpk_<parentStationID>_<index>_<waypointName>"`) -- based on the parent station entity ID + index + the engine NAME component, stable across calls
- **Files**: `timetable_helper.lua:483`

### Crash clicking a line checkbox on an empty diagram (no lines)
- **Root cause**: in `refreshDiagram()` the `drawDebug` variable was declared inside the `if #displayedLines > 0 then` block. With only pure map stations ticked and no related lines, the block was skipped -> `drawDebug` was nil -> `table.concat(nil)` crashed
- **Fix**: moved the `drawDebug` declaration outside the `if` block
- **Files**: `diagram_gui.lua:605`

### Drawing the diagram grid without any lines
- **Requirement**: let users see station labels + horizontal reference lines + time scale even without line timetable data, to plan the overall structure first
- **Fix**:
  1. `refreshDiagram()` no longer exits early on `#displayedLines == 0`; polyline drawing is wrapped in `if #displayedLines > 0 then`
  2. Removed `#displayedLines == 0 then return end` from `doSaveAndDraw()` / `doRefreshData()` / the reopen path
  3. `updateLineList()` is always called (an empty list renders fine)
- **Files**: `diagram_gui.lua:477, 605, 859, 1072, 1104`

### Enhanced diagnostic logs
- `getAllStops()`: prints `rawStops / stations / waypoints` counts + hints for classification anomalies
- `getAllTimetableData()`: prints the number of stops + stations + waypoints per line
- `getAllStationsFlat()`: prints `uniqueStations / uniqueWaypoints / mapOnlyAdded`
- **Files**: `timetable_helper.lua:396-407,471`, `diagram_gui.lua:263,352,882`

## Fixed (2026-07-30, this round)

### AbsoluteLayout station/time labels only showing the first one
- **Symptom**: the diagram's station labels on the left and time scale at the bottom sometimes only showed the first one, all others disappeared (user scenario: of 3 stations, only the name of the one with the largest sort number was shown)
- **Root cause chain**:
  1. The old code cleared the `AbsoluteLayout` with `sll:deleteAll()` and then called `addItem` again. `deleteAll()` may not fully reset the layout's internal state, or TPF2's component name registration may not release deleted component names immediately, making later `addItem`s fail silently
  2. The whole label loop was inside an outermost `pcall`; once one `addItem` failed and threw -> `pcall` aborted -> none of the following labels were created
- **Trial and error, approach 1 (failed)**: create a new `AbsoluteLayout` and replace it via `slc:setLayout(newSll)`
  - **Crash**: `CComponent::SetLayout: Assertion '!m_layout' failed.`
  - **Reason**: in the TPF2 engine `setLayout()` can only be called once per Component; calling it again triggers a C++ assert
- **Final fix** (3 improvements):
  1. **`deleteAll()` -> item-by-item `removeItem()`**: track created components in `menu.stationLabelViews`, and on every redraw clear old components one by one via `pcall(function() sll:removeItem(oldCont) end)`, keeping the layout's internal state clean
  2. **Unique component names**: every `refreshDiagram` appends an increasing `tag` counter -> component names `"stCont_3_1"`, `"stCont_2_2"`, `"stCont_1_3"`, avoiding engine component name registration conflicts
  3. **No outer `pcall` / separate `pcall` per label**: the station label loop now wraps each label's creation + adding in its own `pcall`; one failure doesn't affect rendering of the other labels, and a `"stationLabel add failed: ..."` error is logged
- **Files**: `diagram_gui.lua:486-572` (station label + time label sections)

### Key finding: Component:setLayout() can only be called once
- **Observation**: calling `setLayout()` again on a Component that already has a layout -> `CComponent::SetLayout: Assertion '!m_layout' failed.`
- **Root cause**: on the C++ side `CComponent::SetLayout` is guarded by an `assert(!m_layout)` assertion; once a component is given a layout it's bound permanently. The only way to "replace" a layout at runtime is to operate on the existing layout's items (`removeItem` / `addItem`), not to replace the layout object itself
- **Lesson**: `setLayout()` is a **one-time initialization**; the layout's content (items) can be added/removed dynamically, but the layout object can't be replaced
