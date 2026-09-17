local ADDON_NAME = ...

local DPSPulseForever = {}
_G.DPSPulseForever = DPSPulse

local defaults = {
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = -140,
    scale = 1,
    windowSeconds = 10,
    locked = false,
    visible = true,
}

local function now()
    if GetTimePreciseSec then
        return GetTimePreciseSec()
    end
    return GetTime()
end

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

local function round(value)
    return math.floor(value + 0.5)
end

-- Linear interpolation between two colors at t in [0,1].
local function lerp(a, b, t)
    return a + (b - a) * t
end

-- Returns r,g,b for a heat gradient based on intensity in [0,1]:
-- 0.00 blue -> 0.33 green -> 0.66 yellow -> 1.00 red.
local function gradientColor(intensity)
    if intensity ~= intensity then -- NaN guard
        intensity = 0
    end
    if intensity < 0 then intensity = 0 end
    if intensity > 1 then intensity = 1 end

    -- Stops: {t, r, g, b}
    local stops = {
        { 0.00, 0.25, 0.55, 1.00 }, -- blue
        { 0.33, 0.20, 0.95, 0.40 }, -- green (matches legacy line color)
        { 0.66, 1.00, 0.90, 0.20 }, -- yellow
        { 1.00, 1.00, 0.25, 0.20 }, -- red
    }

    for i = 1, #stops - 1 do
        local s1 = stops[i]
        local s2 = stops[i + 1]
        if intensity <= s2[1] then
            local span = s2[1] - s1[1]
            local t = span > 0 and (intensity - s1[1]) / span or 0
            return lerp(s1[2], s2[2], t), lerp(s1[3], s2[3], t), lerp(s1[4], s2[4], t)
        end
    end

    local last = stops[#stops]
    return last[2], last[3], last[4]
end

local function shallowCopy(src)
    local out = {}
    for key, value in pairs(src) do
        out[key] = value
    end
    return out
end

local function chat(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99DPSPulse Forever|r " .. msg)
    end
end

DPSPulseForever.state = {
    initialized = false,
    playerGUID = nil,
    petGUID = nil,
    inCombat = false,
    fightStart = 0,
    clearAt = nil,
    buckets = {},
    history = {},
    peakDPS = 0,
    sampleAccumulator = 0,
    renderAccumulator = 0,
    logTimeOffset = nil,
    -- Full-combat-session tracking (mirrors Details-style total DPS).
    -- `totalDamage` accumulates from fightStart and is never trimmed.
    -- `sessionDPS` is the *current* combat's DPS when in combat, or the
    -- *last* combat's DPS when out of combat (frozen until next fight).
    totalDamage = 0,
    sessionDPS = 0,
    sessionDuration = 0,
    hasSession = false,
}

DPSPulseForever.config = {
    bucketStep = 0.2,
    sampleInterval = 0.1,
    renderInterval = 0.08,
    clearDelay = 3,
}

DPSPulseForever.ui = {
    frame = nil,
    graph = nil,
    dpsText = nil,
    peakText = nil,
    maxLabel = nil,
    segments = {},
    supportsRotation = true,
}

local damageEvents = {
    SWING_DAMAGE = true,
    SPELL_DAMAGE = true,
    SPELL_PERIODIC_DAMAGE = true,
    RANGE_DAMAGE = true,
    DAMAGE_SHIELD = true,
    DAMAGE_SPLIT = true,
    ENVIRONMENTAL_DAMAGE = true,
}

function DPSPulseForever:GetWindowSeconds()
    return clamp(tonumber(DPSPulseForeverDB.windowSeconds) or defaults.windowSeconds, 2, 60)
end

function DPSPulseForever:GetHistorySeconds()
    local windowSeconds = self:GetWindowSeconds()
    return clamp(windowSeconds * 2, 10, 60)
end

function DPSPulseForever:EnsureDB()
    if type(DPSPulseForeverDB) ~= "table" then
        DPSPulseForeverDB = shallowCopy(defaults)
        return
    end

    for key, value in pairs(defaults) do
        if DPSPulseForeverDB[key] == nil then
            DPSPulseForeverDB[key] = value
        end
    end

    DPSPulseForeverDB.windowSeconds = self:GetWindowSeconds()
    DPSPulseForeverDB.scale = clamp(tonumber(DPSPulseForeverDB.scale) or defaults.scale, 0.5, 2)
    DPSPulseForeverDB.visible = DPSPulseForeverDB.visible ~= false
    DPSPulseForeverDB.locked = DPSPulseForeverDB.locked == true
end

function DPSPulseForever:ResetFightData()
    self.state.buckets = {}
    self.state.history = {}
    self.state.peakDPS = 0
    self.state.fightStart = now()
    self.state.logTimeOffset = nil
    self.state.totalDamage = 0
end

function DPSPulseForever:ClearSession()
    self.state.sessionDPS = 0
    self.state.sessionDuration = 0
    self.state.hasSession = false
end

function DPSPulseForever:StartFight()
    self.state.inCombat = true
    self.state.clearAt = nil
    self:ResetFightData()
end

function DPSPulseForever:EndFight()
    self.state.inCombat = false
    self.state.clearAt = now() + self.config.clearDelay
    -- Freeze the just-finished combat's total DPS so it stays on screen
    -- until the next fight starts (Details-style "last fight" behavior).
    local duration = now() - (self.state.fightStart or now())
    if duration > 0 and self.state.totalDamage > 0 then
        self.state.sessionDPS = self.state.totalDamage / duration
        self.state.sessionDuration = duration
        self.state.hasSession = true
    end
end

function DPSPulseForever:NormalizeEventTime(eventTimestamp)
    local eventTime = tonumber(eventTimestamp)
    if not eventTime then
        return now()
    end

    if not self.state.logTimeOffset then
        self.state.logTimeOffset = now() - eventTime
    end

    return eventTime + self.state.logTimeOffset
end

function DPSPulseForever:TrackDamage(eventTime, amount)
    if not amount or amount <= 0 then
        return
    end

    -- Session-total counter is unbounded across the fight (used for full-combat DPS).
    self.state.totalDamage = (self.state.totalDamage or 0) + amount

    local step = self.config.bucketStep
    local bucketTime = math.floor(eventTime / step) * step
    local buckets = self.state.buckets
    local count = #buckets

    if count > 0 and buckets[count].t == bucketTime then
        buckets[count].dmg = buckets[count].dmg + amount
    else
        buckets[count + 1] = { t = bucketTime, dmg = amount }
    end

    local oldest = eventTime - (self:GetHistorySeconds() + 8)
    local trimIndex = 1
    while trimIndex <= #buckets and buckets[trimIndex].t < oldest do
        trimIndex = trimIndex + 1
    end

    if trimIndex > 1 then
        local newBuckets = {}
        local newIndex = 1
        for i = trimIndex, #buckets do
            newBuckets[newIndex] = buckets[i]
            newIndex = newIndex + 1
        end
        self.state.buckets = newBuckets
    end
end

function DPSPulseForever:ComputeRollingDPS(currentTime)
    local buckets = self.state.buckets
    if #buckets == 0 then
        return 0
    end

    local windowSeconds = self:GetWindowSeconds()
    local elapsed = currentTime - (self.state.fightStart or currentTime)
    local divisor = clamp(elapsed, self.config.bucketStep, windowSeconds)
    local lowerBound = currentTime - windowSeconds
    local sum = 0

    for i = #buckets, 1, -1 do
        local bucket = buckets[i]
        if bucket.t < lowerBound then
            break
        end
        sum = sum + bucket.dmg
    end

    if divisor <= 0 then
        return 0
    end

    return sum / divisor
end

function DPSPulseForever:ComputeSessionDPS(currentTime)
    if self.state.inCombat then
        local elapsed = currentTime - (self.state.fightStart or currentTime)
        if elapsed <= 0 then
            return 0, 0
        end
        return (self.state.totalDamage or 0) / elapsed, elapsed
    end

    if self.state.hasSession then
        return self.state.sessionDPS or 0, self.state.sessionDuration or 0
    end

    return 0, 0
end

function DPSPulseForever:Sample()
    local currentTime = now()

    if (not self.state.inCombat) and self.state.clearAt and currentTime >= self.state.clearAt then
        self.state.clearAt = nil
        self:ResetFightData()
        return
    end

    local currentDPS = self:ComputeRollingDPS(currentTime)
    local sessionDPS = self:ComputeSessionDPS(currentTime)

    local history = self.state.history
    history[#history + 1] = { t = currentTime, dps = currentDPS, session = sessionDPS }

    if currentDPS > self.state.peakDPS then
        self.state.peakDPS = currentDPS
    end

    local historySeconds = self:GetHistorySeconds()
    local oldest = currentTime - historySeconds
    local trimIndex = 1
    while trimIndex <= #history and history[trimIndex].t < oldest do
        trimIndex = trimIndex + 1
    end

    if trimIndex > 1 then
        local newHistory = {}
        local newIndex = 1
        for i = trimIndex, #history do
            newHistory[newIndex] = history[i]
            newIndex = newIndex + 1
        end
        self.state.history = newHistory
    end

end

function DPSPulseForever:ClearSegments()
    local segments = self.ui.segments
    for i = 1, #segments do
        segments[i]:Hide()
    end
    local sessionSegments = self.ui.sessionSegments
    if sessionSegments then
        for i = 1, #sessionSegments do
            sessionSegments[i]:Hide()
        end
    end
end

-- Draw one polyline series into a pre-allocated segment pool.
-- valueFn(point) -> dps value for this series at this sample.
-- colorFn(p1, p2, maxDPS) -> r,g,b,a for the segment between p1 and p2.
-- Returns the next segment index to hide.
function DPSPulseForever:RenderSeries(points, segments, graph, graphWidth, graphHeight, minTime, historySeconds, maxDPS, valueFn, colorFn)
    local segmentIndex = 1

    for i = 2, #points do
        local p1 = points[i - 1]
        local p2 = points[i]
        local v1 = valueFn(p1) or 0
        local v2 = valueFn(p2) or 0

        local x1 = ((p1.t - minTime) / historySeconds) * graphWidth
        local y1 = (clamp(v1 / maxDPS, 0, 1)) * graphHeight
        local x2 = ((p2.t - minTime) / historySeconds) * graphWidth
        local y2 = (clamp(v2 / maxDPS, 0, 1)) * graphHeight

        local dx = x2 - x1
        local dy = y2 - y1
        local dist = math.sqrt(dx * dx + dy * dy)

        local segment = segments[segmentIndex]
        if not segment then
            break
        end

        if dist < 0.01 then
            segment:Hide()
        else
            local r, g, b, a = colorFn(v1, v2, maxDPS)
            segment:SetColorTexture(r, g, b, a or 1)

            segment:ClearAllPoints()
            if self.ui.supportsRotation and segment.SetRotation then
                segment:SetPoint("CENTER", graph, "BOTTOMLEFT", (x1 + x2) * 0.5, (y1 + y2) * 0.5)
                segment:SetSize(dist, 2)
                segment:SetRotation(math.atan2(dy, dx))
            else
                segment:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", math.min(x1, x2), y2)
                segment:SetSize(math.max(1, math.abs(dx)), 2)
            end
            segment:Show()
        end

        segmentIndex = segmentIndex + 1
    end

    for i = segmentIndex, #segments do
        segments[i]:Hide()
    end
end

function DPSPulseForever:RenderGraph()
    if not self.ui.graph then
        return
    end

    local graph = self.ui.graph
    local graphWidth = graph:GetWidth()
    local graphHeight = graph:GetHeight()
    local history = self.state.history

    if #history < 2 then
        self:ClearSegments()
        if self.ui.maxLabel then
            self.ui.maxLabel:SetText("Max: 0")
        end
        return
    end

    local currentTime = now()
    local historySeconds = self:GetHistorySeconds()
    local minTime = currentTime - historySeconds

    local points = {}
    local maxDPS = 0

    for i = 1, #history do
        local point = history[i]
        if point.t >= minTime then
            points[#points + 1] = point
            if point.dps > maxDPS then
                maxDPS = point.dps
            end
            local sessionVal = point.session or 0
            if sessionVal > maxDPS then
                maxDPS = sessionVal
            end
        end
    end

    if #points < 2 then
        self:ClearSegments()
        if self.ui.maxLabel then
            self.ui.maxLabel:SetText("Max: 0")
        end
        return
    end

    maxDPS = math.max(50, round(maxDPS * 1.15))
    if self.ui.maxLabel then
        self.ui.maxLabel:SetText("Max: " .. tostring(round(maxDPS)))
    end

    -- Rolling series: heat-gradient color per segment (existing behavior).
    self:RenderSeries(
        points, self.ui.segments, graph, graphWidth, graphHeight,
        minTime, historySeconds, maxDPS,
        function(p) return p.dps end,
        function(v1, v2, m)
            local intensity = 0
            if m > 0 then
                intensity = clamp(((v1 + v2) * 0.5) / m, 0, 1)
            end
            local r, g, b = gradientColor(intensity)
            return r, g, b, 1
        end
    )

    -- Session series: flat teal, slightly transparent so it reads as "average".
    self:RenderSeries(
        points, self.ui.sessionSegments, graph, graphWidth, graphHeight,
        minTime, historySeconds, maxDPS,
        function(p) return p.session or 0 end,
        function() return 0.55, 0.85, 1.0, 0.85 end
    )
end

function DPSPulseForever:UpdateTexts()
    if not self.ui.dpsText then
        return
    end

    local currentTime = now()
    local currentDPS = self:ComputeRollingDPS(currentTime)
    self.ui.dpsText:SetText(string.format("%d DPS", round(currentDPS)))

    if self.ui.sessionText then
        local sessionDPS, sessionDuration = self:ComputeSessionDPS(currentTime)
        if self.state.inCombat then
            self.ui.sessionText:SetText(string.format("Session %d", round(sessionDPS)))
        elseif self.state.hasSession then
            self.ui.sessionText:SetText(string.format("Last %d (%.1fs)", round(sessionDPS), sessionDuration))
        else
            self.ui.sessionText:SetText("Session 0")
        end
    end

    if self.ui.peakText then
        self.ui.peakText:SetText(string.format("Peak %d", round(self.state.peakDPS)))
    end
end

function DPSPulseForever:ApplyPosition()
    if not self.ui.frame then
        return
    end

    self.ui.frame:ClearAllPoints()
    self.ui.frame:SetPoint(
        DPSPulseForeverDB.point or defaults.point,
        UIParent,
        DPSPulseForeverDB.relativePoint or defaults.relativePoint,
        DPSPulseForeverDB.x or defaults.x,
        DPSPulseForeverDB.y or defaults.y
    )
end

function DPSPulseForever:SavePosition()
    if not self.ui.frame then
        return
    end

    local point, _, relativePoint, x, y = self.ui.frame:GetPoint(1)
    DPSPulseForeverDB.point = point
    DPSPulseForeverDB.relativePoint = relativePoint
    DPSPulseForeverDB.x = round(x or 0)
    DPSPulseForeverDB.y = round(y or 0)
end

function DPSPulseForever:SetVisible(visible)
    DPSPulseForeverDB.visible = visible == true
    if self.ui.frame then
        if DPSPulseForeverDB.visible then
            self.ui.frame:Show()
        else
            self.ui.frame:Hide()
        end
    end
end

function DPSPulseForever:CreateUI()
    if self.ui.frame then
        return
    end

    local frame = CreateFrame("Frame", "DPSPulseForeverFrame", UIParent)
    frame:SetSize(320, 170)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScale(DPSPulseForeverDB.scale)

    frame:SetScript("OnDragStart", function(selfFrame)
        if not DPSPulseForeverDB.locked then
            selfFrame:StartMoving()
        end
    end)

    frame:SetScript("OnDragStop", function(selfFrame)
        selfFrame:StopMovingOrSizing()
        DPSPulseForever:SavePosition()
    end)

    frame:SetScript("OnUpdate", function(_, elapsed)
        if (not DPSPulseForever.state.inCombat) and (not DPSPulseForever.state.clearAt) then
            return
        end

        DPSPulseForever.state.sampleAccumulator = DPSPulseForever.state.sampleAccumulator + elapsed
        DPSPulseForever.state.renderAccumulator = DPSPulseForever.state.renderAccumulator + elapsed

        while DPSPulseForever.state.sampleAccumulator >= DPSPulseForever.config.sampleInterval do
            DPSPulseForever.state.sampleAccumulator = DPSPulseForever.state.sampleAccumulator - DPSPulseForever.config.sampleInterval
            DPSPulseForever:Sample()
        end

        if DPSPulseForever.state.renderAccumulator >= DPSPulseForever.config.renderInterval then
            DPSPulseForever.state.renderAccumulator = 0
            DPSPulseForever:UpdateTexts()
            DPSPulseForever:RenderGraph()
        end
    end)

    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(frame)
    bg:SetColorTexture(0, 0, 0, 0.55)

    local header = frame:CreateTexture(nil, "ARTWORK")
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    header:SetHeight(24)
    header:SetColorTexture(0.08, 0.08, 0.08, 0.8)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -6)
    title:SetText("DPSPulse Forever")

    local lockStatus = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lockStatus:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
    frame.lockStatus = lockStatus

    local dpsText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    dpsText:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -30)
    dpsText:SetText("0 DPS")

    -- Second line: full-combat / "session" DPS — mimics Details "total fight DPS".
    -- Shown as a number alongside the graph *and* plotted as a second series on
    -- the same axes. While in combat this is current-fight DPS; when out of
    -- combat it shows the last completed fight's DPS + duration.
    local sessionText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    sessionText:SetTextColor(0.55, 0.85, 1.0, 1) -- teal, matches the session line
    sessionText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -30)
    sessionText:SetJustifyH("RIGHT")
    sessionText:SetText("Session 0")

    local peakText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    peakText:SetPoint("TOPLEFT", dpsText, "BOTTOMLEFT", 0, -4)
    peakText:SetText("Peak 0")

    local graph = CreateFrame("Frame", nil, frame)
    graph:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -70)
    graph:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 10)

    local graphBg = graph:CreateTexture(nil, "BACKGROUND")
    graphBg:SetAllPoints(graph)
    graphBg:SetColorTexture(0.02, 0.02, 0.02, 0.75)

    local axisX = graph:CreateTexture(nil, "ARTWORK")
    axisX:SetColorTexture(0.5, 0.5, 0.5, 0.35)
    axisX:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", 0, 0)
    axisX:SetPoint("BOTTOMRIGHT", graph, "BOTTOMRIGHT", 0, 0)
    axisX:SetHeight(1)

    local axisY = graph:CreateTexture(nil, "ARTWORK")
    axisY:SetColorTexture(0.5, 0.5, 0.5, 0.35)
    axisY:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", 0, 0)
    axisY:SetPoint("TOPLEFT", graph, "TOPLEFT", 0, 0)
    axisY:SetWidth(1)

    local maxLabel = graph:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    maxLabel:SetPoint("TOPRIGHT", graph, "TOPRIGHT", -2, -2)
    maxLabel:SetText("Max: 0")

    local supportsRotation = true
    local segmentCount = 160
    local segments = {}
    for i = 1, segmentCount do
        local segment = graph:CreateTexture(nil, "OVERLAY")
        segment:SetColorTexture(0.2, 0.95, 0.4, 1)
        segment:SetSize(1, 2)
        segment:Hide()

        if supportsRotation and not segment.SetRotation then
            supportsRotation = false
        end

        segments[i] = segment
    end

    -- Second polyline pool for the full-combat session series (rendered on the
    -- same axes as the rolling series). Drawn at a lower texture layer so the
    -- rolling line reads as the "primary" reading.
    local sessionSegments = {}
    for i = 1, segmentCount do
        local segment = graph:CreateTexture(nil, "ARTWORK")
        segment:SetColorTexture(0.55, 0.85, 1.0, 0.85)
        segment:SetSize(1, 2)
        segment:Hide()
        sessionSegments[i] = segment
    end

    -- Legend: rolling (heat gradient shown as green swatch) + session (teal).
    local legendRoll = graph:CreateTexture(nil, "OVERLAY")
    legendRoll:SetColorTexture(0.2, 0.95, 0.4, 1)
    legendRoll:SetSize(10, 2)
    legendRoll:SetPoint("TOPLEFT", graph, "TOPLEFT", 2, -2)
    local legendRollText = graph:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    legendRollText:SetPoint("LEFT", legendRoll, "RIGHT", 4, 0)
    legendRollText:SetText("Rolling")

    local legendSess = graph:CreateTexture(nil, "OVERLAY")
    legendSess:SetColorTexture(0.55, 0.85, 1.0, 0.85)
    legendSess:SetSize(10, 2)
    legendSess:SetPoint("TOPLEFT", graph, "TOPLEFT", 62, -2)
    local legendSessText = graph:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    legendSessText:SetPoint("LEFT", legendSess, "RIGHT", 4, 0)
    legendSessText:SetText("Session")

    self.ui.frame = frame
    self.ui.graph = graph
    self.ui.dpsText = dpsText
    self.ui.sessionText = sessionText
    self.ui.peakText = peakText
    self.ui.maxLabel = maxLabel
    self.ui.segments = segments
    self.ui.sessionSegments = sessionSegments
    self.ui.supportsRotation = supportsRotation

    self:ApplyPosition()
    self:SetVisible(DPSPulseForeverDB.visible)
    self:UpdateLockStatus()
