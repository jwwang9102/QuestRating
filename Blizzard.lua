local _, QR = ...
local L = QR.L
local D = QR.Data

-- Rating in Blizzard's own quest UI, with or without Questie (plan section 8):
--   * objective tracker (QuestObjectiveTracker blocks, as QLens uses on Forever)
--   * quest log on the world map (QuestScrollFrame title buttons) and the classic QuestLogFrame
--   * hovering a quest log title adds the QuestRating block to its tooltip
-- Only post-hooks and our own FontStrings: Blizzard's text, layout and secure code are left alone
-- (replacing native layout methods taints them on protected clients).
local B = {}
QR.Blizzard = B

local issecret = _G.issecretvalue or function() return false end

-- One FontString of ours per Blizzard row (row.qrTag: a field on Blizzard's row frame): rating word (+ reasons when there is room), placed right
-- after the row's own text on its last line.
local function placeTag(row, textFS, questId, withReasons)
    if not row or not textFS then return end
    local tagFS = row.qrTag
    if not tagFS then
        tagFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        tagFS:SetWordWrap(false)
        row.qrTag = tagFS
    end
    local short, full, tiny = QR.UI.TagParts(questId)
    if not short then tagFS:Hide(); return end
    tagFS:ClearAllPoints()
    -- room: from where the title starts to the row's right edge, or to the first other text of the row
    -- on the right (e.g. the quest type "（地城）" in the quest log), whichever comes first
    -- the visible text column: never past the title's own box (a tracker block can be wider than it shows)
    local left, right = textFS:GetLeft(), row:GetRight()
    local tr = textFS:GetRight()
    if right and tr and tr > (left or 0) + 40 then right = math.min(right, tr) end
    if left and right then
        for _, region in ipairs({ row:GetRegions() }) do
            if region ~= textFS and region ~= tagFS and region.GetObjectType and region:GetObjectType() == "FontString"
                and region:IsShown() and (region:GetText() or "") ~= "" then
                local rl = region:GetLeft()
                if rl and rl > left + 20 and rl < right then right = rl end
            end
        end
    end
    local room = (left and right) and (right - left - 4) or ((textFS:GetWidth() or 0) - 4)
    local boxW = textFS:GetWidth() or 0
    local unbounded = textFS.GetUnboundedStringWidth and textFS:GetUnboundedStringWidth() or textFS:GetStringWidth()
    unbounded = unbounded or 0
    local wrapped = unbounded > boxW + 1
    local function width(t) tagFS:SetText(t); return tagFS:GetStringWidth() or 0 end

    if not wrapped then
        -- the longest tag that fits after the whole title
        local x = (textFS:GetStringWidth() or 0) + 4
        for _, t in ipairs(withReasons and { full, short } or { short }) do
            if x + width(t) <= room then
                tagFS:SetPoint("BOTTOMLEFT", textFS, "BOTTOMLEFT", x, 0)
                tagFS:Show()
                return
            end
        end
    elseif boxW > 0 then
        -- a wrapped title (row height already fits two lines): the rating word right-aligned on the
        -- last line when that line leaves room (CJK titles break per character, so its width is about
        -- the remainder of the full width)
        local last = unbounded - math.floor(unbounded / boxW) * boxW
        local tw = width(short)
        if left and right and last + 4 + tw <= room then
            tagFS:SetPoint("BOTTOMRIGHT", textFS, "BOTTOMLEFT", right - left - 2, 0)
            tagFS:Show()
            return
        end
    end
    -- nothing else fits: the coloured mark just left of the right-hand text (never over the objective
    -- lines below, never over the quest type)
    tagFS:SetText(tiny)
    if left and right then
        tagFS:SetPoint("BOTTOMRIGHT", textFS, "BOTTOMLEFT", right - left - 2, 0)
    else
        tagFS:SetPoint("BOTTOMRIGHT", textFS, "BOTTOMRIGHT", 0, 0)
    end
    tagFS:Show()
end

local function hideTag(row) if row and row.qrTag then row.qrTag:Hide() end end

local warned = {}
local function guard(key, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok and not warned[key] then
        warned[key] = true
        QR.Print(L.MSG_HOOK_FAILED, key, tostring(err))
    end
end

-- hovering a tracker block's quest title: the QuestRating tooltip (rating and reasons; user 2026-11-23)
local hoverHooked = setmetatable({}, { __mode = "k" }) -- blocks hooked (a local table, not a field on them)
local function trackerHover(self, block)
    if not QR.Cfg().showTooltip then return end
    local id = block.id
    if issecret(id) or type(id) ~= "number" or not D.Record(id) then return end
    if not GameTooltip:IsOwned(self) then GameTooltip:SetOwner(self, "ANCHOR_LEFT") else GameTooltip:AddLine(" ") end
    QR.UI.FillTooltip(GameTooltip, id)
    GameTooltip:Show()
end
local function hookTrackerHover(block)
    if hoverHooked[block] then return end
    for _, f in ipairs({ block.HeaderButton or false, block }) do
        if f and f.HookScript and f.HasScript and f:HasScript("OnEnter") then
            hoverHooked[block] = true -- the first frame that takes the mouse; never a second one
            f:HookScript("OnEnter", function(self) guard("tracker tooltip", trackerHover, self, block) end)
            f:HookScript("OnLeave", function(self) if GameTooltip:IsOwned(self) then GameTooltip:Hide() end end)
            return
        end
    end
end


---------------------------------------------------------------------------------------------
-- Objective tracker
---------------------------------------------------------------------------------------------
local function decorateTracker(tracker)
    if type(tracker.EnumerateActiveBlocks) ~= "function" then return end
    local cfg = QR.Cfg()
    tracker:EnumerateActiveBlocks(function(block)
        local id = block and block.id
        if issecret(id) or type(id) ~= "number" or not block.HeaderText then return end
        if cfg.showTracker and D.Record(id) then
            -- one block failing (e.g. secret values) must not stop the others
            if not pcall(placeTag, block, block.HeaderText, id, (cfg.trackerReasons or 0) > 0) then hideTag(block) end
            pcall(hookTrackerHover, block)
        else
            hideTag(block)
        end
    end)
end

-- older module tracker (QUEST_TRACKER_MODULE): blocks in usedBlocks[template][questID] or usedBlocks[questID]
local function decorateModule(module)
    local cfg = QR.Cfg()
    local function visit(block)
        local id = type(block) == "table" and block.id
        if issecret(id) or type(id) ~= "number" or not block.HeaderText then return end
        if cfg.showTracker and D.Record(id) and block:IsShown() then
            if not pcall(placeTag, block, block.HeaderText, id, (cfg.trackerReasons or 0) > 0) then hideTag(block) end
            pcall(hookTrackerHover, block)
        else
            hideTag(block)
        end
    end
    for _, v in pairs(module.usedBlocks or {}) do
        if type(v) == "table" and v.HeaderText then visit(v)
        elseif type(v) == "table" then for _, block in pairs(v) do visit(block) end end
    end
end

local trackerHooked = false
local function hookTracker()
    if trackerHooked then return true end
    local tracker = _G.QuestObjectiveTracker
    if tracker and type(tracker.Update) == "function" then
        hooksecurefunc(tracker, "Update", function(self) guard("QuestObjectiveTracker", decorateTracker, self) end)
        trackerHooked = true
    elseif _G.QUEST_TRACKER_MODULE and type(QUEST_TRACKER_MODULE.Update) == "function" then
        hooksecurefunc(QUEST_TRACKER_MODULE, "Update", function(self) guard("QUEST_TRACKER_MODULE", decorateModule, self) end)
        trackerHooked = true
    end
    return trackerHooked
end

---------------------------------------------------------------------------------------------
-- Wider quest log on the world map: the window grows by cfg.questLogExtraWidth and the quest log
-- takes all of it, so the map keeps its size. Everything Blizzard draws at a fixed width inside the
-- log grows with it (structure from the forever branch of Blizzard's UI source):
--   list:    title buttons (290), objective lines (220 / text 205), zone headers (289), the
--            story header and separator (304) and the parchment background (atlas width, reset by
--            UpdateBackground). Pooled rows are widened when acquired, before Blizzard sets their
--            text and measures their height, so wrapping and row heights use the new width.
--   details: the details frame (308), its scroll area (298), back bar and rewards box (307) with
--            their art, the three buttons, and the QuestInfo texts (contentWidth 289).
-- Only sizes and anchors are changed, after Blizzard's own code has run. 0 turns it off.
---------------------------------------------------------------------------------------------
local logBase -- Blizzard's own window widths, read once before we change anything
-- Never in combat (user 2026-11-23: clicking a tracker title in combat did nothing; these hooks run on the
-- path that opens the map and changed its frames from addon code): skipped, applied when combat ends.
local widenPending = false
local function inCombat()
    if InCombatLockdown and InCombatLockdown() then widenPending = true; return true end
    return false
end

local function extraWidth()
    return math.max(0, math.floor(QR.Cfg().questLogExtraWidth or 0))
end

local function captureBase()
    if logBase then return logBase end
    local map, qmf = _G.WorldMapFrame, _G.QuestMapFrame
    if not (map and qmf and map.questLogWidth and map.minimizedWidth) then return nil end
    logBase = { panel = qmf:GetWidth(), questLogWidth = map.questLogWidth, minimizedWidth = map.minimizedWidth }
    return logBase
end

-- width = the object's own original width + add; the original is remembered the first time we see it
local function widen(obj, add)
    if not (obj and obj.GetWidth) then return end
    if not obj.qrBaseWidth then obj.qrBaseWidth = obj:GetWidth() end
    local want = obj.qrBaseWidth + (add or extraWidth())
    if math.abs((obj:GetWidth() or 0) - want) >= 0.5 then obj:SetWidth(want) end
end

-- window and map area, after Blizzard sized the window and anchored the map area
-- (post-hook of UpdateSpacerFrameAnchoring, which ends every display-state change)
local function layoutMap(map)
    if inCombat() or not captureBase() then return end
    if not (map.QuestLog and map.QuestLog:IsShown()) then return end -- no log: Blizzard's own layout
    local extra = extraWidth()
    map.TitleCanvasSpacerFrame:SetPoint("BOTTOMRIGHT", map, "TOPRIGHT", -3 - logBase.questLogWidth - extra, -67)
    if not (map.IsMaximized and map:IsMaximized()) then
        local want = logBase.minimizedWidth + logBase.questLogWidth + extra
        if math.abs((map:GetWidth() or 0) - want) >= 0.5 then map:SetWidth(want) end
    end
end

-- the parchment behind the list: Blizzard sets it to its atlas size, anchored top-left only
local function fitListBackground(scroll)
    if inCombat() then return end
    local bg = scroll and scroll.Background
    local atlas = bg and bg.GetAtlas and bg:GetAtlas()
    local info = atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas)
    if info and info.width then bg:SetWidth(info.width + extraWidth()) end
end

-- pooled rows: widen every active row the first time (and after a width change)
local function widenPool(pool, objective)
    if inCombat() or not (pool and pool.EnumerateActive) then return end
    local extra = extraWidth()
    for obj in pool:EnumerateActive() do
        if obj.qrWidened ~= extra then
            obj.qrWidened = extra
            widen(obj, extra)
            if objective then widen(obj.Text, extra) end
        end
    end
end

local function widenList()
    local scroll = _G.QuestScrollFrame
    if not scroll then return end
    widenPool(scroll.titleFramePool)
    widenPool(scroll.objectiveFramePool, true)
    widenPool(scroll.headerFramePool)
    local c = scroll.Contents
    if c then
        widen(c.Separator)
        if c.StoryHeader then widen(c.StoryHeader); widen(c.StoryHeader.Background) end
    end
    fitListBackground(scroll)
end

local function widenDetails()
    local d = _G.QuestMapFrame and QuestMapFrame.DetailsFrame
    if inCombat() or not d then return end
    local extra = extraWidth()
    widen(d, extra)
    if d.ScrollFrame then widen(d.ScrollFrame, extra); widen(d.ScrollFrame.Contents, extra) end
    if d.BackFrame then
        widen(d.BackFrame, extra)
        for _, region in ipairs({ d.BackFrame:GetRegions() }) do
            if region.GetObjectType and region:GetObjectType() == "Texture" then widen(region, extra) end
        end
    end
    local box = d.RewardsFrameContainer
    if box then
        widen(box, extra)
        local r = box.RewardsFrame
        if r then widen(r, extra); widen(r.Top, extra); widen(r.Bottom, extra) end
    end
    -- the button row: share the extra width between the three buttons
    local third = math.floor(extra / 3)
    widen(d.AbandonButton, third)
    widen(d.ShareButton, third)
    widen(d.TrackButton, extra - 2 * third)
    -- (Blizzard's AdjustBackgroundTexture is not called from here: Blizzard code run from an addon taints what
    -- it writes)
end

-- QuestInfo texts in the details view: Blizzard sets them to the template's contentWidth
local lastInfoTemplate
local function widenQuestInfo(template)
    lastInfoTemplate = template
    if template ~= _G.QUEST_TEMPLATE_MAP_DETAILS or not template.contentWidth or inCombat() then return end
    local w = template.contentWidth + extraWidth()
    for _, fs in ipairs({ _G.QuestInfoTitleHeader, _G.QuestInfoObjectivesText, _G.QuestInfoTimerText,
                          _G.QuestInfoDescriptionText }) do
        if fs then fs:SetWidth(w) end
    end
    local objectives = _G.QuestInfoObjectivesFrame and QuestInfoObjectivesFrame.Objectives
    if objectives then
        for _, fs in ipairs(objectives) do fs:SetWidth(w) end
    end
end

local function applyLogWidth()
    if inCombat() or not captureBase() then return end
    widenPending = false
    QuestMapFrame:SetWidth(logBase.panel + extraWidth())
    widenList()
    widenDetails()
    -- our own layout after Blizzard's (not Blizzard's UpdateSpacerFrameAnchoring called from here: taint)
    layoutMap(WorldMapFrame)
end

local widenHooked = false
local function hookWiden()
    if widenHooked then return true end
    local map, qmf, scroll = _G.WorldMapFrame, _G.QuestMapFrame, _G.QuestScrollFrame
    if not (map and qmf and scroll) then return false end
    widenHooked = true
    captureBase()
    if type(map.UpdateSpacerFrameAnchoring) == "function" then
        hooksecurefunc(map, "UpdateSpacerFrameAnchoring", function(self) guard("WorldMapFrame width", layoutMap, self) end)
    end
    -- rows are widened as soon as they are acquired, before Blizzard fills and measures them
    for _, key in ipairs({ "titleFramePool", "objectiveFramePool", "headerFramePool" }) do
        local pool = scroll[key]
        if pool and type(pool.Acquire) == "function" then
            hooksecurefunc(pool, "Acquire", function() guard("QuestMapFrame width", widenPool, pool, key == "objectiveFramePool") end)
        end
    end
    if type(scroll.ResizeBackground) == "function" then
        hooksecurefunc(scroll, "ResizeBackground", function(self) guard("QuestMapFrame width", fitListBackground, self) end)
    end
    if type(_G.QuestInfo_Display) == "function" then
        hooksecurefunc("QuestInfo_Display", function(template) guard("QuestMapFrame width", widenQuestInfo, template) end)
    end
    if type(_G.QuestInfo_AdjustTitleWidth) == "function" then
        hooksecurefunc("QuestInfo_AdjustTitleWidth", function(delta)
            guard("QuestMapFrame width", function()
                if inCombat() then return end
                local t = lastInfoTemplate
                if t and t == _G.QUEST_TEMPLATE_MAP_DETAILS and t.contentWidth and _G.QuestInfoTitleHeader then
                    QuestInfoTitleHeader:SetWidth(t.contentWidth + (delta or 0) + extraWidth())
                end
            end)
        end)
    end
    if qmf.DetailsFrame then
        qmf.DetailsFrame:HookScript("OnShow", function() guard("QuestMapFrame width", widenDetails) end)
    end
    qmf:HookScript("OnShow", function() guard("QuestMapFrame width", applyLogWidth) end)
    map:HookScript("OnShow", function() guard("QuestMapFrame width", applyLogWidth) end)
    local regen = CreateFrame("Frame")
    regen:RegisterEvent("PLAYER_REGEN_ENABLED")
    regen:SetScript("OnEvent", function()
        if widenPending and map:IsShown() then guard("QuestMapFrame width", applyLogWidth) end
    end)
    return true
end

---------------------------------------------------------------------------------------------
-- Quest log: world map (QuestScrollFrame) and classic QuestLogFrame
---------------------------------------------------------------------------------------------
local function decorateMapLog()
    local pool = _G.QuestScrollFrame and QuestScrollFrame.titleFramePool
    if not (pool and pool.EnumerateActive) then return end
    guard("QuestMapFrame width", widenList) -- normally already done when the rows were acquired
    local show = QR.Cfg().showTracker
    for button in pool:EnumerateActive() do
        local id = button.questID
        if show and type(id) == "number" and not issecret(id) and D.Record(id) and button.Text then
            if not pcall(placeTag, button, button.Text, id, false) then hideTag(button) end
        else
            hideTag(button)
        end
        -- tooltip: per button, works whether OnEnter is the global function or a mixin method
        if not button.qrHooked then
            button.qrHooked = true
            button:HookScript("OnEnter", function(self) guard("quest log tooltip", B.AddLogTooltip, self) end)
        end
    end
end

local function decorateClassicLog()
    local shown = _G.QUESTS_DISPLAYED or 0
    local scroll = _G.QuestLogListScrollFrame
    local offset = (scroll and FauxScrollFrame_GetOffset) and FauxScrollFrame_GetOffset(scroll) or 0
    local show = QR.Cfg().showTracker
    for i = 1, shown do
        local button = _G["QuestLogTitle" .. i]
        if button then
            local _, _, _, isHeader, _, _, _, id = GetQuestLogTitle(i + offset)
            local textFS = button.GetFontString and button:GetFontString() or _G["QuestLogTitle" .. i .. "NormalText"]
            if show and not isHeader and type(id) == "number" and D.Record(id) and button:IsShown() then
                placeTag(button, textFS, id, false)
            else
                hideTag(button)
            end
        end
    end
end

-- hovering a quest log title: our block below Blizzard's tooltip lines
function B.AddLogTooltip(button)
    if not QR.Cfg().showTooltip then return end
    local id = button and button.questID
    if type(id) ~= "number" or issecret(id) or not D.Record(id) then return end
    if not GameTooltip:IsOwned(button) then return end
    GameTooltip:AddLine(" ")
    QR.UI.FillTooltip(GameTooltip, id)
    GameTooltip:Show()
end

local hooked = {}
local function hookGlobal(name, fn)
    if hooked[name] then return true end
    if type(_G[name]) ~= "function" then return false end
    hooksecurefunc(name, fn)
    hooked[name] = true
    return true
end

local function hookLogs()
    hookWiden()
    local map = hookGlobal("QuestLogQuests_Update", function() guard("QuestLogQuests_Update", decorateMapLog) end)
    local classic = _G.QuestLogTitle1 and GetQuestLogTitle
        and hookGlobal("QuestLog_Update", function() guard("QuestLog_Update", decorateClassicLog) end)
    return map or classic or false
end

-- Redraw Blizzard's tracker and log after a rating change that came without a quest event.
function B.Refresh()
    if InCombatLockdown() then return end -- native events redraw them; never touch layout in combat
    local tracker = _G.QuestObjectiveTracker
    if tracker then guard("QuestObjectiveTracker", decorateTracker, tracker) end
    if _G.QuestScrollFrame and QuestScrollFrame:IsVisible() then
        guard("QuestMapFrame width", applyLogWidth)
        guard("QuestLogQuests_Update", decorateMapLog)
    end
    if _G.QuestLogFrame and QuestLogFrame:IsVisible() then guard("QuestLog_Update", decorateClassicLog) end
end

-- The tracker and the map's quest log can be load-on-demand Blizzard addons: hook what exists now and
-- the rest when it loads.
QR.RegisterReady(function()
    local okTracker, okLog = hookTracker(), hookLogs()
    if not (okTracker and okLog) then
        local f = CreateFrame("Frame")
        f:RegisterEvent("ADDON_LOADED")
        f:SetScript("OnEvent", function(self)
            okTracker = okTracker or hookTracker()
            okLog = okLog or hookLogs()
            if okTracker and okLog then self:UnregisterEvent("ADDON_LOADED") end
            B.Refresh()
        end)
        -- still missing well after login: say so once instead of failing silently
        C_Timer.After(30, function()
            if okTracker and okLog then return end
            f:UnregisterEvent("ADDON_LOADED")
            local missing = {}
            if not okTracker then missing[#missing + 1] = L.UI_TRACKER end
            if not okLog then missing[#missing + 1] = L.UI_QUEST_LOG end
            QR.Print(L.MSG_NO_QUEST_UI, table.concat(missing, "、"))
        end)
    end
    B.Refresh()
end)
