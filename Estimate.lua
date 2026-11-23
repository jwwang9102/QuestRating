local _, QR = ...

-- Pure time-efficiency math. No game API calls here, so every function can be mirrored in
-- _tools/QuestRating_sim.py and checked offline. Units: seconds, yards, XP.
local E = {}
QR.Estimate = E

local floor, ceil, sqrt, min, max = math.floor, math.ceil, math.sqrt, math.min, math.max

-- On foot: between kills and in the grinding baseline.
function E.WalkSpeed(cfg)
    return cfg.walkSpeed
end

-- Travel legs (giver -> targets -> finisher): mount from mountLevel in "auto" mode.
function E.TravelSpeed(cfg, playerLevel)
    if cfg.speedMode == "mount" or (cfg.speedMode == "auto" and (playerLevel or 0) >= cfg.mountLevel) then
        return cfg.mountSpeed
    end
    return cfg.walkSpeed
end

-- Seconds for one travel leg: ground, or a flight path when that is faster on a long leg.
function E.LegTime(yards, cfg, playerLevel)
    local ground = yards / E.TravelSpeed(cfg, playerLevel)
    if yards >= cfg.flightMinYards then
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

-- Single-linkage clustering: points closer than `gap` yards (same instance) join one cluster.
-- points: { {x=, y=, inst=, key=}, ... }. Returns clusters sorted by size, largest first.
function E.Cluster(points, gap)
    local n = #points
    local parent = {}
    for i = 1, n do parent[i] = i end
    local function find(i)
        while parent[i] ~= i do
            parent[i] = parent[parent[i]]
            i = parent[i]
        end
        return i
    end
    local grid = {}
    local function cellKey(inst, cx, cy) return inst .. ":" .. cx .. ":" .. cy end
    for i = 1, n do
        local p = points[i]
        local cx, cy = floor(p.x / gap), floor(p.y / gap)
        for ox = -1, 1 do
            for oy = -1, 1 do
                local list = grid[cellKey(p.inst, cx + ox, cy + oy)]
                if list then
                    for _, j in ipairs(list) do
                        local q = points[j]
                        local dx, dy = p.x - q.x, p.y - q.y
                        if dx * dx + dy * dy <= gap * gap then
                            local a, b = find(i), find(j)
                            if a ~= b then parent[a] = b end
                        end
                    end
                end
            end
        end
        local k = cellKey(p.inst, cx, cy)
        grid[k] = grid[k] or {}
        table.insert(grid[k], i)
    end
    local byRoot, clusters = {}, {}
    for i = 1, n do
        local r = find(i)
        local c = byRoot[r]
        if not c then
            c = { points = {}, n = 0, sx = 0, sy = 0, inst = points[i].inst,
                  minX = math.huge, maxX = -math.huge, minY = math.huge, maxY = -math.huge }
            byRoot[r] = c
            clusters[#clusters + 1] = c
        end
        local p = points[i]
        c.points[#c.points + 1] = p
        c.n = c.n + 1
        c.sx, c.sy = c.sx + p.x, c.sy + p.y
        c.minX, c.maxX = min(c.minX, p.x), max(c.maxX, p.x)
        c.minY, c.maxY = min(c.minY, p.y), max(c.maxY, p.y)
    end
    for _, c in ipairs(clusters) do
        c.x, c.y = c.sx / c.n, c.sy / c.n
    end
    table.sort(clusters, function(a, b) return a.n > b.n end)
    return clusters
end

-- S (spawns), A (bounding-box area, yd^2), d (average walk between kills, yd)
function E.Density(cluster, cfg)
    local S = cluster and cluster.n or 0
    if S < cfg.minSpawns then return S, 0, cfg.densityCap end
    local A = max(1, (cluster.maxX - cluster.minX) * (cluster.maxY - cluster.minY))
    local d = min(cfg.densityCap, 0.5 / sqrt(S / A))
    return S, A, d
end

-- obj: { kind = "kill"|"item"|"object"|"event"|"vendor"|"none", N, p (0..1 or nil),
--        cluster, mobLevel, rank, elite, fromObject, rs (object respawn seconds, server data) }
-- returns { K, S, A, d, tKill, wait, T, xp, p }
function E.Objective(obj, playerLevel, cfg)
    local r = { K = 0, S = 0, A = 0, d = 0, tKill = 0, wait = 0, T = 0, xp = 0, p = obj.p }
    local kind = obj.kind
    if kind == "event" or kind == "vendor" or kind == "none" or (obj.N or 0) <= 0 then
        return r
    end
    -- drops and items from objects use their chance; an object without one gives the item (most known
    -- object chances are 100 %). Kills and object uses always count.
    local p = obj.p
    if kind ~= "item" then p = 1 end
    if not p or p <= 0 then p = obj.fromObject and 1 or cfg.defaultDropRate end
    r.p = p
    r.K = ceil(obj.N / p)
    if obj.synthetic then
        -- location unknown / spawns incomplete: grinding density, no respawn limit
        r.S, r.A, r.d = 0, 0, cfg.grindDistance
    elseif obj.S then
        -- precomputed offline (Data/Generated.lua)
        r.S, r.A, r.d = obj.S, obj.A or 0, obj.d or cfg.densityCap
    else
        r.S, r.A, r.d = E.Density(obj.cluster, cfg)
    end
    local walk = r.d / E.WalkSpeed(cfg)
    if kind == "object" or obj.fromObject then
        r.tKill = cfg.objectLootTime + walk
        r.xp = 0
    else
        r.tKill = E.FightTime(obj.mobLevel, playerLevel, obj.rank, cfg) + cfg.lootTime + walk
        r.xp = E.KillXP(obj.mobLevel, playerLevel, obj.rank == "elite") * r.K
    end
    if not obj.synthetic then
        local effS = max(1, r.S * cfg.shareFactor)
        local waves = ceil(r.K / effS)
        r.wait = max(0, waves - 1) * max(0, (obj.rs or cfg.respawn) - effS * r.tKill)
    end
    r.T = r.K * r.tKill + r.wait
    return r
end

-- model: { groups = { { obj, obj, ... }, ... }, routeYards = number|nil, questXP = number }
-- Objectives inside a group share mobs and run concurrently (max); groups add up.
function E.Quest(model, playerLevel, cfg, nearby)
    local res = { Tfarm = 0, mobXP = 0, wait = 0, objectives = {}, groups = {} }
    for gi, group in ipairs(model.groups) do
        local best
        for _, obj in ipairs(group) do
            local o = E.Objective(obj, playerLevel, cfg)
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
    local tRoute, tEscort = 0, 0
    for _, lg in ipairs(model.routeLegs or {}) do
        if lg.escort then
            tEscort = tEscort + lg.seconds -- at the NPC's pace, not shared with nearby quests
        else
            -- ship / zeppelin legs carry their time (average wait + crossing), walks their yards
            tRoute = tRoute + (lg.seconds or E.LegTime(lg.yards, cfg, playerLevel))
        end
    end
    res.TrouteAlone = tRoute
    res.Troute = res.TrouteAlone / share
    res.Tescort = tEscort
    -- quests already in the log only still need the turn-in: half the fixed talk time
    res.Tfixed = cfg.fixedTime * (model.inLog and 0.5 or 1)
    res.T = res.Troute + res.Tescort + res.Tfarm + res.Tfixed
    res.XP = (model.questXP or 0) + res.mobXP
    return res
end

function E.Baseline(playerLevel, cfg)
    local tk = E.FightTime(playerLevel, playerLevel, "normal", cfg) + cfg.lootTime
        + cfg.grindDistance / E.WalkSpeed(cfg)
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