end

function DPSPulseForever:UpdateLockStatus()
    if not self.ui.frame or not self.ui.frame.lockStatus then
        return
    end

    if DPSPulseForeverDB.locked then
        self.ui.frame.lockStatus:SetText("Locked")
    else
        self.ui.frame.lockStatus:SetText("Unlocked")
    end
end

function DPSPulseForever:ParseDamageAmount(subEvent, ...)
    if subEvent == "SWING_DAMAGE" then
        return tonumber((...))
    end

    if subEvent == "ENVIRONMENTAL_DAMAGE" then
        local _, amount = ...
        return tonumber(amount)
    end

    if subEvent == "SPELL_DAMAGE" or subEvent == "SPELL_PERIODIC_DAMAGE" or subEvent == "RANGE_DAMAGE" or subEvent == "DAMAGE_SHIELD" or subEvent == "DAMAGE_SPLIT" then
        local _, _, _, amount = ...
        return tonumber(amount)
    end

    return nil
end

function DPSPulseForever:HandleCombatLogEvent(...)
    local timestamp
    local subEvent
    local sourceGUID
    local arg12
    local arg13
    local arg14
    local arg15

    if CombatLogGetCurrentEventInfo then
        timestamp, subEvent, _, sourceGUID, _, _, _, _, _, _, _, arg12, arg13, arg14, arg15 = CombatLogGetCurrentEventInfo()
    else
        timestamp, subEvent, _, sourceGUID, _, _, _, _, _, _, _, arg12, arg13, arg14, arg15 = ...
    end

    if not timestamp or not subEvent or not sourceGUID then
        return
    end

    if not damageEvents[subEvent] then
        return
    end

    local isPlayer = sourceGUID == self.state.playerGUID
    local isPet = self.state.petGUID and sourceGUID == self.state.petGUID
    if not isPlayer and not isPet then
        return
    end

    local amount = self:ParseDamageAmount(subEvent, arg12, arg13, arg14, arg15)

    if amount and amount > 0 then
        self:TrackDamage(self:NormalizeEventTime(timestamp), amount)
    end
