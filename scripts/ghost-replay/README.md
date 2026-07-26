# HRL Ghost Replay

## Status

Working:

- HRLREPLAY3 decoding
- On-foot position and orientation playback
- Exact animation playback
- Replay loading from `lua\data\global`
- Decoder regression tests
- Cursor regression tests
- Animation regression tests

Experimental:

- Native animation mode

Not implemented:

- Vehicle ghost spawning
- Detached vehicle playback

## Installation

Copy all three files from `scripts/ghost-replay/` into:

`Documents\My Games\Halo\chimera\lua\scripts\global\`

Place `.hrlreplay3` files into:

`Documents\My Games\Halo\chimera\lua\data\global\`

## Commands

- `hrl_ghost_replay_load <filename>`
- `hrl_ghost_replay_start`
- `hrl_ghost_replay_stop`
- `hrl_ghost_replay_restart`
- `hrl_ghost_replay_status`
- `hrl_ghost_replay_mode <exact|native|off>`

## Tests

- `hrl_ghost_replay_decoder_test`
- `hrl_ghost_replay_cursor_test`
- `hrl_ghost_replay_animation_test`

## Animation modes

### Exact

The reliable default. Recorded base-animation and frame values are applied
directly during playback.

### Native

Experimental. Halo does not consistently advance native animations for
client-spawned bipeds unless they are correctly registered with the engine's
animation update structures.