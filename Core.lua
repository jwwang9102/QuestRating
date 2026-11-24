local ADDON, QR = ...
local L = QR.L

-- Settings. Starting values, not game data (fight time and gap are measured in game once there are
-- enough samples, respawn comes from the server data where it has one). Camp choice and clustering are
-- done offline by _tools/build_questrating_data.py, with its own copy of those settings.
QR.DEFAULTS = {
    fightBase = 15,         -- seconds to kill a same-level normal mob (user, 2026-11-21)
    fightMinFactor = 0.6,   -- level factor clamp
    fightMaxFactor = 2.5,
    fightPerLevel = 0.12,   -- level factor per level of difference
    eliteFactor = 3,
    rareFactor = 2,
    lootTime = 4,           -- seconds per kill to loot
    objectLootTime = 6,     -- seconds per object (herb, chest...)
    walkSpeed = 7,          -- yards per second, on foot (also between kills)
    mountSpeed = 11.2,      -- yards per second, 60% mount (travel legs)
    mountLevel = 40,        -- travel legs use the mount from this level ("auto")
    speedMode = "auto",     -- "auto" | "walk" | "mount"
    flightMinYards = 2000,  -- longer travel legs may use a flight path instead
    flightSpeed = 30,       -- yards per second on a flight path
    flightOverhead = 90,    -- seconds: getting to / from flight masters
    respawn = 150,          -- seconds; only where the server data has no respawn time
    shareFactor = 1.0,      -- fraction of spawns available to you (other players); 1 = not counted (user 2026-11-23)
    fixedTime = 30,         -- seconds for talking / accepting / turning in
    grindDistance = 30,     -- yards between mobs when grinding (baseline)
    densityCap = 200,       -- yards; max walk between kills
    minSpawns = 3,          -- fewer spawns in a camp: its walk is densityCap (outside catch-up camps)
    defaultDropRate = 0.3,  -- used when Questie has no drop rate
    nearbyRadius = 300,     -- yards; other quests this close share the route (at most 300: the database list)
    nearbyCap = 4,          -- route is divided by at most this many quests
    thresholds = { 0.7, 1.0, 1.5, 2.5 }, -- R boundaries, only when the database has no same-level rank points
    chainDepth = 6,         -- follow-up quests looked at for a dungeon prerequisite
    chainMax = 30,          -- quests followed each way along a chain (rated as a whole, user 2026-11-23)
    gearSmall = 3,          -- OneForAll upgrade % below this: +0.5 level (user)
    gearBig = 10,           -- from this %: +2 levels; in between +1 (user)
    gearLevelOffset = 5,    -- quest gear for level L has item level about L + this (gear standard above your level)
    -- display
    showTracker = true,     -- rating tag after quest titles in Questie's tracker
    trackerReasons = 0,     -- reasons in the tag: 0 none (default: they are in the hover tooltip), 1, 2
    showTooltip = true,     -- QuestRating tooltip when hovering a tracker line
    showDropRate = true,    -- drop % on objective lines of unit tooltips
    questLogExtraWidth = 120, -- pixels added to the world map's quest log (0 = Blizzard's width)
}

local function copyDefault(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copyDefault(x) end
    return t
end

function QR.Cfg()
    return QR.db and QR.db.profile or QR.DEFAULTS
end

function QR.Print(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    DEFAULT_CHAT_FRAME:AddMessage(L.MSG_PREFIX .. msg)
end

local function initDB()
    QuestRatingDB = type(QuestRatingDB) == "table" and QuestRatingDB or {}
    QuestRatingDB.profile = type(QuestRatingDB.profile) == "table" and QuestRatingDB.profile or {}
    local p = QuestRatingDB.profile
    -- settings version 2: fight time 12 -> 15 s; removed keys from earlier test builds
    if (QuestRatingDB.version or 1) < 2 then
        p.fightBase = nil
        p.useMount, p.mountSpeed, p.clusterMinShare = nil, nil, nil
        QuestRatingDB.version = 2
    end
    -- settings version 3: maxWaves 3 -> 5
    if QuestRatingDB.version < 3 then
        p.maxWaves = nil
        QuestRatingDB.version = 3
    end
    -- settings version 4: shareFactor 0.7 -> 1 (other players not counted for now)
    if QuestRatingDB.version < 4 then
        p.shareFactor = nil
        QuestRatingDB.version = 4
    end
    -- settings version 5: tracker tags show the rating only (reasons overflowed the tracker, user 2026-11-23)
    if QuestRatingDB.version < 5 then
        p.trackerReasons = nil
        QuestRatingDB.version = 5
    end
    QR.db = QuestRatingDB
    QR.FillDefaults()
end

-- Missing or wrongly typed settings get their default.
function QR.FillDefaults()
    local p = QR.db.profile
    for k, v in pairs(QR.DEFAULTS) do
        if p[k] == nil or type(p[k]) ~= type(v) then p[k] = copyDefault(v) end
    end
end

-- Modules register here; they run at PLAYER_LOGIN once the database is loaded.
QR.onReady = {}
function QR.RegisterReady(fn) QR.onReady[#QR.onReady + 1] = fn end

local function start()
    local ok, missing = QR.Data.Init()
    if not ok then
        QR.disabled = true
        QR.Print(L.MSG_DISABLED, table.concat(missing, ", "))
        return
    end
    QR.ready = true
    for _, fn in ipairs(QR.onReady) do
        local okFn, err = pcall(fn)
        if not okFn then QR.Print("%s", tostring(err)) end
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" and name == ADDON then
        self:UnregisterEvent("ADDON_LOADED")
        initDB()
    elseif event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        start()
    end
end)
