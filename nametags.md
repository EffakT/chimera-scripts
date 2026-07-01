# Nametags Mod — Project Context & Chimera API Reference

This file is the canonical project-knowledge document for the nametag mod.
It is kept in `chimera\lua\scripts\global\` alongside the actual scripts.
A new Claude session should read this before touching any code.

---

## What This Project Is

A Chimera Lua client-side mod for Halo PC/Custom Edition (Combat Evolved, not
Custom Edition specifically) that draws floating name tags above other players'
heads with team colouring, plus a reusable `DebugCore` framework that dumps
live game state to JSON for debugging via a Python bridge.

---

## Architecture

### Single-file constraint (important)
Each Chimera global script runs in its own **isolated Lua state**. Scripts in
the same `global/` folder cannot share globals — `DebugCore = ...` in one file
is invisible to another. Confirmed empirically: `sandboxed=false`,
`script_type=global`, yet DebugCore never became visible across files after 8
retries at 250ms.

**Now split into 3 files (merge-snippet model).** Because of the isolated-state
constraint, the debug tooling can't be a separate auto-loaded global script that
reads nametags' data — so it's kept as reusable **snippet files you paste into
`nametags.lua` only when testing**:
- `nametags.lua` — the standalone renderer (the only file that lives in
  `scripts/global/` and runs). Keeps lightweight ring-buffer logging so it's
  debug-ready.
- `debug_core.lua` — reusable JSON state-dump framework (`DebugCore.dump()`,
  `register`, generic `meta`/`local_player` sources). Callback-free.
- `tagcal.lua` — reusable calibration overlay (`draw_calibration()`, `cal_on`).
  Callback-free.

Both snippets are **callback-free** on purpose: Chimera allows only one
`OnPreCamera`/`OnPreFrame`/`OnCommand` per state, so pasting them can't clash —
you wire them into nametags' existing callbacks via the commented `DEBUG /
CALIBRATION` block at the bottom of `nametags.lua`. **Keep `debug_core.lua` and
`tagcal.lua` OUT of `scripts/global/`** (else Chimera auto-loads them as inert
separate scripts; `debug_core` also prints startup noise + resolves its dump dir).

### Files
- `nametags.lua` — merged file containing both the nametag rendering logic and
  the full DebugCore framework. Placed in `chimera\lua\scripts\global\`.
- `halo_debug_bridge.py` — Python watcher that detects dump file changes,
  screenshots the game window, and bundles both for sending to Claude.

### Output path (dynamic, no hardcoded usernames)
DebugCore writes to:
`%USERPROFILE%\OneDrive\Documents\My Games\Halo\chimera\lua\data\global\chimera_debug_dump.json`
(with fallback to plain Documents if OneDrive variant not found).
Result cached to `%USERPROFILE%\AppData\Local\debugcore_resolved_dir.txt`
to avoid `os.execute` subprocess cost on every reload (was causing multi-second
hitches).

Note: folder is named `Halo` (not `Halo CE`) — user renamed it.

---

## Chimera Lua API Reference

### Script requirements
```lua
clua_version = 2.056  -- must be set or Chimera won't load the script
```
Lua version: **5.5**. Scripts in `global/` are not sandboxed (can use io.*, os.*).

### Registering callbacks — CRITICAL
Callbacks **must** be registered explicitly. Defining `function OnPreFrame()`
alone does nothing. Every callback needs:
```lua
set_callback("eventname", "FunctionName")
```

Confirmed working event name strings (all one word, no spaces):
- `"precamera"` — fires before camera render, receives and must return camera state
- `"preframe"` — fires before each frame render
- `"command"` — fires for console commands; return false to swallow, true to pass through
- `"map load"` — fires when a map loads (note: this one IS two words with a space)
- `"tick"` — fires each game tick
- `"unload"` — fires when script is unloaded

Optional third arg: `"before"`, `"default"`, `"after"`, `"final"` (priority).

### Functions called by name must be global, not local
`set_timer` and `set_callback` look up functions by string in the global table.
A `local function try_register()` will be nil when Chimera tries to call it.
**Always declare timer/callback target functions without `local`.**

### draw_text
```lua
draw_text(text, x, y, width, height, font, align, a, r, g, b)
```
**The 4th/5th args are WIDTH and HEIGHT, not absolute right/bottom.** This was
previously documented (wrongly) as `left, top, right, bottom`. Empirically
confirmed by calibration dump `20260701_083219`:
- Drew text in a box with `x=300, width=400`, align `"center"`. Text rendered
  centered at internal x **500** (= `x + width/2`), and the glyphs rendered
  *past* x=400 — so 400 cannot be an absolute right clip edge; it is a width.
- Cross-checks an earlier nametag: `x=242.94, w=402.94`, center landed at
  **444.4** (= 242.94 + 402.94/2). Exact.

Consequences:
- `"left"` align: text left edge sits at `x`. (This is why the old wrong
  signature appeared to work — for left-align the x-anchor is the left edge
  regardless of what the 4th arg means.)
- `"center"` align: text centers at `x + width/2`. To center on a target
  screen-x `sx`, pass `x = sx - width/2`.
- `"right"` align: text right edge sits at `x + width`.
- Text is top-anchored at `y`; `height` is the clip box height.

Color order is **ARGB** (alpha first). Confirmed from working call in this project.
Fonts: `"smaller"` (11px), `"small"` (15px), `"large"`, `"ticker"`, `"console"`, `"system"`.
Alignment: `"left"`, `"center"`, `"right"`.

**Coordinate space is MODE-DEPENDENT horizontally; height always 480.**
- Widescreen ON (16:9): horizontal space is **640 wide** (centre 320). Calibration
  ruler: left-aligned x = 0/160/320/426/480 → internal 0.7/160.2/321.0/427.1/481.2.
- Widescreen OFF (4:3): horizontal space is **480 wide** (centre 240). Ruler
  (dump `20260702_090226`): x = 0/160/320/426 → px 486/805/1126/1338 = a clean
  **2.0 px/coord**, i.e. coord 480 hits the window's right edge and coord 240 the
  centre.

The pattern: `draw_width = 0.75 × SCREEN_WIDTH` (640/853.333 = 480/640 = 0.75), so
the horizontal half-extent = `0.375 × SCREEN_WIDTH` (320 in 16:9, 240 in 4:3).
`world_to_screen` computes `screen_x = half_w + ndc_x*half_w` with
`half_w = 0.375*SCREEN_WIDTH` — do NOT hardcode 320 (that put 4:3 tags ~1.33× too
far out). Vertical is `240 - ndc_y*240` in both modes. Never rescale to 853.

### console_out
```lua
console_out("text")                       -- plain
console_out("text", r, g, b)             -- RGB
console_out("text", a, r, g, b)          -- ARGB
```

### Player data
```lua
local dyn = get_dynamic_player(id)   -- returns nil if player is dead
local static = get_player(id)        -- always available while player is connected
```

Position (standing biped) — **empirically verified correct**:
```lua
local x = read_float(dyn + 0x5C)
local y = read_float(dyn + 0x60)
local z = read_float(dyn + 0x64)
```

Player name (UTF-16, ASCII range only, 12 char max):
```lua
local function get_player_name(id)
    local obj = get_player(id)
    if not obj then return "Unknown" end
    local addr = obj + 0x4
    local chars = {}
    for i = 1, 12 do
        local b = read_byte(addr + (i-1)*2)
        if b == 0 then break end
        chars[#chars+1] = string.char(b)
    end
    return table.concat(chars)
end
```

Team: `read_byte(get_player(id) + 0x20)` — mapping 0=Red, 1=Blue (not
independently verified against this specific offset, only that it's a
team-equality comparison field per a community script).

### Camera (OnPreCamera)
```lua
set_callback("precamera", "OnPreCamera")

function OnPreCamera(x, y, z, fov, ox1, oy1, oz1, ox2, oy2, oz2)
    -- x,y,z = camera world position
    -- fov   = HORIZONTAL fov in radians (not vertical, not degrees)
    -- ox1,oy1,oz1 = forward/look vector
    -- ox2,oy2,oz2 = up vector
    -- MUST return all values or camera won't update
    return x, y, z, fov, ox1, oy1, oz1, ox2, oy2, oz2
end
```

### Timers
```lua
local id = set_timer(interval_ms, "function_name", [optional_args...])
stop_timer(id)
```
Returns false from callback to stop repeating. Extra args (string/number/bool/nil) forwarded to callback.

### Object lookup
```lua
local obj = get_object(object_id)  -- Chimera's function name (not get_object_memory, that's SAPP)
```

### Vehicles
Vehicle reference on dynamic player: `read_dword(dyn + 0x11C)`
Sentinel for "not in vehicle": `0xFFFFFFFF`
Seat index while in vehicle: `read_word(dyn + 0x2F0)`. **Confirmed mapping:
`0`=driver, `1`=passenger, `2`=gunner** (passenger confirmed in dump
`20260701_124452`, gunner in `084813`/`123901`).

**Seated biped world position: `read_float(dyn + 0xA0/0xA4/0xA8)`.** While
seated, the biped's normal position field (+0x5C) holds only a small
seat-node-relative offset — NOT usable. +0xA0 holds the true world position and
projects onto the seated player. VERIFIED for gunner (`123901`) and passenger
(`124452`); the old `vehicle_origin + (+0x5C)` math was ~90 px off horizontally.

+0xA0 is the biped CENTRE/torso (it projects onto the auto-aim reticle), ~0.33
above the feet, whereas the on-foot read (+0x5C) is the feet. Since the draw code
adds one `TAG_HEIGHT` (0.7, tuned for feet), the vehicle branch subtracts
`SEAT_CENTRE_TO_FEET = 0.35` from the +0xA0 z so seated and on-foot tags sit at
the same height. `0.35` confirmed good on the driver dump `20260701_124955`
(tag lands just above the head for all three seats).
(Whether +0xA0 also equals the standing world position is untested; the code only
uses it in the vehicle branch.)

---

## Nametag Rendering — biped (VERIFIED WORKING)

For an on-foot player the tag is positioned and drawn like this, confirmed
against dumps `20260701_080754` / `081945` / `083219`:

```lua
local TAG_HEIGHT = 0.7                  -- world units above feet; ~visor height
local sx, sy = world_to_screen(x, y, z + TAG_HEIGHT)   -- single anchor, no angular offset
if sx and sy then
    local BOX_W, BOX_H, GAP = 160, 16, 4
    local x_left = sx - BOX_W / 2       -- center align => text centers on sx
    local y_top  = sy - BOX_H - GAP     -- sits just above the anchor
    draw_text(pname, x_left, y_top, BOX_W, BOX_H, "smaller", "center", 0.8, r, g, b)
