-- Pure logic for the vertical station spacing of the train operation chart
-- (no game API access, unit-testable). Rows are numbered 1..nRows; gap i lies
-- between row i and row i+1.
local diagramLayout = {}

---Measures the gaps between adjacent rows along the lines that run between them.
---Each line is followed once around (including the leg back to its first stop) with a
---cumulative leg metric (distance or travel time). Whenever the line moves between two
---adjacent rows, the metric difference is a sample for that gap. Samples of all lines and
---both directions are averaged. Legs without a metric break the measurement.
---@param lines table {{stations = flat stop list {stopIndex, isLineStop, uniqueKey}, metric = [stopIndex] = leg value}, ...}
---@param rowOf table [uniqueKey] = row index
---@param nRows number
---@return table [gap index] = mean metric, or nil where no line runs between the rows
function diagramLayout.lineGaps(lines, rowOf, nRows)
    local samples = {}
    for _, line in ipairs(lines) do
        local stations = line.stations
        local metric = line.metric or {}
        local n = #stations

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

        local points = {}
        local function record(f, c, seg)
            local row = rowOf[stations[f].uniqueKey]
            if row then points[#points + 1] = { row = row, c = c, seg = seg } end
        end

        local cum, seg = 0, 1
        local legStart, legIdx, legWps, wpNo = nil, nil, 0, 0
        local firstStop = nil
        for f = 1, n do
            local st = stations[f]
            if st.isLineStop then
                if legIdx then
                    local m = metric[legIdx]
                    if m then cum = legStart + m else seg = seg + 1 end
                end
                if not firstStop then firstStop = f end
                record(f, cum, seg)
                legStart, legIdx, legWps, wpNo = cum, st.stopIndex, attached[f] or 0, 0
            elseif legIdx then
                wpNo = wpNo + 1
                local m = metric[legIdx]
                if m then record(f, legStart + m * wpNo / (legWps + 1), seg) end
            end
        end
        -- leg back to the first stop
        if firstStop and legIdx and metric[legIdx] then
            record(firstStop, legStart + metric[legIdx], seg)
        end

        for i = 1, #points - 1 do
            local a, b = points[i], points[i + 1]
            if a.seg == b.seg and math.abs(a.row - b.row) == 1 then
                local d = math.abs(b.c - a.c)
                if d > 0 then
                    local g = math.min(a.row, b.row)
                    samples[g] = samples[g] or {}
                    table.insert(samples[g], d)
                end
            end
        end
    end

    local gaps = {}
    for g = 1, nRows - 1 do
        local s = samples[g]
        if s and #s > 0 then
            local sum = 0
            for _, v in ipairs(s) do sum = sum + v end
            gaps[g] = sum / #s
        end
    end
    return gaps
end

---Fills missing gaps from a fallback measure, converted to the units of the primary one
---by the ratio over the gaps both know. Gaps still missing get the mean of the others.
---@param primary table [gap index] = value or nil
---@param fallback table|nil [gap index] = value or nil
---@param nGaps number
---@return table|nil all gaps, or nil if nothing is known at all
function diagramLayout.fillGaps(primary, fallback, nGaps)
    fallback = fallback or {}
    local sp, sf, nPrimary = 0, 0, 0
    for i = 1, nGaps do
        if primary[i] then
            nPrimary = nPrimary + 1
            if fallback[i] then sp = sp + primary[i]; sf = sf + fallback[i] end
        end
    end
    local res = {}
    local sum, count = 0, 0
    for i = 1, nGaps do
        local v = primary[i]
        if not v and fallback[i] then
            if nPrimary == 0 then v = fallback[i]
            elseif sf > 0 then v = fallback[i] * sp / sf end
        end
        res[i] = v
        if v then sum = sum + v; count = count + 1 end
    end
    if count == 0 then return nil end
    for i = 1, nGaps do
        if not res[i] then res[i] = sum / count end
    end
    return res
end

---Converts gaps to row y coordinates (row 1 at y = height, the last row at y = 0).
---Gaps are clamped to at least minFrac of the mean gap so labels of close rows stay apart.
---@param gaps table|nil [gap index] = value; nil gives equal spacing
---@param nRows number
---@param height number
---@param minFrac number|nil default 0.2
---@return table [row index] = y
function diagramLayout.rowYs(gaps, nRows, height, minFrac)
    local ys = {}
    if nRows <= 1 then
        ys[1] = height / 2
        return ys
    end
    local g = {}
    local total = 0
    if gaps then
        local mean = 0
        for i = 1, nRows - 1 do mean = mean + (gaps[i] or 0) end
        mean = mean / (nRows - 1)
        if mean > 0 then
            for i = 1, nRows - 1 do
                g[i] = math.max(gaps[i] or 0, (minFrac or 0.2) * mean)
                total = total + g[i]
            end
        end
    end
    if total <= 0 then
        for i = 1, nRows - 1 do g[i] = 1 end
        total = nRows - 1
    end
    local cum = 0
    for i = 1, nRows do
        ys[i] = (1 - cum / total) * height
        if i < nRows then cum = cum + g[i] end
    end
    return ys
end

return diagramLayout
