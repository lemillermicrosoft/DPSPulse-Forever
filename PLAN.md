# DPSPulse Forever — Plan / TODO

## Port status (v0.1.0)
Straight port of DPSPulse `v0.3.0`. Renames applied:
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
Create a WoW Forever CF project once the platform categorizes 1.60.x. Wire `projectId` into `.curseforge.json`. Reuse the existing `cf-upload` pipeline.

### 4. Native-skin follow-up (deehoc requested)
> "Investigate creating a skin for DPSPulse that does a better job matching the game skins and default controls."

Concretely, that means:
- Replace the ad-hoc dark backdrop with an **`InsetFrameTemplate`** / **`BasicFrameTemplateWithInset`** style backdrop so it feels like a native Blizzard panel.
- Give it a proper title bar with a Blizzard-style close button (`UIPanelCloseButton`).
- Support **default UI drag behavior**: hold Shift to move (matching how the bag, minimap, quest tracker feel), or provide a proper `/dpsf lock` toggle wired to an options panel checkbox.
- Add a minimal **Interface Options panel** entry (`InterfaceOptions_AddCategory`, or the newer `Settings.RegisterAddOnCategory` if WoW Forever includes the retail Settings API).
- Consider `Minimap` LDB launcher via LibDBIcon so it looks like every other well-behaved addon.
- Explore theming via LibSharedMedia and matching the WoW Forever default fonts (whatever they replace `FRIZQT__.TTF` with, if anything).
- Keep the graph render logic untouched — this is a **shell** change, not a behavior change.

### 5. Release workflow
Once #1–#3 are done: cut `v0.1.0` GitHub release, mirror to CurseForge, add a Discord announcement in `deehoc` server.

### 6. Shard-change handling (WoW Forever specific)
WoW Forever surfaces shard changes to the player via a UI button (unlike prior classic clients). A mid-combat shard change will split the combat log and produce anomalous DPS drops.

- Register `PLAYER_ENTERING_WORLD` and detect transitions (both `isInitialLogin` and `isReloadingUi` false).
- Also watch for the specific shard-change event once identified (see workspace `memory/2026-09-17.md` research task).
- On detection during active combat: consider `ClearSession()` + `ResetFightData()` and print a chat note like `"Shard change detected; session reset."` so the user knows why the graph jumped.
