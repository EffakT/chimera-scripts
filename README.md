# chimera-scripts

Client-side **Lua for retail Halo PC (Combat Evolved) via [Chimera](https://github.com/SnowyMouse/chimera)** — a
teammate **nametag/HUD** mod, plus two reusable drop-in debug tools and a set of
empirically-verified reference notes.

> **Scope:** retail Halo PC only. Halo *Custom Edition* already has built-in
> nametags, so the mod is unnecessary there (the projection/memory notes still
> apply generally). **Memory addresses are build-specific to retail Halo PC** —
> re-find them on other builds/versions.

---

## What's in here

| File | What it is |
| ---- | ---------- |
| `scripts/nametags.lua` | **The mod.** The only file you deploy. |
| `scripts/snippets/debug_core.lua` | Reusable JSON state-dump framework (paste-in). |
| `scripts/snippets/tagcal.lua` | Reusable `draw_text` calibration overlay (paste-in). |
| `tools/halo_debug_bridge.py` | Watches the dump file, screenshots the game, bundles both. |
| `docs/chimera-lua-reference.md` | **Verified Chimera Lua field notes — start here.** |
| `docs/nametags.md` | Project knowledge / architecture / open items. |

---

## Nametags — features

- **Teammate-only** (team filter) — a HUD/QoL aid, not enemy ESP (see *Fair play*).
- **Anchored to the biped's head node**, so tags follow crouch and pose.
- Works **on foot and in vehicles** (driver / passenger / gunner).
- **No camera lag** — drawn during `precamera` with the current frame's camera.
- **Auto-detects 4:3 vs widescreen** at runtime (any monitor aspect: 16:9 / 16:10 / ultrawide).
- **Standalone** — zero dependency on the debug tooling.

---

## Install

1. Copy `scripts/nametags.lua` into your Chimera scripts folder:
   `...\Documents\My Games\Halo\chimera\lua\scripts\global\`
2. In-game (`~` for console): `chimera_lua_scripts_reload` — or just restart Halo.

Requires Chimera (`clua_version = 2.056`).

> Do **not** put the `snippets/` files in `scripts\global\` — Chimera would
> auto-load them as inert separate scripts. They're paste-in tools (below).

### Config

Top of `nametags.lua`:

- `FORCE_4_3` — leave `false`. The 4:3/widescreen aspect is auto-detected; this
  is only a manual override in case the detection address breaks on a future build.

---

## Debugging (drop-in tools)

The debug framework and calibration overlay are kept **separate** because Chimera
global scripts run in isolated Lua states (can't share globals) and allow only one
`OnPreCamera` / `OnPreFrame` / `OnCommand` per script. So they're **callback-free
snippets** you merge in only when testing:

1. Paste the contents of `debug_core.lua` and/or `tagcal.lua` into `nametags.lua`.
2. Uncomment the wiring in the `DEBUG / CALIBRATION` block at the bottom of `nametags.lua`.

Then:
- **`dbgdump`** (console) — writes a JSON snapshot of camera/players/draw log.
- **`tagcal`** (console) — toggles a calibration overlay (coordinate ruler + alignment tests).
- **`tools/halo_debug_bridge.py`** — run it to auto-screenshot the game and bundle it with each dump.

---

## Repository layout

```
chimera-scripts/
├── README.md
├── LICENSE
├── scripts/                      # DEPLOY: copy nametags.lua into chimera\lua\scripts\global\
│   ├── nametags.lua
│   └── snippets/                 # NOT auto-loaded — paste into a script to debug
│       ├── debug_core.lua
│       └── tagcal.lua
├── tools/
│   └── halo_debug_bridge.py
└── docs/
    ├── chimera-lua-reference.md  # verified findings guide (headline doc)
    └── nametags.md               # project knowledge / architecture
```

---

## Fair play

Teammate-only nametags are a HUD/QoL feature — teammate positions are already
surfaced by the game (nav markers), so this grants no advantage over opponents.
Rendering **enemy** info would be ESP; the team filter keeps this on the fair
side. Note that some competitive rulesets ban *any* client-side overlay
regardless — check yours.

---

## Credits

The baseline Chimera Lua model (event hooks, `draw_text`, `get_player`, timers,
tags, name reading) is well laid out in **Chalwk's** blog,
[Scripting with Chimera — Client-Side Lua](https://chalwk.github.io/blog/2026/05/17/halo-scripting-with-chimera/),
which was the starting point. The findings in `docs/chimera-lua-reference.md` were
then verified, corrected, and extended independently against live game state.

## License

TODO — add a license (e.g. MIT) before publishing.