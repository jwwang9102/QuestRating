local _, QR = ...
local L = QR.L

-- Settings page (Esc > Options > AddOns > QuestRating, or /qr): display switches and the main
-- estimate assumptions. Plain frames on a canvas, like Questie registers its own pages.
local O = {}
QR.Options = O

local category
local controls = {} -- refresh functions

local function changed()
    QR.InvalidateQuest()
    if QR.UI and QR.UI.Refresh then QR.UI.Refresh() end
end

local function header(parent, text, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", 16, y)
    fs:SetText(text)
    return y - 28
end

local function checkbox(parent, label, key, y)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 16, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    fs:SetText(label)
    cb:SetScript("OnClick", function(self)
        QR.Cfg()[key] = self:GetChecked() and true or false
        changed()
    end)
    controls[#controls + 1] = function() cb:SetChecked(QR.Cfg()[key]) end
    return y - 30
end

-- number box; get/set let one row edit a value inside a table (thresholds)
local function numberBox(parent, label, y, get, set)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", 20, y - 4)
    fs:SetText(label)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(70, 20)
    eb:SetPoint("TOPLEFT", 300, y)
    eb:SetAutoFocus(false)
    local function commit(self)
        local v = tonumber(self:GetText())
        if v then
            set(v)
            changed()
        else
            QR.Print(L.OPT_BAD_VALUE, label ~= "" and label or L.OPT_THRESHOLDS)
        end
        self:SetText(tostring(get()))
        self:ClearFocus()
    end
    eb:SetScript("OnEnterPressed", commit)
    eb:SetScript("OnEditFocusLost", function(self)
        if self:GetText() ~= tostring(get()) then commit(self) end
    end)
    eb:SetScript("OnEscapePressed", function(self) self:SetText(tostring(get())); self:ClearFocus() end)
    controls[#controls + 1] = function() eb:SetText(tostring(get())) end
    return y - 26, eb
end

local function keyBox(parent, label, key, y, lo, hi)
    return (numberBox(parent, label, y, function() return QR.Cfg()[key] end, function(v)
        if lo then v = math.max(lo, v) end
        if hi then v = math.min(hi, v) end
        QR.Cfg()[key] = v
    end))
end

local function build()
    local panel = CreateFrame("Frame")
    panel:Hide()
    local y = -16
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", 16, y)
    title:SetText(L.OPT_TITLE)
    y = y - 40

    y = header(panel, L.OPT_DISPLAY, y)
    y = checkbox(panel, L.OPT_SHOW_TRACKER, "showTracker", y)
    y = keyBox(panel, L.OPT_TRACKER_REASONS, "trackerReasons", y, 0, 2)
    y = checkbox(panel, L.OPT_SHOW_TOOLTIP, "showTooltip", y)
    y = checkbox(panel, L.OPT_SHOW_DROPRATE, "showDropRate", y)
    y = keyBox(panel, L.OPT_LOG_WIDTH, "questLogExtraWidth", y, 0, 400)
    y = y - 10

    y = header(panel, L.OPT_ESTIMATE, y)
    y = keyBox(panel, L.OPT_WALK, "walkSpeed", y, 1)
    y = keyBox(panel, L.OPT_MOUNT, "mountSpeed", y, 1)
    y = keyBox(panel, L.OPT_RESPAWN, "respawn", y, 0)
    y = keyBox(panel, L.OPT_FIGHT, "fightBase", y, 1)
    y = keyBox(panel, L.OPT_SHARE, "shareFactor", y, 0.05, 1)
    y = keyBox(panel, L.OPT_NEARBY_RADIUS, "nearbyRadius", y, 0)
    y = keyBox(panel, L.OPT_NEARBY_CAP, "nearbyCap", y, 1)
    y = keyBox(panel, L.OPT_GEAR_SMALL, "gearSmall", y, 0)
    y = keyBox(panel, L.OPT_GEAR_BIG, "gearBig", y, 0)
    y = keyBox(panel, L.OPT_GEAR_OFFSET, "gearLevelOffset", y, 0)
    y = keyBox(panel, L.OPT_BAND_MID, "bandMid", y, 0.05, 3)
    y = keyBox(panel, L.OPT_BAND_OUT, "bandOut", y, 0.1, 5)

    for i = 1, 4 do
        -- only the first box shows the row label
        local _, eb = numberBox(panel, i == 1 and L.OPT_THRESHOLDS or "", y, function() return QR.Cfg().thresholds[i] end,
            function(v)
                -- keep the bands in order: between the neighbouring thresholds
                local t = QR.Cfg().thresholds
                v = math.max(t[i - 1] or 0, v)
                if t[i + 1] then v = math.min(t[i + 1], v) end
                t[i] = v
            end)
        eb:ClearAllPoints()
        eb:SetPoint("TOPLEFT", 300 + (i - 1) * 78, y)
    end
    y = y - 36

    local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    reset:SetSize(140, 24)
    reset:SetPoint("TOPLEFT", 16, y)
    reset:SetText(L.OPT_RESET)
    reset:SetScript("OnClick", function()
        local p = QR.Cfg()
        for k in pairs(QR.DEFAULTS) do p[k] = nil end
        QR.FillDefaults()
        O.Refresh()
        changed()
        QR.Print(L.OPT_RESET_DONE)
    end)

    panel:SetScript("OnShow", function() O.Refresh() end)
    return panel
end

function O.Refresh()
    for _, fn in ipairs(controls) do fn() end
end

function O.Open()
    if category and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(category:GetID())
    end
end

QR.RegisterReady(function()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
    local panel = build()
    category = Settings.RegisterCanvasLayoutCategory(panel, L.OPT_TITLE)
    Settings.RegisterAddOnCategory(category)
end)
