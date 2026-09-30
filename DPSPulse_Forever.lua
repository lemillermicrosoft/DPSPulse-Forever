local ADDON_NAME = ...

local DPSPulseForever = {}
_G.DPSPulseForever = DPSPulseForever

local defaults = {
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = -140,
    scale = 1,
    windowSeconds = 10,
    locked = false,
    visible = true,
    skin = "classic",
    debug = false,
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
    optionsPanel = nil,
    optionsControls = {},
    refreshingOptions = false,
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
    DPSPulseForeverDB.skin = DPSPulseForeverDB.skin == "blizzard" and "blizzard" or "classic"
    DPSPulseForeverDB.debug = DPSPulseForeverDB.debug == true
end

function DPSPulseForever:ResetFightData()
    self.state.buckets = {}
    self.state.history = {}
    self.state.peakDPS = 0
    self.state.fightStart = now()
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

-- (Removed) DPSPulseForever:NormalizeEventTime -- COMBAT_LOG_EVENT_UNFILTERED
-- provided its own timestamp on TBC; UNIT_COMBAT does not, so we just use now().

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

    maxDPS = math.max(10, round(maxDPS * 1.15))
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

    local point = DPSPulseForeverDB.point or defaults.point
    local relativePoint = DPSPulseForeverDB.relativePoint or defaults.relativePoint
    local x = DPSPulseForeverDB.x or defaults.x
    local y = DPSPulseForeverDB.y or defaults.y
    self.ui.frame:ClearAllPoints()
    self.ui.frame:SetPoint(point, UIParent, relativePoint, x, y)
    self.ui.frame:SetUserPlaced(true)
end

function DPSPulseForever:SavePosition()
    if not self.ui.frame then
        return
    end

    local frame = self.ui.frame
    -- Normalize anchor so restore is deterministic. Compute frame center
    -- offset from UIParent center in UIParent's coord space.
    local scale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local cx, cy = frame:GetCenter()
    local pcx, pcy = UIParent:GetCenter()
    if not cx or not pcx then
        return
    end
    DPSPulseForeverDB.point = "CENTER"
    DPSPulseForeverDB.relativePoint = "CENTER"
    DPSPulseForeverDB.x = round((cx - pcx) * scale)
    DPSPulseForeverDB.y = round((cy - pcy) * scale)
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
    self:RefreshOptions()
end

function DPSPulseForever:SetLocked(locked)
    DPSPulseForeverDB.locked = locked == true
    self:UpdateLockStatus()
    self:RefreshOptions()
end

function DPSPulseForever:SetWindowSeconds(seconds)
    DPSPulseForeverDB.windowSeconds = clamp(tonumber(seconds) or defaults.windowSeconds, 2, 60)
    self:RefreshOptions()
end

function DPSPulseForever:SetScale(scale)
    DPSPulseForeverDB.scale = clamp(tonumber(scale) or defaults.scale, 0.5, 2)
    if self.ui.frame then
        self.ui.frame:SetScale(DPSPulseForeverDB.scale)
    end
    self:RefreshOptions()
end

function DPSPulseForever:ResetSessionData()
    self:ResetFightData()
    self:ClearSession()
    self:UpdateTexts()
    self:RenderGraph()
end

function DPSPulseForever:ResetWindowPosition()
    DPSPulseForeverDB.point = defaults.point
    DPSPulseForeverDB.relativePoint = defaults.relativePoint
    DPSPulseForeverDB.x = defaults.x
    DPSPulseForeverDB.y = defaults.y
    self:ApplyPosition()
end

function DPSPulseForever:ApplySkin(skin)
    skin = skin == "blizzard" and "blizzard" or "classic"
    DPSPulseForeverDB.skin = skin

    local frame = self.ui.frame
    if not frame or not frame.skinTextures then
        return
    end

    local textures = frame.skinTextures
    if skin == "blizzard" then
        -- UI-DialogBox-Border is an atlas of border pieces, not a single
        -- stretchable image. Use Blizzard's backdrop renderer so its corners
        -- and edges are sliced correctly at any frame size.
        frame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        -- WoW Forever's native panels use warm bronze edging and dark umber
        -- surfaces rather than the stock silver dialog palette.
        frame:SetBackdropColor(0.30, 0.20, 0.11, 1)
        frame:SetBackdropBorderColor(0.72, 0.47, 0.20, 1)
        textures.background:Hide()
        textures.header:ClearAllPoints()
        textures.header:SetPoint("TOPLEFT", frame, "TOPLEFT", 5, -4)
        textures.header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -4)
        textures.header:SetHeight(23)
        textures.header:SetTexture(nil)
        textures.header:SetColorTexture(0.13, 0.055, 0.012, 0.98)
        textures.header:Show()
        textures.headerHighlight:SetColorTexture(0.88, 0.62, 0.28, 0.52)
        textures.headerHighlight:Show()
        textures.headerAccent:SetColorTexture(0.72, 0.47, 0.16, 0.95)
        textures.headerAccent:Show()
        textures.headerShadow:Show()
        textures.graphBackground:SetColorTexture(0.055, 0.032, 0.018, 0.94)
        textures.graphWatermark:Show()
        for _, line in ipairs(textures.graphGrid) do line:Show() end
        frame.title:ClearAllPoints()
        frame.title:SetPoint("TOP", frame, "TOP", 0, -9)
        frame.title:SetTextColor(1.0, 0.82, 0.20, 1)
        frame.lockStatus:ClearAllPoints()
        frame.lockStatus:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -9)
        frame.closeButton:Show()
    else
        frame:SetBackdrop(nil)
        textures.background:Show()
        textures.background:SetTexture(nil)
        textures.background:SetColorTexture(0, 0, 0, 0.55)
        textures.header:ClearAllPoints()
        textures.header:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        textures.header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        textures.header:SetHeight(24)
        textures.header:Show()
        textures.header:SetTexture(nil)
        textures.header:SetColorTexture(0.08, 0.08, 0.08, 0.8)
        textures.headerHighlight:Hide()
        textures.headerAccent:Hide()
        textures.headerShadow:Hide()
        textures.graphBackground:SetColorTexture(0.02, 0.02, 0.02, 0.75)
        textures.graphWatermark:Hide()
        for _, line in ipairs(textures.graphGrid) do line:Hide() end
        frame.title:ClearAllPoints()
        frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -6)
        frame.title:SetTextColor(1, 1, 1, 1)
        frame.lockStatus:ClearAllPoints()
        frame.lockStatus:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
        frame.closeButton:Hide()
    end
    self:RefreshOptions()
