-- Watch: are you in combat, and when did anyone in your group last deal or take damage?
-- Damage is seen through whatever this client allows addons: the combat log, group members' health, enemy
-- nameplate health and UNIT_COMBAT. Each signal is counted, so /stray probe shows which ones work here.
local addonName, ns = ...
local log = ns.Logger("Watch")

local W = {
    combatSince = nil,      -- GetTime() the group entered combat
    lastActivity = 0,       -- GetTime() of the last damage dealt or taken by the group
    lastKind = nil,
    alerted = false,        -- an alert fired and no damage happened since
    alertAt = 0,
    alerts = 0,             -- alerts in this fight
    signals = { combatlog = 0, health = 0, plates = 0, unitcombat = 0, secret = 0 },
    combatLogAvailable = false,
    lastHit = {},           -- [enemy GUID] = GetTime() it last took or dealt damage
    health = {},            -- [unit token] = last readable health
}
ns.Watch = W

---------------------------------------------------------------------------
-- Activity
---------------------------------------------------------------------------
local logged = {}
local function Activity(kind, detail, enemyGUID)
    local now = GetTime()
    W.signals[kind] = (W.signals[kind] or 0) + 1
    W.lastActivity = now
    W.lastKind = kind
    if enemyGUID then W.lastHit[enemyGUID] = now end
    if W.alerted then
        W.alerted = false
        log.info("Damage again after the alert (%s: %s): watching for the next stall", kind, tostring(detail))
        ns.Fire("RESUMED", kind)
    end
    if (logged[kind] or 0) + 3 < now then   -- at most one line per signal every 3 s
        logged[kind] = now
        log.debug("Activity %s: %s", kind, tostring(detail))
    end
end
ns.MarkActivity = Activity

