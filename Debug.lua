local _, QR = ...
local L = QR.L

-- /qr debug <questId>: prints every intermediate value of the estimate so the formula can be
-- checked in game against _tools/QuestRating_sim.py.

local function f1(v) return v and string.format("%.1f", v) or "-" end
local function f2(v) return v and string.format("%.2f", v) or "-" end
local function out(fmt, ...) DEFAULT_CHAT_FRAME:AddMessage("  " .. string.format(fmt, ...)) end

local function debugQuest(questId)
    local res, why = QR.Rate(questId)
    if not res then QR.Print("%s", tostring(why or L.MSG_NOT_READY)); return end
    local m = res.model
    QR.Print("[%d] %s  Lv%s  玩家 Lv%d  日誌中=%s  任務經驗=%d",
        questId, tostring(m.name), tostring(m.level), res.playerLevel, tostring(m.inLog), m.questXP or 0)
    if #m.flags > 0 then out("標記: %s", table.concat(m.flags, "、")) end
    if m.xpFromClient then out("任務經驗取自遊戲（資料庫沒有）") end
    if m.dungeonFromTag then out("副本任務：依遊戲的任務類型判定") end
    if res.dungeon and not res.est then out("→ %s（%s）", L.RATING[4], res.reasons[1] or L.REASON_DUNGEON); return end
    if res.prereqZone then out("副本前置：區域 %d（第 %d 環）", res.prereqZone, res.prereqDepth or 0) end
    if res.noData then out("%s：%s", L.NO_DATA, table.concat(res.reasons or {}, "、")); return end
    if m.map then out("主要地點：地圖 %s  %.1f, %.1f", tostring(m.map[1]), m.map[2] or 0, m.map[3] or 0) end
    local est = res.est
    for _, o in ipairs(est.objectives) do
        local obj = o.obj
        out("目標%d %s N=%s(%s) p=%s%s K=%d S=%d A=%.0f d=%s t擊殺=%s 等待=%.0f T=%.0f 怪經驗=%.0f Lv=%s %s",
            obj.index, tostring(obj.kind), tostring(obj.N), tostring(obj.countSource),
            f2(o.p), obj.pUnknown and "(不明)" or "", o.K, o.S, o.A, f1(o.d), f1(o.tKill), o.wait, o.T, o.xp,
            f1(obj.mobLevel), tostring(obj.rank or "-"))
        if obj.src then out("    來源 %s", obj.src) end
        if obj.synthetic then out("    %s：擊殺以練功密度估算", obj.center and L.SPAWNS_INCOMPLETE or L.LOCATION_UNKNOWN) end
    end
    for gi, g in pairs(est.groups) do
        out("群組%d：取目標%d，T=%.0f", gi, g.obj.index, g.T)
    end
    local legs = {}
    for _, lg in ipairs(m.routeLegs or {}) do
        local name = (L.LEG and L.LEG[lg.label]) or lg.label
        if lg.boat then
            legs[#legs + 1] = string.format("%s %s %.0f秒", name, L.LEG_BOAT, lg.seconds)
        elseif lg.escort then
            legs[#legs + 1] = string.format("%s %s %.0f秒", name, L.LEG_ESCORT, lg.seconds)
        else
            legs[#legs + 1] = string.format("%s %.0f碼", name, lg.yards)
        end
    end
    out("路程：%s，共 %.0f 碼", #legs > 0 and table.concat(legs, " → ") or "-", m.routeYards or 0)
    out("同區任務=%d %s  分攤=%d  T路(單獨)=%.0f  T路=%.0f",
        res.nearby, #res.nearbyList > 0 and ("(" .. table.concat(res.nearbyList, ",") .. ")") or "",
        est.share, est.TrouteAlone, est.Troute)
    out("T農怪=%.0f  等待=%.0f  T護送=%.0f  T固定=%.0f  總T=%.0f 秒 (%.1f 分)", est.Tfarm, est.wait, est.Tescort or 0,
        est.Tfixed, est.T, est.T / 60)
    if m.objectives then
        for _, obj in ipairs(m.objectives) do
            if obj.rs then out("    目標%d 物件重生 %d 秒（伺服器資料）", obj.index, obj.rs) end
        end
    end
    out("經驗：任務 %d + 殺怪 %.0f = %.0f", m.questXP or 0, est.mobXP, est.XP)
    out("E=%.0f/小時  B=%.0f/小時  R=%s%s", res.E, res.B, f2(res.R),
        res.Ralone and string.format("（不分攤 R=%s）", f2(res.Ralone)) or "")
    if res.cuts then
        out("標準：%s  門檻 R=%s / %s / %s / %s", res.median and string.format("同等級中位數 R=%s", f2(res.median)) or "固定門檻",
            f2(res.cuts[1]), f2(res.cuts[2]), f2(res.cuts[3]), f2(res.cuts[4]))
    end
    if res.chainSteps then
        out("系列：後續 %d 環 (%s)  R系列=%s%s", res.chainSteps, table.concat(res.chainIds or {}, ","), f2(res.Rchain),
            res.Rchain and res.R and res.Rchain > res.R and "（採用）" or "（不採用，低於單一任務）")
    end
    local g = res.gear
    if g then out("獎勵裝備：%s  物品=%s  OneForAll=%s %s%%  加成=%s%s", g.noOneForAll and "未安裝 OneForAll" or "OneForAll",
        tostring(g.itemID or "-"), tostring(g.kind or "-"), f1(g.pct), f1(res.bonus), g.loading and "（物品資料載入中）" or "")
        if g.scale and g.scale > 1 then out("    裝備標準：%d 級（身上裝備價值 ×%s）", g.level or 0, f2(g.scale)) end
    end
    out("級位 P=%s  加成=%s  滿級=%s  →  %s", f2(res.position), f1(res.bonus), tostring(res.atMax),
        L.RATING[res.level])
    if #res.reasons > 0 then out("理由：%s", table.concat(res.reasons, "·")) end
end

-- /qr log: one line per quest in the log (ID, name, rating, R, reasons)
local function listLog()
    local ids = QR.Data.LogQuests()
    table.sort(ids)
    if #ids == 0 then QR.Print(L.MSG_LOG_EMPTY); return end
    QR.Print(L.MSG_LOG_HEADER, #ids)
    for _, id in ipairs(ids) do
        local ok, res, why = pcall(QR.Rate, id)
        if not ok then
            out("[%d] error: %s", id, tostring(res))
        elseif not res then
            out("[%d] %s", id, tostring(why))
        else
            local name = res.model and res.model.name or "?"
            if res.noData or res.dungeon or not res.est then -- dungeon quests: no time, efficiency is not used
                out("[%d] %s  %s  %s", id, tostring(name), res.level and L.RATING[res.level] or "", table.concat(res.reasons or {}, "·"))
            else
                out("[%d] %s  %s  R=%s  %.1f分%s", id, tostring(name), L.RATING[res.level], f2(res.R), res.est.T / 60,
                    #res.reasons > 0 and ("  " .. table.concat(res.reasons, "·")) or "")
            end
        end
    end
end

SLASH_QUESTRATING1 = "/qr"
SlashCmdList.QUESTRATING = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, arg = msg:match("^(%S*)%s*(.*)$")
    cmd = (cmd or ""):lower()
    if cmd == "log" then
        if QR.disabled then QR.Print(L.MSG_DISABLED, "-"); return end
        if not QR.ready then QR.Print(L.MSG_NOT_READY); return end
        local ok, err = pcall(listLog)
        if not ok then QR.Print("log error: %s", tostring(err)) end
    elseif cmd == "debug" then
        if QR.disabled then QR.Print(L.MSG_DISABLED, "-"); return end
        local id = tonumber(arg)
        if not id then QR.Print(L.MSG_BAD_ID); return end
        local ok, err = pcall(debugQuest, id)
        if not ok then QR.Print("debug error: %s", tostring(err)) end
    elseif cmd == "drop" then
        -- what the last Questie map icon tooltip did with drop rates
        if not QR.mapDropHooked then QR.Print("drop: Questie map tooltip hook not installed"); return end
        if not QR.dropTrace then QR.Print("drop: no map icon tooltip rendered since login"); return end
        QR.Print("drop: last map icon tooltip")
        for _, line in ipairs(QR.dropTrace) do out("%s", line) end
    elseif cmd == "" and QR.Options and QR.Options.Open then
        QR.Options.Open()
        QR.Print(L.MSG_HELP)
    else
        QR.Print(L.MSG_HELP)
    end
end
