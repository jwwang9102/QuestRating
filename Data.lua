local _, QR = ...
local L = QR.L

-- Data layer: QuestRating's own quest database (Data/Generated.lua, built offline by
-- _tools/build_questrating_data.py) plus the live quest log. No dependency on Questie.
-- Everything static (objectives, counts, camps, density, route legs, base XP) is precomputed;
-- only what depends on the player is added here.
local D = {}
QR.Data = D

local GEN -- QR_GEN.quest

function D.Init()
    if type(QR_GEN) ~= "table" or type(QR_GEN.quest) ~= "table" then
        return false, { "Data/Generated.lua" }
    end
    GEN = QR_GEN.quest
    return true, {}
end

---------------------------------------------------------------------------------------------
-- Quest log (game API; Forever has the modern C_QuestLog)
---------------------------------------------------------------------------------------------
-- Quest IDs currently in the log.
function D.LogQuests()
    local out = {}
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
        -- scan at least 75 rows, like Questie: entries under collapsed headers may not be counted
        for i = 1, math.max(C_QuestLog.GetNumQuestLogEntries() or 0, 75) do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and info.questID and info.questID > 0 then
                out[#out + 1] = info.questID
            end
        end
    elseif GetNumQuestLogEntries and GetQuestLogTitle then
        for i = 1, GetNumQuestLogEntries() or 0 do
            local _, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(i)
            if not isHeader and questID and questID > 0 then out[#out + 1] = questID end
        end
    end
    return out
end

local function inLog(questId)
    if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
        local idx = C_QuestLog.GetLogIndexForQuestID(questId)
        return idx ~= nil and idx > 0
    end
    for _, id in ipairs(D.LogQuests()) do if id == questId then return true end end
    return false
end

-- Live objectives of a logged quest: { {required, fulfilled, finished}, ... } or nil.
local function logObjectives(questId)
    if not (C_QuestLog and C_QuestLog.GetQuestObjectives) then return nil end
    local ok, list = pcall(C_QuestLog.GetQuestObjectives, questId)
    if not ok or type(list) ~= "table" then return nil end
    local out = {}
    for _, o in ipairs(list) do
        out[#out + 1] = { required = o.numRequired or 0, fulfilled = o.numFulfilled or 0, finished = o.finished,
                          type = o.type }
    end
    return out
end

---------------------------------------------------------------------------------------------
-- Quest XP: base XP from the database scaled by level like the server (cmangos formula, as
-- Questie's QuestXP does). 0 at max level.
---------------------------------------------------------------------------------------------
function D.QuestXP(rec, playerLevel)
    local lv, xp = rec.xl or 0, rec.xp or 0
    local maxLevel = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
    if lv <= 0 or xp <= 0 or playerLevel >= maxLevel then return 0 end
    local mult = math.min(10, math.max(1, 2 * (lv - playerLevel) + 20))
    xp = xp * mult / 10
    if xp <= 100 then xp = 5 * math.floor((xp + 2) / 5)
    elseif xp <= 500 then xp = 10 * math.floor((xp + 5) / 10)
    elseif xp <= 1000 then xp = 25 * math.floor((xp + 12) / 25)
    else xp = 50 * math.floor((xp + 25) / 50) end
    return xp
end

---------------------------------------------------------------------------------------------
-- Model
---------------------------------------------------------------------------------------------
local KIND = { [1] = "kill", [2] = "item", [3] = "object", [4] = "item", [5] = "event" }
local RANK = { [1] = "elite", [2] = "rare" }
local FLAG = {
    DU = "DROP_UNKNOWN", CU = "COUNT_UNKNOWN", RU = "ROUTE_UNKNOWN", LU = "LOCATION_UNKNOWN",
    SI = "SPAWNS_INCOMPLETE", FM = "FEW_MOBS", EL = "ELITE", RO = "RARE_ONLY", DE = "DROP_EMULATED", MU = "MULTI_UNKNOWN",
}
local LEG = { s = "start", t = "target", f = "finish", d = "deliver" }

local function point(c)
    if type(c) ~= "table" then return nil end
    return { inst = c[1], x = c[2], y = c[3] }
end

function D.Record(questId) return GEN and GEN[questId] end

-- Race / class masks (Questie style, bit n-1 = race or class ID n, 0 = everyone). The masks can carry
-- bits above 32, so plain arithmetic instead of the 32-bit bit library.
local function hasBit(mask, id)
    if not mask or mask == 0 or not id then return true end
    return math.floor(mask / 2 ^ (id - 1)) % 2 == 1
end

-- Can the player take this quest at all (race, class, still in the game)?
function D.Available(rec)
    if not rec or rec.na then return false end
    local raceID = select(3, UnitRace("player"))
    local classID = select(3, UnitClass("player"))
    return hasBit(rec.ra, raceID) and hasBit(rec.cl, classID)
end

-- Drop chance of a quest item from one mob in percent (ForeverDB), or nil.
function D.DropRate(itemID, npcID)
    local list = QR_GEN.drop and QR_GEN.drop[itemID]
    if not list then return nil end
    for i = 1, #list - 1, 2 do
        if list[i] == npcID then return list[i + 1] / 100 end
    end
end

-- Localised dungeon name for a zone ID: the client's area name, else the English name from the database.
-- Same-level standard (QR_GEN.dist): the 20/40/60/80 % points of R over quests around this level, each
-- rated at its own level (band edges), and the median R. nil when the database has none.
-- With your measured fight time / gap (cfg.fightMeasured / cfg.gapMeasured) the points are interpolated in
-- (log F, log G) from QR_GEN.distGrid, the same standard built offline for a grid of fight times and gaps
-- (review 2026-11-23: R and the band edges then use the same settings).
local function gridPoint(level, cfg)
    local g = QR_GEN and QR_GEN.distGrid
    if not g or not (cfg and (cfg.fightMeasured or cfg.gapMeasured)) then return nil end
    local F = cfg.fightBase
    local G = cfg.gap or (cfg.lootTime + cfg.grindDistance / cfg.walkSpeed)
    local function bracket(list, v)
        v = math.max(list[1], math.min(list[#list], v))
        for i = 1, #list - 1 do
            if v <= list[i + 1] then
                local t = (math.log(v) - math.log(list[i])) / (math.log(list[i + 1]) - math.log(list[i]))
                return i, t
            end
        end
        return #list - 1, 1
    end
    local fi, ft = bracket(g.F, F)
    local gi, gt = bracket(g.G, G)
    local nG = #g.G
    local L = math.max(1, math.min(59, level))
    local function at(a, b)
        local d = g.d[(a - 1) * nG + b]
        return d and d[L]
    end
    local d11, d12, d21, d22 = at(fi, gi), at(fi, gi + 1), at(fi + 1, gi), at(fi + 1, gi + 1)
    if not (d11 and d12 and d21 and d22) then return nil end
    local out = {}
    for k = 1, 5 do
        out[k] = (d11[k] * (1 - gt) + d12[k] * gt) * (1 - ft) + (d21[k] * (1 - gt) + d22[k] * gt) * ft
    end
    return out
end

function D.LevelDist(level, cfg)
    local t = QR_GEN and QR_GEN.dist
    if not t or not level then return nil end
    local d = gridPoint(level, cfg) or t[math.max(1, math.min(59, level))]
    if d and #d >= 5 then
        return { math.exp(d[1]), math.exp(d[2]), math.exp(d[4]), math.exp(d[5]) }, math.exp(d[3])
    end
end

-- Name of a dungeon wing / whole-run key (QR_GEN.wing): the locale's wing name, else the client's dungeon name.
function D.WingName(key)
    if L.WING and L.WING[key] then return L.WING[key] end
    local w = QR_GEN.wing and QR_GEN.wing[key]
    return w and D.DungeonName(w.z) or tostring(key)
end

function D.DungeonName(zone)
    if not zone or zone == 0 then return "?" end
    local name = C_Map and C_Map.GetAreaInfo and C_Map.GetAreaInfo(zone)
    if name and name ~= "" then return name end
    return QR_GEN.dungeon and QR_GEN.dungeon[zone] or tostring(zone)
end

-- The client's quest type: dungeon / raid quests ("（地城）" in the quest log). Covers Forever's new
-- dungeons, which the offline data does not know. nil when the client has no data for the quest.
local DUNGEON_TAGS = { [62] = true, [81] = true, [88] = true, [89] = true }
function D.IsDungeonTagged(questId)
    if not (C_QuestLog and C_QuestLog.GetQuestTagInfo) then return nil end
    local ok, info = pcall(C_QuestLog.GetQuestTagInfo, questId)
    if not ok or type(info) ~= "table" then return nil end
    return DUNGEON_TAGS[info.tagID] or false
end

-- Header of the quest log section a quest is in (the zone or dungeon name), or nil.
function D.LogHeader(questId)
    if not (C_QuestLog and C_QuestLog.GetInfo and C_QuestLog.GetNumQuestLogEntries) then return nil end
    local header
    for i = 1, math.max(C_QuestLog.GetNumQuestLogEntries() or 0, 75) do
        local info = C_QuestLog.GetInfo(i)
        if info then
            if info.isHeader then header = info.title
            elseif info.questID == questId then return header end
        end
    end
end

-- Quest XP the client shows for a quest in the log (already scaled for your level), or nil.
local function clientQuestXP(questId)
    if not GetQuestLogRewardXP then return nil end
    local ok, xp = pcall(GetQuestLogRewardXP, questId)
    if ok and type(xp) == "number" and xp > 0 then return xp end
end

-- questId -> model (see Estimate.Quest), or nil, reason.
function D.BuildModel(questId)
    local rec = GEN and GEN[questId]
    if not rec then return nil, string.format(L.MSG_UNKNOWN_QUEST, questId) end
    local pl = UnitLevel("player") or 1
    local title = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questId)
    local model = {
        id = questId, name = title or rec.t, level = rec.lv, requiredLevel = rec.ml,
        questXP = D.QuestXP(rec, pl), dungeon = rec.dg == 1, noData = rec.nd and true or false,
        group = rec.gq == 1, -- group quest: a party of 3-5 (user 2026-11-23)
        center = point(rec.c), map = rec.m, flags = {}, extra = {}, objectives = {}, groups = {},
        inLog = inLog(questId), missing = {},
    }
    if not model.dungeon and D.IsDungeonTagged(questId) then
        model.dungeon, model.dungeonFromTag = true, true
    end
    if model.inLog then
        -- the client's XP of a logged quest is the live WoW Forever value for your level: always preferred
        -- (review 2026-11-23)
        local xp = clientQuestXP(questId)
        if xp then model.questXP, model.xpFromClient = xp, true end
    end
    for _, code in ipairs(rec.f or {}) do
        local key = FLAG[code]
        if key and L[key] then model.flags[#model.flags + 1] = L[key] end
    end

    -- objectives, with live counts for logged quests
    local live = model.inLog and logObjectives(questId) or nil
    local used = {}
    local function liveFor(index, n)
        if not live then return nil end
        if #live == #(rec.o or {}) and live[index] and not used[index] then
            used[index] = true
            return live[index]
        end
        for k, lo in ipairs(live) do -- otherwise match by required amount
            if not used[k] and lo.required == n then used[k] = true; return lo end
        end
    end
    local byGroup = {}
    for i, o in ipairs(rec.o or {}) do
        local obj = {
            index = i, kind = KIND[o.k] or "event", fromObject = o.k == 4, N = o.n, countSource = o.cs,
            p = o.p, pUnknown = o.pu == 1, S = o.S, A = o.A, d = o.d, mobLevel = o.lv, rank = RANK[o.r] or "normal",
            synthetic = o.sy == 1, src = o.src, center = point(o.c), group = o.g, item = o.i, rs = o.rs,
            dRoute = o.dr or 0, dDetour = o.dd or 0, dWing = o.dw, dMult = o.dm, out = o.ox, levelUnknown = o.lu == 1, multiDrop = o.md == 1, altPer = o.ap, presence = o.pr,
        }
        local lo = liveFor(i, o.n)
        obj.liveMatched = lo ~= nil
        if lo and lo.required > 0 then
            obj.N = lo.finished and 0 or math.max(0, lo.required - lo.fulfilled)
            obj.needed, obj.countSource = lo.required, "log"
        end
        model.objectives[#model.objectives + 1] = obj
        local g = byGroup[o.g or i]
        if not g then g = {}; byGroup[o.g or i] = g; model.groups[#model.groups + 1] = g end
        g[#g + 1] = obj
    end
    if model.inLog and #model.objectives > 0 then
        local left = false
        for _, o in ipairs(model.objectives) do
            -- a place-only objective without a live counterpart does not keep the quest open
            if (o.N or 0) > 0 and not (o.kind == "event" and not o.liveMatched) then left = true end
        end
        model.ready = not left
        -- progress on any objective: you have been to the targets (user 2026-11-23)
        for _, o in ipairs(model.objectives) do
            if o.needed and (o.N or 0) < o.needed then model.progress = true end
        end
    end
    -- the client knows best (also covers delivery quests without objectives)
    if model.inLog and C_QuestLog and C_QuestLog.IsComplete then
        local ok, complete = pcall(C_QuestLog.IsComplete, questId)
        if ok and complete then model.ready = true end
    end

    -- route: giver -> targets -> finisher. A logged quest keeps it all until it has progress (then the way
    -- to the first target is behind you) or is ready (then only the way to the turn-in is left).
    -- "B" + segment = ship / zeppelin of that segment, value in seconds. "E" + segment = the escort, in
    -- seconds at the escorted NPC's pace: still to do while the quest is open, gone once it is ready.
    model.routeLegs, model.routeYards = {}, 0
    for _, lg in ipairs(rec.legs or {}) do
        local kind = lg[1]
        local first = kind:sub(1, 1)
        local boat, escort = first == "B", first == "E"
        local label = LEG[(boat or escort) and kind:sub(2) or kind] or kind
        if escort then
            if not model.ready then
                model.routeLegs[#model.routeLegs + 1] = { label = label, seconds = lg[2], escort = true }
            end
        elseif not ((model.ready or model.progress) and label == "start") and not (model.ready and label == "target") then
            if boat then
                model.routeLegs[#model.routeLegs + 1] = { label = label, seconds = lg[2], boat = true }
            else
                model.routeLegs[#model.routeLegs + 1] = { label = label, yards = lg[2] }
                model.routeYards = model.routeYards + lg[2]
            end
        end
    end

    -- dungeon quest: the normal run of its wing(s) (Generated.lua QR_GEN.wing, user 2026-11-23)
    if rec.wd and QR_GEN.wing then
        local run = { wings = rec.wd, need = rec.dn, T = 0, n = 0, kills = {}, shares = {},
                      detourYards = rec.dt and rec.dt.y or 0, detourKills = rec.dt and rec.dt.k or {} }
        for _, k in ipairs(rec.wd) do
            local w = QR_GEN.wing[k]
            if not w then run = nil; break end
            run.T, run.n = run.T + w.t, run.n + (w.n or 0)
            run.kills[#run.kills + 1] = w.k
            run.shares[#run.shares + 1] = w.s  -- kill XP each member gets inside (group share x Forever factor)
            run.inner = run.inner or w.s
        end
        model.run = run
        -- progress on an objective inside the run: a run is behind you (rated by what is left)
        for _, obj in ipairs(model.objectives) do
            if run and (obj.dWing or 0) > 0 and obj.needed and (obj.N or 0) > 0 and obj.N < obj.needed then
                model.runDone = true
            end
        end
    end

    -- What cannot be estimated (user 2026-11-22: estimate where a sound method exists, else say which
    -- data is missing instead of inventing a number). A quest that only waits for its turn-in is
    -- estimable whatever its objectives were.
    local function miss(text)
        for _, t in ipairs(model.missing) do if t == text then return end end
        model.missing[#model.missing + 1] = text
    end
    if not model.ready then
        for i, o in ipairs(rec.o or {}) do
            local obj = model.objectives[i]
            if o.k == 5 and obj and (obj.N or 0) > 0 then
                if o.s == "u" then
                    miss(L.MISSING_SOURCE)      -- item from a source we do not know (crafted, gathered ...)
                elseif (o.s == "t" or o.s == "v" or o.s == "e") and not o.c then
                    miss(L.MISSING_PLACE)       -- talk / buy / reach a place with no known location
                elseif not o.s and ((o.n or 1) > 1 or not o.c) then
                    miss(L.MISSING_OBJECTIVE)
                end
            end
        end
        for _, lo in ipairs(live or {}) do
            if lo.type == "reputation" and not lo.finished then miss(L.MISSING_REPUTATION) end
        end
        if rec.eu then miss(L.MISSING_ESCORT) end -- escort with no path and nothing to measure
        if rec.pv then miss(L.MISSING_PVP) end   -- battleground quest
        for i, o in ipairs(rec.o or {}) do
            local obj = model.objectives[i]
            if o.lu == 1 and obj and (obj.N or 0) > 0 then miss(L.MISSING_MOB_LEVEL) end -- level-scaling mob
        end
        if model.dungeon and not model.run then
            -- raid, quest whose wing is unknown, or a wing without a run time
            miss(rec.dm == "raid" and L.MISSING_DUNGEON_RAID or rec.dm == "wing" and L.MISSING_DUNGEON_WING
                or L.MISSING_DUNGEON_RUNTIME)
        end
        if #(rec.o or {}) == 0 then
            local walk = 0
            for _, lg in ipairs(rec.legs or {}) do if lg[1]:sub(1, 1) ~= "B" then walk = walk + lg[2] end end
            -- not in the server DB and turned in where it was taken: an empty objective list means
            -- "unknown" (reputation, crafting ...); a walk to another NPC is a delivery
            if rec.fv and walk <= 0 and not (live and #live > 0) then miss(L.MISSING_OBJECTIVE) end
            for _, f in ipairs(rec.f or {}) do
                if f == "RU" then miss(L.MISSING_ROUTE) end -- nothing but walking, and the walk is unknown
            end
        end
    end
    if model.questXP <= 0 and pl < ((GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60) then
        -- known to give no XP: rated with quest XP 0 (reason "no XP"); otherwise the XP is unknown
        if rec.x0 then model.noXP = true else miss(L.MISSING_XP) end
    end
    return model
end
