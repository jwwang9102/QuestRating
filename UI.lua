local _, QR = ...
local L = QR.L
local D = QR.Data

-- User interface (plan section 8). Kept close to Questie's own look and only where needed:
--   * Questie tracker: a coloured rating tag after each quest title, and a QuestRating tooltip on hover.
--   * Questie map icon tooltip: the rating tag after each giver's quest title.
--   * Quest offer window: the QuestRating block between the title and the description.
--   * Unit tooltips: the drop % after the objective line. With Questie we fill in Questie's own drop-rate
--     lookup where it has no data (so Questie formats the line); without Questie we add the line ourselves.
-- Every hook checks that the Questie function exists and is wrapped in pcall: if Questie changes, that
-- part switches off with one chat note instead of a Lua error.
local UI = {}
QR.UI = UI

local COLOR = { [0] = "ff9d9d9d", [1] = "ffffffff", [2] = "ffffd100", [3] = "ff1eff00", [4] = "ffff8000" }
local GRAY = "ff9d9d9d"

local function colorize(text, color) return "|c" .. color .. text .. "|r" end
UI.COLOR, UI.GRAY, UI.colorize = COLOR, GRAY, colorize

-- Same rules as Questie's drop-rate text.
local function dropText(rate)
    if rate >= 10 then return string.format("%.0f", rate)
    elseif rate >= 2 then return string.format("%.1f", rate)
    elseif rate >= 0.01 then return string.format("%.2f", rate) end
    return string.format("%.3f", rate)
end

local warned = {}
local function warnOnce(key, err)
    if warned[key] then return end
    warned[key] = true
    QR.Print(L.MSG_HOOK_FAILED, key, tostring(err))
end

