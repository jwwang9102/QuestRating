local _, QR = ...

-- Time-efficiency math. The only game API calls are E.HasRiding's; _tools/build_questrating_data.py mirrors every
-- function (objective_time, rate, dungeon_quest_plan, rate_dungeon, chain_rate). Units: seconds, yards, XP.
local E = {}
QR.Estimate = E

local floor, sqrt, min, max = math.floor, math.sqrt, math.min, math.max

-- On foot: between kills and in the grinding baseline.
function E.WalkSpeed(cfg)
    return cfg.walkSpeed
end

-- Riding (user 2026-11-26: "whether you ride depends on having learned riding, not only the level"): mounted
-- now, a WoW Forever riding quest turned in (OneForAll's group of the "Your First ..." mount quests: the riding
-- skill comes with them), or a riding skill line. Checked at most every 5 s until found; riding is not lost, so
-- once found it stays, and the ratings are redone (review 2026-11-26: a rating cached on foot kept the walk).
local RIDING_QUESTS = { 95511, 96982, 96989, 96994, 96996, 96997, 97017, 97045, 97046, 97171, 97446, 98166, 99326 }
local RIDING_SKILL = { ["Riding"] = true, ["騎術"] = true, ["騎乘"] = true }
local ridingAt, riding = -10, false
local function questDone(id)
    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then return C_QuestLog.IsQuestFlaggedCompleted(id) end
    return IsQuestFlaggedCompleted and IsQuestFlaggedCompleted(id)
end
local function found()
    riding = true
    if QR.InvalidateRatings then QR.InvalidateRatings() end
    return true
end
function E.HasRiding()
    if riding then return true end
    local now = GetTime and GetTime() or 0
    if now - ridingAt < 5 then return false end
    ridingAt = now
    if IsMounted and IsMounted() then return found() end
    for _, id in ipairs(RIDING_QUESTS) do
        if questDone(id) then return found() end
    end
    if GetNumSkillLines and GetSkillLineInfo then
        for i = 1, GetNumSkillLines() do
            local name, isHeader = GetSkillLineInfo(i)
            if name and not isHeader and RIDING_SKILL[name] then return found() end
        end
    end
    return false
end

-- Travel legs (giver -> targets -> finisher): in "auto" mode the mount once you have riding (E.HasRiding);
-- mountLevel only if the riding check itself fails (it does not in the game client).
function E.TravelSpeed(cfg, playerLevel)
    if cfg.speedMode == "mount" then return cfg.mountSpeed end
    if cfg.speedMode == "auto" then
        local ok, has = pcall(E.HasRiding)
        if ok then return has and cfg.mountSpeed or cfg.walkSpeed end
        if (playerLevel or 0) >= cfg.mountLevel then return cfg.mountSpeed end
    end
    return cfg.walkSpeed
end

