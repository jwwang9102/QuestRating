local _, QR = ...
local L = QR.L

-- Settings page (Esc > Options > AddOns > QuestRating, and the minimap button's window): display switches and the main
-- estimate assumptions. Plain frames on a canvas, like Questie registers its own pages.
local O = {}
QR.Options = O

local category
local controls = {} -- refresh functions

local function changed()
    QR.InvalidateQuest()
    if QR.UI and QR.UI.Refresh then QR.UI.Refresh() end
    if QR.Panel and QR.Panel.ApplyMinimap then QR.Panel.ApplyMinimap() end
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

-- Layout of a number row (user 2026-11-26: long labels ran under the boxes): the label wraps inside LABEL_W and
-- the boxes start at BOX_X, right of it; the threshold row's four boxes end inside the window (610 px).
local LABEL_X, LABEL_W, BOX_X, BOX_W = 20, 330, 360, 70
local TH_W, TH_STEP = 56, 62

-- number box; get/set let one row edit a value inside a table (thresholds)
local function numberBox(parent, label, y, get, set)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", LABEL_X, y - 4)
    fs:SetWidth(LABEL_W)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    fs:SetText(label)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(BOX_W, 20)
    eb:SetPoint("TOPLEFT", BOX_X, y)
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
    -- a wrapped label makes the row taller
    return y - math.max(26, math.ceil(fs:GetStringHeight() or 0) + 12), eb
end

local function keyBox(parent, label, key, y, lo, hi)
    return (numberBox(parent, label, y, function() return QR.Cfg()[key] end, function(v)
        if lo then v = math.max(lo, v) end
        if hi then v = math.min(hi, v) end
        QR.Cfg()[key] = v
    end))
end

-- The settings controls on panel (a new hidden frame when nil): the game's settings page and the minimap
-- button's window (Panel.lua) build the same controls. Returns the panel and the height used.
local function build(panel, noTitle)
    panel = panel or CreateFrame("Frame")
    if not noTitle then panel:Hide() end
    local y = -16
    if not noTitle then
        local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
        title:SetPoint("TOPLEFT", 16, y)
        title:SetText(L.OPT_TITLE)
        y = y - 40
    end

    y = header(panel, L.OPT_DISPLAY, y)
    y = checkbox(panel, L.OPT_SHOW_MINIMAP, "showMinimap", y)
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
    y = keyBox(panel, L.OPT_REST, "restPerKill", y, 0, 32) -- the standard grid ends at 32
    y = keyBox(panel, L.OPT_SHARE, "shareFactor", y, 0.05, 1)
    y = keyBox(panel, L.OPT_NEARBY_RADIUS, "nearbyRadius", y, 0, 300) -- the database list is built at 300 yd
    y = keyBox(panel, L.OPT_NEARBY_CAP, "nearbyCap", y, 1)
    y = keyBox(panel, L.OPT_GEAR_SMALL, "gearSmall", y, 0)
    y = keyBox(panel, L.OPT_GEAR_BIG, "gearBig", y, 0)
    y = keyBox(panel, L.OPT_GEAR_OFFSET, "gearLevelOffset", y, 0)

    local thY = y
    for i = 1, 4 do
        -- only the first box shows the row label
        local ny, eb = numberBox(panel, i == 1 and L.OPT_THRESHOLDS or "", y, function() return QR.Cfg().thresholds[i] end,
            function(v)
                -- keep the bands in order: between the neighbouring thresholds
                local t = QR.Cfg().thresholds
                v = math.max(t[i - 1] or 0, v)
                if t[i + 1] then v = math.min(t[i + 1], v) end
                t[i] = v
            end)
        eb:ClearAllPoints()
        eb:SetWidth(TH_W)
        eb:SetPoint("TOPLEFT", BOX_X + (i - 1) * TH_STEP, y)
        if i == 1 then thY = ny end
    end
    y = thY - 10

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
    return panel, 16 - (y - 24)
end
O.Build = build

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
