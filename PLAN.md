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
Currently guessing `11601` from client build `1.60.1 (69893) beta`. Verify by:
- Open the WoW Forever install and read any first-party addon's `.toc` (e.g. `Blizzard_TalentUI.toc`).
- Or launch with the addon enabled; if it shows "Out of Date", flip `Load out of date AddOns` and confirm it works, then update the number.

### 2. WoW Forever API audit (before shipping)
Combat log / API surface used by DPSPulse:
- `CombatLogGetCurrentEventInfo` — TBC+ style, but has a legacy fallback via `select(...)`. WoW Forever is 1.60.x (vanilla-adjacent) — **need to confirm which path fires**.
- `COMBAT_LOG_EVENT_UNFILTERED` event with subEvent parsing (`SWING_DAMAGE`, `RANGE_DAMAGE`, `SPELL_DAMAGE`, `SPELL_PERIODIC_DAMAGE`, `DAMAGE_SHIELD`, `DAMAGE_SPLIT`).
- `UnitGUID`, `GetTime`, `GetTimePreciseSec`, `CreateFrame`, standard UI primitives — all expected safe.
- New restrictions likely in WoW Forever: nothing here uses protected/`SecureActionButtonTemplate` combat-only APIs, so we should be clean, but log a scan.

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
