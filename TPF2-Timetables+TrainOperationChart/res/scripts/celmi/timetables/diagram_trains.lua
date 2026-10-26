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
---@param samples table [stopIndex] = {seconds, ...} measured sectionTimes of all vehicles (> 0 only)
---@param distances table [stopIndex] = distance of leg i, or nil if unknown
---@param roundTrip number|nil estimated round trip time in seconds (from line frequency)
---@param n number number of stops of the line
---@return table [stopIndex] = seconds, or nil where no estimate is possible
function diagramTrains.estimateLegTimes(samples, distances, roundTrip, n)
    local res = {}
    local known = 0
    local unknown = {}
    for i = 1, n do
        local m = samples[i] and median(samples[i])
        if m then
            res[i] = m
            known = known + m
        else
            unknown[#unknown + 1] = i
        end
    end
    if #unknown == 0 or not roundTrip or roundTrip <= 0 then return res end
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
                expected = legStart + legTime * wpNo / (legWps + 1)
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

return diagramTrains
