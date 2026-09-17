# DPSPulse Forever

WoW Forever (beta, client `1.60.1`) port of [DPSPulse](https://github.com/lemillermicrosoft/DPSPulse).

DPSPulse Forever shows a realtime rolling DPS graph and current DPS value during combat, with a Details-style dual-series overlay (rolling window + full-session).

This port is a **straight port** of DPSPulse as-of tag `v0.3.0`. Behavior is identical; only addon identity was renamed (folder, SavedVariables, slash commands, frame name) so it can coexist with the original.

## Status
- Interface: `16001` (confirmed via in-game `GetBuildInfo()` on build 1.60.1.69893).
- CurseForge project: **not yet created**.
- Cosmetic reskin to match WoW Forever's default UI is planned as follow-up work — see `PLAN.md`.

## WoW Forever combat log limitation

WoW Forever hard-taints (`ForceTaint_strong`) any addon that registers `COMBAT_LOG_EVENT_UNFILTERED`, so this port uses the taint-free `UNIT_COMBAT` event instead. That comes with real caveats vs. the TBC original:

- **Damage is only counted while the mob is your current target.** If you tab off mid-fight (or the mob dies before you retarget) any in-flight events are lost.
- **Group content may over-count.** `UNIT_COMBAT` fires for damage the unit takes, not damage you deal — in a party/raid, other players' hits on the same mob will inflate your numbers. Solo and small-group tuning is where this port shines.
- **DoTs and environmental damage may not be surfaced.** UNIT_COMBAT skips much of what the combat log covers.
- **Only `WOUND` actions are tracked** (actual damage). Misses/dodges/parries/blocks are ignored for DPS math.

This is intentional — WoW Forever's design philosophy on combat log privacy is respected. See `PLAN.md` for the upstream API investigation notes.

## Commands
- `/dpspulseforever` (alias `/dpsf`) — toggle frame.
- `/dpsf help` — show all commands (same set as upstream DPSPulse: `show`, `hide`, `window <s>`, `reset`, `lock`, `unlock`, `scale <v>`).

## Install
Copy the folder into `<WoW Forever>/Interface/AddOns/DPSPulse_Forever/` such that these files live directly in it:
- `DPSPulse_Forever.toc`
- `DPSPulse_Forever.lua`
- `Media/`

## Upstream
Bugfixes and features flow from [DPSPulse](https://github.com/lemillermicrosoft/DPSPulse) upstream. This repo only carries the WoW Forever delta (interface number, cosmetic skin work, WoW Forever–specific compat).
