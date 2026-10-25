-- Pure logic for the train operation chart (no game API access, unit-testable):
-- estimating leg travel times and following each train through the timetable slots.
local diagramTrains = {}

local function median(values)
    if #values == 0 then return nil end
    local s = {}
    for i, v in ipairs(values) do s[i] = v end
    table.sort(s)
    local mid = math.floor(#s / 2)
    if #s % 2 == 1 then return s[mid + 1] end
    return (s[mid] + s[mid + 1]) / 2
end
diagramTrains.median = median

---Estimates the travel time of each leg of a line.
---Leg i is the leg leaving stop i (stop i -> stop i+1, the last stop -> stop 1).
---Unmeasured legs get the average pace (seconds per distance) of the measured legs times their
---distance. Only if no pace is available, the round trip time left over by the measured legs is
---split across them by distance; the round trip includes dwell times, so this is a rough guess.
---@param samples table [stopIndex] = {seconds, ...} measured sectionTimes of all vehicles (> 0 only)
---@param distances table [stopIndex] = distance of leg i, or nil if unknown
---@param roundTrip number|nil estimated round trip time in seconds (from line frequency)
---@param n number number of stops of the line
---@return table [stopIndex] = seconds, or nil where no estimate is possible
function diagramTrains.estimateLegTimes(samples, distances, roundTrip, n)
    local res = {}
    local known = 0
    local unknown = {}
    local tPaced, dPaced = 0, 0
    for i = 1, n do
        local m = samples[i] and median(samples[i])
        if m then
            res[i] = m
            known = known + m
            local d = distances and distances[i]
            if d and d > 0 then tPaced = tPaced + m; dPaced = dPaced + d end
        else
            unknown[#unknown + 1] = i
        end
    end
    if #unknown == 0 then return res end

    if dPaced > 0 then
        -- Legs without a distance get the mean distance of all legs with one.
        local dSum, dCount = 0, 0
        for i = 1, n do
            local d = distances[i]
            if d and d > 0 then dSum = dSum + d; dCount = dCount + 1 end
        end
        local pace = tPaced / dPaced
        for _, i in ipairs(unknown) do
            local d = distances[i]
            res[i] = pace * ((d and d > 0) and d or dSum / dCount)
        end
        return res
    end

    if not roundTrip or roundTrip <= 0 then return res end
    local remaining = roundTrip - known
    if remaining <= 0 then return res end

    -- Split the remaining round trip time across the unmeasured legs by distance.
    -- Legs without a distance get the mean distance of the others (or equal weights).
    local dSum, dCount = 0, 0
    for _, i in ipairs(unknown) do
        local d = distances and distances[i]
        if d and d > 0 then dSum = dSum + d; dCount = dCount + 1 end
    end
    local mean = dCount > 0 and dSum / dCount or 1
    local wSum = 0
    local w = {}
    for _, i in ipairs(unknown) do
        local d = distances and distances[i]
        w[i] = (d and d > 0) and d or mean
        wSum = wSum + w[i]
    end
    for _, i in ipairs(unknown) do
        res[i] = remaining * w[i] / wSum
    end
    return res
end

---Picks the timetable slot that best matches an expected arrival time.
---The slot whose [arrival, departure] interval is closest to the expected time wins
---(distance 0 if the expected time lies inside the interval). Estimates are rough, so a
---nearest match is more robust than a strict "first departure after arrival" rule.
---@param slots table {{arrMin, arrSec, depMin, depSec}, ...}
---@param expected number expected arrival, absolute seconds
---@param notBefore number|nil the chosen arrival must not be earlier than this
---@return table|nil {arr = absolute seconds, dep = absolute seconds}
function diagramTrains.pickSlot(slots, expected, notBefore)
    local best = nil
    local kc = math.floor(expected / 3600)
    for _, c in ipairs(slots) do
        local a = (c[1] * 60 + c[2]) % 3600
        local d = (c[3] * 60 + c[4]) % 3600
        for k = kc - 1, kc + 1 do
            local absA = a + 3600 * k
            local absD = d + 3600 * k
            if absD < absA then absD = absD + 3600 end
            if not notBefore or absA >= notBefore then
                local dist = 0
                if expected < absA then dist = absA - expected
                elseif expected > absD then dist = expected - absD end
                if not best or dist < best.dist or (dist == best.dist and absA < best.arr) then
                    best = { arr = absA, dep = absD, dist = dist }
                end
            end
        end
    end
    if best then best.dist = nil end
    return best
end

---Sets legFrac on the waypoints attached to each line stop: the position of the waypoint
---along the leg (0 = leaving stop, 1 = next stop), from the straight-line distances
---stop -> waypoint 1 -> ... -> waypoint n -> next stop. A leg where any position is missing
---gets no legFrac (users fall back to equal spacing).
---@param stations table flat stop list {isLineStop, pos = {x, y} or nil}
function diagramTrains.assignLegFractions(stations)
    local n = #stations
    local f = 1
    while f <= n do
        if stations[f].isLineStop then
            local chain = { stations[f] }
            local g = f + 1
            while g <= n and not stations[g].isLineStop do
                chain[#chain + 1] = stations[g]
                g = g + 1
            end
            if #chain > 1 then
                -- next line stop (wraps around to the first stop)
                local nextStop = nil
                for h = 0, n - 1 do
                    local st = stations[(g - 1 + h) % n + 1]
                    if st.isLineStop then nextStop = st; break end
                end
                local nWps = #chain - 1
                chain[#chain + 1] = nextStop
                local cum = { 0 }
                local ok = nextStop ~= nil
                if ok then
                    for i = 2, #chain do
                        local a, b = chain[i - 1].pos, chain[i].pos
                        if not (a and b) then ok = false; break end
                        cum[i] = cum[i - 1] + math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
                    end
                end
                local total = ok and cum[#chain] or 0
                for i = 2, nWps + 1 do
                    chain[i].legFrac = (total > 0) and cum[i] / total or nil
                end
            end
            f = g
        else
            f = f + 1
        end
    end
end

---Follows each train of a line through the timetable, starting from each slot of the
---first stop that has slots, around the whole line and back to that stop.
---@param stations table flat stop list: {stopIndex, isLineStop, uniqueKey, times = {{am,as,dm,ds}, ...}}
---  Line stops (stations, or waypoints that are line stops) carry the leg times; waypoints
---  attached to a station (isLineStop == false) lie on the leg leaving that station.
---@param legTimes table [stopIndex] = seconds of the leg leaving that stop (may have gaps)
---@param endAtLast boolean|nil rotation line: the train ends at the last stop (it continues on
---  another line there), so the run stops there and its last visit has no departure.
---@return table runs list of runs; a run is a list of visits {flatIdx, arr, dep} in travel
---  order; arr/dep are absolute seconds, or nil where the stop has no slots.
---  The first visit is the start stop (departure), the last is the start stop again (arrival).
function diagramTrains.buildRuns(stations, legTimes, endAtLast)
    local n = #stations
    local startIdx = nil
    for f = 1, n do
        local st = stations[f]
        if st.isLineStop and st.times and #st.times > 0 then startIdx = f; break end
    end
    if not startIdx then return {} end

    -- number of attached waypoints following each line stop
    local attached = {}
    local lastStop = nil
    for f = 1, n do
        if stations[f].isLineStop then
            lastStop = f
            attached[f] = 0
        elseif lastStop then
            attached[lastStop] = attached[lastStop] + 1
        end
    end

    -- travel order: start .. n, 1 .. start-1, then the start stop again
    local order = {}
    for f = startIdx, n do order[#order + 1] = f end
    if not endAtLast then
        for f = 1, startIdx - 1 do order[#order + 1] = f end
        local startKey = stations[startIdx].uniqueKey
        local lastF = order[#order]
        if not (stations[lastF].isLineStop and stations[lastF].uniqueKey == startKey and lastF ~= startIdx) then
            order[#order + 1] = startIdx
        end
    end

    local runs = {}
    for _, slot in ipairs(stations[startIdx].times) do
        local a = (slot[1] * 60 + slot[2]) % 3600
        local d = (slot[3] * 60 + slot[4]) % 3600
        if d < a then d = d + 3600 end
        local run = { { flatIdx = startIdx, arr = a, dep = d } }
        local legStart = d
        local legIdx = stations[startIdx].stopIndex
        local legWps = attached[startIdx] or 0
        local wpNo = 0
        local notBefore = d
        for oi = 2, #order do
            local f = order[oi]
            local st = stations[f]
            local legTime = legTimes[legIdx] or 0
            local expected
            if st.isLineStop then
                expected = legStart + legTime
            else
                wpNo = wpNo + 1
                expected = legStart + legTime * (st.legFrac or wpNo / (legWps + 1))
            end
            local visit = { flatIdx = f }
            local pick = st.times and #st.times > 0 and diagramTrains.pickSlot(st.times, expected, notBefore)
            if pick then
                visit.arr = pick.arr
                visit.dep = pick.dep
                notBefore = pick.dep
            end
            if endAtLast and oi == #order then visit.dep = nil end
            run[#run + 1] = visit
            if st.isLineStop then
                legStart = pick and pick.dep or expected
                legIdx = st.stopIndex
                legWps = attached[f] or 0
                wpNo = 0
            end
        end
        runs[#runs + 1] = run
    end
    return runs
end

---Delay of a train standing at a stop, measured horizontally to the planned dwell segment:
---0 inside [plArr, plDep], negative before the planned arrival, positive after the departure.
---@param plArr number planned arrival, absolute seconds
---@param plDep number planned departure, absolute seconds
---@param now number
---@return number delay seconds
function diagramTrains.dwellDelay(plArr, plDep, now)
    if now < plArr then return now - plArr end
    if now > plDep then return now - plDep end
    return 0
end

---The planned visits of a train from its departure at a stop up to the next line stop.
---@param runs table runs from buildRuns
---@param stations table flat stop list {isLineStop}
---@param flatIdx number flat index of the stop the train departed from
---@param plDep number planned departure there, absolute seconds (any hour)
---@return table|nil visits {flatIdx, arr, dep}, shifted so the first departure equals plDep;
---  the last one is the next line stop. nil if no run departs there at that time.
function diagramTrains.legVisits(runs, stations, flatIdx, plDep)
    for _, run in ipairs(runs) do
        for vi, v in ipairs(run) do
            if v.flatIdx == flatIdx and v.dep and (v.dep - plDep) % 3600 == 0 then
                local shift = plDep - v.dep
                local res = { { flatIdx = flatIdx, arr = v.arr and v.arr + shift, dep = plDep } }
                for vj = vi + 1, #run do
                    local w = run[vj]
                    res[#res + 1] = { flatIdx = w.flatIdx, arr = w.arr and w.arr + shift,
                        dep = w.dep and w.dep + shift }
                    if stations[w.flatIdx].isLineStop then return res end
                end
                -- the last visit of a run (back at its start stop) has a departure too, but no
                -- leg after it: keep looking for the run that starts with this departure
            end
        end
    end
    return nil
end

---Position of a running train on the planned polyline of its leg, assuming it keeps the delay
---it departed with: the point the plan reaches at (now - delay). A train still on the leg after
---the planned arrival waits at the end of the leg, and its delay grows.
---@param pts table planned polyline {{t, y}, ...} in time order, from the departure to the
---  arrival at the next stop
---@param now number
---@param delay number delay at the departure, seconds (negative = early)
---@return number y
---@return number delay current delay
function diagramTrains.trainOnLeg(pts, now, delay)
    local t = now - delay
    local last = pts[#pts].t
    if t > last then
        t = last
        delay = now - last
    end
    if t <= pts[1].t then return pts[1].y, delay end
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        if t <= b.t then
            if b.t <= a.t then return b.y, delay end
            return a.y + (b.y - a.y) * (t - a.t) / (b.t - a.t), delay
        end
    end
    return pts[#pts].y, delay
end

return diagramTrains
