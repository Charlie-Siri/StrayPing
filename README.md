# Stray Ping

When you are in combat but nobody in your group has dealt or taken damage for 5 seconds, a mob is usually stuck somewhere: a caster out of line of sight, a runner, something that aggroed from far away. Stray Ping finds it, tells you and the party, tries one automatic ping, and lights up a button that pings it for the group.

## Use

- `./install.sh` links this folder into WoW Forever's AddOns folder (once).
- The button sits below the middle of the screen, dim until an alert. Shift+drag moves it (out of combat), `/stray reset` puts it back. Bind it to a key in Key Bindings > AddOns > "Ping the stray mob".
- When the alert fires: a sound, big text with the mob's name, a chat line, a party chat line (`/stray party off` to stop), and the button glows with the mob's name. Click it to put an Attack ping on the mob.

| Command | What it does |
| --- | --- |
| `/stray` | Status: settings, and whether you are in combat right now |
| `/stray idle <2-60>` | Seconds of combat with no damage before the alert (default 5) |
| `/stray party on\|off` | Party/raid chat message (default on, at most one every 20 s) |
| `/stray autoping on\|off\|retry` | Try one automatic ping per alert (see below) |
| `/stray mark on\|off` | Also put a skull on the mob when you can mark (leader, assist, or solo). Default off |
| `/stray test [party]` | A practice alert (`party` also posts the party message) |
| `/stray probe` | Which combat APIs this client gives addons, and what has worked so far |
| `/stray log [n]`, `level`, `echo`, `clear` | The action log (also in `WTF/Account/<ACCOUNT>/SavedVariables/StrayPing.lua`) |

## What the game allows, and how this works around it

- **Pinging needs a key press or a click.** The automatic ping is tried once per alert with `C_Ping.SendMacroPing`. If the client blocks it, the addon remembers that (`autoPingResult = "blocked"`) and stops trying; `/stray autoping retry` tests again. The button always works because your click is the key press the game wants.
- **Secure buttons can't change in combat.** The button is always on screen (dim between alerts). When you click it, a secure snippet reads which mob to ping from an ordinary frame's attribute that the addon sets in combat. If this client doesn't allow that read, the button pings your current target instead. The log line "Ping button clicked: /ping [@nameplate2,exists] attack" shows which one happened.
- **Enemies are only known through nameplates** (about 40-60 yards, and only if enemy nameplates are on). A stuck mob without a nameplate is reported ("out of nameplate range") but can't be pinged.
- **Damage might be hidden from addons.** Recent clients can hide the combat log and health values in combat. The addon watches every signal it can: the combat log, group members' health, enemy nameplate health, UNIT_COMBAT. `/stray probe` shows which ones fire. If none do, the alert says it may be a false alarm.

## How the stray mob is picked

Among hostile nameplates that are in combat: on a group member's threat list (+100), in combat (+20), each group member targeting it (-60), seconds since it last took or dealt damage (+2 per second, up to 30). The highest score wins.

## Status

v0.1.0, 2026-11-20. Passes the sandbox use case `StrayPing/stray-mob` (a quilboar dies, a hunter stands back, the alert fires after 5 s, the automatic ping is blocked, the button pings the hunter). **Not tested in game yet.** These things only the live client can answer, so check them first:

1. `/stray probe` in a group fight: does the combat log reach addons, and are health values readable in combat?
2. Does the automatic ping work (`autoPingResult` after the first alert)?
3. Does the button ping the stray mob, or your target? (the "Ping button clicked" log line)
4. Does `UnitThreatSituation` work on nameplate units in combat?

## Files

| File | What it does |
| --- | --- |
| `Log.lua` | Leveled, timestamped log in its own SavedVariable (`StrayPingLog`) |
| `Core.lua` | Settings (`StrayPingDB`), events, secret-value guards, group members, `/stray` |
| `Watch.lua` | Group combat state, damage signals, the stall timer |
| `Alert.lua` | Picking the mob, alert, party message, automatic ping, the secure ping button, probe |
| `Bindings.xml` | The key binding for the button |