local memberByGUID = {}
local function RefreshMembers()
    wipe(memberByGUID)
    local names = {}
    for _, u in ipairs(ns.Members()) do
        local guid = ns.Read(UnitGUID, u)
        if guid then memberByGUID[guid] = u end
        local pet = ns.Read(UnitGUID, u == "player" and "pet" or (u .. "pet"))
        if pet then memberByGUID[pet] = u .. "pet" end
        names[#names + 1] = u
    end
    log.debug("Group: %s", table.concat(names, ", "))
end
local function IsMemberToken(unit)
    return unit == "player" or unit == "pet" or unit:match("^party%d$") or unit:match("^raid%d+$")
        or unit:match("^party%dpet$") or unit:match("^raid%d+pet$")
end

---------------------------------------------------------------------------
-- Signals
---------------------------------------------------------------------------
local DAMAGE = {}
for _, e in ipairs({ "SWING_DAMAGE", "RANGE_DAMAGE", "SPELL_DAMAGE", "SPELL_PERIODIC_DAMAGE", "SPELL_BUILDING_DAMAGE",
    "DAMAGE_SHIELD", "DAMAGE_SPLIT", "SWING_MISSED", "RANGE_MISSED", "SPELL_MISSED", "SPELL_PERIODIC_MISSED",
    "DAMAGE_SHIELD_MISSED" }) do DAMAGE[e] = true end

local GROUP_FLAGS = bit.bor(COMBATLOG_OBJECT_AFFILIATION_MINE or 1, COMBATLOG_OBJECT_AFFILIATION_PARTY or 2,
    COMBATLOG_OBJECT_AFFILIATION_RAID or 4)

local function InGroup(guid, flags)
    if guid and memberByGUID[guid] then return true end
    flags = ns.Num(flags)
    return flags ~= nil and bit.band(flags, GROUP_FLAGS) ~= 0
end

local function OnCombatLog()
    if not CombatLogGetCurrentEventInfo then return end
    local _, sub, _, srcGUID, srcName, srcFlags, _, dstGUID, dstName, dstFlags = CombatLogGetCurrentEventInfo()
    sub = ns.Value(sub)
    if not sub or not DAMAGE[sub] then return end
    srcGUID, dstGUID = ns.Value(srcGUID), ns.Value(dstGUID)
    local fromGroup, toGroup = InGroup(srcGUID, srcFlags), InGroup(dstGUID, dstFlags)
    if not fromGroup and not toGroup then return end
    local enemy = fromGroup and not toGroup and dstGUID or (toGroup and not fromGroup and srcGUID) or nil
    Activity("combatlog", ("%s %s > %s"):format(sub, tostring(ns.Value(srcName)), tostring(ns.Value(dstName))), enemy)
end

local function OnHealth(_, unit)
    if type(unit) ~= "string" then return end
    local member = IsMemberToken(unit)
    local plate = unit:match("^nameplate%d+$")
    if not member and not plate then return end
    if plate and not ns.Yes(UnitCanAttack, "player", unit) then return end
    local h = ns.Num(ns.Read(UnitHealth, unit))
    if not h then
        W.signals.secret = W.signals.secret + 1
        return
    end
    local key = plate and (ns.Read(UnitGUID, unit) or unit) or unit
    local before = W.health[key]
    W.health[key] = h
    if before and h < before then
        if member then Activity("health", ("%s %d > %d"):format(unit, before, h))
        else Activity("plates", ("%s %d > %d"):format(tostring(ns.Read(UnitName, unit)), before, h), key) end
    end
end

local function OnUnitCombat(_, unit, action)
    if type(unit) ~= "string" or ns.Value(action) == "HEAL" then return end
    if IsMemberToken(unit) then
        Activity("unitcombat", ("%s %s"):format(unit, tostring(ns.Value(action))))
    elseif ns.Yes(UnitCanAttack, "player", unit) then
        Activity("unitcombat", ("%s %s"):format(unit, tostring(ns.Value(action))), ns.Read(UnitGUID, unit))
    end
end

---------------------------------------------------------------------------
-- The stall check (4 times a second)
---------------------------------------------------------------------------
local function SnapshotHealth()
    wipe(W.health)
    for _, u in ipairs(ns.Members()) do W.health[u] = ns.Num(ns.Read(UnitHealth, u)) end
end

local function Tick()
    local now = GetTime()
    -- Only your own combat counts: a party member fighting elsewhere isn't your stray mob.
    if not ns.Yes(UnitAffectingCombat, "player") then
        if W.combatSince then
            log.info("Out of combat after %.1f s (%d alert%s)", now - W.combatSince, W.alerts, W.alerts == 1 and "" or "s")
            W.combatSince, W.alerted = nil, false
            wipe(W.lastHit)
            ns.Fire("COMBAT_END")
        end
        return
    end
    if not W.combatSince then
        W.combatSince = now
        W.lastActivity = math.max(W.lastActivity, now)   -- entering combat counts as activity
        W.alerts = 0
        SnapshotHealth()
        log.info("In combat")
        ns.Fire("COMBAT_START", "player")
    end
    local idle = now - W.lastActivity
    if not W.alerted and idle >= ns.db.settings.idle then
        W.alerted = true
        W.alertAt = now
        W.alerts = W.alerts + 1
        log.info("Stall: %.1f s in combat without group damage (last activity: %s, in combat %.1f s)", idle,
            tostring(W.lastKind), now - W.combatSince)
        ns.Fire("STALL", idle)
    end
end

-- Can this client show the addon any damage at all? (No: every fight would look like a stall.)
function W.Blind()
    return not W.combatLogAvailable and W.signals.health == 0 and W.signals.plates == 0 and W.signals.unitcombat == 0
        and W.signals.secret > 0
end

ns.Listen("LOADED", function()
    W.combatLogAvailable = CombatLogGetCurrentEventInfo ~= nil and ns.On("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog)
    if not W.combatLogAvailable then log.warn("No combat log for addons on this client: using health and UNIT_COMBAT only") end
    ns.On("UNIT_HEALTH", OnHealth)
    ns.On("UNIT_COMBAT", OnUnitCombat)
    ns.On("GROUP_ROSTER_UPDATE", RefreshMembers)
    ns.On("PLAYER_ENTERING_WORLD", RefreshMembers)
    RefreshMembers()
    C_Timer.NewTicker(0.25, function() ns.SafeCall("Tick", Tick) end)
end)