---------------------------------------------------------------------------------------------
-- Rating text
---------------------------------------------------------------------------------------------
-- Coloured tag texts: short "【低】", full "【低｜掉率 15%·約 67 隻】" (trackerReasons reasons) and
-- tiny "◆" (a coloured mark where there is no room), or nil when the quest cannot be rated at all.
-- Only characters the zhTW game fonts have (Big5 set): "‹ ›" showed as boxes in game.
function UI.TagParts(questId)
    local res = QR.RateCached(questId)
    if not res then return nil end
    if res.noData then
        -- "【資料不足｜經驗不明】": what is missing, as many as the tracker shows reasons ("不評": no XP)
        local word = res.unrated and L.UNRATED or L.NO_DATA
        local text = word
        local n = math.min(QR.Cfg().trackerReasons or 0, #(res.reasons or {}))
        if n > 0 and res.reasons[1] ~= L.NO_DATA then
            local parts = {}
            for i = 1, n do parts[i] = res.reasons[i] end
            text = text .. "｜" .. table.concat(parts, "·")
        end
        return colorize("【" .. word .. "】", GRAY), colorize("【" .. text .. "】", GRAY), colorize("◆", GRAY)
    end
    local color = COLOR[res.level] or GRAY
    local word = L.RATING[res.level]
    local text = word
    local n = math.min(QR.Cfg().trackerReasons or 0, #(res.reasons or {}))
    if n > 0 then
        local parts = {}
        for i = 1, n do parts[i] = res.reasons[i] end
        text = text .. "｜" .. table.concat(parts, "·")
    end
    return colorize("【" .. word .. "】", color), colorize("【" .. text .. "】", color), colorize("◆", color)
end

-- " 【低｜掉率 15%·約 67 隻】" after a Questie tracker title; "" when there is nothing to show.
function UI.Tag(questId)
    if not QR.Cfg().showTracker then return "" end
    local _, full = UI.TagParts(questId)
    return full and (" " .. full) or ""
end

-- "[25] 名稱" for one follow-up quest. No rating of its own (user 2026-11-23): before this quest is done the
-- follow-up cannot be taken, and its worth is already in this quest's rating (the whole chain); its own rating
-- shows once it can be taken.
local function followUpLine(questId)
    local rec = D.Record(questId)
    local title = (C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questId))
        or (rec and rec.t) or tostring(questId)
    local level = rec and rec.lv and rec.lv > 0 and string.format("[%d] ", rec.lv) or ""
    return level .. title
end

-- Follow-up quests: the chain the rating used, or the way to the dungeon (names only, see followUpLine).
local function addFollowUps(tt, questId)
    local ids, kind = QR.FollowUps(questId)
    if not ids then return end
    tt:AddLine(kind == "dungeon" and L.TT_FOLLOW_DUNGEON or (kind == "chain" and L.TT_FOLLOW_CHAIN or L.TT_FOLLOW_NEXT),
        1, 0.82, 0)
    for i, id in ipairs(ids) do
        tt:AddLine(string.format("%d. %s", i, followUpLine(id)), 1, 1, 1, true)
    end
end

-- QuestRating block of a tooltip: rating, every reason, the numbers behind it, then the follow-ups.
function UI.FillTooltip(tt, questId)
    local ok, err = pcall(UI.FillRating, tt, questId)
    if not ok then tt:AddLine(tostring(err), 1, 0.3, 0.3, true) end
    local okF, errF = pcall(addFollowUps, tt, questId)
    if not okF then tt:AddLine(tostring(errF), 1, 0.3, 0.3, true) end
end

function UI.FillRating(tt, questId)
    local res, why = QR.RateCached(questId)
    tt:AddLine(L.TT_TITLE, 0.2, 0.8, 1)
    if not res then
        tt:AddLine(tostring(why or L.NO_DATA), 0.62, 0.62, 0.62, true)
        return
    end
    if res.noData then
        tt:AddLine(res.unrated and L.UNRATED or L.NO_DATA, 0.62, 0.62, 0.62)
        for _, r in ipairs(res.reasons or {}) do
            if r ~= L.NO_DATA then tt:AddLine(r, 1, 1, 1, true) end
        end
        return
    end
    tt:AddLine(colorize(L.RATING[res.level], COLOR[res.level] or GRAY))
    for _, r in ipairs(res.reasons or {}) do tt:AddLine(r, 1, 1, 1, true) end
    local est = res.est
    if est then
        tt:AddLine(string.format(L.TT_TIME, math.max(1, math.floor(est.T / 60 + 0.5)), est.XP), 0.62, 0.62, 0.62)
        if not res.atMax then
            if res.median then
                tt:AddLine(string.format(L.TT_EFFICIENCY_MEDIAN, (res.R or 0) / res.median), 0.62, 0.62, 0.62)
            else
                tt:AddLine(string.format(L.TT_EFFICIENCY, res.R or 0), 0.62, 0.62, 0.62)
            end
        end
        if res.Rchain then
            local n = (res.chainSteps or 0) + #(res.chainBack or {}) + 1
            if res.median then
                tt:AddLine(string.format(L.TT_CHAIN_AVG, n, res.Rchain / res.median), 0.62, 0.62, 0.62)
            else
                tt:AddLine(string.format(L.TT_CHAIN_AVG_B, n, res.Rchain), 0.62, 0.62, 0.62)
            end
        end
        local g = res.gear
        if g and g.noOneForAll and D.Record(questId) and D.Record(questId).rw then
            tt:AddLine(L.TT_NEED_ONEFORALL, 0.62, 0.62, 0.62)
        end
    end
end

---------------------------------------------------------------------------------------------
-- Questie integration
---------------------------------------------------------------------------------------------
local questie = {} -- modules found at login

local function importModule(name)
    local loader = _G.QuestieLoader
    if type(loader) ~= "table" or type(loader.ImportModule) ~= "function" then return nil end
    local ok, mod = pcall(loader.ImportModule, loader, name)
    return ok and type(mod) == "table" and mod or nil
end

-- Redraw Questie's tracker (rating changed without a quest log event, e.g. gear or settings).
-- Questie's Update does nothing in combat or before the tracker started: try again after combat.
local refreshPending, refreshAfterCombat = false, false
-- the after-combat redraw: its event is registered once at load, never in combat (this client blocks
-- RegisterEvent / UnregisterEvent of some events in combat, taint log 2026-11-23)
local combatFrame = CreateFrame("Frame")
combatFrame:SetScript("OnEvent", function()
    if refreshAfterCombat then
        refreshAfterCombat = false
        UI.Refresh()
    end
end)
pcall(combatFrame.RegisterEvent, combatFrame, "PLAYER_REGEN_ENABLED")
function UI.Refresh()
    if QR.Blizzard and QR.Blizzard.Refresh then pcall(QR.Blizzard.Refresh) end
    local tracker = questie.tracker
    if not tracker or type(tracker.Update) ~= "function" or refreshPending then return end
    refreshPending = true
    C_Timer.After(0.2, function()
        refreshPending = false
        if InCombatLockdown() then
            refreshAfterCombat = true -- redrawn when combat ends
            return
        end
        local ok, err = pcall(tracker.Update, tracker)
        if not ok then warnOnce("QuestieTracker:Update", err) end
    end)
end

-- 1. tracker titles: Questie's QuestSection reads TrackerData.GetColoredQuestName at draw time. The same
--    function also names quests in Questie's tooltip and right-click menu, so tag only while
--    QuestSection.Draw runs. (No pcall around Draw: Questie may run it in a coroutine.)
local inTrackerDraw = false
local function hookTrackerTitles(trackerData, questSection)
    local orig = trackerData.GetColoredQuestName
    if type(orig) ~= "function" then warnOnce("TrackerData.GetColoredQuestName", "missing"); return end
    local draw = questSection and questSection.Draw
    if type(draw) ~= "function" then warnOnce("QuestSection.Draw", "missing"); return end
    questSection.Draw = function(...)
        inTrackerDraw = true
        local a, b = draw(...)
        inTrackerDraw = false
        return a, b
    end
    trackerData.GetColoredQuestName = function(displayQuest, ...)
        local name = orig(displayQuest, ...)
        if inTrackerDraw and type(name) == "string" and type(displayQuest) == "table" and displayQuest.Id then
            local ok, tag = pcall(UI.Tag, displayQuest.Id)
            if ok then return name .. tag end
            warnOnce("tracker tag", tag)
        end
        return name
    end
end

-- 2. tooltip on tracker lines. Questie's own tooltip only shows in a group; ours shows solo too and
--    sits above Questie's when both are visible.
local tip, tipLine
local function hideTip(line)
    if tip and (line == nil or line == tipLine) then
        tipLine = nil
        tip:Hide()
    end
end
local function showTip(line)
    if not QR.Cfg().showTooltip or type(line) ~= "table" or not line.Quest or not line:IsVisible() then return end
    if line.mode ~= "quest" and line.mode ~= "objective" then return end
    local questId = line.Quest.Id
    if type(questId) ~= "number" or not D.Record(questId) then return end
    -- achievement objectives reuse SetQuest and can share a quest's ID (Questie checks the same)
    local td = questie.trackerData
    if td and type(td.GetQuest) == "function" and td.GetQuest(questId) ~= line.Quest then return end
    if not tip then
        tip = CreateFrame("GameTooltip", "QuestRatingTooltip", UIParent, "GameTooltipTemplate")
        tip:SetClampedToScreen(true)
        -- Questie sets each line's OnHide to its original Hide, which our hook never sees:
        -- close ourselves when the line goes away
        tip:HookScript("OnUpdate", function(self)
            if not (tipLine and tipLine:IsVisible() and tipLine:IsMouseOver()) then hideTip() end
        end)
    end
    tipLine = line
    tip:SetOwner(line, "ANCHOR_NONE")
    tip:ClearAllPoints()
    local questieTip = _G.QuestieTrackerQuestTooltip
    if questieTip and questieTip:IsShown() then
        tip:SetPoint("BOTTOMLEFT", questieTip, "TOPLEFT")
    else
        tip:SetPoint("BOTTOMLEFT", line, "TOPLEFT")
    end
    UI.FillTooltip(tip, questId)
    tip:Show()
end
local function hookTrackerTooltip(mod)
    if type(mod.Show) ~= "function" or type(mod.Hide) ~= "function" then
        warnOnce("TrackerQuestTooltip", "missing"); return
    end
    hooksecurefunc(mod, "Show", function(line)
        local ok, err = pcall(showTip, line)
        if not ok then warnOnce("tracker tooltip", err) end
    end)
    hooksecurefunc(mod, "Hide", function(line) pcall(hideTip, line) end)
end

-- 3. drop % in Questie's unit tooltip: answer Questie's own lookup where its drop tables have nothing
local function hookDropRates(questieDB)
    local orig = questieDB.GetItemDroprate
    if type(orig) ~= "function" then warnOnce("QuestieDB.GetItemDroprate", "missing"); return end
    questieDB.GetItemDroprate = function(itemId, npcId, ...)
        local r = orig(itemId, npcId, ...)
        if (type(r) ~= "table" or not r[1]) and QR.Cfg().showDropRate then
            local p = D.DropRate(itemId, npcId)
            if p then return { p, "questrating" } end
        end
        return r
    end
end

-- 4. drop % on the objective lines of Questie's map icon tooltip (world map / minimap objective icons).
-- Questie collects those lines in tooltip.questOrder[questId] = { { [line text] = { [npc name] = true } } }
-- and renders them through TooltipLayout:Render; before that render, the drop rate of the line's item
-- from the listed NPCs (Questie's rate, else ours) is added to the end of the line, e.g. "0/9 X  [12%]".
local function rateRange(lo, hi)
    if hi - lo < 0.005 then return dropText(lo) .. "%" end
    return dropText(lo) .. "-" .. dropText(hi) .. "%"
end

-- QR.dropTrace: what the last map icon tooltip render did, step by step (shown by /qr drop)
local function trace(fmt, ...)
    local t = QR.dropTrace
    if t and #t < 60 then t[#t + 1] = string.format(fmt, ...) end
end

local function plain(text)
    return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""))
