local _, QR = ...
local L = QR.L

-- Minimap button and its window (user 2026-11-26: "like OneForAll"): a button on the minimap rim (drag to
-- move it around, left-click opens / closes the window) and a window with two tabs: your measured pace
-- (KillTimer: fight time, rest, gap) and the settings (the same controls as the game's settings page).
-- The button's geometry follows OneForAll / LibDBIcon so it sits like other minimap buttons.
local P = {}
QR.Panel = P

local button, frame

local function getAngle(y, x)
    if math.atan2 then return math.atan2(y, x) end
    if x == 0 then return y >= 0 and math.pi / 2 or -math.pi / 2 end
    local a = math.atan(y / x)
    if x < 0 then a = a + math.pi end
    return a
end

local function positionButton()
    if not button or not Minimap then return end
    local angle = (QR.db and QR.db.minimapAngle) or 200
    local half = (Minimap:GetWidth() or 140) / 2
    local radius = half + 5
    local r = math.rad(angle)
    local x, y = math.cos(r), math.sin(r)
    if (GetMinimapShape and GetMinimapShape() or "ROUND") == "SQUARE" then
        local m = math.max(math.abs(x), math.abs(y))
        if m > 0 then x, y = x / m, y / m end
        radius = half + 4
    end
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x * radius, y * radius)
end

local function dragUpdate()
    local mx, my = Minimap:GetCenter()
    if not mx then return end
    local scale = UIParent:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    local angle = math.deg(getAngle(cy / scale - my, cx / scale - mx))
    if angle < 0 then angle = angle + 360 end
    if QR.db then QR.db.minimapAngle = angle end
    positionButton()
end

-- ---------------------------------------------------------------------------------------- statistics

local function fmtSrc(src)
    return src == "measured" and L.PANEL_SRC_MEASURED or src == "character" and L.PANEL_SRC_CHARACTER or L.PANEL_SRC_DEFAULT
end

local function statsText()
    local K, cfg = QR.Kill, QR.Cfg()
    local level = UnitLevel("player") or 1
    local lines = {}
    local function add(fmt, ...) lines[#lines + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt end
    add(L.PANEL_WHO, UnitName("player") or "?", level, math.max(1, level - 2), level)
    add("")
    local fb, nfb = K.FightBase(level)
    add(L.PANEL_FIGHT, fb and string.format(L.PANEL_FIGHT_MEASURED, fb) or string.format(L.PANEL_FIGHT_DEFAULT, cfg.fightBase), nfb)
    local rest, nr, src = K.Rest(level, cfg.restPerKill)
    add(L.PANEL_REST, rest, fmtSrc(src), nr, K.REST_KILLS)
    local gp, ngp = K.Gap(level)
    add(L.PANEL_GAP, gp and string.format("%.1f", gp) or "-", ngp)
    add("")
    add(L.PANEL_LEVELS)
    local any = false
    for l = level, math.max(1, level - 5), -1 do
        local s = K.LevelStats(l)
        if s then
            any = true
            local restText = s.rk > 0 and string.format(L.PANEL_REST_ROW, s.rf, s.rk, s.rs / s.rk) or L.PANEL_REST_NONE
            add(L.PANEL_LEVEL_ROW, l, s.nf, restText, s.ng)
        end
    end
    if not any then add(L.PANEL_NO_RECORDS) end
    add("")
    add(L.PANEL_NOTE)
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------------------- window

local function makeTab(parent, id, text, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(110, 24)
    b:SetText(text)
    b:SetPoint("TOPLEFT", 14 + (id - 1) * 116, -30)
    b:SetScript("OnClick", onClick)
    return b
end

local function build()
    frame = CreateFrame("Frame", "QuestRatingPanel", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(660, 560)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    tinsert(UISpecialFrames, "QuestRatingPanel") -- Esc closes it
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -6)
    title:SetText(L.OPT_TITLE)

    -- statistics tab
    local stats = CreateFrame("Frame", nil, frame)
    stats:SetPoint("TOPLEFT", 12, -60)
    stats:SetPoint("BOTTOMRIGHT", -12, 12)
    local text = stats:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("TOPLEFT", 8, -8)
    text:SetPoint("RIGHT", -8, 0)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetSpacing(3)
    local function refreshStats() text:SetText(statsText()) end
    stats:SetScript("OnShow", refreshStats)

    -- settings tab: the settings controls in a scroll frame
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -60)
    scroll:SetPoint("BOTTOMRIGHT", -32, 12)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(610, 100)
    scroll:SetScrollChild(child)
    local _, height = QR.Options.Build(child, true)
    child:SetHeight(height or 800)
    scroll:Hide()

    local function show(which)
        stats:SetShown(which == 1)
        scroll:SetShown(which == 2)
        if which == 1 then refreshStats() elseif QR.Options.Refresh then QR.Options.Refresh() end
    end
    makeTab(frame, 1, L.PANEL_TAB_STATS, function() show(1) end)
    makeTab(frame, 2, L.PANEL_TAB_SETTINGS, function() show(2) end)
    frame:SetScript("OnShow", function() show(stats:IsShown() and 1 or (scroll:IsShown() and 2 or 1)) end)
end

function P.Toggle()
    if not frame then build() end
    frame:SetShown(not frame:IsShown())
end

-- ---------------------------------------------------------------------------------------- button

function P.ApplyMinimap()
    if not button then return end
    button:SetShown(QR.Cfg().showMinimap ~= false)
end

local function createButton()
    if button or not Minimap then return end
    button = CreateFrame("Button", "QuestRatingMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel((Minimap:GetFrameLevel() or 0) + 8)
    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("LeftButton")
    -- LibDBIcon geometry: background, icon, tracking border anchored at the button's top left
    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    button:SetScript("OnClick", function() P.Toggle() end)
    button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", dragUpdate) end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(L.OPT_TITLE, 1, 0.82, 0)
        GameTooltip:AddLine(L.PANEL_TIP_CLICK, 1, 1, 1)
        GameTooltip:AddLine(L.PANEL_TIP_DRAG, 0.75, 0.75, 0.75)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    positionButton()
    if Minimap.HookScript then Minimap:HookScript("OnSizeChanged", positionButton) end
    -- also in the game's AddOns list at the minimap, where the client has one
    if type(AddonCompartmentFrame) == "table" and type(AddonCompartmentFrame.RegisterAddon) == "function" then
        pcall(AddonCompartmentFrame.RegisterAddon, AddonCompartmentFrame, {
            text = L.OPT_TITLE, icon = "Interface\\Icons\\INV_Misc_Note_01", notCheckable = true,
            func = function() P.Toggle() end,
        })
    end
    P.ApplyMinimap()
end

QR.RegisterReady(createButton)
