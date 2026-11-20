-- Alert: find the mob the group is stuck on, tell you (and the party), try one automatic ping, and keep a button
-- on screen that pings it again.
--
-- What the client allows (and why it is built this way):
--   * A ping normally needs a key press or a click. The automatic ping is tried once per alert; if the client
--     blocks it (ADDON_ACTION_BLOCKED/FORBIDDEN), that is remembered and only the button is used from then on.
--   * Secure buttons can't be shown, hidden, moved or re-pointed by addon code in combat. So the button is always
--     there (dim between alerts), and a secure snippet picks the mob at click time from a token this file writes
--     into an ordinary frame's attribute. If the snippet can't read it on this client, the button pings your target.
--   * Enemies are only known through their nameplates: a mob too far for a nameplate can be reported, not pinged.
local addonName, ns = ...
local log = ns.Logger("Alert")

local A = { suspect = nil, lastParty = -math.huge, autoPending = nil }
ns.Alert = A

---------------------------------------------------------------------------
-- Which mob? Nameplates of hostile units in combat, ranked.
---------------------------------------------------------------------------
local function Plates()
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return {} end
    local ok, plates = pcall(C_NamePlate.GetNamePlates)
    if not ok or type(plates) ~= "table" then return {} end
    local out = {}
    for _, p in ipairs(plates) do
        local unit = p.namePlateUnitToken or (p.UnitFrame and p.UnitFrame.unit)
        if unit then out[#out + 1] = unit end
    end
    return out
end

-- Returns { unit, name, guid, engaged, targetedBy, idle, score } for the most likely stray mob, plus the list.
function A.FindSuspect()
    local W = ns.Watch
    local now = GetTime()
    local members = ns.Members()
    local candidates = {}
    for _, unit in ipairs(Plates()) do
        if ns.Yes(UnitExists, unit) and ns.Yes(UnitCanAttack, "player", unit) and not ns.Yes(UnitIsDead, unit) then
            local inCombat = ns.Yes(UnitAffectingCombat, unit)
            local engaged, targetedBy = {}, {}
            for _, m in ipairs(members) do
                if UnitThreatSituation and ns.Read(UnitThreatSituation, m, unit) ~= nil then engaged[#engaged + 1] = m end
                if ns.Yes(UnitIsUnit, (m == "player" and "target" or (m .. "target")), unit) then targetedBy[#targetedBy + 1] = m end
            end
            if inCombat or #engaged > 0 then
                local guid = ns.Read(UnitGUID, unit)
                local hit = guid and W.lastHit[guid]
                local idle = now - (hit or W.combatSince or now)
                -- in combat with the group, nobody targeting it, nobody hitting it: the stray
                local score = (#engaged > 0 and 100 or 0) + (inCombat and 20 or 0) - #targetedBy * 60 + math.min(idle, 30) * 2
                candidates[#candidates + 1] = { unit = unit, name = ns.Read(UnitName, unit), guid = guid, engaged = engaged,
                    targetedBy = targetedBy, idle = idle, score = score }
            end
        end
    end
    table.sort(candidates, function(a, b) return a.score > b.score end)
    return candidates[1], candidates
end

---------------------------------------------------------------------------
-- The ping button (secure: pings at click time, works in combat)
---------------------------------------------------------------------------
local data = CreateFrame("Frame")   -- not protected: addon code may set its attributes in combat
local button

local function MacroFor(token)
    if token then return ("/ping [@%s,exists] attack"):format(token) end
    return "/ping [@target,exists] attack"
end

local function CreateButton()
    local s = ns.db.settings
    local b = CreateFrame("Button", "StrayPingButton", UIParent, "SecureActionButtonTemplate, SecureHandlerBaseTemplate")
    button = b
    b:SetSize(44, 44)
    b:SetPoint(s.point[1], UIParent, s.point[2], s.point[3], s.point[4])
    b:SetFrameStrata("HIGH")
    b:SetMovable(true)
    b:SetClampedToScreen(true)
    b:RegisterForClicks("LeftButtonUp", "LeftButtonDown")
    b:SetAttribute("useOnKeyDown", false)
    b:SetAttribute("type1", "macro")
    b:SetAttribute("macrotext1", MacroFor(nil))

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexture(132212)   -- a marked-target icon
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.border = b:CreateTexture(nil, "BACKGROUND")
    b.border:SetPoint("TOPLEFT", -2, 2)
    b.border:SetPoint("BOTTOMRIGHT", 2, -2)
    b.border:SetColorTexture(0, 0, 0, 0.8)
    b.glow = b:CreateTexture(nil, "OVERLAY")
    b.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    b.glow:SetBlendMode("ADD")
    b.glow:SetVertexColor(1, 0.35, 0.2)
    b.glow:SetPoint("CENTER")
    b.glow:SetSize(84, 84)
    b.glow:Hide()
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.label:SetPoint("TOP", b, "BOTTOM", 0, -3)
    b.label:SetText("Ping")

    -- At click time, in the secure environment: ping the mob this file chose, if it can be read here.
    SecureHandlerSetFrameRef(b, "data", data)
    SecureHandlerWrapScript(b, "OnClick", b, [[
        local d = self:GetFrameRef("data")
        local token = d and d:GetAttribute("token")
        if token and UnitExists(token) then
            self:SetAttribute("macrotext1", "/ping [@" .. token .. ",exists] attack")
        else
            self:SetAttribute("macrotext1", "/ping [@target,exists] attack")
        end
    ]])
    b:SetScript("PostClick", function(self, mouse, down)
        if down then return end
        ns.SafeCall("PostClick", function()
            local text = self:GetAttribute("macrotext1")
            log.info("Ping button clicked: %s (stray mob: %s)", tostring(text), A.suspect and tostring(A.suspect.name) or "none")
        end)
    end)

    -- Shift+drag moves it (out of combat: secure frames can't move in combat).
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() and not ns.InLockdown() then self:StartMoving() end
    end)
    b:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        ns.db.settings.point = { point, relPoint, math.floor(x + 0.5), math.floor(y + 0.5) }
        log.info("Button moved to %s/%s %d,%d", point, relPoint, x, y)
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Stray Ping")
        if A.suspect then
            GameTooltip:AddLine(("Click: ping %s for the group"):format(A.suspect.name or "the stray mob"), 1, 1, 1)
        else
            GameTooltip:AddLine("Click: ping your target. When you are stuck in combat, it pings the stray mob.", 1, 1, 1, true)
        end
        GameTooltip:AddLine("Shift+drag to move. Bind a key in Key Bindings > AddOns.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetAlpha(s.idleAlpha)
end

local function SetHot(on, name)
    if not button then return end
    button:SetAlpha(on and 1 or ns.db.settings.idleAlpha)
    if on then button.glow:Show() else button.glow:Hide() end
    button.label:SetText(on and (name or "Stray mob") or "Ping")
end

---------------------------------------------------------------------------
-- Telling people
---------------------------------------------------------------------------
local big
local function BigText(text)
    if not ns.db.settings.bigText then return end
    if not big then
        big = CreateFrame("Frame", nil, UIParent)
        big:SetSize(800, 40)
        big:SetPoint("TOP", 0, -140)
        big:SetFrameStrata("HIGH")
        big.text = big:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        big.text:SetAllPoints()
        big.text:SetTextColor(1, 0.45, 0.25)
        big:Hide()
    end
    big.text:SetText(text)
    big:Show()
    big.shownAt = GetTime()
    C_Timer.After(4, function() if big.shownAt and GetTime() - big.shownAt >= 3.9 then big:Hide() end end)
end

local function PartyMessage(text, force)
    local s = ns.db.settings
    if not (s.party or force) then return end
    if not ns.Yes(IsInGroup) then log.debug("Party message skipped: not in a group") return end
    local now = GetTime()
    if not force and now - A.lastParty < s.partyCooldown then
        log.debug("Party message skipped: sent one %.0f s ago", now - A.lastParty)
        return
    end
    A.lastParty = now
    local channel = ns.Yes(IsInRaid) and "RAID" or "PARTY"
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    local ok, err = pcall(send, text, channel)
    if ok then log.info("Said in %s: %s", channel, text) else log.warn("Could not send to %s: %s", channel, tostring(err)) end
end

local function CanMark()
    if not ns.Yes(IsInGroup) then return true end
    return ns.Yes(UnitIsGroupLeader, "player") or ns.Yes(UnitIsGroupAssistant, "player")
end

---------------------------------------------------------------------------
-- The automatic ping (once per alert; remembered when the client blocks it)
---------------------------------------------------------------------------
local function TryAutoPing(target)
    local s = ns.db.settings
    if not s.autoPing then return end
    if ns.db.autoPingResult == "blocked" or ns.db.autoPingResult == "missing" then
        log.debug("Automatic ping skipped: %s on this client (/stray autoping retry to try again)", ns.db.autoPingResult)
        return
    end
    local send = C_Ping and C_Ping.SendMacroPing
    if not send then
        ns.db.autoPingResult = "missing"
        log.warn("Automatic ping: C_Ping.SendMacroPing doesn't exist on this client; the button pings instead")
        return
    end
    A.autoPending = { at = GetTime(), target = target }
    local kind = Enum and Enum.PingSubjectType and Enum.PingSubjectType.Attack or "attack"
    local ok, err = pcall(send, kind, target)
    log.info("Automatic ping sent at %s: call %s%s", tostring(target), ok and "returned" or "failed", ok and "" or (": " .. tostring(err)))
    if not ok then
        ns.db.autoPingResult = "blocked"
        A.autoPending = nil
        return
    end
    -- No block event within a moment: it went through.
    ns.After(0.5, "AutoPingResult", function()
        if A.autoPending then
            A.autoPending = nil
            if ns.db.autoPingResult ~= "works" then log.info("Automatic ping works on this client") end
            ns.db.autoPingResult = "works"
        end
    end)
end

local function OnBlocked(event, addon, func)
    if addon ~= addonName then return end
    log.warn("%s: %s was blocked by the client", event, tostring(func))
    if A.autoPending or tostring(func):find("Ping") then
        A.autoPending = nil
        ns.db.autoPingResult = "blocked"
        ns.Print("The game doesn't let addons ping by themselves, so only the button pings from now on (/stray autoping retry to test again).")
    end
end

---------------------------------------------------------------------------
-- The alert
---------------------------------------------------------------------------
local function Raise(idle, test, partyTest)
    local s = ns.db.settings
    local suspect = A.FindSuspect()
    A.suspect = suspect
    data:SetAttribute("token", suspect and suspect.unit or nil)
    local name = suspect and suspect.name or nil
    local seconds = math.floor(idle + 0.5)
    local who = name and ("%s isn't being fought"):format(name) or "the mob is out of nameplate range"
    log.info("Alert%s: %d s without damage; suspect %s (%s, engaged with %s, targeted by %s, untouched %.0f s)",
        test and " (test)" or "", seconds, tostring(name), tostring(suspect and suspect.unit),
        suspect and table.concat(suspect.engaged, ",") or "-", suspect and table.concat(suspect.targetedBy, ",") or "-",
        suspect and suspect.idle or 0)
    if s.sound and PlaySound then pcall(PlaySound, SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master") end
    BigText(name and ("Stray mob: %s"):format(name) or "Stuck in combat")
    local blind = ns.Watch.Blind and ns.Watch.Blind()
    ns.Print("|cffff7040Stuck in combat|r for %d s with no damage: %s.%s%s", seconds, who,
        name and " Click the Ping button to show the group where it is." or "",
        blind and " (This client hides damage from addons, so this may be a false alarm: /stray probe.)" or "")
    if (s.party and not test) or partyTest then
        PartyMessage(("[Stray Ping] Stuck in combat for %ds: %s"):format(seconds,
            name and (name .. " has nobody on it") or "a mob nobody can see"), partyTest)
    end
    if s.mark and suspect and CanMark() and not ns.Read(GetRaidTargetIndex, suspect.unit) then
        local ok = pcall(SetRaidTarget, suspect.unit, 8)
        log.info("Skull on %s: %s", tostring(name), ok and "done" or "failed")
    end
    SetHot(true, name)
    if suspect and not test then TryAutoPing(suspect.unit) end
end

ns.Listen("STALL", function(idle) Raise(idle, false) end)
ns.Listen("RESUMED", function()
    -- damage again: keep the button pointed at the mob but stop glowing
    SetHot(false)
end)
ns.Listen("COMBAT_END", function()
    A.suspect = nil
    data:SetAttribute("token", nil)
    SetHot(false)
end)
ns.Listen("TEST", function(party) Raise(ns.db.settings.idle, true, party) end)
ns.Listen("RESET_POSITION", function()
    if ns.InLockdown() then ns.Print("Not in combat.") return end
    ns.db.settings.point = { "CENTER", "CENTER", 0, -180 }
    button:ClearAllPoints()
    button:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
    ns.Print("Button back in place. Shift+drag to move it.")
end)

ns.Listen("STATUS", function()
    local W, s = ns.Watch, ns.db.settings
    ns.Print("alert after %d s of your combat with no group damage; party chat %s; automatic ping %s (%s); skull %s.",
        s.idle, s.party and "on" or "off", s.autoPing and "on" or "off", tostring(ns.db.autoPingResult or "not tried yet"),
        s.mark and "on" or "off")
    ns.Print("Group: %d in group, %s. /stray help for commands.", #ns.Members(),
        W.combatSince and ("in combat for %.0f s, last damage %.1f s ago"):format(GetTime() - W.combatSince, GetTime() - W.lastActivity)
        or "not in combat")
end)

ns.Listen("PROBE", function()
    local W = ns.Watch
    local function has(v) return v ~= nil and "yes" or "no" end
    local pings = {}
    if C_Ping then for k in pairs(C_Ping) do pings[#pings + 1] = k end end
    table.sort(pings)
    local lines = {
        ("Client %s. Combat log for addons: %s (CombatLogGetCurrentEventInfo %s)."):format(tostring((GetBuildInfo())),
            W.combatLogAvailable and "yes" or "no", has(CombatLogGetCurrentEventInfo)),
        ("Damage seen since login: combat log %d, group health %d, enemy nameplates %d, UNIT_COMBAT %d; hidden (secret) values %d."):format(
            W.signals.combatlog, W.signals.health, W.signals.plates, W.signals.unitcombat, W.signals.secret),
        ("Secret values API: %s. Nameplates API: %s (%d plates now). Threat API: %s. Secure snippets: %s."):format(
            has(issecretvalue), has(C_NamePlate and C_NamePlate.GetNamePlates), #Plates(), has(UnitThreatSituation), has(SecureHandlerWrapScript)),
        ("C_Ping: %s. Automatic ping result: %s."):format(#pings > 0 and table.concat(pings, ", ") or "missing", tostring(ns.db.autoPingResult or "not tried yet")),
    }
    for _, l in ipairs(lines) do ns.Print(l) end
    if W.Blind() then ns.Print("|cffff8040This client hides all damage from addons here: alerts would be false alarms.|r") end
end)

ns.Listen("LOADED", function()
    CreateButton()
    ns.On("ADDON_ACTION_BLOCKED", OnBlocked)
    ns.On("ADDON_ACTION_FORBIDDEN", OnBlocked)
end)

BINDING_HEADER_STRAYPING = "Stray Ping"
_G["BINDING_NAME_CLICK StrayPingButton:LeftButton"] = "Ping the stray mob"