-- Seconds for one travel leg: ground, or a flight path when that is faster on a long leg; noFly for a quest's
-- route legs, whose flights are their own legs (the build's fly_route).
function E.LegTime(yards, cfg, playerLevel, noFly)
    local ground = yards / E.TravelSpeed(cfg, playerLevel)
    if not noFly and yards >= cfg.flightMinYards then
        return min(ground, cfg.flightOverhead + yards / cfg.flightSpeed)
    end
    return ground
end

-- rank: "normal" | "elite" | "rare"
function E.FightTime(mobLevel, playerLevel, rank, cfg)
    local f = 1 + cfg.fightPerLevel * (mobLevel - playerLevel)
    f = min(cfg.fightMaxFactor, max(cfg.fightMinFactor, f))
    local r = (rank == "elite" and cfg.eliteFactor) or (rank == "rare" and cfg.rareFactor) or 1
    return cfg.fightBase * f * r
end

-- Classic (Azeroth) kill XP: 5*level+45, +5% per level above you (max 4), reduced by the
-- zero-difference table below you, 0 at or below the grey level, x2 for elites.
local function grayLevel(pl)
    if pl <= 5 then return 0 end
    if pl <= 39 then return pl - floor(pl / 10) - 5 end
    return pl - floor(pl / 5) - 1
end
E.GrayLevel = grayLevel
-- A grey quest at your level. Level -1 / 0 is a quest whose level follows yours (review 2026-11-24): never grey.
function E.QuestGray(questLevel, pl)
    return (questLevel or 0) > 0 and questLevel <= grayLevel(pl)
end

local function zeroDiff(pl)
    if pl <= 7 then return 5 end
    if pl <= 9 then return 6 end
    if pl <= 11 then return 7 end
    if pl <= 15 then return 8 end
    if pl <= 19 then return 9 end
    if pl <= 29 then return 11 end
    if pl <= 39 then return 12 end
    if pl <= 44 then return 13 end
    if pl <= 49 then return 14 end
    if pl <= 54 then return 15 end
    if pl <= 59 then return 16 end
    return 17
end

function E.KillXP(mobLevel, playerLevel, isElite)
    if mobLevel <= grayLevel(playerLevel) then return 0 end
    local base = 5 * mobLevel + 45
    local xp
    if mobLevel >= playerLevel then
        xp = base * (1 + 0.05 * min(mobLevel - playerLevel, 4))
    else
        xp = base * (1 - (playerLevel - mobLevel) / zeroDiff(playerLevel))
    end
    xp = max(0, xp)
    if isElite then xp = xp * 2 end
    return xp
end

function E.Dist(a, b)
    if not (a and b) or a.inst ~= b.inst then return nil end
    local dx, dy = a.x - b.x, a.y - b.y
    return sqrt(dx * dx + dy * dy)
end

-- Group quests (user 2026-11-23): a party of 3-5, whichever is best. Kill XP: the server's group rate
-- (2 players 1.0, 3 1.166, 4 1.3, 5 1.4) split over the members. Fight time: your solo fight time (elites
-- included) / (party - 1): one member heals, the others deal damage as you do (user 2026-11-23: N to N-1
-- times as fast, with a healer). Kill credit is shared; items to collect several of x party (one per corpse)
-- unless the item drops for every member (user 2026-11-25: one per corpse unless the data says otherwise).
local GROUP_RATE = { 1.0, 1.0, 1.166, 1.3, 1.4 }
E.GROUP_RATE = GROUP_RATE

-- obj: { kind = "kill"|"item"|"object"|"event"|"vendor"|"none", N, p (0..1 or nil),
--        S, A, d (precomputed camp), presence, altPer, mobLevel, rank, fromObject, rs (camp respawn, server data) }
-- party: nil (alone) or { n = members }
-- returns { K, S, A, d, effS (targets up at a time), tKill, wait, altT, T, xp, p }
function E.Objective(obj, playerLevel, cfg, party)
    local r = { K = 0, S = 0, A = 0, d = 0, tKill = 0, wait = 0, T = 0, xp = 0, p = obj.p }
    local kind = obj.kind
    if kind == "event" or kind == "vendor" or kind == "none" or (obj.N or 0) <= 0 or obj.incidental then
        return r -- incidental: a random drop / the quest's starter item, held when you do it (the build's random_drop)
    end
    -- drops and items from objects use their chance; an object without one gives the item (most known
    -- object chances are 100 %). Kills and object uses always count.
    local p = obj.p
    if kind ~= "item" then p = 1 end
    if not p or p <= 0 then p = obj.fromObject and 1 or cfg.defaultDropRate end
    r.p = p
    local mul = 1
    if party and (kind == "item" or obj.fromObject) and (obj.needed or obj.N) > 1 and not obj.multiDrop then
        mul = party.n
    end
    -- expected kills and respawn waves (no rounding up: an 80 % drop of a single mob waits a quarter of a
    -- respawn on average, not a whole one)
    r.K = obj.N * mul / (p * (obj.perLoot or 1)) -- perLoot: items per loot (the build's LOOT_COUNT)
    if obj.synthetic or not obj.S then
        -- location unknown / spawns incomplete: grinding density, no respawn limit
        r.S, r.A, r.d = 0, 0, cfg.grindDistance
    else
        -- precomputed offline (Data/Generated.lua)
        r.S, r.A, r.d = obj.S, obj.A or 0, obj.d or cfg.densityCap
    end
    local walk = r.d / E.WalkSpeed(cfg)
    if kind == "object" or obj.fromObject then
        r.tKill = cfg.objectLootTime + walk
        r.xp = 0
    else
        local fight = E.FightTime(obj.mobLevel, playerLevel, obj.rank, cfg)
        local xp = E.KillXP(obj.mobLevel, playerLevel, obj.rank == "elite")
        if party then
            fight = fight / (party.n - 1)
            xp = xp * GROUP_RATE[party.n] / party.n
        end
        r.tKill = fight + select(2, E.GapTerms(cfg, party)) + walk
        r.xp = xp * r.K
    end
    if not (obj.synthetic or not obj.S) then
        -- mobs up when you start (spawn points x the chance a point shows the target x your share); later
        -- waves the same after each respawn (the floor only avoids a division by zero)
        local effS = max(1e-3, r.S * (obj.presence or 1) * cfg.shareFactor)
        r.effS = effS
        local waves = r.K / effS
        -- shared spawn points (VMaNGOS): once the camp is used up, the other creatures its points show are
        -- killed too (altPer per target, as normal mobs of the target's level), while the points respawn: a
        -- wave after the first takes max(respawn, its kills + its other kills)
        local a = 0
        if obj.altPer and (kind == "kill" or kind == "item") and not obj.fromObject then
            a = obj.altPer * (E.FightTime(obj.mobLevel, playerLevel, "normal", cfg) / (party and (party.n - 1) or 1)
                + select(2, E.GapTerms(cfg, party)))
        end
        r.wait = max(0, waves - 1) * max(0, (obj.rs or (QR_GEN and QR_GEN.respawn) or cfg.respawn) - effS * (r.tKill + a))
        if a > 0 and r.K > effS then
            -- other kills: altPer per target beyond the first wave, plus the others already on the points you
            -- clear first (about one point's worth, altPer x presence: exact for a single point)
            local nAlt = r.K - effS + (obj.presence or 1)
            r.altT = nAlt * a
            r.xp = r.xp + nAlt * obj.altPer * E.KillXP(obj.mobLevel, playerLevel, false)
                * (party and GROUP_RATE[party.n] / party.n or 1)
        end
    end
    -- the walk between camps merged offline (walking to targets up at the next camp beats waiting), once
    local cw = (not (obj.synthetic or not obj.S) and obj.campWalk) or 0
    -- the camp's other hostile mobs pulled with the targets (build: camp_trash, flat { level, rank, per target }),
    -- mounted or not, when they give XP (user 2026-11-25)
    local trT = 0
    if obj.trash then
        local RANKS = { [0] = "normal", [1] = "elite", [2] = "rare" }
        local _, gapNoWalk = E.GapTerms(cfg, party)
        for i = 1, #obj.trash - 2, 3 do
            local lv, rank, per = obj.trash[i], obj.trash[i + 1], obj.trash[i + 2]
            if lv > E.GrayLevel(playerLevel) and lv < playerLevel + 5 then -- grey / red (build: RED_LEVELS)
                local k = r.K * per
                local ft = E.FightTime(lv, playerLevel, RANKS[rank] or "normal", cfg) / (party and (party.n - 1) or 1)
                trT = trT + k * (ft + gapNoWalk)
                r.xp = r.xp + k * E.KillXP(lv, playerLevel, rank == 1) * (party and GROUP_RATE[party.n] / party.n or 1)
            end
        end
    end
    r.trash = trT
    r.T = r.K * r.tKill + r.wait + (r.altT or 0) + (cw > 0 and E.LegTime(cw, cfg, playerLevel) or 0) + trT
    -- creature drops and objects with close times, both taken while farming (build: bf, user 2026-11-23)
    if obj.both then
        r.T, r.wait, r.xp, r.K = r.T * obj.both, r.wait * obj.both, r.xp * obj.both, r.K * obj.both
    end
    return r
end

-- model: { groups = { { obj, obj, ... }, ... }, routeYards = number|nil, questXP = number }
-- Objectives inside a group share mobs and run concurrently (max); groups add up.
-- A group quest (model.group) is estimated for a party of 3, 4 and 5; the best one is kept (res.party).
function E.Quest(model, playerLevel, cfg, nearby, party)
    if model.group and not party then
        local best
        for n = 3, 5 do
            local r = E.Quest(model, playerLevel, cfg, nearby, { n = n })
            if not best or (r.T > 0 and r.XP / r.T > best.XP / max(1, best.T)) then best = r end
        end
        return best
    end
    -- an orange quest (user 2026-11-27, by the quest's level): 3 levels above you +25 % fight and rest, 4 levels
    -- +50 % (cfg.orangeFight); with no rest at all, cfg.orangeRest seconds per kill instead. Mirror of the build's rate.
    local d = (model.level or 0) - playerLevel
    -- a red quest (5+ above) gets here only when cfg.rateAboveRange rates it: with the +4 rate (user 2026-11-27)
    if d > 4 then d = 4 end
    local of = cfg.orangeFight and cfg.orangeFight[d]
    if of then
        local rest0 = cfg.rest or cfg.restPerKill or 0
        cfg = setmetatable({ fightBase = cfg.fightBase * of,
                             rest = rest0 > 0 and rest0 * of or (cfg.orangeRest and cfg.orangeRest[d] or 0) },
                           { __index = cfg })
    end
    local res = { Tfarm = 0, mobXP = 0, wait = 0, objectives = {}, groups = {}, party = party and party.n }
    for gi, group in ipairs(model.groups) do
        local best
        for _, obj in ipairs(group) do
            local o = E.Objective(obj, playerLevel, cfg, party)
            o.obj = obj
            res.objectives[#res.objectives + 1] = o
            if not best or o.T > best.T then best = o end
        end
        if best then
            res.Tfarm = res.Tfarm + best.T
            res.mobXP = res.mobXP + best.xp
            res.wait = res.wait + best.wait
            res.groups[gi] = best
        end
    end
    local share = min(cfg.nearbyCap, 1 + (nearby or 0))
    res.share = share
    -- nearby quests share the whole route, long deliveries and ships too (R080; user 2026-11-24: "long
    -- deliveries are shared: a delivery is a lead-in, counted with the quests it leads to")
    local tRoute, tEscort = 0, 0
    for _, lg in ipairs(model.routeLegs or {}) do
        if lg.escort then
            tEscort = tEscort + lg.seconds -- at the NPC's pace, not shared with nearby quests
        else
            -- ship / zeppelin legs carry their time (average wait + crossing), walks their yards
            tRoute = tRoute + (lg.seconds or (lg.swim and lg.yards / (cfg.swimSpeed or 4.722))
                or E.LegTime(lg.yards, cfg, playerLevel, true))
        end
    end
    -- hostile mobs along the walked legs (user 2026-11-25: a tunnel full of mobs lengthens the walk), fought on
    -- foot below mountLevel when they give XP (mirror of the build's rate / corridor_kills)
    local rc = model.routeClear
    local clearXP = 0
    if rc and E.TravelSpeed(cfg, playerLevel) == cfg.walkSpeed and not model.ready then
        local RANKS = { [0] = "normal", [1] = "elite", [2] = "rare" }
        local _, gapNoWalk = E.GapTerms(cfg, party)
        for i = 1, #rc - 2, 3 do
            local lv, rank, n = rc[i], rc[i + 1], rc[i + 2]
            if lv > E.GrayLevel(playerLevel) and lv < playerLevel + 5 then -- grey: no XP; red (5+ above): avoided
                local ft = E.FightTime(lv, playerLevel, RANKS[rank] or "normal", cfg) / (party and (party.n - 1) or 1)
                tRoute = tRoute + n * (ft + gapNoWalk)
                clearXP = clearXP + n * E.KillXP(lv, playerLevel, rank == 1) * (party and GROUP_RATE[party.n] / party.n or 1)
            end
        end
    end
    res.TrouteAlone = tRoute
    res.TrouteNear = tRoute -- the part nearby quests share (all of it; the map's hubs share it the same way)
    res.Troute = tRoute / share
    res.mobXP = res.mobXP + clearXP / share -- the mobs on the way are part of the route, shared alike
    res.Tescort = tEscort
    res.Tfixed = cfg.fixedTime -- accept + turn-in talk, also for a logged quest (user 2026-11-23)
    res.T = res.Troute + res.Tescort + res.Tfarm + res.Tfixed
    res.XP = (model.questXP or 0) + res.mobXP
    return res
end

-- Dungeon quest: the normal run of its wing(s) with this quest (user 2026-11-23).
-- model.run = { T (run seconds), n (kills of a run), kills = { {level, elite, count, ...}, ... } and shares
--   (kill XP each member gets: group share x Forever's dungeon kill-XP factor) per wing, inner = share of the
--   main wing }. Objectives inside the run carry dRoute / dWing (target spawns on the route / in the wing),
--   dMult (group need multiplier) and out = {S, A, d} (camp outside dungeons) from the database.
-- The run is shared by every quest it can do, each by the part the route finishes (net gain, no extra way);
-- the rest of a quest is its own catch-up, the best XP per second of more killing in the wing / more runs / farming
-- outside. Travel: a fixed QR_GEN.dungeonTravel for a run, there and back. Mirror of the build's
-- dungeon_quest_plan / rate_dungeon.
-- partyMax: highest level in your group; WoW Forever gives no XP for a kill when a group member is more
-- than 12 levels above it (reported rule of the 13 / 14 Nov hotfixes, exact text not retrieved). Returns
-- the XP and whether the rule removed any kill.
function E.RunXP(run, playerLevel, partyMax)
    local xp, cut = 0, false
    local floorLevel = (partyMax or 0) - 12
    for w, k in ipairs(run.kills) do
        local wxp = 0
        for i = 1, #k - 2, 3 do
            if k[i] < floorLevel then
                cut = true
            else
                wxp = wxp + k[i + 2] * E.KillXP(k[i], playerLevel, k[i + 1] == 1)
            end
        end
        xp = xp + wxp * (run.shares[w] or 0)
    end
    return xp, cut
end

local function travelTime()
    return (QR_GEN and QR_GEN.dungeonTravel) or 0 -- not counted (user 2026-11-24: only the run itself)
end

local function chance(obj, cfg)
    if obj.kind ~= "item" then return 1 end
    if obj.p and obj.p > 0 then return obj.p end
    return obj.fromObject and 1 or cfg.defaultDropRate
end

-- What one run does for a quest: frac (part the route finishes, mean over its objectives inside) and the
-- catch-up options for the rest: wing (more kills in the same run), run (then more runs), out (farming
-- outside alone, each member his own share), each { T, X, more }. noRoute: as if the route gave nothing
-- (a quest whose run is behind it, farmed outside). shared: as a companion in another quest's run, only what the
-- base route finishes, without this quest's own detour (net gain, review 2026-11-23).
function E.DungeonPlan(model, playerLevel, cfg, noRoute, shared)
    local run = model.run
    local tkill = run.T / max(1, run.n)
    local share = run.inner or 0
    local plan = { opts = {} }
    plan.rx, plan.levelCut = E.RunXP(run, playerLevel, cfg.partyMax)
    local fsum, fn, pend = 0, 0, {}
    for _, obj in ipairs(model.objectives) do
        if (obj.dWing or 0) > 0 then
            local need = (obj.N or 0) * (obj.dMult or 1)
            if need > 0 then
                local p = chance(obj, cfg)
                local kills = obj.kind == "kill" or (obj.kind == "item" and not obj.fromObject)
                local kxp = kills and obj.mobLevel >= (cfg.partyMax or 0) - 12
                    and E.KillXP(obj.mobLevel, playerLevel, obj.rank == "elite") * share or 0
                local got = noRoute and 0 or (obj.dRoute + (shared and 0 or (obj.dDetour or 0))) * p
                fsum, fn = fsum + min(1, got / need), fn + 1
                if got < need - 1e-9 then pend[#pend + 1] = { obj = obj, rest = need - got, p = p, kxp = kxp } end
                -- several drops and one run likely gets too few (the dungeon rating's only partial quest, user
                -- 2026-11-28): multiFrac is this objective's part, the lowest such part
                if need > 1 and obj.kind == "item" and not obj.fromObject and got < need - 1e-9 then
                    plan.multiFrac = min(plan.multiFrac or 1, got / need)
                end
            end
        end
    end
    plan.frac = fn > 0 and fsum / fn or 1
    -- the quest's own detour from the run's route to its objectives: walk + its extra kills at the run's pace;
    -- dropped once every objective it serves is done (live progress)
    local detourLeft = false
    for _, obj in ipairs(model.objectives) do
        if (obj.dDetour or 0) > 0 and (obj.N or 0) > 0 then detourLeft = true end
    end
    local useDetour = detourLeft and not shared
    local dk, dn, dx = useDetour and run.detourKills or {}, 0, 0
    for i = 1, #dk - 2, 3 do
        dn = dn + dk[i + 2]
        if dk[i] >= (cfg.partyMax or 0) - 12 then dx = dx + dk[i + 2] * E.KillXP(dk[i], playerLevel, dk[i + 1] == 1) end
    end
    plan.detT = (useDetour and (run.detourYards or 0) or 0) / E.WalkSpeed(cfg) + dn * tkill
    plan.detX = dx * share
    -- objectives off the run's route (outside the dungeon, or inside off every route): estimated as in the open world, alone, on the run's
    -- trip (no route of their own, user 2026-11-23); the quest's own part, not a companion's
    plan.outT, plan.outX = 0, 0
    if not shared then
        for _, obj in ipairs(model.objectives) do
            if (obj.dWing or 0) == 0 then
                local r = E.Objective(obj, playerLevel, cfg)
                plan.outT, plan.outX = plan.outT + r.T, plan.outX + r.xp
            end
        end
    end
    if #pend == 0 then return plan end
    local T, X, more, offT, offX = 0, 0, 0, 0, 0
    for _, e in ipairs(pend) do
        -- spawns not reached yet: the quest's own detour already counted its spawns (review 2026-11-23)
        local off = max(0, e.obj.dWing - e.obj.dRoute - (shared and 0 or (e.obj.dDetour or 0)))
        local k = min(off, e.rest / e.p) -- expected kills (no rounding up)
        T, X = T + k * tkill, X + k * e.kxp
        local left = e.rest - k * e.p
        if left > 1e-9 then more = max(more, left / (e.obj.dWing * e.p)) end
        -- a later run kills every off-route spawn again (they respawned)
        local offAll = e.obj.dWing - e.obj.dRoute
        offT, offX = offT + offAll * tkill, offX + offAll * e.kxp
    end
    if more > 0 then
        T = T + more * (run.T + travelTime() + offT)
        X = X + more * (plan.rx + offX)
    end
    plan.opts[more > 0 and "run" or "wing"] = { T = T, X = X, more = more }
    local outside = true
    for _, e in ipairs(pend) do if not e.obj.out then outside = false end end
    if outside then
        local T2, X2 = 0, 0
        for _, e in ipairs(pend) do
            local o = e.obj.out
            local r = E.Objective({ kind = e.obj.kind, fromObject = e.obj.fromObject, N = e.rest / (e.obj.dMult or 1),
                p = e.obj.p, S = o[1], A = o[2], d = o[3], synthetic = o[1] < cfg.minSpawns,
                rs = o[4], presence = o[5], altPer = o[6], campWalk = o[7] or nil,
                mobLevel = e.obj.mobLevel, rank = e.obj.rank }, playerLevel, cfg)
            T2, X2 = T2 + r.T, X2 + r.xp
        end
        plan.opts.out = { T = T2, X = X2, more = 0 }
    end
    return plan
end

-- companions = { {id, xp, t}, ... }: the other quests the run can do, each its quest XP x the part the route
-- finishes, and its talk time.
function E.Dungeon(model, playerLevel, cfg, companions)
    local run = model.run
    local res = { Tfarm = 0, mobXP = 0, wait = 0, objectives = {}, groups = {}, share = 1, Tescort = 0,
                  dungeon = true, Trun = run.T, runs = 0, companions = {}, otherXP = 0, otherT = 0, runXP = 0 }
    res.Tfixed = cfg.fixedTime -- accept + turn-in talk, also for a logged quest (user 2026-11-23)
    local qxp = model.questXP or 0
    if model.ready then -- only the way back and the turn-in are left: half the fixed travel (user 2026-11-23)
        local tf = travelTime() / 2
        res.TrouteAlone, res.Troute, res.XP = tf, tf, qxp
        res.T = tf + res.Tfixed
        return res
    end
    local plan = E.DungeonPlan(model, playerLevel, cfg)
    res.plan, res.runXP, res.frac, res.levelCut = plan, plan.rx, plan.frac, plan.levelCut
    -- a quest that needs the dungeon (user 2026-11-23: taking, an objective or turning in) with nothing left
    -- inside: still a dungeon quest; the way back (half the fixed travel) and the objectives left outside
    if model.anyIn and not model.insideLeft then
        local tf = travelTime() / 2
        res.TrouteAlone, res.Troute, res.Tfarm, res.mobXP = tf, tf, plan.outT, plan.outX
        res.XP, res.T, res.mode = qxp + plan.outX, tf + plan.outT + res.Tfixed, "after"
        return res
    end
    -- the shared run, with this quest's own detour
    local XP = plan.rx + plan.frac * qxp + plan.detX + plan.outX
    local T = run.T + travelTime() + res.Tfixed + plan.detT + plan.outT
    for _, c in ipairs(companions or {}) do
        XP, T = XP + c.xp, T + c.t
        res.otherXP, res.otherT = res.otherXP + c.xp, res.otherT + c.t
        res.companions[#res.companions + 1] = c.id
    end
    res.runs, res.Troute, res.TrouteAlone = 1, travelTime(), travelTime()
    -- this quest's catch-up: the quickest option (user 2026-11-23: not the one with more kill XP)
    local rest = (1 - plan.frac) * qxp
    local bestMode, best
    for mode, o in pairs(plan.opts) do
        if not best or o.T < best.T or (o.T == best.T and mode < bestMode) then bestMode, best = mode, o end
    end
    if best then
        XP, T = XP + rest + best.X, T + best.T
        res.mode, res.catchT, res.runs = bestMode, best.T, 1 + best.more
    end
    res.Tfarm = run.T + plan.detT + plan.outT + (res.catchT or 0)
    res.mobXP = XP - qxp - res.otherXP
    res.XP, res.T = XP, T
    -- a run is behind you (progress on its objectives): farming the rest outside may beat another run
    if model.runDone then
        local nr = E.DungeonPlan(model, playerLevel, cfg, true)
        local o = nr.opts.out
        -- with the objectives outside the run (nr.outT / outX), not the detour inside; by quest XP per second
        -- (this quest; the run: with its other quests), not kill XP (user 2026-11-23)
        if o and qxp / (o.T + nr.outT + res.Tfixed) > (qxp + res.otherXP) / T then
            res.mode, res.catchT, res.runs, res.companions, res.otherXP, res.otherT = "out", o.T, 0, {}, 0, 0
            res.Troute, res.TrouteAlone, res.Tfarm, res.mobXP = 0, 0, o.T + nr.outT, o.X + nr.outX
            res.XP, res.T = qxp + o.X + nr.outX, o.T + nr.outT + res.Tfixed
        end
    end
    return res
end

-- Gap per kill in the baseline (loot + rest + the grinding walk), and its non-walking part for every other
-- kill (loot + rest; a quest kill adds its own walk). Rest: measured in game (cfg.rest, KillTimer K.Rest:
-- standing still while recovering, user 2026-11-26), else the setting restPerKill. In a party it is split
-- like the fight time (party.n - 1: a healer). Mirror of the build's gap_terms.
function E.GapTerms(cfg, party)
    local walk = cfg.grindDistance / E.WalkSpeed(cfg)
    local rest = cfg.rest or cfg.restPerKill or 0
    if party then rest = rest / (party.n - 1) end
    local noWalk = cfg.lootTime + rest
    return noWalk + walk, noWalk
end

function E.Baseline(playerLevel, cfg)
    local tk = E.FightTime(playerLevel, playerLevel, "normal", cfg) + E.GapTerms(cfg)
    return E.KillXP(playerLevel, playerLevel, false) / tk * 3600
end

-- Continuous rating position 0..4 from R (see plan section 3.8): band i (very low .. high)
-- maps linearly onto [i-1, i); R at or above the top threshold is 4 (very high).
function E.Position(R, cfg)
    local t = cfg.thresholds
    local edges = { 0, t[1], t[2], t[3], t[4] }
    if R >= edges[5] then return 4 end
    for i = 1, 4 do
        if R < edges[i + 1] then
            return (i - 1) + (R - edges[i]) / (edges[i + 1] - edges[i])
        end
    end
    return 4
end

function E.Level(position, bonus)
    local v = floor(min(4, position + (bonus or 0)))
    return max(0, v)
end