end

function DPSPulseForever:HandleSlash(msg)
    local command = string.lower((msg or ""):match("^%s*(.-)%s*$") or "")

    if command == "" or command == "toggle" then
        self:SetVisible(not DPSPulseForeverDB.visible)
        return
    end

    if command == "show" then
        self:SetVisible(true)
        return
    end

    if command == "hide" then
        self:SetVisible(false)
        return
    end

    if command == "reset" then
        self:ResetFightData()
        self:ClearSession()
        self:UpdateTexts()
        self:RenderGraph()
        chat("Current fight data reset.")
        return
    end

    if command == "lock" then
        DPSPulseForeverDB.locked = true
        self:UpdateLockStatus()
        chat("Frame locked.")
        return
    end

    if command == "unlock" then
        DPSPulseForeverDB.locked = false
        self:UpdateLockStatus()
        chat("Frame unlocked.")
        return
    end

    local windowValue = command:match("^window%s+([%d%.]+)$")
    if windowValue then
        local seconds = clamp(tonumber(windowValue) or defaults.windowSeconds, 2, 60)
        DPSPulseForeverDB.windowSeconds = seconds
        chat("Rolling window set to " .. tostring(seconds) .. "s.")
        return
    end

    local scaleValue = command:match("^scale%s+([%d%.]+)$")
    if scaleValue then
        local scale = clamp(tonumber(scaleValue) or 1, 0.5, 2)
        DPSPulseForeverDB.scale = scale
        if self.ui.frame then
            self.ui.frame:SetScale(scale)
        end
        chat("Scale set to " .. tostring(scale) .. ".")
        return
    end

    chat("Commands: show, hide, toggle, window <2-60>, scale <0.5-2>, lock, unlock, reset")
