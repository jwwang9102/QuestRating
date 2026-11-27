local _, QR = ...
local L = QR.L

-- World map (user 2026-11-23):
--   * map recommendation ("升級推薦") after OneForAll's zone level: on the continent map's hover label (after
--     OneForAll's "(10 - 25)") and under OneForAll's "Level X - Y" at the top right of a zone map;
--   * dungeon recommendation in the tooltip of OneForAll's dungeon entrance pins.
-- Passive hooks only (hooksecurefunc / HookScript, no Blizzard map method called), each in pcall: if
-- OneForAll or the map changes, that part stays silent instead of breaking the map.
local M = {}
QR.MapUI = M

local function word(level)
    local UI = QR.UI
    if level == nil then return UI.colorize(L.NO_DATA, UI.GRAY) end -- no standard for the level
    return UI.colorize(L.RATING[level], UI.COLOR[level] or UI.GRAY)
end

-- Map ratings change with the quest log, level, gear, your measured pace and the map you are on: a short cache keeps hovering cheap.
local zoneCache, zoneStamp = {}, 0
local function zoneRating(uiMap)
    local now = GetTime()
    if now - zoneStamp > 5 then wipe(zoneCache); zoneStamp = now end
    local c = zoneCache[uiMap]
    if c == nil then
        local ok, r = pcall(QR.RateZone, uiMap)
        c = ok and r or false
        zoneCache[uiMap] = c
    end
    return c or nil
end

---------------------------------------------------------------------------------------------
-- Zone map: under OneForAll's "Level X - Y" (top right of the map)
---------------------------------------------------------------------------------------------
local zoneFrame, zoneText
local function isZoneMap(id)
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(id)
    local zoneType = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
    return info and info.mapType == zoneType
end
local function updateZoneText()
    local parent = WorldMapFrame.ScrollContainer or WorldMapFrame
    if not zoneFrame then
        zoneFrame = CreateFrame("Frame", nil, parent)
        zoneFrame:SetSize(1, 1)
        zoneFrame:SetFrameStrata("HIGH")
        zoneFrame:SetFrameLevel(510)
        zoneFrame:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -12, -34) -- below OneForAll's large level text
        zoneText = zoneFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        zoneText:SetPoint("TOPRIGHT")
        zoneText:SetJustifyH("RIGHT")
    end
    local id = WorldMapFrame:IsShown() and WorldMapFrame:GetMapID()
    local r = id and isZoneMap(id) and zoneRating(id)
    if r then
        if r.quests == 0 then
            zoneText:SetText(string.format(L.MAP_REC_NONE, word(r.level)))
        else
            local move = r.here and string.format(L.MAP_REC_MOVE_HERE, math.floor((r.travel or 0) / 60 + 0.5))
                or r.travel == nil and (r.located and L.MAP_REC_MOVE_NONE or L.MAP_REC_MOVE_UNKNOWN)
                or string.format(L.MAP_REC_MOVE, math.floor(r.travel / 60 + 0.5))
            zoneText:SetText(string.format(L.MAP_REC_DETAIL, word(r.level), r.quests, math.floor(r.T / 60 + 0.5), move))
        end
        zoneFrame:Show()
    else
        zoneFrame:Hide()
    end
end

---------------------------------------------------------------------------------------------
-- Continent map hover label: after OneForAll's "(10 - 25)"
---------------------------------------------------------------------------------------------
-- map name -> uiMap for the maps with a recommendation standard (exact names; without OneForAll too)
local nameIndex
local function mapByName(name)
    if not nameIndex then
        nameIndex = {}
        for id in pairs(QR_GEN and QR_GEN.zlv or {}) do
            local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(id)
            if info and info.name then nameIndex[info.name] = id end
        end
    end
    return name and nameIndex[name]
end
local function labelHook(label)
    local fs = label.Name
    if not fs then return end
    local id = mapByName(fs:GetText())
    local r = id and zoneRating(id)
    local extra = label.qrRec
    if not r then
        if extra then extra:Hide() end
        return
    end
    if not extra then
        extra = label:CreateFontString(nil, "OVERLAY")
        local font, size, flags = fs:GetFont()
        if font then extra:SetFont(font, math.max(8, (size or 14) * 0.8), flags) end
        extra:SetShadowOffset(fs:GetShadowOffset())
        extra:SetShadowColor(fs:GetShadowColor())
        label.qrRec = extra
    end
    extra:ClearAllPoints()
    local after = (label.ofaRange and label.ofaRange:IsShown()) and label.ofaRange or fs
    extra:SetPoint("LEFT", after, "RIGHT", 6, 1)
    -- with the quantity behind it (review 2026-11-26: a map of a few minutes of quests can be very high)
    extra:SetText(string.format(L.MAP_REC, word(r.level))
        .. (r.quests > 0 and string.format(L.MAP_REC_QTY, r.quests, math.floor(r.T / 60 + 0.5)) or "")
        .. (r.travel == nil and L.MAP_REC_NO_MOVE_TAG or ""))
    extra:Show()
