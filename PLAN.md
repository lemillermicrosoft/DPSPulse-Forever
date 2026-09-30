# DPSPulse Forever — Plan / TODO

## Port status (v0.2.0)
Originally ported from DPSPulse `v0.3.0`. Renames applied:
- Folder: `DPSPulse` → `DPSPulse_Forever`
- .toc/.lua filenames: `DPSPulse_Forever.{toc,lua}`
- Lua global table: `DPSPulse` → `DPSPulseForever`
- SavedVariables: `DPSPulseDB` → `DPSPulseForeverDB`
- Frame name: `DPSPulseFrame` → `DPSPulseForeverFrame`
- Slash: `/dpspulse` → `/dpspulseforever` (+ `/dpsf` alias)
- SLASH globals: `SLASH_DPSPULSE*` → `SLASH_DPSPULSEFOREVER*`, `SlashCmdList.DPSPULSE` → `SlashCmdList.DPSPULSEFOREVER`
- Display strings: chat prefix + title now read "DPSPulse Forever"

## Open TODOs

### 1. Confirm `## Interface:` number
**RESOLVED** — Interface number is `16001`, confirmed in-game via `/run print(select(4, GetBuildInfo()))`.

Lesson learned: WoW Forever does NOT use the classic-era `major*10000 + minor*100 + patch` formula. The `1.6` family gets `160xx` numbering.

### 2. WoW Forever API audit (before shipping)
**RESOLVED** — audit complete, findings baked into current code.

- **`COMBAT_LOG_EVENT_UNFILTERED` is `ForceTaint_strong` on WoW Forever.** Registering it hard-taints the addon ("blocked from an action only available to the Blizzard UI" appears immediately on load). Switched to `UNIT_COMBAT` — the taint-free per-unit event — filtered on `unit == "target"`, action `WOUND`. See `HandleUnitCombat` in the Lua source.
- `C_CombatLog.IsCombatLogRestricted()` returns `true` on this client and there's no obvious way to unlock it. `C_CombatLog.{Get,Set}CurrentCombatFilter` (retail's privacy opt-in) do not exist here.
- All other DPSPulse API usage (`UnitGUID`, `GetTime`, `GetTimePreciseSec`, `CreateFrame`, drag scripts, `SetMovable`, `SetClampedToScreen`) is taint-free on WoW Forever.
- Retail-style taint rules apply on top of the Classic Era base, but DPSPulse's shell code doesn't trip any of them — the only violation was the combat log event registration.

### 3. CurseForge project
**RESOLVED** — CurseForge project `1719813` is configured. WoW Forever `1.60.1` resolves to game-version ID `17053`, and the initial v0.1.0 file was uploaded as file `9021565`.

### 4. Native skin and in-game options
**RESOLVED in v0.2.0** — the window now offers a persistent `Classic` or `Blizzard / native` skin. The native variant uses Blizzard-shipped dialog artwork and `UIPanelCloseButton`; graph rendering is unchanged.

A custom canvas panel is registered under Esc > Options > AddOns through `Settings.RegisterCanvasLayoutCategory` / `Settings.RegisterAddOnCategory` when available, with `InterfaceOptions_AddCategory` as the legacy fallback. It includes every slash-configurable preference plus visibility, lock, rolling window, scale, skin, session reset, and position reset. Controls apply live and refresh from saved state. No external libraries or protected APIs are used.

### 5. Release workflow
**RESOLVED** — `v0.1.0` was published to GitHub and mirrored to CurseForge on 2026-09-30. A Discord announcement remains optional.

### 6. Shard-change handling (WoW Forever specific)
WoW Forever surfaces shard changes to the player via a UI button (unlike prior classic clients). A mid-combat shard change will split the combat log and produce anomalous DPS drops.

- Register `PLAYER_ENTERING_WORLD` and detect transitions (both `isInitialLogin` and `isReloadingUi` false).
- Also watch for the specific shard-change event once identified (see workspace `memory/2026-09-17.md` research task).
- On detection during active combat: consider `ClearSession()` + `ResetFightData()` and print a chat note like `"Shard change detected; session reset."` so the user knows why the graph jumped.
