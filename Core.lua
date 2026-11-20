-- Core: namespace, saved variables, event dispatch, shared helpers, slash commands.
local addonName, ns = ...

ns.name = addonName
ns.title = "Stray Ping"
local log = ns.Logger("Core")

local DB_DEFAULTS = {
    version = 1,
    settings = {
        idle = 5,             -- seconds of your combat with no group damage dealt or taken before the alert
        party = true,         -- also say it in party/raid chat
        partyCooldown = 20,   -- seconds between two party messages
        autoPing = true,      -- try one automatic ping when the alert fires (the client may block it)
        mark = false,         -- put a skull on the stray mob (needs group leader or assist)
        sound = true,
        bigText = true,
        idleAlpha = 0.35,     -- the ping button between alerts (it stays clickable: secure buttons can't hide in combat)
        point = { "CENTER", "CENTER", 0, -180 },
    },
    autoPingResult = nil,     -- nil = not tried yet, "works", "blocked", "missing"
}

local function ApplyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            if type(v) == "table" then target[k] = {}; ApplyDefaults(target[k], v) else target[k] = v end
        elseif type(v) == "table" and type(target[k]) == "table" then
            ApplyDefaults(target[k], v)
        end
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}
local QUIET_EVENTS = {   -- too frequent to log each time; their handlers log what matters
    COMBAT_LOG_EVENT_UNFILTERED = true, UNIT_HEALTH = true, UNIT_COMBAT = true, UNIT_FLAGS = true,
    NAME_PLATE_UNIT_ADDED = true, NAME_PLATE_UNIT_REMOVED = true, UNIT_THREAT_LIST_UPDATE = true,
    UNIT_THREAT_SITUATION_UPDATE = true, GROUP_ROSTER_UPDATE = true, UNIT_TARGET = true,
}

-- Register a handler. Unknown or forbidden events (API differences between clients) are logged and skipped.
function ns.On(event, fn)
    if not handlers[event] then
        local ok, err = pcall(eventFrame.RegisterEvent, eventFrame, event)
        if not ok then
            log.warn("Event %s not available on this client, handler skipped: %s", event, tostring(err))
            return false
        end
        handlers[event] = {}
    end
    table.insert(handlers[event], fn)
    return true
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    if not QUIET_EVENTS[event] then
        log.debug("Event %s (%s, %s)", event, tostring((...)), tostring((select(2, ...))))
    end
    for i = 1, #list do ns.SafeCall("Event:" .. event, list[i], event, ...) end
end)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function StripColors(text) return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
ns.StripColors = StripColors

function ns.Print(msg, ...)
    if select("#", ...) > 0 then msg = msg:format(...) end
    print("|cffff7040Stray Ping|r: " .. msg)
    log.info("Chat: %s", StripColors(msg))
end

function ns.After(delay, label, fn) C_Timer.After(delay, function() ns.SafeCall(label, fn) end) end

-- Secret values: in combat the client may hand addons values Lua can't compare. These treat them as unknown.
local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) == true end
ns.IsSecret = IsSecret
function ns.Value(v) if v ~= nil and not IsSecret(v) then return v end end
function ns.Num(v) if type(v) == "number" and not IsSecret(v) then return v end end
function ns.Read(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, ...)
    if ok then return ns.Value(v) end
end
function ns.Yes(fn, ...)
    local v = ns.Read(fn, ...)
    return v == true or v == 1
end

function ns.InLockdown()
    local fn = InCombatLockdown or (C_RestrictedActions and C_RestrictedActions.InCombatLockdown)
    return fn ~= nil and ns.Read(fn) == true
end

