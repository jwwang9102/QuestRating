local _, QR = ...
local L = QR.L
local E = QR.Estimate
local D = QR.Data

-- Turns a model into a rating: R, continuous position, level 0..4 and direct reasons.
-- Time efficiency, quest chains (ranked by their best whole route), dungeon quests as the normal run of
-- their wing (user 2026-11-23: no longer "very high" by default), reward gear from OneForAll (level bonus).

local modelCache = {} -- [questId] = model | { fail = reason }
local rateCache = {}  -- [questId] = { res, why } for the UI (tracker titles are redrawn often)
local wingCache = {}  -- [wing] = dungeon recommendation (depends on level and the quests of the run)

function QR.InvalidateQuest(questId)
    if questId then modelCache[questId] = nil else wipe(modelCache) end
    wipe(rateCache) -- ratings depend on other quests (nearby, chains), so drop them all
    wipe(wingCache) -- level ups and quest events change the level range check and the run's quests
end

-- Ratings that only change with gear, talents or settings (models stay valid).
function QR.InvalidateRatings()
    wipe(rateCache)
    wipe(wingCache)
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

local completed, inLogQuest, openToYou -- below

-- Other quests near this one (database rec.nb: main point within the build's nearbyRadius, 300 yd) that you
-- can do along: taken or takeable now, not done, not exclusive with this one (user 2026-11-23: quests not
-- taken share the route too). Mirror of the build's nearby_count.
-- pl: the level the quest is done at (a follow-up in a chain: its own level), default yours
local function countNearby(model, cfg, pl)
    local rec = D.Record(model.id)
    if not model.center or not rec or not rec.nb then return 0, {} end
    pl = pl or UnitLevel("player") or 1
    local exclusive = {}
    for _, x in ipairs(rec.ex or {}) do exclusive[x] = true end
    local list = {}
    for _, id in ipairs(rec.nb) do
        local orec = D.Record(id)
        if orec and orec.dg ~= 1 and not exclusive[id] and openToYou(id, orec, pl) then
            local mine = false
            for _, x in ipairs(orec.ex or {}) do if x == model.id then mine = true end end
            local c = orec.c
            local d = (not mine) and c and model.center and E.Dist(model.center, { inst = c[1], x = c[2], y = c[3] })
            if d and d <= cfg.nearbyRadius then list[#list + 1] = id end
        end
    end
    return #list, list
end

---------------------------------------------------------------------------------------------
-- Follow-up quests (plan sections 3.7 and 5). Database field nq = { {questId, yards}, ... }:
-- next in chain, the quest a breadcrumb leads to, quests that need this one.
---------------------------------------------------------------------------------------------
function completed(questId)
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

-- Other quests the same dungeon run can do (user 2026-11-23), as E.Dungeon candidates { {id, xp, t}, ... }:
-- same main wing, open to you, not done, taken or takeable now (min level, prerequisites done), not
-- grey, not exclusive with one done or taken. Each adds its quest XP x the part the route finishes and its
-- talk time (its own catch-up is not part of the shared run). Mirror of the build's run_companions
-- (offline, prerequisites outside the wing count as done).
function inLogQuest(id)
    return C_QuestLog and C_QuestLog.GetLogIndexForQuestID and (C_QuestLog.GetLogIndexForQuestID(id) or 0) > 0
end
-- open to you, not done, and taken or takeable now (min level, not grey, prerequisites done)
function openToYou(id, rec, pl)
    if not (D.Available(rec) and not completed(id)) then return false end
    if inLogQuest(id) then return true end
    if (rec.ml or 0) > pl or E.QuestGray(rec.lv, pl) then return false end
    for _, x in ipairs(rec.ex or {}) do -- an exclusive sibling done or taken
        if completed(x) or inLogQuest(x) then return false end
    end
    for _, pre in ipairs(rec.pa or {}) do if not completed(pre) then return false end end
    if rec.p1 and #rec.p1 > 0 then
        for _, pre in ipairs(rec.p1) do if completed(pre) then return true end end
        return false
    end
    return true
end
-- all: every quest of the dungeon this character can still do at pl (not done, race / class, min level, not grey),
-- also ones not taken yet or whose prerequisites are not done (user 2026-11-24, the dungeon recommendation:
-- "count them all"); else only quests open to you now.
local function runCompanions(model, pl, cfg, all)
    local out = {}
    local inList = {}
    local wl = model.run and model.run.wings[1] and QR_GEN.wingQuests and QR_GEN.wingQuests[model.run.wings[1]]
    for _, x in ipairs(wl or {}) do inList[x] = true end
    -- an earlier step that needs this run too (mirror of the build's WING_SET: quests with something inside)
    local function needsRun(p)
        if not inList[p] or completed(p) then return false end
        local pm = getModel(p)
        return pm and not pm.fail and pm.anyIn and true or false
    end
    local function canDo(id, rec)
        if not all then return openToYou(id, rec, pl) end
        if not (D.Available(rec) and not completed(id)) then return false end
        if inLogQuest(id) then return true end
        -- a later step of a chain in this dungeon whose earlier step needs the run too: one run cannot do both
        for _, p in ipairs(rec.pa or {}) do if needsRun(p) then return false end end
        if rec.p1 and #rec.p1 > 0 then
            local met, blocked = false, false
            for _, p in ipairs(rec.p1) do
                if completed(p) then met = true elseif needsRun(p) then blocked = true end
            end
            if blocked and not met then return false end
        end
        return inLogQuest(id) or ((rec.ml or 0) <= pl and not E.QuestGray(rec.lv, pl))
    end
    local wing = model.run and model.run.wings[1]
    local list = wing and QR_GEN.wingQuests and QR_GEN.wingQuests[wing]
    if not list or model.ready then return out end
    local taken = { [model.id] = true }
    local function excluded(rec, id)
        for _, x in ipairs(rec.ex or {}) do
            if taken[x] or completed(x) then return true end
        end
        for t in pairs(taken) do -- the other way round: a quest taken is exclusive with this one
            local trec = D.Record(t)
            for _, x in ipairs(trec and trec.ex or {}) do if x == id then return true end end
        end
        return false
    end
    for _, id in ipairs(list) do
        local rec = D.Record(id)
        if not taken[id] and rec and not excluded(rec, id) and canDo(id, rec) then
            local other = getModel(id)
            if other and other.run and other.insideLeft and not other.offRoute and not other.noData
                and #other.missing == 0 then -- something to do in the run, with data
                taken[id] = true
                -- its share: what the base route finishes (its own detour is its own business)
                local op = (not other.ready) and E.DungeonPlan(other, pl, cfg, false, true) or nil
                local frac = op and op.frac or 1
                -- its quest XP at the level rated (a follow-up in a chain: that level; the client's live value
                -- only at your own level)
                local qxp = (other.xpFromClient and pl == (UnitLevel("player") or 1)) and other.questXP
                    or D.QuestXP(rec, pl)
                out[#out + 1] = { id = id, xp = frac * (qxp or 0), t = cfg.fixedTime, taken = inLogQuest(id),
                                  open = openToYou(id, rec, pl) }
            end
        end
    end
    return out
end

-- The dungeon's other quests still to do (inside or outside): they share an open-world route (user
-- 2026-11-23). Same filters as runCompanions without "something inside". Mirror of run_companions(need_inside=False).
local function runSiblings(model, pl)
    local wing = model.run and model.run.wings[1]
    local list = wing and QR_GEN.wingQuests and QR_GEN.wingQuests[wing]
    if not list or model.ready then return 0 end
    local taken, n = { [model.id] = true }, 0
    for _, id in ipairs(list) do
        local rec = D.Record(id)
        if not taken[id] and rec and openToYou(id, rec, pl) then
            local ex = false
            for _, x in ipairs(rec.ex or {}) do if taken[x] or completed(x) then ex = true end end
            for t in pairs(taken) do
                local trec = D.Record(t)
                for _, x in ipairs(trec and trec.ex or {}) do if x == id then ex = true end end
            end
            local other = not ex and getModel(id)
            if other and other.run and not other.offRoute and not other.noData and #other.missing == 0 then
                taken[id] = true; n = n + 1
            end
        end
    end
    return n
end

-- A dungeon quest (user 2026-11-23). What is left all doable outside (no objective inside the run left): an
-- ordinary quest, its own route shared the usual way with nearby quests and with the run's other quests still to
-- do (solve "outonly"). Else the run, or, when every objective can be done outside too, the better of the run and
-- the open world (solve "in" / "out"). withNearby false: no route sharing. Returns est,
-- nearby count, list. Mirror of the build's rate_dungeon.
local function rateDungeonQuest(model, pl, cfg, withNearby)
    local comps = runCompanions(model, pl, cfg)
    local function open()
        local om = D.OpenModel(model, cfg)
        if not om then return nil end
        local n, list = 0, {}
        if withNearby then
            n, list = countNearby(model, cfg, pl)
            n = n + runSiblings(model, pl)
        end
        local o = E.Quest(om, pl, cfg, n)
        return o, n, list
    end
    if not model.insideLeft then
        local o, n, list = open()
        if o then o.solve = "outonly"; return o, n, list end
    end
    local est = E.Dungeon(model, pl, cfg, comps)
    if model.insideLeft then
        local o, n, list = open()
        if o and o.T > 0 and est.T > 0 then
            -- by quest XP per second (the run: with its other quests), not kill XP (user 2026-11-23)
            if (o.XP - o.mobXP) / o.T > (est.XP - est.mobXP) / est.T then o.solve = "out"; return o, n, list end
            est.solve = "in"
        end
    end
    return est, 0, {}
end

-- A follow-up in a chain at player level `lv` (no chain, no bonus), with route sharing like every quest of
-- the standard (user 2026-11-23: unshared follow-ups made whole chains look half as good as the quests they
-- are ranked against); nil when it cannot be estimated. The model's quest XP is scaled for the real player
-- level, so it is re-scaled for `lv` here.
local function soloEstimate(questId, lv, cfg)
    local m = getModel(questId)
    if not m or m.noData or (m.dungeon and not m.run) or #m.missing > 0 then return nil end
    local est = m.run and rateDungeonQuest(m, lv, cfg, true) or E.Quest(m, lv, cfg, (countNearby(m, cfg, lv)))
    if est.T <= 0 then return nil end
    -- at your own level a logged quest keeps the client's live XP (review 2026-11-23)
    if not (lv == (UnitLevel("player") or 1) and m.xpFromClient) then
        est.XP = est.XP - (m.questXP or 0) + D.QuestXP(D.Record(questId), lv)
    end
    return est
end

-- Quest chains (user 2026-11-23): database cn / cp = the next / previous quests of the same chain (the build
-- tells a chain from a mere prerequisite: next in chain or offered right after, not a breadcrumb, not an opener
-- of 3+ quests). chainCost: hours saved and seconds of f, the next (forward) or previous quest of questId: a
-- follow-up at the level you would do it, max(your level, its quest level), a quest before at its own level (at
-- most yours), each with its usual route sharing (as the standard), plus the walk between turn-in and giver;
-- quests you have done are left out (user 2026-11-23: only what is left of the chain counts; the build, without
-- your progress, counts the whole chain). nil when it cannot be estimated: the chain stops there.
-- Mirror of the build's chain_cost (that one filters by the quest's faction, this one by yours).
local function chainCost(questId, f, pl, cfg, top, forward)
    local rec, frec = D.Record(questId), D.Record(f)
    if not (rec and frec and D.Available(frec)) then return nil end
    local flv = (frec.lv or 0) > 0 and frec.lv or pl -- level -1 / 0 follows yours
    local lv = forward and math.min(top, math.max(pl, flv)) or math.max(1, math.min(pl, flv))
    local est = soloEstimate(f, lv, cfg)
    local B = E.Baseline(lv, cfg)
    if not (est and B > 0) then return nil end
    local src, dst = rec, f
    if not forward then src, dst = frec, questId end
    local yards
    for _, x in ipairs(src.nq or {}) do
        if x[1] == dst and x[2] and x[2] >= 0 then yards = x[2] end
    end
    return est.XP / B, est.T + (yards and E.LegTime(yards, cfg, lv) or 0)
end

-- Every route on from questId (forward) or back from it: { { h, t, ids }, ... }; a choice of two (two next or
-- two previous quests) gives two routes (user 2026-11-23). Mirror of the build's chain_paths.
local CHAIN_PATHS = 32
local function contains(list, x)
    for _, v in ipairs(list or {}) do if v == x then return true end end
    return false
end
-- a quest you can no longer take: one it excludes is done or in your log (as openToYou)
local function closedOff(id)
    if inLogQuest(id) then return false end -- taken: it is yours
    local rec = D.Record(id)
    for _, x in ipairs(rec and rec.ex or {}) do
        if completed(x) or inLogQuest(x) then return true end
    end
    return false
end
-- every one of `ids` is needed (all in pa, none excludes another)
local function allNeeded(rec, ids)
    if #ids < 2 then return false end
    for _, p in ipairs(ids) do if not contains(rec.pa, p) then return false end end
    for _, a in ipairs(ids) do
        local ra = D.Record(a)
        for _, b in ipairs(ids) do
            if a ~= b and (contains(ra and ra.ex, b) or contains((D.Record(b) or {}).ex, a)) then return false end
        end
    end
    return true
end
local chainPaths
-- the quests in preds that child needs (all), each with its best route back, summed: h, t, { ids }; seen is
-- left as it was. Mirror of the build's chain_needed.
local function chainNeeded(child, preds, pl, cfg, top, seen, depth, memo)
    local h, t, ids, added = 0, 0, {}, {}
    for _, p in ipairs(preds) do
        if not seen[p] and not completed(p) and not closedOff(p) then
            local key = "b" .. child .. ":" .. p
            if memo[key] == nil then memo[key] = { chainCost(child, p, pl, cfg, top, false) } end
            local ch, ct = memo[key][1], memo[key][2]
            if ch then
                seen[p] = true; added[#added + 1] = p
                local best, bestR
                for _, r in ipairs(chainPaths(p, pl, cfg, top, false, seen, depth + 1, memo)) do
                    local rr = (ct + r.t) > 0 and (ch + r.h) / (ct + r.t) or 0
                    if not bestR or rr > bestR then best, bestR = r, rr end
                end
                h, t = h + ch + best.h, t + ct + best.t
                ids[#ids + 1] = p
                for _, id in ipairs(best.ids) do
                    ids[#ids + 1] = id
                    if not seen[id] then seen[id] = true; added[#added + 1] = id end
                end
            end
        end
    end
    for _, id in ipairs(added) do seen[id] = nil end
    return h, t, ids
end
local function sortedLinks(rec, forward)
    local list = {}
    local links = rec.cp
    if forward then links = rec.cn end -- (not "forward and cn or cp": a missing cn would read cp)
    for _, f in ipairs(links or {}) do list[#list + 1] = f end
    table.sort(list)
    return list
end
function chainPaths(questId, pl, cfg, top, forward, seen, depth, memo)
    local rec = D.Record(questId)
    local out = {}
    if rec and depth < (cfg.chainMax or 30) then
        local list = sortedLinks(rec, forward)
        if not forward and allNeeded(rec, list) then
            -- every one of them is needed (The Hermit Tanner needs 95494 and 95507): one route
            local h, t, ids = chainNeeded(questId, list, pl, cfg, top, seen, depth, memo)
            out[1] = { h = h, t = t, ids = ids }
            return out
        end
        if not forward then
            -- one of a choice done: the quest's prerequisite is met, nothing before it is left (review 2026-11-23:
            -- after Escape Through Force, Escape Through Stealth can no longer be taken)
            for _, f in ipairs(list) do
                if completed(f) then out[1] = { h = 0, t = 0, ids = {} }; return out end
            end
            for _, f in ipairs(rec.p1 or {}) do -- any one of p1 done also meets it
                if completed(f) then out[1] = { h = 0, t = 0, ids = {} }; return out end
            end
        end
        for _, f in ipairs(list) do
            if not seen[f] and not completed(f) and not closedOff(f) then -- done or shut out: left out
                local key = (forward and "f" or "b") .. questId .. ":" .. f
                if memo[key] == nil then memo[key] = { chainCost(questId, f, pl, cfg, top, forward) } end
                local h, t = memo[key][1], memo[key][2]
                if h then
                    seen[f] = true
                    -- f's other needed quests join the route (mirror of the build's chain_paths)
                    local xh, xt, xids = 0, 0, {}
                    if forward then
                        local frec = D.Record(f)
                        local fcp = frec and sortedLinks(frec, false) or {}
                        if frec and allNeeded(frec, fcp) then
                            local others = {}
                            for _, p in ipairs(fcp) do if p ~= questId then others[#others + 1] = p end end
                            xh, xt, xids = chainNeeded(f, others, pl, cfg, top, seen, depth + 1, memo)
                        end
                    end
                    local xadded = {}
                    for _, id in ipairs(xids) do if not seen[id] then seen[id] = true; xadded[#xadded + 1] = id end end
                    for _, p in ipairs(chainPaths(f, pl, cfg, top, forward, seen, depth + 1, memo)) do
                        local ids = { f }
                        for _, id in ipairs(xids) do ids[#ids + 1] = id end
                        for _, id in ipairs(p.ids) do ids[#ids + 1] = id end
                        out[#out + 1] = { h = h + xh + p.h, t = t + xt + p.t, ids = ids }
                        if #out >= CHAIN_PATHS then break end
                    end
                    for _, id in ipairs(xadded) do seen[id] = nil end
                    seen[f] = nil
                    if #out >= CHAIN_PATHS then return out end
                end
            end
        end
    end
    if #out == 0 then out[1] = { h = 0, t = 0, ids = {} } end
    return out
end

-- The whole chain the quest belongs to (user 2026-11-23), back to its first quest and on to its last. A choice
-- of two is two routes: a quest on both (before the choice) takes the better route, a quest after it its own
-- branch. Returns grinding hours saved (H), total seconds, { ids } of the follow-ups and { ids } of the quests
-- before on the best route through the quest; R = H * 3600 / T. Mirror of the build's chain_rate.
local function chainEstimate(questId, est0, pl, cfg, B0)
    local top = ((GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60) - 1 -- quest XP is 0 at max level
    local H0, T0 = est0.XP / B0, est0.T
    local memo = {}
    local fw = chainPaths(questId, pl, cfg, top, true, { [questId] = true }, 0, memo)
    local bw = chainPaths(questId, pl, cfg, top, false, { [questId] = true }, 0, memo)
    local bestR, bestH, bestT, bestF, bestB
    for _, f in ipairs(fw) do
        for _, b in ipairs(bw) do
            local T = T0 + f.t + b.t
            local R = T > 0 and (H0 + f.h + b.h) / T or 0
            if not bestR or R > bestR + 1e-15 then bestR, bestH, bestT, bestF, bestB = R, H0 + f.h + b.h, T, f.ids, b.ids end
        end
    end
    return bestH, bestT, bestF, bestB
end

-- Bonus a chain's follow-ups add (user 2026-11-23): the best one among the follow-ups on its route, a reward
-- that is an upgrade (QR.Gear.Bonus) or a key quest (unlocks a dungeon, raid, area, reputation or skill: +2,
-- as a key quest's own +2). Returns bonus, the follow-up's id.
local function followUpBonus(ids, cfg, questId)
    local best, bestId = 0, nil
    for _, id in ipairs(ids or {}) do
        local rec = D.Record(id)
        local b = rec and (QR.Gear.Bonus(rec, cfg)) or 0
        if rec and (rec.kq == "t" or rec.kq == "k") then b = math.max(b, 2) end
        if b > best then best, bestId = b, id end
    end
    -- a key quest further on in the chain counts even when the chain cannot be estimated up to it (review
    -- 2026-11-23: the druid bear-form steps lost their +2 when Body and Heart became "no data")
    if best < 2 and questId then
        local seen, frontier, depth = { [questId] = true }, { questId }, 0
        while #frontier > 0 and depth < (cfg.chainMax or 30) and best < 2 do
            local nxt = {}
            for _, q in ipairs(frontier) do
                local rec = D.Record(q)
                for _, f in ipairs(rec and rec.cn or {}) do
                    local frec = not seen[f] and D.Record(f)
                    if frec and D.Available(frec) and not completed(f) then
                        seen[f] = true
                        if frec.kq == "t" or frec.kq == "k" then best, bestId = 2, f; break end
                        nxt[#nxt + 1] = f
                    end
                end
                if best >= 2 then break end
            end
            frontier, depth = nxt, depth + 1
        end
    end
    return best, bestId
end

local function buildReasons(res, model, est, cfg)
    local reasons, seen = {}, {}
    local function add(text)
        if text and not seen[text] then
            seen[text] = true
            reasons[#reasons + 1] = text
        end
    end
    if res.keyQuest == "t" then
        local krec = D.Record(model.id)
        add(krec and krec.kw == "skill" and L.REASON_KEY_SKILL or L.REASON_KEY_TOP)
    elseif res.keyQuest == "k" then
        local rec = D.Record(model.id)
        add(string.format(L.REASON_KEY_PLUS, L.KEY_KIND[rec and rec.kw] or ""))
    end
    if model.ready then add(L.REASON_READY) end
    if est.party then
        add(string.format(L.REASON_GROUP, est.party))
    else
        -- an elite target: only the tag "group advised" (user 2026-11-24), the time is the solo estimate
        for _, g in pairs(est.groups or {}) do
            if g.obj and g.obj.rank == "elite" then add(L.REASON_ELITE_GROUP); break end
        end
    end
    -- dungeon quest: in the run or in the open world, the better one (user 2026-11-23)
    if est.solve == "outonly" then add(L.REASON_SOLVE_OUTONLY)
    elseif est.solve == "out" then add(L.REASON_SOLVE_OUT)
    elseif est.solve == "in" then add(L.REASON_SOLVE_IN) end
    -- dungeon run: which run, how long, more runs or farming outside, what the group needs
    if est.dungeon and est.mode == "after" and not model.ready then add(L.REASON_AFTER_RUN) end
    if est.dungeon and not model.ready and est.mode ~= "after" then
        local run = model.run
        add(string.format(L.REASON_RUN, D.WingName(run.wings[1]), math.max(1, math.floor(run.T / 60 + 0.5))))
        if model.runDone then add(L.REASON_RUN_PROGRESS) end
        if est.levelCut then add(L.REASON_LEVEL_GAP) end
        local mins = math.max(1, math.floor((est.catchT or 0) / 60 + 0.5))
        if est.mode == "out" then add(string.format(L.REASON_CATCH_OUT, mins))
        elseif est.mode == "run" then add(string.format(L.REASON_CATCH_RUN, est.runs - (model.runDone and 0 or 1)))
        elseif est.mode == "wing" then add(string.format(L.REASON_CATCH_WING, mins)) end
        if run.need then add(string.format(L.REASON_GROUP_NEED, run.need)) end
    end
    if res.prereqZone then
        add(res.prereqZone > 0 and string.format(L.REASON_DUNGEON_PREREQ, D.DungeonName(res.prereqZone))
            or L.REASON_DUNGEON_PREREQ_NONAME)
    end
    if res.atMax then add(L.REASON_MAX_BASE) end
    -- bonus sources are always named
    if res.gearText then add(res.gearText) end
    if res.gear and res.gear.loading then add(L.REASON_GEAR_LOADING) end
    if res.chainSteps or res.chainBack then
        add(string.format(L.REASON_CHAIN_AVG, #(res.chainBack or {}), res.chainSteps or 0))
    end
    if res.followBonus and res.followBonus > 0 then
        local frec = D.Record(res.followBonusId)
        add(string.format(L.REASON_FOLLOW_BONUS, frec and frec.t or "?", res.followBonus))
    end
    -- a grey quest: that alone explains the rating
    if not res.atMax and E.QuestGray(model.level, res.playerLevel) then
        add(L.REASON_QUEST_GRAY)
        return reasons
    end
    -- direct cause of a low rating: the biggest time sink, with numbers
    if res.level <= 1 and not res.atMax then
        local cands = {}
        if est.wait > 0 then
            -- targets up at a time (spawn points x the chance a point shows the target), not the points
            local S, objects = -1, false
            for _, g in pairs(est.groups) do
                if g.wait > 0 and (g.effS or 0) >= S then
                    S, objects = g.effS or 0, g.obj.kind == "object" or g.obj.fromObject
                end
            end
            cands[#cands + 1] = { t = est.wait, text = string.format(objects and L.REASON_RESPAWN_OBJECT or L.REASON_RESPAWN,
                math.max(0, S), math.floor(est.wait / 60 + 0.5)) }
        end
        if est.Troute > 0 then
            cands[#cands + 1] = { t = est.Troute, text = string.format(L.REASON_ROUTE, math.max(1, math.floor(est.Troute / 60 + 0.5))) }
        end
        if (est.Tescort or 0) > 0 then
            cands[#cands + 1] = { t = est.Tescort, text = string.format(L.REASON_ESCORT, math.max(1, math.floor(est.Tescort / 60 + 0.5))) }
        end
        for _, g in pairs(est.groups) do
            local obj = g.obj
            local farm = g.T - g.wait - (g.altT or 0)
            if (g.altT or 0) > 0 then
                cands[#cands + 1] = { t = g.altT, text = string.format(L.REASON_ALT, math.max(1, math.floor(g.altT / 60 + 0.5))) }
            end
            if obj.kind == "object" or obj.fromObject then
                -- picking up: how many, and the walk + use time per object
                if obj.fromObject and obj.p and g.p and g.p < 0.5 then
                    cands[#cands + 1] = { t = farm, text = string.format(L.REASON_OBJECT_CHANCE, math.floor(g.p * 100 + 0.5), math.floor(g.K + 0.5)) }
                elseif g.K > 0 then
                    cands[#cands + 1] = { t = farm, text = string.format(L.REASON_OBJECT, math.floor(g.K + 0.5), math.floor(g.tKill + 0.5)) }
                end
            elseif obj.kind == "item" and g.p and g.p < 0.5 and not obj.pUnknown then
                cands[#cands + 1] = { t = farm, text = string.format(L.REASON_DROP, math.floor(g.p * 100 + 0.5), math.floor(g.K + 0.5)) }
            elseif obj.rank == "elite" and not est.party then
                cands[#cands + 1] = { t = farm, text = string.format(L.REASON_ELITE, math.floor(g.K + 0.5)) }
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
    -- (route sharing is efficiency, the general standard: no reason line for it, user 2026-11-22 / 11-23)
    -- data reliability
    for _, f in ipairs(model.flags) do
        if f == L.DROP_UNKNOWN or f == L.COUNT_UNKNOWN or f == L.ROUTE_UNKNOWN or f == L.LOCATION_UNKNOWN or f == L.SPAWNS_INCOMPLETE
            or f == L.DROP_EMULATED or f == L.MULTI_UNKNOWN then
            add(f)
        end
    end
    return reasons
end

-- Returns a result table (all intermediate values kept for /qr debug), or nil, reason.
function QR.Rate(questId)
    if not QR.ready then return nil, L.MSG_NOT_READY end
    local cfg = QR.CfgFor(UnitLevel("player") or 1) -- your measured fight time once there are enough samples
    local model, why = getModel(questId)
    if not model then return nil, why end
    local res = { questId = questId, model = model, playerLevel = UnitLevel("player") or 1 }
    -- a dungeon quest further down the chain: named in the reasons; the chain estimate decides its worth
    if not model.dungeon then
        local zone, depth = dungeonAhead(questId, cfg)
        if zone then res.prereqZone, res.prereqDepth = zone, depth end
    end
    -- gives no XP: not rated below max level and not in the standard (user 2026-11-22 / 11-23); an
    -- attunement or a new skill is still the best rating, at max level XP is not rated anyway
    if model.noXP and res.playerLevel < maxLevel() then
        local rec = D.Record(questId)
        if not (rec and rec.kq == "t") then
            res.noData, res.unrated = true, true
            res.reasons = { L.REASON_UNRATED_NO_XP }
            if rec and rec.kq == "k" then
                table.insert(res.reasons, 1, string.format(L.REASON_KEY_PLUS, L.KEY_KIND[rec.kw] or ""))
            end
            return res
        end
    end
    -- almost no XP at your level (user 2026-11-22 R017, 11-24 "find a proper threshold"): below lowXP of the
    -- median quest XP of the quests you can take at your level (QR_GEN.xpMed; the build's low_xp); not rated
    -- and left out of the map recommendation, like a quest without XP. A quest that opens other quests is not
    -- (review 2026-11-24: a talk quest opening a chain or several quests is worth what it opens)
    local med = QR_GEN and QR_GEN.xpMed and QR_GEN.xpMed[res.playerLevel]
    if med and res.playerLevel < maxLevel() and (model.questXP or 0) > 0
        and model.questXP < (QR_GEN.lowXP or 0.1) * med then
        local rec = D.Record(questId)
        if not (rec and (rec.kq == "t" or (rec.nq and #rec.nq > 0))) then -- nq: quests it opens (build: low_xp)
            res.noData, res.unrated, res.lowXP = true, true, true
            res.reasons = { string.format(L.REASON_UNRATED_LOW_XP, model.questXP) }
            if rec and rec.kq == "k" then
                table.insert(res.reasons, 1, string.format(L.REASON_KEY_PLUS, L.KEY_KIND[rec.kw] or ""))
            end
            return res
        end
    end
    if model.noData or #model.missing > 0 then
        -- not estimable: say what is missing instead of rating on a guess
        local rec = D.Record(questId)
        if rec and rec.kq == "t" then
            -- an attunement every member needs, or a new skill: the best rating even without an estimate (user 2026-11-23)
            res.level, res.keyQuest = 4, "t"
            res.reasons = { rec.kw == "skill" and L.REASON_KEY_SKILL or L.REASON_KEY_TOP }
            for _, m in ipairs(#model.missing > 0 and model.missing or { L.NO_DATA }) do res.reasons[#res.reasons + 1] = m end
            return res
        end
        if res.playerLevel >= maxLevel() then
            -- max level: XP efficiency is not rated (base 中 + reward and key-quest bonus), so missing time
            -- data does not matter (user 2026-11-23, e.g. Tier 0.5 quests)
            res.atMax, res.position = true, 2.0
            res.bonus, res.gearText, res.gear = QR.Gear.Bonus(rec, cfg)
            -- a key quest further on in its chain adds +2, as for quests that can be estimated
            res.followBonus, res.followBonusId = followUpBonus(nil, cfg, questId)
            if res.followBonus > 0 then res.bonus = (res.bonus or 0) + res.followBonus end
            res.level = E.Level(2.0, res.bonus)
            res.reasons = { L.REASON_MAX_BASE }
            if res.followBonus > 0 then
                local frec = D.Record(res.followBonusId)
                res.reasons[#res.reasons + 1] = string.format(L.REASON_FOLLOW_BONUS, frec and frec.t or "?", res.followBonus)
            end
            if rec and rec.kq == "k" then
                res.level, res.keyQuest = E.Level(2.0, (res.bonus or 0) + 2), "k"
                res.reasons[#res.reasons + 1] = string.format(L.REASON_KEY_PLUS, L.KEY_KIND[rec.kw] or "")
            end
            if res.gearText then res.reasons[#res.reasons + 1] = res.gearText end
            if res.gear and res.gear.loading then res.reasons[#res.reasons + 1] = L.REASON_GEAR_LOADING end
            -- what could not be estimated (no effect on the rating at max level)
            for _, m in ipairs(#model.missing > 0 and model.missing or { L.NO_DATA }) do res.reasons[#res.reasons + 1] = m end
            return res
        end
        res.noData = true
        res.reasons = {} -- a new list: model.missing is cached with the model
        if rec and rec.kq == "k" then res.reasons[1] = string.format(L.REASON_KEY_PLUS, L.KEY_KIND[rec.kw] or "") end
        for _, m in ipairs(#model.missing > 0 and model.missing or { L.NO_DATA }) do res.reasons[#res.reasons + 1] = m end
        return res
    end
    local pl = res.playerLevel
    local nearby, nearbyList, est = 0, {}, nil
    if model.run then
        -- dungeon quest: the run with the other quests it can do, or the open world
        est, nearby, nearbyList = rateDungeonQuest(model, pl, cfg, true)
    else
        nearby, nearbyList = countNearby(model, cfg)
        est = E.Quest(model, pl, cfg, nearby)
    end
    res.est, res.nearby, res.nearbyList = est, nearby, nearbyList
    res.B = E.Baseline(pl, cfg)
    res.E = est.T > 0 and (est.XP / est.T * 3600) or 0
    res.R = res.B > 0 and res.E / res.B or 0
    res.atMax = pl >= maxLevel()
    -- standard: rank among same-level quests (user 2026-11-23), each 20 % one band
    local scale = cfg
    local cuts, median = D.LevelDist(pl, cfg)
    if cuts then
        scale = { thresholds = cuts }
        res.median = median
    end
    res.cuts = scale.thresholds
    res.position = res.atMax and 2.0 or E.Position(res.R, scale)
    -- a chain (user 2026-11-23): ranked by its best whole route, also when lower than alone
    if not res.atMax and est.T > 0 then
        local cH, cT, ids, back
        if res.B > 0 then cH, cT, ids, back = chainEstimate(questId, est, pl, cfg, res.B) end
        if cH and cT > 0 and (#ids > 0 or #back > 0) then
            res.chainSteps, res.chainIds, res.chainBack = #ids, ids, back
            res.Rchain = cH * 3600 / cT
            local p = E.Position(res.Rchain, scale)
            res.position = p
        end
    end
    -- reward gear (OneForAll)
    res.bonus, res.gearText, res.gear = QR.Gear.Bonus(D.Record(questId), cfg)
    -- follow-ups on the chain's route with an upgrade or a key quest add their best bonus
    res.followBonus, res.followBonusId = followUpBonus(res.chainIds, cfg, questId)
    if res.followBonus > 0 then res.bonus = (res.bonus or 0) + res.followBonus end
    res.level = E.Level(res.position, res.bonus)
    -- key quests (user 2026-11-23; _tools/calibration/key_quests.tsv): every member needs it to enter a
    -- dungeon / raid / area -> the best rating; a dungeon key (one per group), a new reputation or system -> +2
    local rec = D.Record(questId)
    if rec and rec.kq == "t" then
        res.level, res.keyQuest = 4, "t"
    elseif rec and rec.kq == "k" then
        res.level, res.keyQuest = E.Level(res.position, (res.bonus or 0) + 2), "k"
    end
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

-- A follow-up's own rating for the tooltip (user 2026-11-24, R028: show each follow-up's rating and reasons): the
-- quest alone at your level, without its chain (the chain is already the rating of the quest you look at) and
-- without the bonus of key quests further on; its reward bonus and its own key-quest rule kept. Returns level
-- (or nil when it is not rated: noData / unrated), reasons, the result.
function QR.OwnRating(questId)
    local res = QR.RateCached(questId)
    if not res then return nil end
    if res.noData then return nil, res.reasons or {}, res end
    if res.atMax or not res.R or not res.cuts then return res.level, res.reasons or {}, res end
    local level
    if res.keyQuest == "t" then
        level = 4
    else
        -- at the level you would do it, max(your level, its level), as the chain counts it (review 2026-11-24)
        local pl, rec = res.playerLevel, D.Record(questId)
        local lv = math.min(59, math.max(pl, (rec and rec.lv or 0) > 0 and rec.lv or pl))
        local R, cuts = res.R, res.cuts
        if lv ~= pl then
            local cfg = QR.CfgFor(lv)
            local est, B = soloEstimate(questId, lv, cfg), E.Baseline(lv, cfg)
            local c = D.LevelDist(lv, cfg)
            if est and B > 0 and c then R, cuts = est.XP / est.T * 3600 / B, c end
        end
        local b = (res.bonus or 0) - (res.followBonus or 0) + (res.keyQuest == "k" and 2 or 0)
        level = E.Level(E.Position(R, { thresholds = cuts }), b)
    end
    local skip = {}
    if res.chainSteps or res.chainBack then
        skip[string.format(L.REASON_CHAIN_AVG, #(res.chainBack or {}), res.chainSteps or 0)] = true
    end
    if res.followBonus and res.followBonus > 0 then
        local frec = D.Record(res.followBonusId)
        skip[string.format(L.REASON_FOLLOW_BONUS, frec and frec.t or "?", res.followBonus)] = true
    end
    local reasons = {}
    for _, r in ipairs(res.reasons or {}) do if not skip[r] then reasons[#reasons + 1] = r end end
    return level, reasons, res
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
    ACTIVE_TALENT_GROUP_CHANGED = true, GROUP_ROSTER_UPDATE = true }
QR.RegisterReady(function()
    local ev = CreateFrame("Frame")
    for _, e in ipairs({ "PLAYER_LEVEL_UP", "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN",
        "PLAYER_EQUIPMENT_CHANGED", "CHARACTER_POINTS_CHANGED", "TRAIT_CONFIG_UPDATED", "ACTIVE_TALENT_GROUP_CHANGED",
        "GET_ITEM_INFO_RECEIVED", "GROUP_ROSTER_UPDATE" }) do
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

---------------------------------------------------------------------------------------------
-- Dungeon and map recommendation (user 2026-11-23)
---------------------------------------------------------------------------------------------
-- A dungeon wing at your level: one normal run's kill XP + the quests of that run you can do now (each by the
-- part the route finishes, as in a dungeon quest's estimate) over the run time + the fixed travel + their talk
-- time. Ranked like a quest among the same-level open-world quests (QR_GEN.dist): "high" = better than most
-- quests of your level. Returns { level, R, xph, medianXph, quests, atMax } or nil.
-- The level range of a wing: the client's dungeon finder (user 2026-11-23: "the built-in dungeon finder's
-- range; too high or too low is not recommended"). LFGDungeons IDs (server hotfix table lfg_dungeons) -> our
-- wings; the range is the finder's recommended levels (minRecLevel / maxRecLevel). A single level is no range
-- (user 2026-11-23: every dungeon showed one level): then the route's mob levels, or for a wing without a route
-- the allowed min / max. Without the finder (API missing, data not loaded) the route's mob levels, marked as such.
local LFG_WINGS = { [1] = { "WC" }, [2] = { "Scholo" }, [3] = { "RFC" }, [5] = { "DM" }, [7] = { "SFK" }, [9] = { "BFD" },
    [11] = { "Stocks" }, [13] = { "Gnomer" }, [15] = { "RFK" }, [17] = { "SM" }, [19] = { "RFD" }, [21] = { "Ulda" },
    [23] = { "ZF" }, [25] = { "Mara" }, [27] = { "ST" }, [29] = { "BRD" }, [31] = { "LBRS" }, [33] = { "DM-East" },
    [35] = { "DM-West" }, [37] = { "DM-North" }, [39] = { "Strat-Live", "Strat-UD" }, [43] = { "UBRS" },
    [3272] = { "Lordaeron" }, [3273] = { "Thanes" }, [3271] = { "Dalaran" }, [3274] = { "Excavation" } }
-- WoW Forever dungeons without any creature data (server and ForeverDB: no spawns on their maps), so no route:
-- shown as "no data" instead of not at all (user 2026-11-23: the Excavation Site was missing). The build lists
-- every dungeon with its recommended levels (QR_GEN.wingLv); the ones without a wing entry have no route.
function QR.NoDataWings()
    local out = {}
    for key in pairs(QR_GEN and QR_GEN.wingLv or {}) do
        if not (QR_GEN.wing and QR_GEN.wing[key]) then out[key] = true end
    end
    return out
end
local finderRange, finderRaw = nil, {}
local function finderRanges()
    if finderRange then return finderRange end
    local out, n = {}, 0
    if GetLFGDungeonInfo then
        for id, keys in pairs(LFG_WINGS) do
            local ok, _, _, _, minL, maxL, _, minRec, maxRec = pcall(GetLFGDungeonInfo, id)
            minL, maxL, minRec, maxRec = tonumber(minL) or 0, tonumber(maxL) or 0, tonumber(minRec) or 0, tonumber(maxRec) or 0
            -- the recommended range, else the allowed one; a single level is no range (user 2026-11-23: every
            -- dungeon showed one level: with level scaling the client's recommended range collapses), so then the
            -- route's mob levels are used
            local lo, hi, rec
            if ok and minRec > 0 and maxRec > minRec then lo, hi, rec = minRec, maxRec, true
            elseif ok and minL > 0 and maxL > minL then lo, hi = minL, maxL end
            for _, k in ipairs(keys) do
                finderRaw[k] = ok and { minL, maxL, minRec, maxRec } or nil
                if lo then out[k] = { lo, hi, rec = rec } end
            end
            if ok and (minL > 0 or minRec > 0) then n = n + 1 end
        end
    end
    local all = 0
    for _ in pairs(LFG_WINGS) do all = all + 1 end
    if n == all then finderRange = out end -- keep asking until the client has every entry
    return out
end
-- lo, hi, source ("list": the published recommended levels, user 2026-11-23; "finder": the client's dungeon
-- finder; false: the route's mob levels)
function QR.WingRange(key)
    local lv = QR_GEN and QR_GEN.wingLv and QR_GEN.wingLv[key]
    if lv then return lv[1], lv[2], "list" end
    local r = finderRanges()[key]
    local w = QR_GEN and QR_GEN.wing and QR_GEN.wing[key]
    -- the allowed range (used when the recommended one is a single level) can be very wide with scaling: the
    -- route's mob levels come first then; a finder range far from them is a mismatch (e.g. a scaling cap)
    if r and not r.rec and w and w.lo then r = nil end
    if r and not (w and w.lo and (r[1] > w.hi + 5 or r[2] < w.lo - 5)) then return r[1], r[2], "finder" end
    return w and w.lo, w and w.hi, false
end
-- raw finder values of a wing (for /qr dungeons): { min, max, recommended min, recommended max } or nil
function QR.WingFinderRaw(key)
    finderRanges()
    return finderRaw[key]
end

local rateWing
function QR.RateWing(key)
    local c = wingCache[key]
    if c == nil then c = rateWing(key) or false; if QR.ready then wingCache[key] = c end end
    return c or nil
end
function rateWing(key)
    local w = QR_GEN and QR_GEN.wing and QR_GEN.wing[key]
    if QR.ready and not w and QR_GEN.wingLv and QR_GEN.wingLv[key] then
        local lo, hi, finder = QR.WingRange(key)
        local pl = UnitLevel("player") or 1
        if lo and hi and (pl < lo or pl > hi) then
            return { outside = true, key = key, lo = lo, hi = hi, finder = finder } -- not recommended, as rated wings
        end
        return { noData = true, key = key, lo = lo, hi = hi, finder = finder }
    end
    if not (QR.ready and w) then return nil end
    local pl = UnitLevel("player") or 1
    local lo, hi, finder = QR.WingRange(key)
    if lo and hi and (pl < lo or pl > hi) then
        return { outside = true, key = key, lo = lo, hi = hi, finder = finder } -- not recommended, not rated
    end
    local cfg = QR.CfgFor(pl)
    local run = { wings = { key }, T = w.t, n = w.n or 0, kills = { w.k }, shares = { w.s }, inner = w.s }
    local xp = E.RunXP(run, pl, cfg.partyMax)
    local T = w.t + ((QR_GEN.dungeonTravel) or 0) -- the run itself (travel not counted, user 2026-11-24)
    local comps = runCompanions({ id = 0, run = run }, pl, cfg, true) -- every dungeon quest you can still do
    -- also the run with only the quests already in your log (user 2026-11-24: which quests to take, and the
    -- rating without them)
    local xp0, T0 = xp, T
    local need = {}
    for _, c in ipairs(comps) do
        xp, T = xp + c.xp, T + c.t
        if c.taken then xp0, T0 = xp0 + c.xp, T0 + c.t elseif c.xp > 0 then need[#need + 1] = c
        else xp0, T0 = xp0 + c.xp, T0 + c.t end -- (a quest the run gives no part of: not one to take for it)
    end
    local res = { quests = #comps, atMax = pl >= maxLevel(), key = key, T = T, lo = lo, hi = hi, finder = finder,
                  need = need }
    local B = E.Baseline(pl, cfg)
    local cuts, median = D.LevelDist(pl, cfg)
    local function level(x, t)
        local xph = t > 0 and x / t * 3600 or 0
        local R = B > 0 and xph / B or 0
        return E.Level(res.atMax and 2.0 or E.Position(R, cuts and { thresholds = cuts } or cfg), 0), xph, R
    end
    res.level, res.xph, res.R = level(xp, T)
    res.levelTaken, res.xphTaken = level(xp0, T0)
    res.medianXph = median and median * B or nil
    return res
end

-- A map at your level (user 2026-11-23; not compared with grinding): its open-world quests you can take now
-- (quests without XP or with almost none, as rated, left out; a slow quest is not), in hubs (a map with two hubs
-- of many quests each is not "scattered"): the quests' main points grouped into hubs by greedy disc cover at
-- nearbyRadius (each hub at most 2 x radius across); inside a hub the quests share their own routes (divided by
-- min(nearbyCap, quests in the hub)) plus a walk between their main points; between hubs one tour (nearest
-- neighbour over the hub centres); the trip to the map is not counted (user 2026-11-24). Two ranks among the
-- maps that fit your level (user 2026-11-21 "by the number of quests and their ratings", 11-24 "also
-- concentration and distance", "no one-hour cap"): the XP per hour of doing them all (QR_GEN.zdist) and their
-- number (QR_GEN.zcount), each 0..4; the map's position is their geometric mean. A map fits when its quest levels
-- (QR_GEN.zlv, 20-80 %) are at most 4 above you and not all grey. Returns { level, xph, quests, good, hubs }
-- or nil (max level, the map does not fit, no standard, nothing to take). Mirror of the build's map_plan / ZDIST.
-- the zone map you are on: the first zone map up the parents of where you stand (a cave, a building, a dock or
-- any other sub-map counts as its zone; user 2026-11-23: on Darkshore the map rating fell from "very high" to "very
-- low" for a while: only micro maps were walked up, so another sub-map type, or no map during a load, read as
-- "not on this map"; the trip to a map is no longer counted, the map you are on is still reported). No map
-- for a moment (loading, a transition): the last zone seen. Inside a dungeon or on a continent: none.
local lastZone
local function playerZoneMap()
    if IsInInstance and IsInInstance() then lastZone = nil; return nil end
    local id = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if not id then return lastZone end
    local zoneType = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
    for _ = 1, 8 do
        local info = C_Map.GetMapInfo(id)
        if not info then break end
        if info.mapType == zoneType then lastZone = id; return id end
        if info.mapType ~= nil and info.mapType < zoneType then break end -- continent / world / cosmic
        id = info.parentMapID
        if not id or id == 0 then break end
    end
    lastZone = nil
    return nil
end

function QR.RateZone(uiMap)
    if not (QR.ready and uiMap) then return nil end
    local pl = UnitLevel("player") or 1
    if pl >= maxLevel() then return nil end
    local lv = QR_GEN and QR_GEN.zlv and QR_GEN.zlv[uiMap]
    if not lv or lv[1] - pl > 4 or lv[2] <= E.GrayLevel(pl) then return nil end
    local cuts = QR_GEN.zdist and QR_GEN.zdist[math.max(1, math.min(59, pl))]
    local ncuts = QR_GEN.zcount and QR_GEN.zcount[math.max(1, math.min(59, pl))]
    if not (cuts and ncuts) then return nil end
    -- the standard is built at the default pace: the map's quests are estimated the same way (review 2026-11-23)
    local cfg = QR.DEFAULTS
    local list = D.MapQuests(uiMap)
    local onMap = {}
    for _, id in ipairs(list) do onMap[id] = true end
    -- open on this map: not done, can take it at your level, prerequisites done or themselves open here (the
    -- build counts every quest of the level; a chain on the map is done in one visit)
    local openMemo = {}
    local function openHere(id, depth)
        if openMemo[id] ~= nil then return openMemo[id] end
        local rec = D.Record(id)
        local ok = rec and D.Available(rec) and not completed(id) and (inLogQuest(id)
            or ((rec.ml or 0) <= pl and not E.QuestGray(rec.lv, pl))) and true or false
        if ok and not inLogQuest(id) and depth < 8 then
            local function pre(p) return completed(p) or (onMap[p] and openHere(p, depth + 1)) end
            for _, p in ipairs(rec.pa or {}) do if not pre(p) then ok = false end end
            if ok and rec.p1 and #rec.p1 > 0 then
                local any = false
                for _, p in ipairs(rec.p1) do if pre(p) then any = true end end
                ok = any
            end
        end
        openMemo[id] = ok
        return ok
    end
    local items, good, seenKey = {}, 0, {}
    -- two records of the same quest (WoW Forever re-adds some with a new ID: To Serve Kum'isha 2521 / 93685):
    -- same title, level, XP, main point and objectives count once (mirror of the build's map_dup_key)
    local function dupKey(rec)
        local parts = {}
        for _, o in ipairs(rec.o or {}) do parts[#parts + 1] = string.format("%d:%d:%d", o.k or 0, o.i or 0, o.n or 0) end
        table.sort(parts)
        local c = rec.c or {}
        return string.format("%s|%s|%s|%.1f,%.1f,%.1f|", rec.t or "", tostring(rec.lv), tostring(rec.xp or 0),
            c[1] or 0, c[2] or 0, c[3] or 0) .. table.concat(parts, ",")
    end
    for _, id in ipairs(list) do
        local rec = D.Record(id)
        local key = rec and dupKey(rec)
        if rec and rec.c and not rec.cl and rec.ho ~= 1 and not seenKey[key] and openHere(id, 0) then -- no class / holiday quests
            local res = QR.RateCached(id)
            local m = res and res.model
            -- only quests without XP or with almost none (res.unrated) are left out; a slow quest is not (user 2026-11-24)
            if m and not res.noData and not m.noXP then
                local est = E.Quest(m, pl, cfg, 0) -- alone, its own route unshared
                if est.T > 0 then
                    items[#items + 1] = { xp = est.XP, t = est.T, route = est.TrouteNear or 0,
                                          p = { inst = rec.c[1], x = rec.c[2], y = rec.c[3] } }
                    if (res.level or 0) >= 3 then good = good + 1 end
                    seenKey[key] = true
                end
            end
        end
    end
    if #items == 0 then return nil end
    -- hubs: greedy disc cover (QT clustering) at nearbyRadius, mirror of the build's hubs_of
    local R0 = cfg.nearbyRadius
    local nb = {}
    for a = 1, #items do
        nb[a] = {}
        for b = 1, #items do
            if a ~= b then
                local d = E.Dist(items[a].p, items[b].p)
                if d and d <= R0 then nb[a][#nb[a] + 1] = b end
            end
        end
    end
    local left, nLeft, hubs = {}, #items, {}
    for a = 1, #items do left[a] = true end
    while nLeft > 0 do
        local best, bestN
        for a = 1, #items do
            if left[a] then
                local n = 0
                for _, b in ipairs(nb[a]) do if left[b] then n = n + 1 end end
                if not bestN or n > bestN then best, bestN = a, n end
            end
        end
        local g = { best }
        for _, b in ipairs(nb[best]) do if left[b] then g[#g + 1] = b end end
        for _, b in ipairs(g) do left[b] = false end
        nLeft = nLeft - #g
        table.sort(g)
        hubs[#hubs + 1] = g
    end
    local here = playerZoneMap() == uiMap
    local xp, T, centres = 0, 0, {} -- the trip there is not counted (user 2026-11-24)
    -- nearest-neighbour tour from the first point (user 2026-11-24: the distance between quests counts)
    local function tour(pts)
        local s, cur, rest = 0, pts[1], {}
        for k = 2, #pts do rest[#rest + 1] = pts[k] end
        while #rest > 0 do
            local bi, bd
            for k, c in ipairs(rest) do
                local d = E.Dist(cur, c) or math.huge
                if not bd or d < bd then bi, bd = k, d end
            end
            if bd and bd < math.huge then s = s + E.LegTime(bd, cfg, pl) end
            cur = table.remove(rest, bi)
        end
        return s
    end
    for _, g in ipairs(hubs) do
        local share = math.min(cfg.nearbyCap, #g)
        local sx, sy, pts = 0, 0, {}
        for _, k in ipairs(g) do
            local it = items[k]
            xp, T = xp + it.xp, T + it.t - it.route + it.route / share
            sx, sy = sx + it.p.x, sy + it.p.y
            pts[#pts + 1] = it.p
        end
        T = T + tour(pts) -- the walk between the hub's quests
        centres[#centres + 1] = { inst = items[g[1]].p.inst, x = sx / #g, y = sy / #g }
    end
    -- tour over the hub centres: nearest neighbour from the biggest hub
    local cur, rest = centres[1], {}
    for k = 2, #centres do rest[#rest + 1] = centres[k] end
    while #rest > 0 do
        local bi, bd
        for k, c in ipairs(rest) do
            local d = E.Dist(cur, c) or math.huge
            if not bd or d < bd then bi, bd = k, d end
        end
        if bd and bd < math.huge then T = T + E.LegTime(bd, cfg, pl) end
        cur = table.remove(rest, bi)
    end
    -- how well you level here and how much there is: the geometric mean of the two ranks, so a map weak in either
    -- is not good (one quick quest is no map to go to; mirror of the build's ZDIST / ZCOUNT)
    local xph = T > 0 and xp / T * 3600 or 0
    local pos = math.sqrt(E.Position(xph, { thresholds = cuts }) * E.Position(#items, { thresholds = ncuts }))
    return { level = E.Level(pos, 0), xph = xph, position = pos, quests = #items, good = good, hubs = #hubs,
             here = here }
end
