# chimera-scripts

Client-side **Lua for retail Halo PC (Combat Evolved) via [Chimera](https://github.com/SnowyMouse/chimera)** — currently including a teammate **nametag/HUD mod**, an experimental **HRL ghost replay system**, reusable debugging tools, and empirically verified engine-reference notes.

> **Scope:** retail Halo PC only. Halo *Custom Edition* already has built-in nametags, so the nametag mod is unnecessary there. Some projection, replay, and memory findings may still apply more generally.
>
> **Memory addresses are build-specific to retail Halo PC.** Re-find and verify them before using these scripts on other builds or versions.

---

## What's in here

| File                                      | What it is                                                                          |
| ----------------------------------------- | ----------------------------------------------------------------------------------- |
| `scripts/nametags.lua`                    | **Nametag mod.** Standalone deployable script.                                      |
| `scripts/lap_limit_sync.lua`              | **Lap Limit Syncer.** Standalone deployable script.                                 |
| `scripts/ghost-replay/hrl_ghost.lua`      | Main HRL ghost replay script and command interface.                                 |
| `scripts/ghost-replay/replay_decode.lua`  | HRLREPLAY3 binary decoder.                                                          |
| `scripts/ghost-replay/ghost_playback.lua` | Client-side ghost spawning, transform playback, and animation module.               |
| `scripts/snippets/debug_core.lua`         | Reusable JSON state-dump framework designed to be pasted into another script.       |
| `scripts/snippets/tagcal.lua`             | Reusable `draw_text` calibration overlay designed to be pasted into another script. |
| `tools/halo_debug_bridge.py`              | Watches the debug dump, screenshots the game, and bundles both.                     |
| `docs/chimera-lua-reference.md`           | Verified Chimera Lua and retail Halo PC memory notes.                               |
| `docs/nametags.md`                        | Nametag architecture, findings, and open items.                                     |
| `docs/ghost-replay.md`                    | Ghost replay architecture, installation, commands, status, and limitations.         |
| `docs/hrlreplay3-format.md`               | HRLREPLAY3 header and binary format specification.                                  |

---

## Projects

### Teammate nametags

A client-side HUD/QoL mod that renders readable nametags above teammates, with temporary enemy nametags available while holding F4 for administration purposes.

Features:

* **Team-filtered** nametags — teammates are shown normally; enemy nametags require holding F4.
* **F3 visibility toggle** — press once to show nametags and again to hide them.
* **F4 hold-to-show enemy nametags** — hold F4 to temporarily reveal enemy nametags; release F4 to hide them again.
* **Persistent visibility state** — the last F3 setting is restored after restarting Halo or reloading Chimera Lua.
* **Enabled by default** on first launch, before a saved preference exists.
* **Input protection** — F3 is ignored while chat or the console is open.
* **Anchored to the biped's head node**, so tags follow crouching and animation poses.
* Works **on foot and in vehicles**, including drivers, passengers, and gunners.
* **No camera lag** — rendered during `precamera` using the current frame's camera state.
* **Automatic aspect-ratio handling** for 4:3, 16:9, 16:10, ultrawide, and other monitor shapes.
* **Standalone** — no dependency on the debug tooling.

See [`docs/nametags.md`](docs/nametags.md) for architecture, verified findings, and open work.

### HRL ghost replay

An experimental client-side replay viewer for HRLREPLAY3 recordings produced by the Halo Racing League server tooling.

Current working functionality:

* Loads `.hrlreplay3` files from Chimera's `lua\data\global` directory.
* Decodes the HRLREPLAY3 text header and compact binary sample stream.
* Spawns a client-side cyborg biped.
* Replays on-foot position and orientation.
* Applies recorded animation indices and frames using **exact animation mode**.
* Supports playback start, stop, restart, status, and animation-mode commands.
* Includes decoder, cursor, and animation regression self-tests.

Current limitations:

* Vehicle ghost spawning is not yet implemented.
* Detached-vehicle playback is not yet implemented.
* Native Halo animation advancement is unreliable for client-spawned bipeds.
* **Exact animation mode is therefore the default and recommended mode.**
* The replay scripts are still experimental and may contain build-specific assumptions.

See [`docs/ghost-replay.md`](docs/ghost-replay.md) for installation, commands, architecture, and current status.

See [`docs/hrlreplay3-format.md`](docs/hrlreplay3-format.md) for the replay format specification.

---

## Installation

Requires Chimera with:

```lua
clua_version = 2.056
```

The default retail Halo PC Chimera directory is:

```text
Documents\My Games\Halo\chimera\
```

### Teammate nametags

Copy:

```text
scripts\nametags.lua
```

to:

```text
Documents\My Games\Halo\chimera\lua\scripts\global\nametags.lua
```

Then reload Chimera Lua in the in-game console:

```text
chimera_lua_scripts_reload
```

Restarting Halo also loads the script.

Press `F3` in game to toggle teammate nametags. The selected state is saved automatically to Chimera's script data directory and inherited on the next launch.
Hold `F4` in game to temporarily show enemy nametags. Release `F4` to hide enemy nametags again. F4 does not change the saved F3 nametag visibility state.

#### Nametag configuration

Configuration is located near the top of `nametags.lua`.

* `FORCE_4_3` — leave this as `false` under normal use. Aspect handling is detected automatically. This option exists only as a fallback if the detection address breaks on another build.
* `NAMETAGS_ENABLED_BY_DEFAULT` — controls the first-launch state when no saved preference exists. It defaults to `true`.

### Lap Limit Sync

Currently PC/Retail support only

Copy:

```text
scripts\lap_limit_sync.lua
```

to:

```text
Documents\My Games\Halo\chimera\lua\scripts\global\lap_limit_sync.lua
```

Then reload Chimera Lua in the in-game console:

```text
chimera_lua_scripts_reload
```

Restarting Halo also loads the script.

When a server reports a lap limit change via an RCON message, the script detects the message and updates the client-side lap limit accordingly.

### HRL ghost replay

Copy all three files from:

```text
scripts\ghost-replay\
```

into:

```text
Documents\My Games\Halo\chimera\lua\scripts\global\
```

The resulting layout should be:

```text
lua\scripts\global\
├── hrl_ghost.lua
├── replay_decode.lua
└── ghost_playback.lua
```

Place replay files in:

```text
Documents\My Games\Halo\chimera\lua\data\global\
```

For example:

```text
lua\data\global\
└── example-run.hrlreplay3
```

Reload Chimera Lua after installing or updating the scripts:

```text
chimera_lua_scripts_reload
```

Load and start a replay using:

```text
hrl_ghost_replay_load example-run
hrl_ghost_replay_status
hrl_ghost_replay_start
```

The `.hrlreplay3` extension may be omitted from the load command.

#### Replay commands

```text
hrl_ghost_replay_load <filename[.hrlreplay3]>
hrl_ghost_replay_start
hrl_ghost_replay_stop
hrl_ghost_replay_restart
hrl_ghost_replay_status
hrl_ghost_replay_mode <exact|native|off>
```

Regression tests:

```text
hrl_ghost_replay_decoder_test
hrl_ghost_replay_cursor_test
hrl_ghost_replay_animation_test
```

All three tests should pass before investigating live playback problems.

#### Animation modes

* `exact` — reliable default. Applies the recorded base-animation index and frame directly during playback.
* `native` — experimental. Relies on Halo's native animation updater, which does not consistently advance animations for client-spawned bipeds.
* `off` — disables replay animation writes.

---

## Debugging tools

The debug framework and calibration overlay are kept separate because Chimera global scripts:

* run in isolated Lua states;
* cannot reliably share globals;
* allow only one `OnPreCamera`, `OnPreFrame`, and `OnCommand` implementation per script.

The files under `scripts/snippets/` are therefore **callback-free paste-in tools**, not standalone global scripts.

> Do **not** copy the files under `scripts/snippets/` directly into `lua\scripts\global\`. Chimera would auto-load them as separate inert scripts.

To use them with the nametag project:

1. Paste the contents of `debug_core.lua` and/or `tagcal.lua` into `nametags.lua`.
2. Uncomment the relevant wiring in the `DEBUG / CALIBRATION` block near the bottom of `nametags.lua`.

Available tools:

* `dbgdump` — writes a JSON snapshot containing camera, player, and draw-log state.
* `tagcal` — toggles the coordinate ruler and alignment-test overlay.
* `tools/halo_debug_bridge.py` — watches for dump changes, captures a screenshot, and bundles both for analysis.

The replay project also contains integrated diagnostics for animation fields, replay decoding, cursor progression, and client-spawned object behaviour.

---

## Repository layout

```text
chimera-scripts/
├── README.md
├── LICENSE
├── scripts/
│   ├── nametags.lua
│   ├── lap_limit_sync.lua
│   ├── ghost-replay/
│   │   ├── hrl_ghost.lua
│   │   ├── replay_decode.lua
│   │   └── ghost_playback.lua
│   └── snippets/
│       ├── debug_core.lua
│       └── tagcal.lua
├── tools/
│   └── halo_debug_bridge.py
└── docs/
    ├── chimera-lua-reference.md
    ├── nametags.md
    ├── ghost-replay.md
    └── hrlreplay3-format.md
```

Deployment rules:

* `scripts/nametags.lua` is copied directly into `chimera\lua\scripts\global\`.
* All files under `scripts/ghost-replay/` are copied together into `chimera\lua\scripts\global\`.
* Files under `scripts/snippets/` are pasted into another script when needed and should not be auto-loaded independently.
* `.hrlreplay3` files belong under `chimera\lua\data\global\`, not in the scripts directory.

---

## Fair play

The nametag mod displays teammate information by default.

Teammate positions are already surfaced by Halo through navigation markers, so clearer teammate labels are treated here as a HUD/QoL feature rather than an opponent-tracking advantage.

Enemy nametags can be temporarily revealed by holding F4. This is intentionally a hold-to-show function rather than a persistent toggle, so enemy information is not left enabled accidentally.

The replay system displays previously recorded runs and does not expose live opponent information.

---

## Build compatibility

The scripts and reference notes currently target retail Halo PC.

Memory addresses, object layouts, callback behaviour, and internal animation structures may differ across:

* Halo Custom Edition;
* alternate executables;
* patched releases;
* compatibility layers;
* future Chimera versions.

Treat undocumented or hardcoded memory fields as build-specific until verified against live game state.

---

## Credits

The baseline Chimera Lua model — including event hooks, `draw_text`, `get_player`, timers, tag access, and player-name reading — is well documented in **Chalwk's** article:

[Scripting with Chimera — Client-Side Lua](https://chalwk.github.io/blog/2026/05/17/halo-scripting-with-chimera/)

That work was the starting point for this repository. The findings in `docs/chimera-lua-reference.md` were then verified, corrected, and extended independently against live retail Halo PC game state.

The HRL replay format and server-side recorder originate from the Halo Racing League project. The Chimera replay scripts in this repository provide the client-side decoder and playback implementation.

---

## License

TODO — add a license before publishing.

MIT would be a reasonable default for the Lua scripts, Python tooling, and documentation, provided all incorporated code and references are compatible with that licence.