end

function DPSPulseForever:SetSkin(skin)
    self:ApplySkin(skin)
end

function DPSPulseForever:CreateUI()
    if self.ui.frame then
        return
    end

    local frameTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil
    local frame = CreateFrame("Frame", "DPSPulseForeverFrame", UIParent, frameTemplate)
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

    local headerHighlight = frame:CreateTexture(nil, "OVERLAY")
    headerHighlight:SetPoint("TOPLEFT", header, "TOPLEFT", 3, -2)
    headerHighlight:SetPoint("TOPRIGHT", header, "TOPRIGHT", -3, -2)
    headerHighlight:SetHeight(1)
    headerHighlight:Hide()

    local headerAccent = frame:CreateTexture(nil, "OVERLAY")
    headerAccent:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 3, 1)
    headerAccent:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -3, 1)
    headerAccent:SetHeight(1)
    headerAccent:Hide()

    local headerShadow = frame:CreateTexture(nil, "ARTWORK")
    headerShadow:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -1)
    headerShadow:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -1)
    headerShadow:SetHeight(3)
    headerShadow:SetColorTexture(0, 0, 0, 0.72)
    headerShadow:Hide()

    -- The optional native skin uses only Blizzard-shipped dialog artwork.
    -- It is decorative and does not alter graph rendering or combat data.
    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 2, 2)
    closeButton:SetScript("OnClick", function()
        DPSPulseForever:SetVisible(false)
    end)
    closeButton:Hide()
    frame.closeButton = closeButton

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -6)
    title:SetText("DPSPulse Forever")
    frame.title = title

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

    local graphBg = graph:CreateTexture(nil, "BACKGROUND", nil, 0)
    graphBg:SetAllPoints(graph)
    graphBg:SetColorTexture(0.02, 0.02, 0.02, 0.75)

    -- Native-skin depth: a very faint addon emblem and low-contrast chart grid.
    -- Both stay behind every label and data series, so readability is preserved.
    local graphWatermark = graph:CreateTexture(nil, "BACKGROUND", nil, 1)
    graphWatermark:SetTexture("Interface\\AddOns\\DPSPulse_Forever\\Media\\icon")
    graphWatermark:SetSize(88, 88)
    graphWatermark:SetPoint("CENTER", graph, "CENTER", 0, -5)
    graphWatermark:SetAlpha(0.035)
    if graphWatermark.SetDesaturated then graphWatermark:SetDesaturated(true) end
    graphWatermark:Hide()

    local graphGrid = {}
    for i = 1, 5 do
        local line = graph:CreateTexture(nil, "BACKGROUND", nil, 2)
        line:SetColorTexture(0.78, 0.52, 0.22, 0.10)
        line:SetWidth(1)
        line:SetPoint("TOP", graph, "TOPLEFT", (i / 6) * 300, 0)
        line:SetPoint("BOTTOM", graph, "BOTTOMLEFT", (i / 6) * 300, 0)
        line:Hide()
        graphGrid[#graphGrid + 1] = line
    end
    for i = 1, 3 do
        local line = graph:CreateTexture(nil, "BACKGROUND", nil, 2)
        line:SetColorTexture(0.78, 0.52, 0.22, 0.10)
        line:SetHeight(1)
        line:SetPoint("LEFT", graph, "BOTTOMLEFT", 0, (i / 4) * 90)
        line:SetPoint("RIGHT", graph, "BOTTOMRIGHT", 0, (i / 4) * 90)
        line:Hide()
        graphGrid[#graphGrid + 1] = line
    end

    frame.skinTextures = {
        background = bg,
        header = header,
        headerHighlight = headerHighlight,
        headerAccent = headerAccent,
        headerShadow = headerShadow,
        graphBackground = graphBg,
        graphWatermark = graphWatermark,
        graphGrid = graphGrid,
    }

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
    self:ApplySkin(DPSPulseForeverDB.skin)
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

function DPSPulseForever:RefreshOptions()
    local controls = self.ui.optionsControls
    if not controls or not controls.visible then
        return
    end

    self.ui.refreshingOptions = true
    controls.visible:SetChecked(DPSPulseForeverDB.visible)
    controls.locked:SetChecked(DPSPulseForeverDB.locked)
    controls.debug:SetChecked(DPSPulseForeverDB.debug)
    controls.classicSkin:SetChecked(DPSPulseForeverDB.skin == "classic")
    controls.blizzardSkin:SetChecked(DPSPulseForeverDB.skin == "blizzard")
    controls.window:SetValue(self:GetWindowSeconds())
    controls.scale:SetValue(DPSPulseForeverDB.scale)
    controls.windowValue:SetText(string.format("%ds", round(self:GetWindowSeconds())))
    controls.scaleValue:SetText(string.format("%.2f", DPSPulseForeverDB.scale))
    self.ui.refreshingOptions = false
end

local function setCheckButtonText(checkButton, text)
    local label = checkButton.Text or (checkButton:GetName() and _G[checkButton:GetName() .. "Text"])
    if label then
        label:SetText(text)
    end
end

function DPSPulseForever:CreateOptionsPanel()
    if self.ui.optionsPanel then
        return
    end

    local panel = CreateFrame("Frame", "DPSPulseForeverOptionsPanel", UIParent)
    panel.name = "DPSPulse Forever"
    self.ui.optionsPanel = panel

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("DPSPulse Forever")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetText("Display, graph window, and appearance")

    local controls = self.ui.optionsControls
    local visible = CreateFrame("CheckButton", "DPSPulseForeverOptionsVisible", panel, "UICheckButtonTemplate")
    visible:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", -4, -14)
    setCheckButtonText(visible, "Show DPS window")
    visible:SetScript("OnClick", function(button)
        if not DPSPulseForever.ui.refreshingOptions then
            DPSPulseForever:SetVisible(button:GetChecked() == true)
        end
    end)
    controls.visible = visible

    local locked = CreateFrame("CheckButton", "DPSPulseForeverOptionsLocked", panel, "UICheckButtonTemplate")
    locked:SetPoint("TOPLEFT", visible, "BOTTOMLEFT", 0, -4)
    setCheckButtonText(locked, "Lock window position")
    locked:SetScript("OnClick", function(button)
        if not DPSPulseForever.ui.refreshingOptions then
            DPSPulseForever:SetLocked(button:GetChecked() == true)
        end
    end)
    controls.locked = locked

    local debug = CreateFrame("CheckButton", "DPSPulseForeverOptionsDebug", panel, "UICheckButtonTemplate")
    debug:SetPoint("TOPLEFT", locked, "BOTTOMLEFT", 0, -4)
    setCheckButtonText(debug, "Debug UNIT_COMBAT events")
    debug:SetScript("OnClick", function(button)
        if not DPSPulseForever.ui.refreshingOptions then
            DPSPulseForeverDB.debug = button:GetChecked() == true
            DPSPulseForever.state.debugCount = 0
        end
    end)
    controls.debug = debug

    local windowLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    windowLabel:SetPoint("TOPLEFT", debug, "BOTTOMLEFT", 4, -20)
    windowLabel:SetText("Rolling window")
    local windowValue = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    windowValue:SetPoint("LEFT", windowLabel, "RIGHT", 12, 0)
    controls.windowValue = windowValue

    local windowSlider = CreateFrame("Slider", "DPSPulseForeverOptionsWindow", panel, "OptionsSliderTemplate")
    windowSlider:SetPoint("TOPLEFT", windowLabel, "BOTTOMLEFT", 4, -12)
    windowSlider:SetWidth(260)
    windowSlider:SetMinMaxValues(2, 60)
    windowSlider:SetValueStep(1)
    if windowSlider.SetObeyStepOnDrag then windowSlider:SetObeyStepOnDrag(true) end
    _G[windowSlider:GetName() .. "Low"]:SetText("2s")
    _G[windowSlider:GetName() .. "High"]:SetText("60s")
    _G[windowSlider:GetName() .. "Text"]:SetText("")
    windowSlider:SetScript("OnValueChanged", function(_, value)
        value = round(value)
        windowValue:SetText(string.format("%ds", value))
        if not DPSPulseForever.ui.refreshingOptions then
            DPSPulseForever:SetWindowSeconds(value)
        end
    end)
    controls.window = windowSlider

    local scaleLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    scaleLabel:SetPoint("TOPLEFT", windowSlider, "BOTTOMLEFT", -4, -28)
    scaleLabel:SetText("UI scale")
    local scaleValue = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    scaleValue:SetPoint("LEFT", scaleLabel, "RIGHT", 12, 0)
    controls.scaleValue = scaleValue

    local scaleSlider = CreateFrame("Slider", "DPSPulseForeverOptionsScale", panel, "OptionsSliderTemplate")
    scaleSlider:SetPoint("TOPLEFT", scaleLabel, "BOTTOMLEFT", 4, -12)
    scaleSlider:SetWidth(260)
    scaleSlider:SetMinMaxValues(0.5, 2)
    scaleSlider:SetValueStep(0.05)
    if scaleSlider.SetObeyStepOnDrag then scaleSlider:SetObeyStepOnDrag(true) end
    _G[scaleSlider:GetName() .. "Low"]:SetText("0.5")
    _G[scaleSlider:GetName() .. "High"]:SetText("2.0")
    _G[scaleSlider:GetName() .. "Text"]:SetText("")
    scaleSlider:SetScript("OnValueChanged", function(_, value)
        value = math.floor(value * 20 + 0.5) / 20
        scaleValue:SetText(string.format("%.2f", value))
        if not DPSPulseForever.ui.refreshingOptions then
            DPSPulseForever:SetScale(value)
        end
    end)
    controls.scale = scaleSlider

    local skinLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    skinLabel:SetPoint("TOPLEFT", scaleSlider, "BOTTOMLEFT", -4, -28)
    skinLabel:SetText("Window skin")

    local classicSkin = CreateFrame("CheckButton", "DPSPulseForeverOptionsClassicSkin", panel, "UIRadioButtonTemplate")
    classicSkin:SetPoint("TOPLEFT", skinLabel, "BOTTOMLEFT", -4, -8)
    setCheckButtonText(classicSkin, "Original / minimal")
    classicSkin:SetScript("OnClick", function()
        if not DPSPulseForever.ui.refreshingOptions then DPSPulseForever:SetSkin("classic") end
    end)
    controls.classicSkin = classicSkin

    local blizzardSkin = CreateFrame("CheckButton", "DPSPulseForeverOptionsBlizzardSkin", panel, "UIRadioButtonTemplate")
    blizzardSkin:SetPoint("LEFT", classicSkin, "RIGHT", 90, 0)
    setCheckButtonText(blizzardSkin, "Blizzard / native")
    blizzardSkin:SetScript("OnClick", function()
        if not DPSPulseForever.ui.refreshingOptions then DPSPulseForever:SetSkin("blizzard") end
    end)
    controls.blizzardSkin = blizzardSkin

    local resetData = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetData:SetSize(160, 24)
    resetData:SetPoint("TOPLEFT", classicSkin, "BOTTOMLEFT", 4, -24)
    resetData:SetText("Reset session data")
    resetData:SetScript("OnClick", function()
        DPSPulseForever:ResetSessionData()
        chat("Current fight data reset.")
    end)

    local resetPosition = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetPosition:SetSize(170, 24)
    resetPosition:SetPoint("LEFT", resetData, "RIGHT", 10, 0)
    resetPosition:SetText("Reset window position")
    resetPosition:SetScript("OnClick", function()
        DPSPulseForever:ResetWindowPosition()
        chat("Window position reset.")
    end)

    panel:SetScript("OnShow", function() DPSPulseForever:RefreshOptions() end)

    local registered = false
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local ok, category = pcall(Settings.RegisterCanvasLayoutCategory, panel, panel.name)
        if ok and category then
            panel.category = category
            registered = pcall(Settings.RegisterAddOnCategory, category)
        end
    end
    if not registered and InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end

    self:RefreshOptions()
end

function DPSPulseForever:HandleUnitCombat(unit, action, flags, amount, damageType)
    -- WoW Forever: COMBAT_LOG_EVENT_UNFILTERED is ForceTaint_strong (registering
    -- it hard-taints the addon). UNIT_COMBAT is the taint-free replacement, but
    -- only fires while the unit is your current target (and its aliases:
    -- softenemy, nameplate1, targettarget). Filter on "target" to avoid duplicates.
    -- Caveats: retargeting mid-fight loses events; group-mate damage on the same
    -- mob may inflate; some DoT/environmental damage not surfaced here.
    if unit ~= "target" then
        return
    end

    if action ~= "WOUND" then
        return
    end

    local dmg = tonumber(amount)
    if not dmg or dmg <= 0 then
        return
    end

    self:TrackDamage(now(), dmg)
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
        self:ResetSessionData()
        chat("Current fight data reset.")
        return
    end

    if command == "resetposition" then
        self:ResetWindowPosition()
        chat("Window position reset.")
        return
    end

    if command == "lock" then
        self:SetLocked(true)
        chat("Frame locked.")
        return
    end

    if command == "unlock" then
        self:SetLocked(false)
        chat("Frame unlocked.")
        return
    end

    local windowValue = command:match("^window%s+([%d%.]+)$")
    if windowValue then
        local seconds = clamp(tonumber(windowValue) or defaults.windowSeconds, 2, 60)
        self:SetWindowSeconds(seconds)
        chat("Rolling window set to " .. tostring(seconds) .. "s.")
        return
    end

    local scaleValue = command:match("^scale%s+([%d%.]+)$")
    if scaleValue then
        local scale = clamp(tonumber(scaleValue) or 1, 0.5, 2)
        self:SetScale(scale)
        chat("Scale set to " .. tostring(scale) .. ".")
        return
    end

    local skinValue = command:match("^skin%s+(%a+)$")
    if skinValue == "classic" or skinValue == "blizzard" then
        self:SetSkin(skinValue)
        chat("Skin set to " .. skinValue .. ".")
        return
    end

    if command == "debug" then
        DPSPulseForeverDB.debug = not DPSPulseForeverDB.debug
        self.state.debugCount = 0
        self:RefreshOptions()
        chat("Debug " .. (DPSPulseForeverDB.debug and "ON (first 8 UNIT_COMBAT events will dump to chat)" or "off") .. ".")
        return
    end

    chat("Commands: show, hide, toggle, window <2-60>, scale <0.5-2>, lock, unlock, reset, resetposition, skin <classic|blizzard>, debug")
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
        self:CreateOptionsPanel()
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
    elseif event == "PLAYER_LOGOUT" then
        self:SavePosition()
    elseif event == "UNIT_COMBAT" then
        self:HandleUnitCombat(...)
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("UNIT_PET")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
-- WoW Forever: COMBAT_LOG_EVENT_UNFILTERED is ForceTaint_strong; use UNIT_COMBAT.
eventFrame:RegisterEvent("UNIT_COMBAT")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    DPSPulseForever:HandleEvent(event, ...)
end)
