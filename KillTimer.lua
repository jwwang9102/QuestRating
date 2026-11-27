local _, QR = ...

-- Your own pace (user 2026-11-23, review 2026-11-23): instead of fixed values, medians of what your solo
-- play takes, per character and level (the estimate uses your level and the two below, MIN_SAMPLES at
-- least, the last MAX samples per level). Only built-in events: entering / leaving combat and the combat
-- log while in combat (kills by you or your pet).
--   f = fight time per kill: combat time / kills weighted by the estimate's level and elite factors (one
--       fight for two pulled mobs gives half the time per kill).
--   g = gap per kill: time from the end of the previous solo fight to this one (loot, rest, walk), divided
--       by this fight's plain kill count. Not sampled across a death, a taxi / loss of control, a level-up,
--       a group or an instance. Shown for information; the estimate uses r (rest) and its own walk.
--   r = rest before a fight: { seconds, kills } (user 2026-11-26): in the same gap, the seconds you stand
--       still out of combat with health (or mana, for mana users) below full and the loot window closed (the
--       loot time is counted on its own), whatever else you do meanwhile (map, bags, ...: you recover all the
--       same). Walking while recovering is not rest (the walk is the estimate's own).
local K = {}
QR.Kill = K

local MAX, MIN_SAMPLES, MAX_FIGHT = 30, 5, 300
-- Rest per kill is the mean (sum of rest / sum of kills), not a median: rest comes every few fights (video
-- check 2026-11-26: 6-12 of 30-36 fights had none, and a median of 30 fights read 20-67 % low). The newest
-- REST_WINDOW kills at your level and the two below; REST_KILLS kills give a measured value (same check:
-- the mean of 30 kills within about 10 % of the whole stretch, of 15 kills up to 60 % off). With fewer, the
-- missing kills take a prior (K.Rest). REST_FIGHTS fights are kept per level.
local REST_KILLS, REST_WINDOW, REST_FIGHTS, REST_TICK = 30, 60, 60, 0.5

local function store()
    local db = QR.db
    if not db then return nil end
    db.kill = type(db.kill) == "table" and db.kill or {}
    local who = (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "?")
    db.kill[who] = type(db.kill[who]) == "table" and db.kill[who] or {}
    return db.kill[who]
end

local function levelData(s, level)
    local t = s[level]
    if type(t) ~= "table" then t = {} end
    if t[1] ~= nil then t = { f = t } end -- older format: a plain list of fight times
    t.f = type(t.f) == "table" and t.f or {}
    t.g = type(t.g) == "table" and t.g or {}
    t.r = type(t.r) == "table" and t.r or {}
    s[level] = t
    return t
end

local function median(key, level)
    local s = store()
    if not s or not level then return nil, 0 end
    local all = {}
    for l = level - 2, level do
        if type(s[l]) == "table" then
            for _, v in ipairs(levelData(s, l)[key]) do all[#all + 1] = v end
        end
    end
    if #all < MIN_SAMPLES then return nil, #all end
    table.sort(all)
    local n = #all
    return n % 2 == 1 and all[(n + 1) / 2] or (all[n / 2] + all[n / 2 + 1]) / 2, n
end

-- Seconds per same-level normal kill in fights, and the number of samples.
function K.FightBase(level) return median("f", level) end
-- Seconds of gap per kill (loot, rest, walk), and the number of samples.
function K.Gap(level) return median("g", level) end

-- Sum of rest seconds and kills of every stored fight of this character (all levels).
local function restAll(s)
    local R, N = 0, 0
    for l, t in pairs(s) do
        if type(l) == "number" and type(t) == "table" then
            for _, e in ipairs(levelData(s, l).r) do R, N = R + e[1], N + e[2] end
        end
    end
    return R, N
end

-- Seconds of rest per kill, the kills it is measured on, and its source: "measured" (REST_KILLS kills or
-- more at your level and the two below, the newest REST_WINDOW of them), else the measured kills plus a
-- prior for the missing ones (REST_KILLS in all): "character" (your mean over every level, once it has
-- REST_KILLS kills: your class and habits) or "default" (the setting).
function K.Rest(level, default)
    local s = store()
    local R, N = 0, 0
    if s and level then
        for l = level, level - 2, -1 do
            if type(s[l]) == "table" then
                local list = levelData(s, l).r
                for i = #list, 1, -1 do
                    if N >= REST_WINDOW then break end
                    R, N = R + list[i][1], N + list[i][2]
                end
            end
        end
    end
    if N >= REST_KILLS then return R / N, N, "measured" end
    local prior, src = default or 0, "default"
    if s then
        local AR, AN = restAll(s)
        if AN >= REST_KILLS then prior, src = AR / AN, "character" end
    end
    return (R + prior * (REST_KILLS - N)) / REST_KILLS, N, src
end
K.REST_KILLS = REST_KILLS

-- Raw records of one level (the statistics window, Panel.lua): fight samples, gap samples, and the rest
-- records' fights, kills and seconds. nil without any record.
function K.LevelStats(level)
    local s = store()
    if not s or type(s[level]) ~= "table" then return nil end
    local d = levelData(s, level)
    local rf, rk, rs = #d.r, 0, 0
    for _, e in ipairs(d.r) do rk, rs = rk + e[2], rs + e[1] end
    return { nf = #d.f, ng = #d.g, rf = rf, rk = rk, rs = rs }
end

-- Highest level in your group (you included).
local function partyMax()
    local top = UnitLevel("player") or 1
    local prefix, n = nil, 0
    if IsInRaid and IsInRaid() then prefix, n = "raid", 40
    elseif IsInGroup and IsInGroup() then prefix, n = "party", 4 end
    for i = 1, n do
        local lv = UnitLevel(prefix .. i)
        if lv and lv > top then top = lv end
    end
    return top
end

-- Settings with your measured pace (each part falls back to the setting until it has enough samples)
-- and the highest level in your group.
function QR.CfgFor(level)
    local cfg = QR.Cfg()
    local fb = K.FightBase(level)
    local rest, restKills, restSource = K.Rest(level, cfg.restPerKill)
    return setmetatable({ fightBase = fb or cfg.fightBase, fightMeasured = fb ~= nil, rest = rest, restKills = restKills,
                          restSource = restSource, partyMax = partyMax() }, { __index = cfg })
end

QR.RegisterReady(function()
    local fight   -- { start, weight, kills, level, gap } while a solo fight runs
    local lastEnd -- end of the previous solo fight, while a gap can still be measured
    local lastLevel
    local restSec = 0     -- rest seconds since lastEnd (r)
    local looting = false -- loot window open
    local ev = CreateFrame("Frame")
    -- Kills: the WoW Forever client forbids registering COMBAT_LOG_EVENT_UNFILTERED (blocked-action dialog,
    -- which pcall does not prevent; taint log 2026-11-23, and OneForAll / QLens note the same), so on clients
    -- with secret values a kill is the "you gain experience" message (CHAT_MSG_COMBAT_XP_GAIN: your or your
    -- pet's kill that gives XP) while a solo fight runs; elsewhere the combat log. Every event is registered
    -- here, once, at login.
    local useCombatLog = not _G.issecretvalue
    local events = { "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_DEAD", "PLAYER_CONTROL_LOST",
        "PLAYER_LEVEL_UP", "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD", "LOOT_OPENED", "LOOT_CLOSED",
        useCombatLog and "COMBAT_LOG_EVENT_UNFILTERED" or "CHAT_MSG_COMBAT_XP_GAIN" }
    for _, e in ipairs(events) do
        pcall(ev.RegisterEvent, ev, e)
    end
    -- r: standing still out of combat, recovering (health, or mana for a mana user, below full), loot window
    -- closed; protected (secret) values are not read
    local secret = _G.issecretvalue
    local function recovering()
        if looting or UnitAffectingCombat("player") or UnitIsDeadOrGhost("player") then return false end
        if (IsMounted and IsMounted()) or (UnitOnTaxi and UnitOnTaxi("player")) then return false end
        if (GetUnitSpeed("player") or 0) > 0 then return false end
        local hp, hpMax = UnitHealth("player"), UnitHealthMax("player")
        if secret and (secret(hp) or secret(hpMax)) then return false end
        if hp < hpMax then return true end
        if UnitPowerType("player") == 0 then
            local mp, mpMax = UnitPower("player", 0), UnitPowerMax("player", 0)
            if secret and (secret(mp) or secret(mpMax)) then return false end
            if mp < mpMax then return true end
        end
        return false
    end
    C_Timer.NewTicker(REST_TICK, function()
        if not lastEnd then return end
        local ok, yes = pcall(recovering) -- an error must not repeat every tick
        if ok and yes then restSec = restSec + REST_TICK end
    end)
    local function killWeight(guid)
        -- the killed mob's level and rank when it is your (dead) target, else a same-level normal mob
        local cfg = QR.Cfg()
        if guid and UnitGUID("target") ~= guid then return 1 end
        if not guid and not (UnitIsDead and UnitIsDead("target")) then return 1 end
        local pl, ml = UnitLevel("player") or 1, UnitLevel("target") or -1
        if ml < 0 then ml = pl + 3 end
        local f = math.min(cfg.fightMaxFactor, math.max(cfg.fightMinFactor, 1 + cfg.fightPerLevel * (ml - pl)))
        local c = UnitClassification and UnitClassification("target")
        local r = (c == "elite" or c == "rareelite" or c == "worldboss") and cfg.eliteFactor or (c == "rare" and cfg.rareFactor) or 1
        return f * r
    end
    local function add(list, v)
        list[#list + 1] = math.floor(v * 10 + 0.5) / 10
        while #list > MAX do table.remove(list, 1) end
    end
    ev:SetScript("OnEvent", function(self, event)
        if event == "LOOT_OPENED" or event == "LOOT_CLOSED" then
            looting = event == "LOOT_OPENED"
            return
        end
        if event == "PLAYER_REGEN_DISABLED" then
            local inInstance = IsInInstance and IsInInstance()
            if (IsInGroup and IsInGroup()) or inInstance or (UnitOnTaxi and UnitOnTaxi("player")) then
                fight, lastEnd = nil, nil
                return
            end
            local now, level = GetTime(), UnitLevel("player")
            local measured = lastEnd and lastLevel == level
            fight = { start = now, weight = 0, kills = 0, level = level,
                      gap = measured and (now - lastEnd) or nil, rest = measured and restSec or nil }
            lastEnd = nil
        elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
            if not fight then return end
            local _, sub, _, src, _, _, _, dest = CombatLogGetCurrentEventInfo()
            if sub == "PARTY_KILL" and (src == UnitGUID("player") or src == UnitGUID("pet")) then
                fight.weight, fight.kills = fight.weight + killWeight(dest), fight.kills + 1
            end
        elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
            if not fight then return end
            fight.weight, fight.kills = fight.weight + killWeight(nil), fight.kills + 1
        elseif event == "PLAYER_REGEN_ENABLED" then
            -- the last kill's XP message can come right after combat ends: close the fight a moment later
            if not useCombatLog and fight and not fight.closing then
                local closing = fight
                closing.closing, closing.endT = true, GetTime()
                C_Timer.After(0.5, function()
                    if fight == closing then self:GetScript("OnEvent")(self, "QR_FIGHT_END") end -- not a new fight
                end)
                return
            end
        end
        if event == "PLAYER_REGEN_ENABLED" or event == "QR_FIGHT_END" then
            local f = fight
            fight = nil
            if not f or f.kills <= 0 or UnitIsDeadOrGhost("player") or (IsInGroup and IsInGroup()) then return end
            local now = f.endT or GetTime() -- the end of combat, not the delayed close
            local t = now - f.start
            if t <= 0 or t > MAX_FIGHT or UnitLevel("player") ~= f.level then return end
            local s = store()
            if not s then return end
            local d = levelData(s, f.level)
            add(d.f, t / f.weight)
            if f.gap and f.gap > 0 then add(d.g, f.gap / f.kills) end
            if f.rest then
                d.r[#d.r + 1] = { math.floor(f.rest * 10 + 0.5) / 10, f.kills }
                while #d.r > REST_FIGHTS do table.remove(d.r, 1) end
            end
            lastEnd, lastLevel, restSec = now, f.level, 0
            if QR.InvalidateRatings then QR.InvalidateRatings() end
        elseif event ~= "PLAYER_REGEN_DISABLED" and event ~= "COMBAT_LOG_EVENT_UNFILTERED"
            and event ~= "CHAT_MSG_COMBAT_XP_GAIN" then
            -- death, taxi / loss of control, level-up, group change, loading screen: no gap across it
            lastEnd = nil
        end
    end)
end)
