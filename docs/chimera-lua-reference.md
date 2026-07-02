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

`draw_text` coordinates are a **virtual space with a fixed height of 480**. From
the script's side the measured layout is:

| mode          | input width | centre |
| ------------- | ----------- | ------ |
| widescreen ON | **640**     | 320    |
| 4:3 (@1080p)  | **480**     | 240    |

**Why (from Chimera's `lua_draw_text` source):** it scales the x-coords you pass by
`width_scale = monitor_aspect × 0.75` (y is *not* scaled) and draws into the
widescreen HUD space. That scale exactly cancels the HUD expansion, so:

- **Widescreen fix ON → the input space is a constant `640` wide (centre `320`)
  for *any* monitor aspect** (16:9, 16:10, ultrawide). The 3D world renders at the
  monitor aspect, so only the **vertical FOV** needs that aspect.
- **Widescreen fix OFF →** native HUD is 640 (4:3), so the input centre =
  `320 / (monitor_aspect × 0.75)` (= 240 at 1080p) and the render is 4:3.

So `half_w = 320` is correct for all widescreen-on setups — *don't* derive it from
the resolution (a naive `0.375 × render_width` gives 288 at 16:10). This was
confirmed both by reading Chimera's source and by a **calibration overlay**: draw
left-aligned labels at known x and read where they land (4:3 came out a clean
2.0 px/coord, coord 480 = right edge, 240 = centre). Measure draw-space behaviour,
don't assume it.

### Getting the aspect (for vertical FOV) at runtime

There's **no Chimera Lua API for the resolution** (I dumped all globals). The
horizontal centre is the constant 320 above; the one per-monitor value you still
need is the aspect for the **vertical FOV** = the monitor aspect. Read it from the
game's **resolution struct** at a FIXED `halo.exe` address (base `0x400000`, no
ASLR — launch-stable *and* live):

```lua
-- halo.exe resolution struct (build-specific; verify on your build)
local RES_HEIGHT = 0x69C638   -- uint16, e.g. 1080   (halo.exe+0x29C638)
local RES_WIDTH  = 0x69C63A   -- uint16, e.g. 1920   (halo.exe+0x29C63A)

local function monitor_aspect()
    local w, h = read_word(RES_WIDTH), read_word(RES_HEIGHT)
    if w and h and w >= 320 and h >= 240 then return w / h end
    return 16/9
end
```

Chimera locates this struct via signature scan — pattern
`75 0A 66 A1 ?? ?? ?? ?? 66 89 42 04 83 C4 10 C3`, where the `mov ax,[<addr>]`
operand is the struct address. Re-find it that way on a new build (Cheat Engine
array-of-bytes scan with read-only memory enabled).

**Pitfall — don't read the Chimera widescreen_fix flag for the mode.** The
`widescreen_fix` / `font_override` bytes live in Chimera's injected `strings.dll`,
which **ASLR relocates every launch**, so hardcoded absolute addresses drift, read
stale 0, and get mis-detected as 4:3 (tags shift ~1.33× left). Because `half_w` is
a constant 320 for widescreen-on anyway, you don't need the flag in the normal
case; the rare 4:3-off case is a manual toggle. (The resolution struct is in
fixed-base `halo.exe`, so it has no such problem — but note it's the *monitor*
aspect, which equals the render aspect only while the fix is on.)

> A separate heap value that flipped `640 ↔ 746` with the widescreen fix looked
> promising but was a **red herring** — a Chimera-internal number, not the render
> aspect (the window measured a true 16:9). Always cross-check against a screenshot.

---

## `world_to_screen` (world → HUD coordinates)

Camera comes from the `precamera` callback (see below). `cam.fov` is the
**horizontal** FOV in radians. Derive the vertical FOV from the aspect — do **not**
reuse the horizontal FOV for both axes (that was the root cause of a "right
direction, wrong amount" vertical error).

```lua
local aspect  = monitor_aspect()  -- render aspect (see above); widescreen-on
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

local half_w   = 320                            -- constant (widescreen on, any aspect)
local screen_x = half_w + ndc_x * half_w        -- input space is 640 wide, centre 320
local screen_y = 240   - ndc_y * 240            -- height 480, y never scaled
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
| resolution struct `halo.exe+0x29C638` (h) / `+0x29C63A` (w) | **verified; fixed-base halo.exe, launch-stable** |
| widescreen bytes in Chimera `strings.dll`  | **ASLR-unstable across launches — abandoned** |
| head node index (12) / layout          | **model dependent** — sanity-check + fallback |

---

## Thanks

Much of the baseline Chimera Lua model here — event hooks, `draw_text`,
`get_player`/`get_dynamic_player`, timers, tags, name reading — is well laid out in
Chalwk's blog, which was the starting point for a lot of this:
**[Scripting with Chimera — Client-Side Lua](https://chalwk.github.io/blog/2026/05/17/halo-scripting-with-chimera/)**.
The findings above are what I then verified/corrected/extended on my own build.
