local _, QR = ...

-- Your own pace (user 2026-11-23, review 2026-11-23): instead of fixed values, medians of what your solo
-- play takes, per character and level (the estimate uses your level and the two below, MIN_SAMPLES at
-- least, the last MAX samples per level). Only built-in events: entering / leaving combat and the combat
-- log while in combat (kills by you or your pet).
--   f = fight time per kill: combat time / kills weighted by the estimate's level and elite factors (one
--       fight for two pulled mobs gives half the time per kill).
--   g = gap per kill: time from the end of the previous solo fight to this one (loot, rest, walk), divided
--       by this fight's plain kill count. Not sampled across a death, a taxi / loss of control, a level-up,
--       a group or an instance.
local K = {}
QR.Kill = K

local MAX, MIN_SAMPLES, MAX_FIGHT = 30, 5, 300

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
    local gp = K.Gap(level)
    return setmetatable({ fightBase = fb or cfg.fightBase, fightMeasured = fb ~= nil, gap = gp, gapMeasured = gp ~= nil,
                          partyMax = partyMax() }, { __index = cfg })
end

QR.RegisterReady(function()
    local fight   -- { start, weight, kills, level, gap } while a solo fight runs
    local lastEnd -- end of the previous solo fight, while a gap can still be measured
    local lastLevel
    local ev = CreateFrame("Frame")
    for _, e in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_DEAD", "PLAYER_CONTROL_LOST",
        "PLAYER_LEVEL_UP", "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD" }) do
        pcall(ev.RegisterEvent, ev, e)
    end
    local function killWeight(guid)
        -- the killed mob's level and rank when it is your target, else a same-level normal mob
        local cfg = QR.Cfg()
        if UnitGUID("target") ~= guid then return 1 end
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
        if event == "PLAYER_REGEN_DISABLED" then
            local inInstance = IsInInstance and IsInInstance()
            if (IsInGroup and IsInGroup()) or inInstance or (UnitOnTaxi and UnitOnTaxi("player")) then
                fight, lastEnd = nil, nil
                return
            end
            local now, level = GetTime(), UnitLevel("player")
            fight = { start = now, weight = 0, kills = 0, level = level,
                      gap = (lastEnd and lastLevel == level) and (now - lastEnd) or nil }
            lastEnd = nil
            self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
            if not fight then return end
            local _, sub, _, src, _, _, _, dest = CombatLogGetCurrentEventInfo()
            if sub == "PARTY_KILL" and (src == UnitGUID("player") or src == UnitGUID("pet")) then
                fight.weight, fight.kills = fight.weight + killWeight(dest), fight.kills + 1
            end
        elseif event == "PLAYER_REGEN_ENABLED" then
            self:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
            local f = fight
            fight = nil
            if not f or f.kills <= 0 or UnitIsDeadOrGhost("player") or (IsInGroup and IsInGroup()) then return end
            local now = GetTime()
            local t = now - f.start
            if t <= 0 or t > MAX_FIGHT or UnitLevel("player") ~= f.level then return end
            local s = store()
            if not s then return end
            local d = levelData(s, f.level)
            add(d.f, t / f.weight)
            if f.gap and f.gap > 0 then add(d.g, f.gap / f.kills) end
            lastEnd, lastLevel = now, f.level
            if QR.InvalidateRatings then QR.InvalidateRatings() end
        else
            -- death, taxi / loss of control, level-up, group change, loading screen: no gap across it
            lastEnd = nil
        end
    end)
end)
