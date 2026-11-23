local _, QR = ...
local L = QR.L
local E = QR.Estimate
local D = QR.Data

-- Turns a model into a rating: R, continuous position, level 0..4 and direct reasons.
-- Time efficiency, quest chains (follow-up quests can only raise R), dungeon quests and dungeon
-- prerequisites (very high), reward gear from OneForAll (level bonus).

local modelCache = {} -- [questId] = model | { fail = reason }
local rateCache = {}  -- [questId] = { res, why } for the UI (tracker titles are redrawn often)

function QR.InvalidateQuest(questId)
    if questId then modelCache[questId] = nil else wipe(modelCache) end
    wipe(rateCache) -- ratings depend on other quests (nearby, chains), so drop them all
end

-- Ratings that only change with gear, talents or settings (models stay valid).
function QR.InvalidateRatings()
    wipe(rateCache)
end

local function getModel(questId)
    local m = modelCache[questId]
    if m == nil then
        local ok, built, reason = pcall(D.BuildModel, questId)
        if not ok then
            reason = "BuildModel error: " .. tostring(built)
            built = nil
        end
        m = built or { fail = reason or L.NO_DATA }
        modelCache[questId] = m
    end
    if m.fail then return nil, m.fail end
    return m
end
QR.GetModel = getModel