end
local labelHooked = false
local function hookLabel()
    if labelHooked then return end
    for dp in pairs(WorldMapFrame.dataProviders or {}) do
        local label = type(dp) == "table" and dp.Label
        if label and label.Name and label.EvaluateLabels then
            hooksecurefunc(label, "EvaluateLabels", function(self) pcall(labelHook, self) end)
            labelHooked = true
            return
        end
    end
end

---------------------------------------------------------------------------------------------
-- OneForAll dungeon entrance pins: the recommendation of each wing in the tooltip
---------------------------------------------------------------------------------------------
-- OneForAll dungeon record -> our wing keys (Dire Maul and Blackrock Spire share an instance map)
local KEY_WINGS = { dme = { "DM-East" }, dmw = { "DM-West" }, dmn = { "DM-North" }, lbrs = { "LBRS" }, ubrs = { "UBRS" } }
local function wingsOf(d)
    local byName = QR_GEN and QR_GEN.wingName and d.name and QR_GEN.wingName[d.name]
    if byName then return { byName } end -- OneForAll's dungeon name (the build maps them, user 2026-11-23)
    if KEY_WINGS[d.key] then return KEY_WINGS[d.key] end
    local out = {}
    local wings = QR_GEN and QR_GEN.wing or {}
    if d.instanceID then
        for k, w in pairs(wings) do if w.m == d.instanceID then out[#out + 1] = k end end
    else -- WoW Forever's new dungeons have no instance ID in OneForAll
        local n = d.name or ""
        if n:find("Thanes") and wings.Thanes then out[1] = "Thanes"
        elseif n:find("Lordaeron") and wings.Lordaeron then out[1] = "Lordaeron" end
    end
    table.sort(out)
    return out
end

local function isOfaPin(owner)
    local lm = _G.OneForAll and _G.OneForAll.MapLandmarks
    for _, pin in ipairs(lm and lm._pool or {}) do
        if pin == owner then return true end
    end
    return false
end

local adding = false
local function addDungeonLines(tt)
    if adding then return end
    local owner = tt:GetOwner()
    local e = owner and owner.entry
    if not (e and e.list and e.kind == "dungeon" and isOfaPin(owner)) then return end
    local seen, lines = {}, {}
    for _, d in ipairs(e.list) do
        for _, key in ipairs(wingsOf(d)) do
            if not seen[key] then
                seen[key] = true
                local r = QR.RateWing(key)
                if r then lines[#lines + 1] = { key = key, r = r } end -- incl. "outside its levels" (shown as such)
            end
        end
    end
    if #lines == 0 then return end
    adding = true
    for _, it in ipairs(lines) do
        local r = it.r
        local name = (#lines > 1 or #e.list > 1) and ("  " .. QR.Data.WingName(it.key)) or ""
        if r.noData then
            tt:AddLine(string.format(L.DUNGEON_REC, QR.UI.colorize(r.noDataText or L.DUNGEON_NO_DATA, QR.UI.GRAY)) .. name, 1, 1, 1)
        elseif r.outside then
            tt:AddLine(string.format(L.DUNGEON_REC, QR.UI.colorize(string.format(L.DUNGEON_OUTSIDE, r.lo, r.hi), QR.UI.GRAY))
                .. name, 1, 1, 1)
        else
            tt:AddLine(string.format(L.DUNGEON_REC, word(r.level)) .. name, 1, 1, 1)
        end
        if r.outside or r.noData then
            -- the range is in the line above, or nothing to rate
        elseif r.atMax then
            tt:AddLine(L.DUNGEON_REC_MAX, 0.8, 0.8, 0.8)
        else
            tt:AddLine(string.format(L.DUNGEON_REC_DETAIL, r.xph, r.medianXph or 0), 0.8, 0.8, 0.8)
        end
        if (r.quests or 0) > 0 then tt:AddLine(string.format(L.DUNGEON_REC_QUESTS, r.quests), 0.8, 0.8, 0.8) end
        if not r.noData and (r.xpUnknown or 0) > 0 then
            tt:AddLine(string.format(L.DUNGEON_XP_PARTIAL, r.xpUnknown), 0.8, 0.8, 0.8)
        end
        if r.need and #r.need > 0 then
            -- the quests to take for this rating (a prerequisite not done yet: marked), and the rating without them
            tt:AddLine(L.DUNGEON_NEED_TITLE, 0.8, 0.8, 0.8)
            for i, c in ipairs(r.need) do
                if i > 8 then tt:AddLine(string.format(L.DUNGEON_NEED_MORE, #r.need - 8), 0.6, 0.6, 0.6); break end
                local rec = QR.Data.Record(c.id)
                local title = (C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(c.id))
                    or (rec and rec.t) or tostring(c.id)
                tt:AddLine("    " .. title .. (c.open and "" or L.DUNGEON_NEED_PRE), 0.8, 0.8, 0.8)
            end
            if r.levelTaken ~= r.level then tt:AddLine(string.format(L.DUNGEON_WITHOUT, word(r.levelTaken)), 0.8, 0.8, 0.8) end
        end
        if not r.noData and not r.outside and QR_GEN.wing[it.key] and QR_GEN.wing[it.key].e then tt:AddLine(L.DUNGEON_REC_EST, 0.8, 0.8, 0.8) end
        if not r.outside and r.lo and r.lo > 0 then
            local fmt = r.finder == "list" and L.DUNGEON_REC_LEVEL_LIST or (r.finder and L.DUNGEON_REC_LEVEL or L.DUNGEON_REC_LEVEL_ROUTE)
            tt:AddLine(string.format(fmt, r.lo, r.hi), 0.8, 0.8, 0.8)
        end
    end
    tt:Show() -- resize; the guard stops this OnShow from adding the lines again
    adding = false
end

---------------------------------------------------------------------------------------------
-- /qr dungeons: the wings around your level, best first
---------------------------------------------------------------------------------------------
function M.ListDungeons()
    local list = {}
    for key, w in pairs(QR_GEN and QR_GEN.wing or {}) do
        local r = QR.RateWing(key)
        if r and not r.outside then list[#list + 1] = { key = key, r = r, w = w } end
    end
    table.sort(list, function(a, b) return a.r.xph > b.r.xph end)
    QR.Print(L.DUNGEON_LIST)
    if #list == 0 then DEFAULT_CHAT_FRAME:AddMessage(L.DUNGEON_LIST_NONE) end
    for _, it in ipairs(list) do
        DEFAULT_CHAT_FRAME:AddMessage(string.format(L.DUNGEON_LIST_LINE, QR.Data.WingName(it.key), word(it.r.level),
            it.r.xph, math.floor(it.r.T / 60 + 0.5), it.r.quests) .. (it.w.e and L.DUNGEON_EST_TAG or "")
            .. ((it.r.need and #it.r.need > 0 and it.r.levelTaken ~= it.r.level)
                and string.format(L.DUNGEON_LIST_WITHOUT, #it.r.need, word(it.r.levelTaken)) or ""))
    end
    local pl = UnitLevel("player") or 1
    for key in pairs(QR.NoDataWings()) do
        local lo, hi = QR.WingRange(key)
        if not lo or (pl >= lo and pl <= hi) then
            DEFAULT_CHAT_FRAME:AddMessage("  " .. QR.Data.WingName(key) .. "  " .. L.DUNGEON_NO_DATA)
        end
    end
    -- the finder's raw values (min-max, recommended min-max), to check in game
    local raw = {}
    local keys = {}
    for key in pairs(QR_GEN and QR_GEN.wing or {}) do keys[#keys + 1] = key end
    for key in pairs(QR.NoDataWings()) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do
        local r = QR.WingFinderRaw(key)
        raw[#raw + 1] = key .. (r and string.format(L.DUNGEON_FINDER_RAW_ONE, r[1], r[2], r[3], r[4]) or " -")
    end
    table.sort(raw)
    DEFAULT_CHAT_FRAME:AddMessage(L.DUNGEON_FINDER_RAW .. table.concat(raw, ", "))
end

QR.RegisterReady(function()
    if not WorldMapFrame then return end
    -- registered after OneForAll's own hooks (it loads first): its texts are placed when ours run
    WorldMapFrame:HookScript("OnShow", function()
        pcall(hookLabel)
        pcall(updateZoneText)
    end)
    if WorldMapFrame.OnMapChanged then
        hooksecurefunc(WorldMapFrame, "OnMapChanged", function() pcall(updateZoneText) end)
    end
    GameTooltip:HookScript("OnShow", function(tt)
        local ok = pcall(addDungeonLines, tt)
        if not ok then adding = false end
    end)
end)
