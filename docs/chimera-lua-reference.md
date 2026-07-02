# Chimera Lua — Verified Field Notes (Projection, Nametags & Memory)

Practical, **empirically verified** notes gathered while building a client-side
teammate **nametag/HUD** mod with Chimera. Everything here was tested against real logged game
state + screenshots, not copied from documentation — where a value is a guess or
convention it is labelled as such.

**Environment these were verified on:** retail Halo PC *Combat Evolved* via
Chimera (build 1262), Lua 5.5, `clua_version = 2.056`, run in a window.

**Scope:** the nametag mod targets **retail Halo PC only** — *Halo Custom Edition*
already has built-in nametags, so it's unnecessary there. (The API/projection/
memory notes below are still generally useful on either.)

> **Golden rule:** treat every memory offset as *unverified until tested against
> real logged data on your build*. Static addresses in particular are
> version/build dependent. I was burned twice trusting "authoritative" values
> (a guessed FOV constant and a third-party offset that conflicted with reality).

---

## `draw_text` — signature, coordinates, alignment

```lua
draw_text(text, x, y, width, height, font, align, a, r, g, b)
```

- **The 4th/5th args are WIDTH and HEIGHT, not right/bottom.** (Some older docs
  say `left, top, right, bottom` — that's wrong.) Verified with a calibration
  ruler: centered text landed at `x + width/2`, and glyphs rendered *past* a value
  passed as an "absolute right", proving it's a width.
- Colour order is **ARGB** (alpha first).
- Text is **top-anchored** at `y`; `height` is just the clip box.

Alignment (horizontal), verified:

| align      | where the text goes                    |
| ---------- | -------------------------------------- |
| `"left"`   | left edge of text sits at `x`          |
| `"center"` | text is centered at `x + width/2`      |
| `"right"`  | right edge of text sits at `x + width` |

To center text on a target screen-x `sx`: `draw_text(t, sx - w/2, y, w, h, f, "center", ...)`.

Fonts (height in the 480-tall space): `"smaller"` ≈ 11px, `"small"` ≈ 15px,
`"large"`, `"ticker"`, `"console"`, `"system"`.

---

## Screen coordinate space (this bites people)

`draw_text` coordinates are a **virtual space with a fixed height of 480**. The
**horizontal width depends on Chimera's widescreen fix**:

| mode  | draw-space width | centre |
| ----- | ---------------- | ------ |
| 16:9  | **640**          | 320    |
| 4:3   | **480**          | 240    |

The pattern that held in both modes: `draw_width = 0.75 × internal_render_width`
(where render width is `853.333` for 16:9 or `640` for 4:3). So the horizontal
half-extent is `0.375 × render_width`.

How this was measured: draw left-aligned labels at known x-coords and read where
they land on a screenshot. In 4:3 the ruler came out at a clean **2.0 px per
coord** (coord 480 = right edge, coord 240 = centre); in 16:9 it was 1.5 px/coord
(coord 640 = right edge). This "calibration overlay" trick is the reliable way to
learn any draw-space behaviour — don't reason about it, measure it.

### Detecting the aspect at runtime

There is **no Chimera Lua API for the resolution** (I dumped all globals). But the
widescreen state is readable from two static bytes (Chimera-module, i.e.
`strings.dll`, addresses — **version dependent**):

```lua
-- VERIFY these on your build before trusting them.
local WIDESCREEN_FIX = 0x6D124874  -- 0 = off/4:3, non-zero = on/16:9
local FONT_OVERRIDE  = 0x6D11BD44  -- non-zero FORCES widescreen on
```

`font_override` forces widescreen on, so the render is **16:9 if EITHER byte is
non-zero, and 4:3 only when BOTH are zero**. Guard the reads and default to 16:9
so a bad read never wrongly forces 4:3 (which mis-scales everything).

> A separate heap value that flipped `640 ↔ 746` with the widescreen fix looked
> promising but was a **red herring** — it was a Chimera-internal number, not the
> render aspect (the window measured a true 16:9). Always cross-check a candidate
> value against a screenshot before wiring it in.

---

## `world_to_screen` (world → HUD coordinates)

Camera comes from the `precamera` callback (see below). `cam.fov` is the
**horizontal** FOV in radians. Derive the vertical FOV from the aspect — do **not**
reuse the horizontal FOV for both axes (that was the root cause of a "right
direction, wrong amount" vertical error).

```lua
-- render_width = 853.333 (16:9) or 640 (4:3); see aspect detection above
local aspect  = render_width / 480
local half_h  = cam.fov / 2
local half_v  = math.atan(math.tan(half_h) / aspect)

-- camera basis
local fwd   = normalize(cam.look)
local up    = normalize(cam.up)
local right = normalize(cross(fwd, up))
local tup   = cross(right, fwd)   -- NOTE: cross(right, fwd), verified. Do not flip.

local d = { wx - cam.x, wy - cam.y, wz - cam.z }
local x, y, z = dot(d, right), dot(d, tup), dot(d, fwd)
if z <= 0 then return nil end     -- behind camera

local ndc_x = (x / z) / math.tan(half_h)
local ndc_y = (y / z) / math.tan(half_v)

local half_w   = render_width * 0.375           -- 320 (16:9) or 240 (4:3)
local screen_x = half_w + ndc_x * half_w
local screen_y = 240   - ndc_y * 240            -- height is 480 in both modes
```

---

## Callback firing order — and the one-frame camera lag

Verified by logging a shared counter in both callbacks: **each frame fires
`preframe` FIRST, then `precamera`.**

Consequence: if you capture the camera in `precamera` and *draw in `preframe`*,
your draw uses the **previous** frame's camera — tags lag one frame behind camera
motion (but track player motion fine, since player positions are read fresh).

Fix: **do the projection + drawing inside `precamera`**, using the camera you were
handed that frame. `draw_text` calls issued during `precamera` *do* render.

```lua
function OnPreCamera(x, y, z, fov, ox1, oy1, oz1, ox2, oy2, oz2)
    _last_camera = { x=x, y=y, z=z, fov=fov, look={ox1,oy1,oz1}, up={ox2,oy2,oz2} }
    DrawEverything()                 -- project + draw here, with THIS frame's camera
    return x, y, z, fov, ox1, oy1, oz1, ox2, oy2, oz2   -- returning is mandatory
end
set_callback("precamera", "OnPreCamera")
```

---

## Reading players

```lua
local dyn = get_dynamic_player(id)  -- live object; nil if dead
local plr = get_player(id)          -- persistent player entry; valid while connected
```

**Name** — UTF-16, ASCII range, 12 chars, at `get_player(id) + 0x4`:

```lua
local addr, chars = plr + 0x4, {}
for i = 1, 12 do
    local b = read_byte(addr + (i-1)*2)
    if b == 0 then break end
    chars[#chars+1] = string.char(b)
end
local name = table.concat(chars)
```

**Team** — `read_byte(get_player(id) + 0x20)`. It *is* a team field (compare for
equality). The specific mapping (0 = Red, 1 = Blue) is the usual convention but
was **not independently verified** — use equality, not the numeric value, if you
can. Use it to show tags for **teammates only**.

> **On "ESP":** drawing tags for *teammates* is a HUD/QoL feature — teammate
> positions are already surfaced by the game (nav markers), so it grants no edge
> over opponents. It only becomes ESP (an unfair advantage) if you render
> **enemy** info. Keep the team filter on; reserve "ESP" for the enemy case.

---

## Biped world positions (verified)

For a **standing** (on-foot) biped:

| what             | offset (`dyn +`) | notes                                          |
| ---------------- | ---------------- | ---------------------------------------------- |
| feet / origin    | `0x5C/0x60/0x64` | the standard position; ~feet level             |
| centre / torso   | `0xA0/0xA4/0xA8` | ~0.36 above feet; lands on the auto-aim reticle |

Reference heights measured on the player biped: **feet → centre ≈ 0.36**,
**feet → eye/camera ≈ 0.62**.

### Head (and the full skeleton)

The biped carries a **skeletal node array** of per-bone WORLD translations:

- base **`0x578`**, stride **`0x34`** (52-byte node structs), ~19 position nodes
- **head = node 12 = `dyn + 0x7E8/0x7EC/0x7F0`**

Verified: node 12 was simultaneously the highest node and the closest to the eye.
This is the point headshots test against. Anchoring a tag to the head node makes it
**follow crouch/pose** (unlike a fixed `feet + height`). It is **model dependent**
(the node index/layout is per biped tag) — sanity-check the read (e.g. head must be
within ~1.5 units of the `0xA0` centre) and fall back to `feet + offset` otherwise.

---

## Vehicles

```lua
local vehicle_id = read_dword(dyn + 0x11C)   -- 0xFFFFFFFF = not in a vehicle
local seat       = read_word (dyn + 0x2F0)   -- 0 = driver, 1 = passenger, 2 = gunner (verified)
local veh        = get_object(vehicle_id)
```

Vehicle object: position at `veh + 0x5C/0x60/0x64`; orientation as **unit vectors**
`forward = veh + 0x74`, `up = veh + 0x80` (both confirmed magnitude 1).

**Critical gotcha for seated players:** a seated biped's `0x5C` is a *tiny offset
relative to the seat node*, **not** its world position — `vehicle_origin + 0x5C`
lands near the vehicle centre, not the seat. Instead read the biped's true world
position from **`0xA0`** (works standing *and* seated). This one field replaced a
whole pile of seat-marker/rotation math.

---

## Debugging technique: JSON state dump + screenshot

The single most useful tool here was a small **"DebugCore"** dumper: a console
command writes every interesting value (camera, players, per-draw log) to a JSON
file, and a watcher screenshots the game at the same instant. Comparing the logged
numbers against pixel positions in the screenshot is what made every offset/coord
finding falsifiable. Pair it with the calibration-ruler overlay for draw-space
questions.

Output path gotcha: write to a **user-owned path** (`%USERPROFILE%\Documents\...`),
never the Halo install dir — under an unelevated process Windows silently
redirects writes into `AppData\Local\VirtualStore\...` where you'll never find
them. Also avoid `os.execute` on hot paths (it spawns a real subprocess → hitches).

---

## Isolated Lua states (architecture constraint)

Each global script runs in its **own isolated Lua state** — separate global
scripts in `scripts/global/` **cannot share globals or tables** (confirmed: a table
defined in one was never visible to another). To share a framework (like a debug
dumper) across scripts you must **merge it into the same file/state**, not rely on
cross-script globals. Callbacks are also one-per-event-per-state: only one
`OnPreCamera`/`OnPreFrame`/`OnCommand` per script.

---

## Verified vs. unverified — quick summary

| item                                    | status                                  |
| --------------------------------------- | --------------------------------------- |
| `draw_text` = `(text,x,y,w,h,font,align,ARGB)` | **verified**                     |
| draw space 640 (16:9) / 480 (4:3), h=480 | **verified** (calibration ruler)       |
| `world_to_screen` recipe above          | **verified** (pixel-accurate)           |
| `preframe` fires before `precamera`     | **verified** (event log)                |
| feet `0x5C`, centre `0xA0`, head node `0x7E8` | **verified** (this biped)         |
| seat index `0x2F0`: 0/1/2 = drv/pass/gun | **verified**                           |
| vehicle orient `0x74`/`0x80`            | **verified** (unit vectors)             |
| team field `0x20`                       | verified as a team field; 0=Red mapping **assumed** |
| widescreen `0x6D124874` / font_override `0x6D11BD44` | **verified on build 1262; version dependent** |
| head node index (12) / layout          | **model dependent** — sanity-check + fallback |

---

## Thanks

Much of the baseline Chimera Lua model here — event hooks, `draw_text`,
`get_player`/`get_dynamic_player`, timers, tags, name reading — is well laid out in
Chalwk's blog, which was the starting point for a lot of this:
**[Scripting with Chimera — Client-Side Lua](https://chalwk.github.io/blog/2026/05/17/halo-scripting-with-chimera/)**.
The findings above are what I then verified/corrected/extended on my own build.
