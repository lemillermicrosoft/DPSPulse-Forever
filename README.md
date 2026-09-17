# DPSPulse Forever

WoW Forever (beta, client `1.60.1`) port of [DPSPulse](https://github.com/lemillermicrosoft/DPSPulse).

DPSPulse Forever shows a realtime rolling DPS graph and current DPS value during combat, with a Details-style dual-series overlay (rolling window + full-session).

This port is a **straight port** of DPSPulse as-of tag `v0.3.0`. Behavior is identical; only addon identity was renamed (folder, SavedVariables, slash commands, frame name) so it can coexist with the original.

## Status
- Interface: `11601` (guessed from client version 1.60.1 — needs beta-client verification, see `PLAN.md`).
- CurseForge project: **not yet created**.
- Cosmetic reskin to match WoW Forever's default UI is planned as follow-up work — see `PLAN.md`.

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