end

function DPSPulseForever:HandleEvent(event, ...)
    if event == "ADDON_LOADED" then
        local loadedName = ...
        if loadedName ~= ADDON_NAME then
            return
        end
        self:EnsureDB()
    elseif event == "PLAYER_LOGIN" then
        if self.state.initialized then
            return
        end

        self.state.initialized = true
        self.state.playerGUID = UnitGUID("player")
        self.state.petGUID = UnitGUID("pet")

        self:CreateUI()
        self:ResetFightData()

        SLASH_DPSPULSEFOREVER1 = "/dpspulseforever"
        SLASH_DPSPULSEFOREVER2 = "/dpsf"
        SlashCmdList.DPSPULSEFOREVER = function(msg)
            self:HandleSlash(msg)
        end

        chat("Loaded. Type /dpspulseforever help for commands.")
    elseif event == "PLAYER_REGEN_DISABLED" then
        self:StartFight()
    elseif event == "PLAYER_REGEN_ENABLED" then
        self:EndFight()
    elseif event == "UNIT_PET" then
        local unit = ...
        if unit == "player" then
            self.state.petGUID = UnitGUID("pet")
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        self.state.playerGUID = UnitGUID("player")
        self.state.petGUID = UnitGUID("pet")
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        self:HandleCombatLogEvent(...)
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("UNIT_PET")
eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    DPSPulseForever:HandleEvent(event, ...)
end)