-- Group unit tokens: player first, then party1-4 or raid1-40.
function ns.Members()
    local list = { "player" }
    if IsInRaid and ns.Yes(IsInRaid) then
        for i = 1, 40 do
            local u = "raid" .. i
            if ns.Yes(UnitExists, u) and not ns.Yes(UnitIsUnit, u, "player") then list[#list + 1] = u end
        end
    else
        for i = 1, 4 do
            local u = "party" .. i
            if ns.Yes(UnitExists, u) then list[#list + 1] = u end
        end
    end
    return list
end

---------------------------------------------------------------------------
-- Loading
---------------------------------------------------------------------------
ns.On("ADDON_LOADED", function(_, name)
    if name ~= addonName then return end
    ns.InitLog()
    StrayPingDB = StrayPingDB or {}
    ApplyDefaults(StrayPingDB, DB_DEFAULTS)
    ns.db = StrayPingDB
    local s = ns.db.settings
    log.info("Loaded %s %s: idle %ds, party %s, autoPing %s (last result %s), mark %s, client %s",
        addonName, tostring(C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version") or "?"),
        s.idle, tostring(s.party), tostring(s.autoPing), tostring(ns.db.autoPingResult), tostring(s.mark),
        tostring((select(1, GetBuildInfo()))))
    if ns.Fire then ns.Fire("LOADED") end
end)

local listeners = {}
function ns.Listen(msg, fn) listeners[msg] = listeners[msg] or {}; table.insert(listeners[msg], fn) end
function ns.Fire(msg, ...)
    for _, fn in ipairs(listeners[msg] or {}) do ns.SafeCall("Msg:" .. msg, fn, ...) end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function OnOff(v) return v and "on" or "off" end

SLASH_STRAYPING1, SLASH_STRAYPING2 = "/stray", "/strayping"
SlashCmdList.STRAYPING = function(msg)
    ns.SafeCall("Slash", function()
        local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
        cmd = cmd:lower()
        local s = ns.db.settings
        log.info("Command: /stray %s", msg or "")
        if cmd == "" then
            ns.Fire("STATUS")
        elseif cmd == "help" then
            ns.Print("Commands:")
            for _, line in ipairs({
                "/stray - status",
                ("/stray idle <seconds> - combat with no damage before the alert (now %d s)"):format(s.idle),
                ("/stray party on|off - also say it in party chat (now %s)"):format(OnOff(s.party)),
                ("/stray autoping on|off|retry - one automatic ping per alert (now %s, last result: %s)"):format(
                    OnOff(s.autoPing), tostring(ns.db.autoPingResult or "not tried yet")),
                ("/stray mark on|off - skull the stray mob when you can mark (now %s)"):format(OnOff(s.mark)),
                "/stray test [party] - a practice alert",
                "/stray probe - which combat APIs this client gives addons",
                "/stray reset - put the ping button back (move it with Shift+drag out of combat)",
                "/stray log [n] | level <debug|info|warn|error> | echo | clear",
            }) do print("  " .. line) end
        elseif cmd == "idle" then
            local n = tonumber(rest)
            if n and n >= 2 and n <= 60 then s.idle = n; ns.Print("Alert after %d s of combat with no damage.", n)
            else ns.Print("Use /stray idle <2-60> (now %d s).", s.idle) end
        elseif cmd == "party" then
            s.party = rest == "on" or (rest == "" and not s.party)
            ns.Print("Party chat messages: %s.", OnOff(s.party))
        elseif cmd == "autoping" then
            if rest == "retry" then
                ns.db.autoPingResult = nil; s.autoPing = true
                ns.Print("The next alert will try the automatic ping again.")
            else
                s.autoPing = rest == "on" or (rest == "" and not s.autoPing)
                ns.Print("Automatic ping: %s (last result: %s).", OnOff(s.autoPing), tostring(ns.db.autoPingResult or "not tried yet"))
            end
        elseif cmd == "mark" then
            s.mark = rest == "on" or (rest == "" and not s.mark)
            ns.Print("Skull on the stray mob: %s (only when you are leader or assist, or solo).", OnOff(s.mark))
        elseif cmd == "test" then
            ns.Fire("TEST", rest == "party")
        elseif cmd == "probe" then
            ns.Fire("PROBE")
        elseif cmd == "reset" then
            ns.Fire("RESET_POSITION")
        elseif cmd == "log" then
            ns.LogCommand(rest)
        else
            ns.Print("Unknown command. /stray help")
        end
    end)
end
