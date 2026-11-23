local _, QR = ...
local L = QR.L

-- Reward gear bonus (plan section 6): OneForAll's Gear Value decides how much a reward item is an
-- upgrade for the current spec and gear; QuestRating only maps that % to a level bonus.
-- OneForAll is optional: without it (or if its internals change) there is simply no gear bonus.
local G = {}
QR.Gear = G

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant

G.pending = {} -- [itemID] = true while the client has no data for it yet
G.failed = {}  -- [itemID] = true when the client could not load it: not asked for again

-- Extra bonus for items whose value OneForAll cannot see (use / proc effects). Draft for review:
-- _tools/QuestRating_whitelist_draft.md. itemID -> 0.5 | 1 | 2. Empty until approved.
G.WHITELIST = {}

local function gearValue()
    local ofa = _G.OneForAll
    local gv = type(ofa) == "table" and ofa.GearValue
    if type(gv) == "table" and type(gv.Change) == "function" then return gv end
end
function G.Available() return gearValue() ~= nil end

local QUALITY = { [0] = "灰", [1] = "白", [2] = "綠", [3] = "藍", [4] = "紫", [5] = "橙" }

-- "藍雙手斧": quality colour word + weapon type or armour slot
local function itemLabel(itemID)
    local _, _, quality = GetItemInfo(itemID)
    local _, _, subType, equipLoc, _, classID = GetItemInfoInstant(itemID)
    local what = (classID == 2 and subType) or (equipLoc and _G[equipLoc]) or subType or tostring(itemID)
    return (QUALITY[quality] or "") .. what
end

local function levelBonus(pct, cfg)
    if pct >= cfg.gearBig then return 2 end
    if pct >= cfg.gearSmall then return 1 end
    return 0.5
end

-- Average item level of what is worn (no shirt / tabard), nil while an item has no data.
local GEAR_SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }
local function wornItemLevel()
    local sum, n = 0, 0
    for _, s in ipairs(GEAR_SLOTS) do
        local id = GetInventoryItemID and GetInventoryItemID("player", s)
        if id then
            local ilvl = select(4, GetItemInfo(id))
            if not ilvl then return nil end
            sum, n = sum + ilvl, n + 1
        end
    end
    return n > 0 and sum / n or nil
end

-- Upgrade % of a reward against gear that fits the level you will use it at (user 2026-11-22):
-- level L = max(player level, quest level, item's required level). At your own level that is
-- simply what you wear (OneForAll's own result). Above it, your worn gear is scaled up to the
-- gear of level L: an item's stats grow about with its item level, and quest gear for level L
-- has item level about L + gearLevelOffset, so worn values x k with
-- k = max(1, (L + gearLevelOffset) / average worn item level).
-- Returns kind, pct, L, k.
local function changeAtLevel(gv, itemID, questLevel, cfg)
    local pl = UnitLevel("player") or 1
    local reqLevel = select(5, GetItemInfo(itemID)) or 0
    local L = math.max(pl, questLevel or 0, reqLevel)
    if L <= pl or type(gv.Upgrade) ~= "function" or type(gv.Total) ~= "function" then
        local kind, pct = gv.Change(itemID)
        return kind, pct, pl, 1
    end
    local worn = wornItemLevel() or (pl + cfg.gearLevelOffset)
    local k = math.max(1, (L + cfg.gearLevelOffset) / math.max(1, worn))
    local v, d, equipped, base = gv.Upgrade(itemID)
    if not v then return nil end
    if equipped then return "worn", nil, L, k end
    if d == nil then return nil end -- no comparison (e.g. shield with a two-hander worn), as OneForAll's Change
    local tot = gv.Total()
    if not tot or tot <= 0 then return nil end
    if not base or base <= 0 then
        if v <= 0 then return "same", nil, L, k end
        return "new", v / (tot * k) * 100, L, k
    end
    local pct = (v - base * k) / (tot * k) * 100
    if pct >= 0.1 then return "up", pct, L, k end
    if pct <= -0.1 then return "down", -pct, L, k end
    return "same", nil, L, k
end

-- Best single reward (choice and fixed rewards are not added up).
-- Returns bonus, reason text or nil, info = { itemID, kind, pct, level, scale, loading }
function G.Bonus(rec, cfg)
    local items = rec and rec.rw
    if not items then return 0 end
    local gv = gearValue()
    local best, bestText, info, loading = 0, nil, nil, false
    for _, itemID in ipairs(items) do
        local b, text, kind, pct, level, scale = 0, nil, nil, nil, nil, nil
        local cached = not (C_Item and C_Item.IsItemDataCachedByID) or C_Item.IsItemDataCachedByID(itemID)
        if G.failed[itemID] then
            -- unknown to this client: no bonus, no "loading"
        elseif not cached then
            G.pending[itemID] = true
            loading = true
            if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
        elseif gv then
            local ok, k, p, lv, sc = pcall(changeAtLevel, gv, itemID, rec.lv, cfg)
            if ok then kind, pct, level, scale = k, p, lv, sc end
            if (kind == "up" or kind == "new") and type(pct) == "number" and pct > 0 then
                b = levelBonus(pct, cfg)
                local fmt = kind == "new" and L.REASON_GEAR_NEW or L.REASON_GEAR
                local pctText = (gv.Pct and gv.Pct(pct)) or string.format("%.1f", pct)
                text = string.format(fmt, itemLabel(itemID), pctText)
                if scale and scale > 1 then text = text .. string.format(L.REASON_GEAR_AT_LEVEL, level) end
            end
        end
        local w = G.WHITELIST[itemID]
        if w and w > b then
            b, text = w, string.format(L.REASON_GEAR_LISTED, itemLabel(itemID))
        end
        if b > best then
            best, bestText = b, text
            info = { itemID = itemID, kind = kind, pct = pct, level = level, scale = scale }
        end
    end
    info = info or {}
    info.loading = loading and best == 0
    info.noOneForAll = gv == nil
    return best, bestText, info
end
