# DPSPulse Forever

WoW Forever (beta, client `1.60.1`) port of [DPSPulse](https://github.com/lemillermicrosoft/DPSPulse).

DPSPulse Forever shows a realtime rolling DPS graph and current DPS value during combat, with a Details-style dual-series overlay (rolling window + full-session).

This port began as a straight port of DPSPulse tag `v0.3.0`. The graph and damage-tracking behavior remain unchanged, while the WoW Forever edition now adds native in-game options, a choice of window skins, and a compact collapse mode.

## Status
- Interface: `16001` (confirmed via in-game `GetBuildInfo()` on build 1.60.1.69893).
- CurseForge project ID: `1719813`; WoW Forever `1.60.1` release uploads are enabled.
- Version `0.2.0` adds an Esc > Options > AddOns panel and a live, persistent Blizzard/native skin.

## WoW Forever combat log limitation

WoW Forever hard-taints (`ForceTaint_strong`) any addon that registers `COMBAT_LOG_EVENT_UNFILTERED`, so this port uses the taint-free `UNIT_COMBAT` event instead. That comes with real caveats vs. the TBC original:

- **Damage is only counted while the mob is your current target.** If you tab off mid-fight (or the mob dies before you retarget) any in-flight events are lost.
- **Group content may over-count.** `UNIT_COMBAT` fires for damage the unit takes, not damage you deal — in a party/raid, other players' hits on the same mob will inflate your numbers. Solo and small-group tuning is where this port shines.
- **DoTs and environmental damage may not be surfaced.** UNIT_COMBAT skips much of what the combat log covers.
- **Only `WOUND` actions are tracked** (actual damage). Misses/dodges/parries/blocks are ignored for DPS math.

This is intentional — WoW Forever's design philosophy on combat log privacy is respected. See `PLAN.md` for the upstream API investigation notes.

## Options and commands
All display settings are available under **Esc > Options > AddOns > DPSPulse Forever** (with a legacy Interface Options registration fallback). The panel controls visibility, position lock, automatic collapse after combat, rolling window (2–60 seconds), UI scale (0.5–2), debug mode, Classic/Blizzard skin, session reset, and window-position reset. Changes apply immediately and persist in `DPSPulseForeverDB` where applicable.

Use the **−** button in the window header to collapse the display to a 28×28 **+** button. Click **+** to expand it again. The compact button keeps the same saved position and can still be dragged while unlocked. With auto-collapse enabled, the full display opens when combat starts and collapses when combat ends.

Slash commands remain available:
- `/dpspulseforever` (alias `/dpsf`) — toggle frame.
- `/dpsf show`, `hide`, `lock`, `unlock`, `reset`, or `debug`.
- `/dpsf collapse`, `/dpsf expand`, `/dpsf autocollapse <on|off>`, and `/dpsf status`.
- `/dpsf window <2-60>` and `/dpsf scale <0.5-2>`.
- `/dpsf skin <classic|blizzard>` and `/dpsf resetposition`.

## Install
Copy the folder into `<WoW Forever>/Interface/AddOns/DPSPulse_Forever/` such that these files live directly in it:
- `DPSPulse_Forever.toc`
- `DPSPulse_Forever.lua`
- `Media/`

## Upstream
Bugfixes and features flow from [DPSPulse](https://github.com/lemillermicrosoft/DPSPulse) upstream. This repo only carries the WoW Forever delta (interface number, options/native skin work, WoW Forever–specific compat).