end

local function objectiveDropSuffix(questieDB, questId, line, names)
    local quest = questieDB.GetQuest and questieDB.GetQuest(questId)
    local nameList = {}
    for n in pairs(names) do nameList[#nameList + 1] = tostring(n) end
    trace("quest %s line \"%s\" names {%s}", tostring(questId), plain(line), table.concat(nameList, ", "))
    if not (quest and quest.Objectives) then trace("  no Questie quest objectives") end
    for _, obj in ipairs(quest and quest.Objectives or {}) do
        trace("  objective %s type=%s id=%s desc=\"%s\" item=\"%s\"", tostring(obj.Index), tostring(obj.Type), tostring(obj.Id),
            plain(obj.Description or ""), tostring(type(obj.Id) == "number" and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(obj.Id)))
        if obj.Type == "item" and type(obj.Id) == "number" then
            local itemName = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(obj.Id)
            local matched = (itemName and itemName ~= "" and line:find(itemName, 1, true))
                or (type(obj.Description) == "string" and obj.Description ~= "" and line:find(obj.Description, 1, true))
            if matched then
                local ids = {}
                for _, id in pairs(questieDB.QueryItemSingle(obj.Id, "npcDrops") or {}) do ids[id] = true end
                local list = QR_GEN.drop and QR_GEN.drop[obj.Id]
                if list then
                    for i = 1, #list - 1, 2 do ids[list[i]] = true end
                end
                local lo, hi
                for id in pairs(ids) do
                    local name = questieDB.QueryNPCSingle(id, "name")
                    local r = questieDB.GetItemDroprate(obj.Id, id) -- our rate when Questie has none
                    local p = type(r) == "table" and tonumber(r[1])
                    trace("    npc %d \"%s\" listed=%s rate=%s", id, tostring(name), tostring(name and names[name] or false), tostring(p))
                    if name and names[name] and p then lo, hi = math.min(lo or p, p), math.max(hi or p, p) end
                end
                trace("  -> %s", lo and rateRange(lo, hi) or "no rate for the listed NPCs")
                if lo then return "  |cFF999999[" .. rateRange(lo, hi) .. "]|r" end
                return nil
            end
        end
    end
end

local function addMapDropRates(questieDB, questOrder, rows)
    local suffix = {}
    for questId, textList in pairs(questOrder) do
        for _, textData in pairs(textList) do
            for line, names in pairs(textData) do
                if type(line) == "string" and #line >= 4 and suffix[line] == nil then
                    local set = type(names) == "table" and names or (type(names) == "string" and { [names] = true }) or {}
                    suffix[line] = objectiveDropSuffix(questieDB, questId, line, set) or false
                end
            end
        end
    end
    local added = 0
    for _, row in ipairs(rows) do
        if row.kind == "line" and type(row.text) == "string" then
            for line, s in pairs(suffix) do
                if s and #row.text >= #line and row.text:sub(-#line) == line then
                    row.text = row.text .. s
                    added = added + 1
                    break
                end
            end
        end
    end
    trace("rows %d, drop rates added to %d", #rows, added)
end

-- 5. rating tag after each quest title of a giver in the same tooltip (available / turn-in quest icons).
-- Questie keeps them in tooltip.npcAndObjectOrder[giver name][coloured title] = { questId = ..., title = ... }
-- and draws each as a double line whose left text ends with that title. The tag is added before Questie
-- measures the rows, and AddDoubleLine never wraps, so the tooltip grows to fit it.
local function addGiverRatings(npcAndObjectOrder, rows)
    local byTitle = {}
    for _, quests in pairs(npcAndObjectOrder) do
        if type(quests) == "table" then
            for _, q in pairs(quests) do
                if type(q) == "table" and type(q.title) == "string" and #q.title > 0 and type(q.questId) == "number" then
                    byTitle[q.title] = q.questId
                end
            end
        end
    end
    if not next(byTitle) then return end
    for _, row in ipairs(rows) do
        if row.kind == "doubleLine" and type(row.leftText) == "string" and not row.qrTagged then
            for title, questId in pairs(byTitle) do
                if #row.leftText >= #title and row.leftText:sub(-#title) == title then
                    local _, full = UI.TagParts(questId)
                    if full then row.leftText = row.leftText .. " " .. full end
                    row.qrTagged = true
                    break
                end
            end
        end
    end
end

local function hookMapIconDropRates(layout, questieDB)
    local orig = layout.Render
    if type(orig) ~= "function" then warnOnce("TooltipLayout.Render", "missing"); return end
    QR.mapDropHooked = true
    layout.Render = function(self, tooltip, rows, ...)
        -- only a map icon tooltip being shown (ShowOnTooltip set its owner and questOrder)
        local isMap = type(tooltip) == "table" and type(tooltip.questOrder) == "table" and type(rows) == "table"
            and tooltip._showData and tooltip.GetOwner and tooltip:GetOwner() == (tooltip._showOwner or tooltip._owner)
        if isMap and type(tooltip.npcAndObjectOrder) == "table" then
            local ok, err = pcall(addGiverRatings, tooltip.npcAndObjectOrder, rows)
            if not ok then warnOnce("map giver tooltip", err) end
        end
        if isMap then
            QR.dropTrace = {}
            if not QR.Cfg().showDropRate then
                trace("showDropRate is off")
            else
                local ok, err = pcall(addMapDropRates, questieDB, tooltip.questOrder, rows)
                if not ok then trace("error: %s", tostring(err)); warnOnce("map icon tooltip", err) end
            end
        end
        return orig(self, tooltip, rows, ...)
    end
end

---------------------------------------------------------------------------------------------
-- Quest offer window (an NPC's "accept quest" page): one summary line between the title and the
-- description, "QuestRating：【中｜理由·理由】", with as many reasons as fit on one line of the page
-- (contentWidth of QUEST_TEMPLATE_DETAIL); hovering it shows the full QuestRating tooltip. Blizzard lays
-- the page out in QuestInfo_Display, each element anchored under the previous one; after it ran, our
-- line goes under the title and the description is anchored under it, so everything below moves down.
---------------------------------------------------------------------------------------------
-- rating colours that are unreadable on parchment, and their dark counterparts
local PARCHMENT = { ["ffffffff"] = "ff202020", ["ff9d9d9d"] = "ff5a5a5a", ["ffffd100"] = "ff7a5200",
                    ["ff1eff00"] = "ff006400", ["ffff8000"] = "ffa04000" }

local offerLine -- button holding the summary text; .questId is the quest it shows
local function offerSummary(questId, width, fs, dark, allReasons)
    local res = QR.RateCached(questId)
    local word, color, reasons = L.NO_DATA, GRAY, {}
    if res and not res.noData then
        word, color, reasons = L.RATING[res.level], COLOR[res.level] or GRAY, res.reasons or {}
    elseif res then
        if res.unrated then word = L.UNRATED end
        for _, r in ipairs(res.reasons or {}) do
            if r ~= L.NO_DATA then reasons[#reasons + 1] = r end
        end
    end
    if dark then color = PARCHMENT[color] or color end
    local function build(n)
        local text = word
        if n > 0 then
            local parts = {}
            for i = 1, n do parts[i] = reasons[i] end
            text = text .. "｜" .. table.concat(parts, "·")
        end
        return L.TT_TITLE .. "：" .. colorize("【" .. text .. "】", color)
    end
    if allReasons then fs:SetText(build(#reasons)); return end -- quest log pages: every reason, wrapped
    for n = #reasons, 1, -1 do
        fs:SetText(build(n))
        if fs:GetUnboundedStringWidth() <= width then return end
    end
    fs:SetText(build(0))
end

-- the quest a QuestInfo page shows: the NPC's offer (QUEST_TEMPLATE_DETAIL) or the quest log's details
-- (classic QuestLogFrame QUEST_TEMPLATE_LOG, world map QUEST_TEMPLATE_MAP_DETAILS; user 2026-11-23)
local function pageQuest(template)
    if template == _G.QUEST_TEMPLATE_DETAIL then return GetQuestID and GetQuestID(), false end
    if template ~= _G.QUEST_TEMPLATE_LOG and template ~= _G.QUEST_TEMPLATE_MAP_DETAILS then return nil end
    local id
    if template == _G.QUEST_TEMPLATE_MAP_DETAILS then
        id = _G.QuestMapFrame and QuestMapFrame.DetailsFrame and QuestMapFrame.DetailsFrame.questID
    end
    if (type(id) ~= "number" or id <= 0) and C_QuestLog and C_QuestLog.GetSelectedQuest then id = C_QuestLog.GetSelectedQuest() end
    if (type(id) ~= "number" or id <= 0) and GetQuestLogSelection and GetQuestLogTitle then
        local idx = GetQuestLogSelection()
        if idx and idx > 0 then id = select(8, GetQuestLogTitle(idx)) end
    end
    return id, true
end

-- the shown QuestInfo element anchored right under the title (the objectives on log pages, the description on
-- the NPC offer page), with its first anchor
local QUEST_INFO_ELEMENTS = { "QuestInfoObjectivesText", "QuestInfoDescriptionText", "QuestInfoDescriptionHeader",
    "QuestInfoObjectivesHeader", "QuestInfoRewardText", "QuestInfoRequiredMoneyText", "QuestInfoGroupSize",
    "QuestInfoAnchor", "QuestInfoSpacerFrame" }
local function underTitle(title)
    for _, name in ipairs(QUEST_INFO_ELEMENTS) do
        local f = _G[name]
        if f and f.GetPoint and f:IsShown() then
            local point, rel, relPoint, x, y = f:GetPoint(1)
            if rel == title then return f, point, relPoint, x, y end
        end
    end
end

-- A follow-up quest offered right after a turn-in (user 2026-11-23, screenshot): the offer page came up with
-- an empty title, description and objectives. No addon writes those texts (audit of every addon 2026-11-23);
-- QuestInfo_Display fills them from GetTitleText / GetQuestText / GetObjectiveText at QUEST_DETAIL, and on the
-- Forever client those can still be empty in the event's call stack (QuestieTrace re-samples them for the same
-- reason). So after an offer page is drawn we look again for 3 s: when the page shows an empty title or
-- description and the client now has them, the page is drawn again the way Blizzard draws it on QUEST_DETAIL
-- (QuestFrameDetailPanel Hide + Show), at most once per page. A page drawn with its text is left alone.
local redrawnFor
local function drawnEmpty()
    local t = _G.QuestInfoTitleHeader and QuestInfoTitleHeader:GetText() or ""
    local d = _G.QuestInfoDescriptionText and QuestInfoDescriptionText:GetText() or ""
    return t == "" or d == ""
end
local function scheduleOfferRedraw(id0)
    local panel = _G.QuestFrameDetailPanel
    if not (panel and C_Timer and GetTitleText and GetQuestText) then return end
    local tries = 0
    local function try()
        tries = tries + 1
        if not panel:IsShown() or not drawnEmpty() then return end -- closed, or drawn with its text
        local id = GetQuestID and GetQuestID() or 0
        local ready = (GetTitleText() or "") ~= "" and (GetQuestText() or "") ~= "" and id ~= 0
        if not ready then
            if tries < 15 then C_Timer.After(0.2, try) end
            return
        end
        if redrawnFor == id then return end -- already redrawn once for this page
        redrawnFor = id
        panel:Hide()
        panel:Show()
    end
    C_Timer.After(0.2, try)
end
QR.RegisterReady(function()
    local f = CreateFrame("Frame")
    pcall(f.RegisterEvent, f, "QUEST_FINISHED") -- the quest window closed: the next page is a new one
    f:SetScript("OnEvent", function() redrawnFor = nil end)
end)
local function checkOfferPage(template)
    if template ~= _G.QUEST_TEMPLATE_DETAIL then return end
    local id = GetQuestID and GetQuestID() or 0
    if redrawnFor and redrawnFor == id and id ~= 0 then return end -- our own redraw (or already done)
    redrawnFor = nil
    if drawnEmpty() then scheduleOfferRedraw(id) end
end

local function showOfferRating(template, parentFrame)
    if not parentFrame then return end
    local questId, logPage = pageQuest(template)
    if questId == nil and not logPage then return end
    local desc, title = _G.QuestInfoDescriptionText, _G.QuestInfoTitleHeader
    if not (desc and title) then return end
    local below, bPoint, bRelPoint, bx, by = underTitle(title)
    if not offerLine then
        offerLine = CreateFrame("Button", nil, parentFrame)
        local fs = offerLine:CreateFontString(nil, "ARTWORK", "QuestFont")
        fs:SetPoint("TOPLEFT")
        fs:SetJustifyH("LEFT")
        offerLine.text = fs
        offerLine:SetScript("OnEnter", function(self)
            if not self.questId then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            UI.FillTooltip(GameTooltip, self.questId)
            GameTooltip:Show()
        end)
        offerLine:SetScript("OnLeave", function(self)
            if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
        end)
    end
    if not (QR.Cfg().showTooltip and type(questId) == "number" and questId > 0 and D.Record(questId)) then
        offerLine.questId = nil
        offerLine:Hide() -- Blizzard's own layout stays as it is
        return
    end
    -- light text (contrast setting) keeps the tooltip colours, parchment gets dark ones
    local tr, tg, tb = desc:GetTextColor()
    local dark = (0.299 * (tr or 0) + 0.587 * (tg or 0) + 0.114 * (tb or 0)) < 0.5
    local fs = offerLine.text
    fs:SetTextColor(tr or 0, tg or 0, tb or 0)
    local width = template.contentWidth or desc:GetWidth()
    fs:SetWordWrap(logPage and true or false)
    fs:SetWidth(width)
    offerSummary(questId, width, fs, dark, logPage)
    offerLine.questId = questId
    offerLine:SetParent(parentFrame)
    offerLine:SetSize(math.min(width, fs:GetUnboundedStringWidth() + 2), math.max(12, fs:GetStringHeight() or 12))
    offerLine:ClearAllPoints()
    offerLine:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    offerLine:Show()
    if below then -- the element that was under the title goes under our line, with its own offsets
        below:ClearAllPoints()
        below:SetPoint(bPoint or "TOPLEFT", offerLine, bRelPoint or "BOTTOMLEFT", bx or 0, by or -8)
    end
    if GameTooltip:GetOwner() == offerLine then offerLine:GetScript("OnEnter")(offerLine) end
end

---------------------------------------------------------------------------------------------
-- Without Questie: drop % lines in the unit tooltip for objectives in the log
---------------------------------------------------------------------------------------------
local function npcFromGUID(guid)
    if type(guid) ~= "string" then return nil end
    local kind, _, _, _, _, npcId = strsplit("-", guid)
    if kind == "Creature" or kind == "Vehicle" then return tonumber(npcId) end
end

local function addDropLines(tt, data)
    if tt ~= GameTooltip or not QR.Cfg().showDropRate then return end
    local guid = data and data.guid
    if not guid and UnitGUID then guid = UnitGUID("mouseover") end
    local ok, npcId = pcall(npcFromGUID, guid) -- secret values on some clients
    if not ok or not npcId then return end
    for _, questId in ipairs(D.LogQuests()) do
        local model = QR.GetModel(questId)
        for _, obj in ipairs(model and model.objectives or {}) do
            local p = obj.item and D.DropRate(obj.item, npcId)
            if p and (obj.N or 1) > 0 then
                local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(obj.item)) or ("item " .. obj.item)
                local progress = obj.needed and string.format("%d/%d ", obj.needed - obj.N, obj.needed) or ""
                tt:AddLine(string.format("   %s%s  |cFF999999[%s%%]|r", progress, name, dropText(p)), 1, 1, 1)
            end
        end
    end
end

---------------------------------------------------------------------------------------------
-- Wider tooltip instead of wrapped drop-rate lines (plan 8.1)
---------------------------------------------------------------------------------------------
local function widenForDropRate(tt, text)
    if type(text) ~= "string" or not text:find("%%%]") then return end
    local fs = _G[tt:GetName() .. "TextLeft" .. tt:NumLines()]
    if not (fs and fs.GetUnboundedStringWidth and tt.SetMinimumWidth) then return end
    local need = fs:GetUnboundedStringWidth() + 24
    if need > (tt.qrMinWidth or 0) then
        tt.qrMinWidth = need
        tt:SetMinimumWidth(need)
    end
end

---------------------------------------------------------------------------------------------
QR.RegisterReady(function()
    local trackerData = importModule("TrackerData")
    if trackerData then
        questie.tracker = importModule("QuestieTracker")
        questie.trackerData = trackerData
        hookTrackerTitles(trackerData, importModule("QuestSection"))
        local tooltipMod = importModule("TrackerQuestTooltip")
        if tooltipMod then hookTrackerTooltip(tooltipMod) end
        local questieDB = importModule("QuestieDB")
        if questieDB then
            hookDropRates(questieDB)
            local layout = importModule("TooltipLayout")
            if layout then hookMapIconDropRates(layout, questieDB) end
        end
        UI.Refresh()
    elseif TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tt, data)
            local ok, err = pcall(addDropLines, tt, data)
            if not ok then warnOnce("unit tooltip", err) end
        end)
    end
    if type(_G.QuestInfo_Display) == "function" then
        hooksecurefunc("QuestInfo_Display", function(template, parentFrame)
            local ok, err = pcall(showOfferRating, template, parentFrame)
            if not ok then warnOnce("quest offer window", err) end
            ok, err = pcall(checkOfferPage, template)
            if not ok then warnOnce("quest offer redraw", err) end
        end)
    else
        warnOnce("QuestInfo_Display", "missing")
    end
    if GameTooltip and GameTooltip.GetName then
        hooksecurefunc(GameTooltip, "AddLine", function(tt, text) pcall(widenForDropRate, tt, text) end)
        GameTooltip:HookScript("OnTooltipCleared", function(tt)
            if tt.qrMinWidth then
                tt.qrMinWidth = nil
                tt:SetMinimumWidth(0)
            end
        end)
    end
end)
