local _, QR = ...
local L = QR.L

-- /qr debug <questId>: prints every intermediate value of the estimate so the formula can be
-- checked in game against its mirror in _tools/build_questrating_data.py.

local function f1(v) return v and string.format("%.1f", v) or "-" end
local function f2(v) return v and string.format("%.2f", v) or "-" end
local function out(fmt, ...) DEFAULT_CHAT_FRAME:AddMessage("  " .. string.format(fmt, ...)) end

local function debugQuest(questId)
    local res, why = QR.Rate(questId)
    if not res then QR.Print("%s", tostring(why or L.MSG_NOT_READY)); return end
    local m = res.model
    QR.Print("[%d] %s  Lv%s  玩家 Lv%d  日誌中=%s  已有進度=%s  可交=%s  任務經驗=%d",
        questId, tostring(m.name), tostring(m.level), res.playerLevel, tostring(m.inLog), tostring(m.progress or false),
        tostring(m.ready or false), m.questXP or 0)
    if #m.flags > 0 then out("標記: %s", table.concat(m.flags, "、")) end
    local fb, nfb = QR.Kill.FightBase(res.playerLevel)
    local gp, ngp = QR.Kill.Gap(res.playerLevel)
    out("戰鬥時間：%s（單刷紀錄 %d 筆，等級 %d-%d）", fb and string.format("%.1f 秒/隻，實測中位數", fb)
        or string.format("%d 秒，設定值（紀錄未滿 5 筆）", QR.Cfg().fightBase), nfb, math.max(1, res.playerLevel - 2), res.playerLevel)
    out("戰鬥間隔：%s（紀錄 %d 筆；含換點和交任務的跑路，只供參考，估算不用）", gp and string.format("%.1f 秒/隻，實測中位數", gp)
        or "尚無紀錄", ngp)
    local rs, nrs, src = QR.Kill.Rest(res.playerLevel, QR.Cfg().restPerKill)
    out("休息：%.1f 秒/隻（%s；實測 %d 隻，等級 %d-%d，滿 %d 隻後只用實測）", rs,
        src == "measured" and "實測平均" or src == "character" and "不足的部分用本角色各等級平均" or "不足的部分用設定值",
        nrs, math.max(1, res.playerLevel - 2), res.playerLevel, QR.Kill.REST_KILLS)
    if m.xpFromClient then out("任務經驗取自遊戲（日誌中的任務一律用遊戲的數值）") end
    if m.dungeonFromTag then out("副本任務：依遊戲的任務類型判定") end
    if res.prereqZone then out("副本前置：區域 %d（後續第 %d 個任務）", res.prereqZone, res.prereqDepth or 0) end
    if res.noData then out("%s：%s", res.unrated and L.UNRATED or L.NO_DATA, table.concat(res.reasons or {}, "、")); return end
    if m.map then out("主要地點：地圖 %s  %.1f, %.1f", tostring(m.map[1]), m.map[2] or 0, m.map[3] or 0) end
    local est = res.est
    if not est then -- rated without an estimate (attunement, max level): its reasons only
        out("%s", table.concat(res.reasons or {}, "、"))
        return
    end
    if est.solve then out("副本任務解法：%s", est.solve == "in" and "進副本（副本外也可解，效率較低）"
        or est.solve == "out" and "副本外（比打副本有效率）" or "副本外（剩下的目標都在副本外）") end
    if est.dungeon then
        local run = m.run
        local names = {}
        for _, k in ipairs(run.wings) do names[#names + 1] = QR.Data.WingName(k) end
        out("副本：%s  一輪 %.0f 秒  擊殺 %d 隻  每人每輪經驗 %.0f（每隻 ×%s）", table.concat(names, "+"), run.T, run.n,
            est.runXP or 0, f2(run.inner))
        out("路線完成比例 %s  補打方式 %s  補打 %.0f 秒  輪數 %.2f  全隊需求 %s  已打過一輪=%s", f2(est.frac),
            tostring(est.mode or "-"), est.catchT or 0, est.runs or 0, tostring(run.need or "-"), tostring(m.runDone or false))
        out("自己的繞路 %.0f 秒、經驗 %.0f（路程 %d 碼）", est.plan and est.plan.detT or 0, est.plan and est.plan.detX or 0,
            run.detourYards or 0)
        out("同輪任務 %s  （經驗 %.0f，接交 %.0f 秒）", #(est.companions or {}) > 0 and table.concat(est.companions, ",") or "-",
            est.otherXP or 0, est.otherT or 0)
        for _, obj in ipairs(m.objectives) do
            if (obj.dWing or 0) > 0 then
                out("    目標%d 路線上 %d / 同區 %d  ×%d 人份  副本外營地 %s", obj.index, obj.dRoute or 0, obj.dWing,
                    obj.dMult or 1, obj.out and string.format("%d 隻", obj.out[1]) or "無")
            end
        end
    end
    for _, o in ipairs(est.objectives) do
        local obj = o.obj
        out("目標%d %s N=%s(%s) p=%s%s K=%.1f S=%d 出現率=%s 在場=%s A=%.0f d=%s t擊殺=%s 等待=%.0f T=%.0f 怪經驗=%.0f Lv=%s %s",
            obj.index, tostring(obj.kind), tostring(obj.N), tostring(obj.countSource),
            f2(o.p), obj.pUnknown and "(不明)" or "", o.K, o.S, f2(obj.presence or 1), f1(o.effS), o.A, f1(o.d),
            f1(o.tKill), o.wait, o.T, o.xp, f1(obj.mobLevel), tostring(obj.rank or "-"))
        if obj.src then out("    來源 %s", obj.src) end
        if o.altT then out("    共用生成點：另清別種怪 %.0f 秒（每隻目標 %.2f 隻）", o.altT, obj.altPer or 0) end
        if obj.synthetic then out("    %s：擊殺以練功密度估算", obj.center and L.SPAWNS_INCOMPLETE or L.LOCATION_UNKNOWN) end
    end
    for gi, g in pairs(est.groups) do
        out("群組%d：取目標%d，T=%.0f", gi, g.obj.index, g.T)
    end
    local legs = {}
    for _, lg in ipairs((est.solve == "out" or est.solve == "outonly") and m.openLegs or m.routeLegs or {}) do
        local name = (L.LEG and L.LEG[lg.label]) or lg.label
        if lg.boat then
            legs[#legs + 1] = string.format("%s %s %.0f秒", name, L.LEG_BOAT, lg.seconds)
        elseif lg.flight then
            legs[#legs + 1] = string.format("%s %s %.0f秒", name, L.LEG_FLIGHT, lg.seconds)
        elseif lg.swim then
            legs[#legs + 1] = string.format("%s %s %.0f碼", name, L.LEG_SWIM, lg.yards)
        elseif lg.escort then
            legs[#legs + 1] = string.format("%s %s %.0f秒", name, L.LEG_ESCORT, lg.seconds)
        else
            legs[#legs + 1] = string.format("%s %.0f碼", name, lg.yards)
        end
    end
    if est.dungeon then
        out("路程：副本固定來回 %.0f 秒（%s）", est.Troute or 0, (m.ready or est.mode == "after") and "只剩回程" or "一輪")
        if est.plan then out("路線外的目標（副本外或副本內路線外，共用這次）%.0f 秒、經驗 %.0f", est.plan.outT or 0, est.plan.outX or 0) end
    else
        local open = est.solve == "out" or est.solve == "outonly"
        out("路程：%s，共 %.0f 碼", #legs > 0 and table.concat(legs, " → ") or "-", (open and m.openYards or m.routeYards) or 0)
    end
    out("同區任務=%d（含同副本未解任務）%s  分攤=%d  T路(單獨)=%.0f  T路=%.0f",
        res.nearby, #res.nearbyList > 0 and ("(" .. table.concat(res.nearbyList, ",") .. ")") or "",
        est.share, est.TrouteAlone, est.Troute)
    out("T農怪=%.0f  等待=%.0f  T護送=%.0f  T固定=%.0f  總T=%.0f 秒 (%.1f 分)", est.Tfarm, est.wait, est.Tescort or 0,
        est.Tfixed, est.T, est.T / 60)
    if est.party then
        out("團體任務：%d 人隊伍（1 補 %d 輸出：戰鬥時間 = 單刷 / %d；打怪經驗 x %.3f/%d）", est.party, est.party - 1,
            est.party - 1, QR.Estimate.GROUP_RATE[est.party], est.party)
    end
    if m.objectives then
        for _, obj in ipairs(m.objectives) do
            if obj.rs then out("    目標%d 重生 %d 秒（伺服器資料）", obj.index, obj.rs) end
        end
    end
    out("經驗：任務 %d%s + 殺怪 %.0f = %.0f", m.questXP or 0,
        (est.otherXP or 0) > 0 and string.format(" + 同輪任務 %d", est.otherXP) or "", est.mobXP, est.XP)
    out("E=%.0f/小時  B=%.0f/小時  R=%s", res.E, res.B, f2(res.R))
    if res.cuts then
        out("標準：%s  門檻 R=%s / %s / %s / %s", res.median and string.format("同等級中位數 R=%s", f2(res.median)) or "固定門檻",
            f2(res.cuts[1]), f2(res.cuts[2]), f2(res.cuts[3]), f2(res.cuts[4]))
    end
    if res.chainSteps then
        out("任務鏈：後續 %d 個 (%s)、前置 %d 個 (%s)  R鏈=%s  後續加分 %s", res.chainSteps, table.concat(res.chainIds or {}, ","),
            #(res.chainBack or {}), table.concat(res.chainBack or {}, ","), f2(res.Rchain), tostring(res.followBonus or 0))
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
            if res.noData or not res.est then
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
    elseif cmd == "dungeons" then
        if QR.disabled then QR.Print(L.MSG_DISABLED, "-"); return end
        if not QR.ready then QR.Print(L.MSG_NOT_READY); return end
        local ok, err = pcall(QR.MapUI.ListDungeons)
        if not ok then QR.Print("dungeons error: %s", tostring(err)) end
    elseif cmd == "drop" then
        -- what the last Questie map icon tooltip did with drop rates
        if not QR.mapDropHooked then QR.Print("drop: Questie map tooltip hook not installed"); return end
        if not QR.dropTrace then QR.Print("drop: no map icon tooltip rendered since login"); return end
        QR.Print("drop: last map icon tooltip")
        for _, line in ipairs(QR.dropTrace) do out("%s", line) end
    elseif cmd == "" and QR.Panel then
        QR.Panel.Toggle()
        QR.Print(L.MSG_HELP)
    else
        QR.Print(L.MSG_HELP)
    end
end