end
```

Key points (each a previous bug):
- `world_to_screen` output is already in the 640-wide `draw_text` space — do not
  rescale.
- Centering is done via `x = sx - width/2` + `align="center"` (see `draw_text`
  above). The old code passed an absolute "right" that was read as a width,
  shoving the tag right; and an earlier version used `align="left"` with a
  half-width subtraction, shoving it left.
- The head offset is a single `z + TAG_HEIGHT` projection. An earlier version
  ALSO subtracted a separately-computed angular pixel offset — double counting
  that drifted with distance. Removed.
- `TAG_HEIGHT = 0.7` is a tunable world constant (not a hard-verified value);
  raise it for more clearance above the helmet.

---

## Projection Math (world_to_screen)

Screen dimensions under Chimera's widescreen fix: **853.333 × 480** (height
always 480, width = 480 × 16/9). `cam.fov` is horizontal FOV in radians.
Vertical FOV must be derived:
```lua
local aspect = 853.333 / 480
local half_hfov = cam.fov / 2
local half_vfov = math.atan(math.tan(half_hfov) / aspect)
-- use half_hfov for ndc_x, half_vfov for ndc_y
```

Cross product order `cross(right, forward)` for `true_up` is **correct** —
an earlier "fix" attempt to flip it to `cross(forward, right)` was wrong and
reverted. Do not change without re-deriving against real camera+target samples.

Screen centre: horizontal = `0.375 * SCREEN_WIDTH` (**320** in 16:9, **240** in
4:3 — see draw_text coordinate space above), vertical = **240** (height 480, both
modes). Output feeds `draw_text` directly, no rescaling. `SCREEN_WIDTH` (853.333
or 640) is used two ways: `/480` for the vertical-FOV aspect, and `*0.375` for the
horizontal half-extent. Both are mode-dependent and driven by the widescreen-fix
read (below).

**Aspect ratio is detected at runtime from two Chimera settings.** `SCREEN_WIDTH`
is refreshed each frame by `read_screen_width()`, which reads two static bytes:
- **`0x6D124874` = widescreen_fix** (0 = off/4:3, non-zero = on/16:9)
- **`0x6D11BD44` = font_override** (a *separate* setting that **forces widescreen
  on** when non-zero)

Because font_override forces widescreen on, the render is **16:9 if EITHER byte
is non-zero, and 4:3 ONLY when BOTH are zero**. (Don't treat `0x6D11BD44` as a
second copy of widescreen_fix — it's font_override; it only matters because of
the force-on behaviour.) `SCREEN_WIDTH` feeds both the vertical-FOV aspect
(`/480`) and the horizontal half-extent (`*0.375`). Reads are guarded: 4:3 is
concluded only when both bytes read 0, so a failed/garbage read defaults toward
16:9 (never wrongly forces 4:3, which would mis-scale). Notes: no Chimera Lua API
exposes resolution (122 globals dumped via a `tagapi` probe); an earlier heap
value `0x69FBB290` (flips 640↔746) was a RED HERRING (window measured true 16:9
959×540). The `0x6D…` addresses are Chimera-module ("strings.dll") statics,
stable across restarts — version-dependent, hence the safe fallback.

**Status: VERIFIED.** The full projection (position + head offset) was checked
against the visible biped in dumps `080754`/`081945` — projected head landed on
the on-screen visor to within measurement error.

---

## Debug Tools

Console commands (registered in `OnCommand`, swallowed so they don't error):
- `dbgdump` — writes the JSON state dump. The Python bridge
  (`halo_debug_bridge.py`) detects the file change, screenshots, and bundles
  both into a timestamped folder under `lua\data\global\<YYYYMMDD_HHMMSS>\`
  (`dump.json`, `bundle.json`, `screenshot.png`).
- `tagcal` — toggles a calibration overlay (`draw_calibration`) that renders a
  fixed coordinate ruler + alignment test strings, independent of camera and
  players. Used to confirm the `draw_text` coordinate space and alignment
  behaviour. Off by default (`cal_on = false`).

Dump sources (`DebugCore.sources`):
- `camera` — `_last_camera` from `OnPreCamera` (x/y/z/fov/look/up).
- `local_player`, `meta` (tick/build/map/server_type).
- `nametags` — `{ draw_log, debug_log, vehicle_log, errors }`. `draw_log`
  records each tag's `screen_anchor`, box `x/y/w/h`, `expect_center_x`, `drawn`.
  `vehicle_log` records the raw seat-position reads (see Known Issues #1).

**Testing workflow:** code change → user reloads → reproduces the scenario with
console open (player + targets stationary, so reads are stable) → `dbgdump` →
share timestamp. Measurements are taken from `screenshot.png` against the logged
values. Per the standing rule, offsets/constants stay UNVERIFIED until matched
to a real dump in-conversation.

---

## Known Issues / Open Items

1. **Vehicle seat position — SOLVED (read `dyn + 0xA0`).** Seated players now use
   the biped's true world position at `+0xA0/0xA4/0xA8` (see Vehicles API above),
   replacing the old `vehicle_origin + (+0x5C)` math.

   How it was found:
   - The old math (`vehicle_origin + player_local`) landed ~90 px left of the
     gunner in dumps `20260701_084813` and `123123`. `player_local` (+0x5C) was
     only `(-0.12, 0, 0.32)` — far too small; it's relative to the seat node,
     not the seat's world position. Rotating it (via `veh_fwd`/`veh_up`, which
     ARE valid orientation unit vectors at +0x74/+0x80) didn't help.
   - Back-projection put the true gunner world pos near the vehicle but offset
     behind+up. A memory scan of the biped (`biped_scan`) found that exact triple
     at **+0xA0**. Confirmed in dump `20260701_123901`: `+0xA0` projected to
     internal x=332.7, matching the target waypoint at 329.7.

   Verified across ALL THREE seats — gunner (`123901`), passenger (`124452`),
   driver (`124955`).

   Known cosmetic imperfection (ACCEPTED — "make do"): the tag uses biped +0xA0
   = centre of mass, which for a seated (posed) biped is shifted OUTBOARD from
   the player's visual centre — ~21 px right of the indicator triangle for the
   passenger, ~10 px left for the driver (offset flips by seat side, so a
   constant nudge can't fix it). Investigated in dumps `125305`/`125838`: the
   triangle sits on the player's body centre (passenger body centre internal
   x≈245.6, triangle x≈240.9), while +0xA0 lands at the shoulder (x≈262). No
   scanned biped/vehicle/static-player field lands on the body centre; the
   nearest was vehicle +0xA0 (x≈235.8) but that's the VEHICLE centre — shared by
   all occupants, so it would collapse multiple tags together. +0xA0 is kept
   because it is per-player and on the correct player. Do not swap to a
   vehicle-level field. The height constant
   `SEAT_CENTRE_TO_FEET = 0.35` was confirmed good on the driver dump (tag lands
   between head and waypoint, just above the head). Only non-Warthog vehicles
   remain untested, but the +0xA0 read should be general. `veh_fwd`/`veh_up`
   (0x74/0x80) confirmed = vehicle orientation unit vectors (kept noted in case
   future seat math needs them).

2. **Seat index mapping — RESOLVED.** `0`=driver, `1`=passenger, `2`=gunner,
   confirmed across dumps `084813`/`123901` (gunner) and `124452` (passenger).

3. **Movement lag — RESOLVED.** Tag lagged one frame behind camera motion (not
   player motion). ROOT CAUSE confirmed via `event_log` (dump `20260701_131815`):
   the callbacks fire **preframe → precamera** every frame, so drawing in
   `preframe` used the camera captured at the PREVIOUS frame's `precamera` (one
   frame stale). Having our own `OnPreCamera` wasn't enough because we still DREW
   in preframe. FIX: nametag render moved into `DrawNametags()`, called from
   `OnPreCamera` right after `_last_camera` is set from the current frame's camera
   args. Verified in-game: lag gone AND `draw_text` DOES render when issued during
   `precamera`. Bonus: this also fixed the intermittent `norm(v)` nil error — that
   was `world_to_screen` running in preframe on the very first frame before
   `precamera` had set the camera. `OnPreFrame` now only does the calibration
   overlay + event log.

7. **Enemy nametags hidden — IMPLEMENTED (pending offset verification).**
   `DrawNametags` renders a tag only when the other player's team equals the
   local player's team (`get_player + 0x20`, equality only — mapping-agnostic).
   Always on (no toggle, by request); fail-safe hides ALL tags if the local
   team can't be read, so enemies are never shown. FFA note: if the gametype has
   no real teams this may hide everyone (accepted). The `0x20` team offset is
   still UNVERIFIED here — `team_log` (temporary) records per-player
   `my_team`/`their_team`/`is_teammate`; confirm with a team-game dump + visual
   (teammate tag shows, enemy hidden) before trusting.

8. **Head-position field — FOUND + head-anchoring DONE (verified on-foot).**
   The biped has a skeletal **node array** of per-bone WORLD translations: base
   `0x578`, stride `0x34` (52-byte node structs), 19 position nodes (0–18). The
   **head is node 12 → biped + `0x7E8`/`0x7EC`/`0x7F0`**. Confirmed in dump
   `20260702_074318`: among all nodes it was both the highest-z (feet+0.561) and
   the closest to the eye/camera (0.089), i.e. the head. (Headshots use this same
   node/collision data — that's why it exists.) Feet 0x00–0x400 only holds feet
   (`0x5C`) + centre (`0xA0`); the nodes live further out.
   IMPLEMENTED: `get_head_position(dyn)` reads node 12 and tags now anchor to
   `head + HEAD_CLEARANCE (0.14)` (≈ feet+0.70 standing, so standing placement is
   unchanged, but it now FOLLOWS crouch/pose and should work seated too). MODEL-
   DEPENDENT (assumes this mod's single player biped); a sanity check (head must
   be within 1.5 u of the `0xA0` centre) falls back to `get_player_world_position
   + TAG_HEIGHT` if the read is implausible. `draw_log.anchor_src` = "head" or
   "fallback" so a dump shows which path ran.
   VERIFIED on-foot (dump `20260702_075204`): `draw_log.anchor_src` = "head" for
   all entries (so `0x7E8` reads valid for REMOTE players, not just local), and
   tags sit just above the head visually. `tagscan` diagnostic removed.
   STILL TO VERIFY: seated players (should also read the head node, since nodes
   are computed for seated bipeds). If seated works, the vehicle
   `0xA0`/`SEAT_CENTRE_TO_FEET` special-casing in `get_player_world_position` can
   be retired — the head node would then anchor everything, and it's only used as
   the fallback path anyway.

4. **DebugCore dependency — RESOLVED (decoupled).** nametags no longer depends
   on DebugCore. The file is now a self-contained "standalone core" (rendering,
   camera capture via its own `OnPreCamera`/`_last_camera`, projection) followed
   by an OPTIONAL DebugCore section marked by an `END OF STANDALONE CORE` banner.
   `world_to_screen` reads the core-owned `_last_camera` directly. The only
   nametags→DebugCore link is a single `DebugCore.register("nametags", ...)` call
   that lives inside the optional section. Deleting everything below the marker
   leaves name tags fully working (no dumps/commands). To ship without debug:
   delete the section below the marker; keep it for development.

5. **Vehicle turret rotation** — gunner offset assumes static rest orientation.
   Unverified whether live turret rotation causes drift.

6. **Vehicle tilt** — seat math doesn't account for vehicle's own world-space
   rotation (slopes, mid-air). Known simplification.

---

## Environment Notes

- Windows, OneDrive-redirected Documents folder.
- Halo folder named `Halo` (not `Halo CE`) under `My Games`.
- Game is retail Combat Evolved (not Custom Edition), running via Chimera.
- `os.execute` in Lua spawns a real subprocess — avoid on hot paths.
- VirtualStore: writes to `Program Files` are silently redirected to
  `%USERPROFILE%\AppData\Local\VirtualStore\...` if Halo runs unelevated.
  Always write to user-owned paths instead.