local function maxLevel()
    return (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
end

-- Other quests in the log whose main area is within nearbyRadius of this quest's.
local function countNearby(model, cfg)
    if not model.center then return 0, {} end
    local list = {}
    for _, otherId in ipairs(D.LogQuests()) do
        if otherId ~= model.id then
            local other = getModel(otherId)
            local d = other and other.center and E.Dist(model.center, other.center)
            if d and d <= cfg.nearbyRadius then list[#list + 1] = otherId end
        end
    end
    return #list, list
end

---------------------------------------------------------------------------------------------
-- Follow-up quests (plan sections 3.7 and 5). Database field nq = { {questId, yards}, ... }:
-- next in chain, the quest a breadcrumb leads to, quests that need this one.
---------------------------------------------------------------------------------------------
local function completed(questId)
    return C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(questId)
end

-- usable follow-ups of a quest: { {id, yards or nil}, ... }
local function followers(questId)
    local out = {}
    local rec = D.Record(questId)
    for _, f in ipairs(rec and rec.nq or {}) do
        local frec = D.Record(f[1])
        if frec and D.Available(frec) and not completed(f[1]) then
            out[#out + 1] = { id = f[1], yards = (f[2] and f[2] >= 0) and f[2] or nil, rec = frec }
        end
    end
    return out
end

-- The nearest dungeon quest among the follow-ups (breadth first, chainDepth steps):
-- zone, depth, path { questId, ... } from the first follow-up to the dungeon quest.
local function dungeonAhead(questId, cfg)
    local seen, frontier, parent = { [questId] = true }, { questId }, {}
    for depth = 1, cfg.chainDepth do
        local nextFrontier = {}
        for _, id in ipairs(frontier) do
            for _, f in ipairs(followers(id)) do
                if not seen[f.id] then
                    seen[f.id] = true
                    parent[f.id] = id
                    if f.rec.dg == 1 or D.IsDungeonTagged(f.id) then
                        local path, cur = {}, f.id
                        while cur and cur ~= questId do
                            table.insert(path, 1, cur)
                            cur = parent[cur]
                        end
                        return f.rec.dz or 0, depth, path
                    end
                    nextFrontier[#nextFrontier + 1] = f.id
                end
            end
        end
        if #nextFrontier == 0 then return nil end
        frontier = nextFrontier
    end
end

-- One quest on its own at player level `lv` (no route sharing, no chain, no bonus); nil when it
-- cannot be estimated. The model's quest XP is scaled for the real player level, so it is
-- re-scaled for `lv` here.
local function soloEstimate(questId, lv, cfg)
    local m = getModel(questId)
    if not m or m.noData or m.dungeon or #m.missing > 0 then return nil end
    local est = E.Quest(m, lv, cfg, 0)
    if est.T <= 0 then return nil end
    est.XP = est.XP - (m.questXP or 0) + D.QuestXP(D.Record(questId), lv)
    return est
end

-- The chain from this quest on (user 2026-11-22: each quest at its own level). A follow-up is
-- estimated at the level you would do it, max(player level, its quest level), and its XP is
-- divided by the grinding baseline of that level, so a level-50 quest in a level-30 chain counts
-- as "hours of grinding saved at 50", not as huge XP at 30. At each step the follow-up with the
-- best normalised XP per second (an exclusive choice takes the better branch), x chainDecay^i,
-- plus the walk from the previous turn-in. Stops at a dungeon quest or one that cannot be estimated.
-- Returns grinding hours saved (H), total seconds, steps, { ids }; R of the chain = H * 3600 / T.
local function chainEstimate(questId, est0, pl, cfg, B0)
    local seen = { [questId] = true }
    local H, T, steps, ids = est0.XP / B0, est0.T, 0, {}
    local cur = questId
    local top = ((GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60) - 1 -- quest XP is 0 at max level
    for i = 1, cfg.chainDepth do
        local best
        for _, f in ipairs(followers(cur)) do
            if not seen[f.id] then
                seen[f.id] = true
                local lv = math.min(top, math.max(pl, f.rec.lv or pl))
                local est = soloEstimate(f.id, lv, cfg)
                local B = E.Baseline(lv, cfg)
                if est and B > 0 then
                    local gapT = f.yards and E.LegTime(f.yards, cfg, lv) or 0
                    local h = est.XP / B
                    local r = h / (est.T + gapT)
                    if not best or r > best.r then
                        best = { id = f.id, h = h, T = est.T, gapT = gapT, r = r }
                    end
                end
            end
        end
        if not best then break end
        H = H + best.h * cfg.chainDecay ^ i
        T = T + best.T + best.gapT
        steps, cur = i, best.id
        ids[#ids + 1] = best.id
    end
    return H, T, steps, ids
end

local function buildReasons(res, model, est, cfg)
    local reasons, seen = {}, {}
    local function add(text)
        if text and not seen[text] then
            seen[text] = true
            reasons[#reasons + 1] = text
        end
    end
    if model.ready then add(L.REASON_READY) end
    if model.noXP and not res.atMax then add(L.REASON_NO_XP) end
    -- bonus sources are always named
    if res.gearText then add(res.gearText) end
    if res.gear and res.gear.loading then add(L.REASON_GEAR_LOADING) end
    if res.chainRaised then add(string.format(L.REASON_CHAIN, res.chainSteps)) end
    -- a grey quest: that alone explains the rating
    if not res.atMax and model.level and model.level <= E.GrayLevel(res.playerLevel) then
        add(L.REASON_QUEST_GRAY)
        return reasons
    end
    -- direct cause of a low rating: the biggest time sink, with numbers
    if res.level <= 1 and not res.atMax then
        local cands = {}
        if est.wait > 0 then
            local S, objects = 0, false
            for _, g in pairs(est.groups) do
                if g.wait > 0 and g.S >= S then
                    S, objects = g.S, g.obj.kind == "object" or g.obj.fromObject
                end
            end
            cands[#cands + 1] = { t = est.wait, text = string.format(objects and L.REASON_RESPAWN_OBJECT or L.REASON_RESPAWN,
                S, math.floor(est.wait / 60 + 0.5)) }
        end
        if est.Troute > 0 then
            cands[#cands + 1] = { t = est.Troute, text = string.format(L.REASON_ROUTE, math.max(1, math.floor(est.Troute / 60 + 0.5))) }
        end
        if (est.Tescort or 0) > 0 then
            cands[#cands + 1] = { t = est.Tescort, text = string.format(L.REASON_ESCORT, math.max(1, math.floor(est.Tescort / 60 + 0.5))) }
        end
        for _, g in pairs(est.groups) do
            local obj = g.obj
            local farm = g.T - g.wait
            if obj.kind == "object" or obj.fromObject then
                -- picking up: how many, and the walk + use time per object
                if obj.fromObject and obj.p and g.p and g.p < 0.5 then
                    cands[#cands + 1] = { t = farm, text = string.format(L.REASON_OBJECT_CHANCE, math.floor(g.p * 100 + 0.5), g.K) }
                elseif g.K > 0 then
                    cands[#cands + 1] = { t = farm, text = string.format(L.REASON_OBJECT, g.K, math.floor(g.tKill + 0.5)) }
                end
            elseif obj.kind == "item" and g.p and g.p < 0.5 and not obj.pUnknown then
                cands[#cands + 1] = { t = farm, text = string.format(L.REASON_DROP, math.floor(g.p * 100 + 0.5), g.K) }
            elseif obj.rank == "elite" then
                cands[#cands + 1] = { t = farm, text = string.format(L.REASON_ELITE, g.K) }
            end
            if obj.kind ~= "object" and not obj.fromObject and g.xp == 0 and g.K > 0 then
                cands[#cands + 1] = { t = farm, text = L.REASON_LOW_MOBXP }
            end
        end
        table.sort(cands, function(a, b) return a.t > b.t end)
        local n = 0
        for _, c in ipairs(cands) do
            if n >= 2 then break end
            if not seen[c.text] then add(c.text); n = n + 1 end
        end
    end
    -- route sharing, only when it raised the level
    if res.nearbyRaised then
        add(string.format(L.REASON_NEARBY, est.share))
    end
    -- data reliability
    for _, f in ipairs(model.flags) do
        if f == L.DROP_UNKNOWN or f == L.COUNT_UNKNOWN or f == L.ROUTE_UNKNOWN or f == L.LOCATION_UNKNOWN or f == L.SPAWNS_INCOMPLETE then
            add(f)
        end
    end
    return reasons
end

-- Returns a result table (all intermediate values kept for /qr debug), or nil, reason.
function QR.Rate(questId)
    if not QR.ready then return nil, L.MSG_NOT_READY end
    local cfg = QR.Cfg()
    local model, why = getModel(questId)
    if not model then return nil, why end
    local res = { questId = questId, model = model, playerLevel = UnitLevel("player") or 1 }
    -- dungeon quest, or a dungeon quest further down the chain: very high regardless of efficiency
    -- (plan section 5)
    local dungeonText
    if model.dungeon then
        dungeonText = L.REASON_DUNGEON
    else
        local zone, depth = dungeonAhead(questId, cfg)
        if zone then
            res.prereqZone, res.prereqDepth = zone, depth
            -- zone 0: a dungeon quest known only by its quest type, with no zone on record
            dungeonText = zone > 0 and string.format(L.REASON_DUNGEON_PREREQ, D.DungeonName(zone))
                or L.REASON_DUNGEON_PREREQ_NONAME
        end
    end
    if dungeonText then
        res.dungeon, res.level, res.position, res.bonus = true, 4, 4, 0
        res.reasons = { dungeonText }
        if model.noData then return res end
    elseif model.noData or #model.missing > 0 then
        -- not estimable: say what is missing instead of rating on a guess
        res.noData = true
        res.reasons = #model.missing > 0 and model.missing or { L.NO_DATA }
        return res
    end
    local pl = res.playerLevel
    local nearby, nearbyList = countNearby(model, cfg)
    local est = E.Quest(model, pl, cfg, nearby)
    res.est, res.nearby, res.nearbyList = est, nearby, nearbyList
    res.B = E.Baseline(pl, cfg)
    res.E = est.T > 0 and (est.XP / est.T * 3600) or 0
    res.R = res.B > 0 and res.E / res.B or 0
    res.atMax = pl >= maxLevel()
    if res.dungeon then return res end
    -- standard: the main distribution of same-level quests (user 2026-11-22), R banded around its median
    local scale = cfg
    local m, sd = D.LevelDist(pl)
    if m then
        local a, b = cfg.bandMid or 0.5, cfg.bandOut or 1.5
        scale = { thresholds = { math.exp(m - b * sd), math.exp(m - a * sd), math.exp(m + a * sd), math.exp(m + b * sd) } }
        res.median = math.exp(m)
    end
    res.cuts = scale.thresholds
    res.position = res.atMax and 2.0 or E.Position(res.R, scale)
    if nearby > 0 and not res.atMax then
        local alone = E.Quest(model, pl, cfg, 0)
        local Ralone = (alone.T > 0 and alone.XP / alone.T * 3600 or 0) / res.B
        res.Ralone = Ralone
        res.nearbyRaised = E.Level(E.Position(Ralone, scale), 0) < E.Level(res.position, 0)
    end
    -- follow-up quests: only when the whole chain is more efficient than this quest alone
    if not res.atMax and est.T > 0 then
        local cH, cT, steps, ids
        if res.B > 0 then cH, cT, steps, ids = chainEstimate(questId, est, pl, cfg, res.B) end
        if cH and steps > 0 and cT > 0 then
            res.chainSteps, res.chainIds = steps, ids
            res.Rchain = cH * 3600 / cT
            if res.Rchain > res.R then
                local p = E.Position(res.Rchain, scale)
                res.chainRaised = E.Level(p, 0) > E.Level(res.position, 0)
                res.position = p
            end
        end
    end
    -- reward gear (OneForAll)
    res.bonus, res.gearText, res.gear = QR.Gear.Bonus(D.Record(questId), cfg)
    res.level = E.Level(res.position, res.bonus)
    res.reasons = buildReasons(res, model, est, cfg)
    return res
end

-- Follow-up quests to show in the tooltip: the path to the dungeon for a dungeon prerequisite, else
-- the chain the rating used, else the direct follow-ups. Returns { questId, ... } and the kind
-- ("dungeon" | "chain" | "next"), or nil.
function QR.FollowUps(questId)
    if not QR.ready then return nil end
    local cfg = QR.Cfg()
    local _, _, path = dungeonAhead(questId, cfg)
    if path and #path > 0 then return path, "dungeon" end
    local res = QR.RateCached(questId)
    if res and res.chainIds and #res.chainIds > 0 then return res.chainIds, "chain" end
    local ids = {}
    for _, f in ipairs(followers(questId)) do ids[#ids + 1] = f.id end
    if #ids > 0 then return ids, "next" end
end

-- Cached QR.Rate for the UI; errors become a reason instead of breaking the caller's frame.
function QR.RateCached(questId)
    local c = rateCache[questId]
    if not c then
        local ok, res, why = pcall(QR.Rate, questId)
        if not ok then res, why = nil, tostring(res) end
        c = { res, why }
        if QR.ready then rateCache[questId] = c end
    end
    return c[1], c[2]
end

-- Models hold live log progress and level-scaled XP: drop them when either changes.
-- Gear and talents only change the reward bonus.
local GEAR_EVENTS = { PLAYER_EQUIPMENT_CHANGED = true, CHARACTER_POINTS_CHANGED = true, TRAIT_CONFIG_UPDATED = true,
    ACTIVE_TALENT_GROUP_CHANGED = true }
QR.RegisterReady(function()
    local ev = CreateFrame("Frame")
    for _, e in ipairs({ "PLAYER_LEVEL_UP", "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN",
        "PLAYER_EQUIPMENT_CHANGED", "CHARACTER_POINTS_CHANGED", "TRAIT_CONFIG_UPDATED", "ACTIVE_TALENT_GROUP_CHANGED",
        "GET_ITEM_INFO_RECEIVED" }) do
        pcall(ev.RegisterEvent, ev, e) -- not every event exists on every client
    end
    local function refresh() if QR.UI and QR.UI.Refresh then QR.UI.Refresh() end end
    ev:SetScript("OnEvent", function(_, event, itemID, success)
        if event == "GET_ITEM_INFO_RECEIVED" then
            -- a reward item we asked for arrived (or failed for good): re-rate and redraw once
            if QR.Gear.pending[itemID] then
                QR.Gear.pending[itemID] = nil
                if success == false then QR.Gear.failed[itemID] = true end
                QR.InvalidateRatings()
                refresh()
            end
        elseif GEAR_EVENTS[event] then
            QR.InvalidateRatings()
            refresh()
        elseif event == "PLAYER_LEVEL_UP" then
            -- UnitLevel may still return the old level during the event
            C_Timer.After(0, function() QR.InvalidateQuest(); refresh() end)
        else
            QR.InvalidateQuest()
            -- Questie may redraw before this handler runs: redraw once more with fresh ratings. Not on
            -- QUEST_LOG_UPDATE, which a tracker redraw can itself cause (it would loop); Questie redraws
            -- on progress anyway.
            if event ~= "QUEST_LOG_UPDATE" then refresh() end
        end
    end)
end)
