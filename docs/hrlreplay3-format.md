# HRL replay file format (`.hrlreplay3`)

Written by the reusable server-side `replay.lua` module used by HRL when replay
recording is enabled. One file is written per finished lap attempt, including
warp-discarded attempts. Laps that never finish are not written.

The current production format is:

- magic: `HRLREPLAY3`
- encoding: `delta-varint-v7`
- extension: `.hrlreplay3`
- sampling rate: normally 30 samples per second

Two playback paths now exist:

- browser playback for map/vehicle visualization;
- Chimera client-side ghost playback for retail Halo PC.

Chimera playback currently uses **exact animation mode** as the reliable default:
recorded animation indices and frames are written directly to the spawned ghost.
Native animation advancement remains experimental because client-spawned bipeds
are not consistently registered with Halo's native animation updater.

---

## Current implementation status

Working:

- HRLREPLAY3/v7 decoding;
- on-foot position and orientation playback;
- exact compact-animation playback;
- replay loading from Chimera's `lua\data\global` directory;
- decoder, playback-cursor and animation regression tests;
- browser decoding of the compact replay stream.

Recorded by the format but not yet fully wired in Chimera playback:

- vehicle ghost spawning and vehicle transforms;
- detached-vehicle ghost spawning and transforms.

Experimental:

- native animation mode.

---

## Known limitations

- Memory offsets are build-specific. Position, orientation, vehicle and animation
  fields must be re-verified before using the recorder on another Halo/SAPP build.
- A seated biped's own position may freeze. While seated, the recorder therefore
  resolves the vehicle object and records the vehicle's world transform.
- On-foot yaw and pitch come from the recorded forward/aim vector. They may show
  where the player was looking rather than movement/body direction.
- Samples are normally recorded once per server tick. Sampling gaps are represented
  by an explicit tick delta.
- Compact animation values are raw object/unit fields, not semantic animation names.
  Playback compatibility still depends on the map's biped and animation graph.
- Exact animation playback is deterministic but manually writes recorded animation
  fields. Native mode may begin or stop advancing depending on unrelated engine
  animation refreshes, such as a weapon change.
- Vehicle and detached-vehicle data are encoded, but Chimera object spawning for
  those paths is still placeholder work.

---

## File naming

Recommended current filename:

```text
<unix_time>_<sequence>_<player_hash>_<map>.hrlreplay3
```

The server recorder's replay directory must already exist unless directory creation
is handled by the host application. Player/hash/map values are sanitized before
being included in the filename or header.

For Chimera playback, copy replay files to:

```text
Documents\My Games\Halo\chimera\lua\data\global\
```

Then load by filename:

```text
hrl_ghost_replay_load <filename[.hrlreplay3]>
```

---

## File layout

The file begins with a plain-text header and ends with a variable-length binary
sample stream.

```text
HRLREPLAY3\n
encoding=delta-varint-v7\n
animation_capture=raw-biped-animation-v1\n
map=<value>\n
race_type=<0|1>\n
player_hash=<value>\n
player_name=<value>\n
lap_time=<seconds>\n
warp_discarded=<0|1>\n
vehicle=<comma-separated tag paths, may be empty>\n
tick_rate=<positive number>\n
sample_count=<N>\n
[biped_tag_path=<tag path>\n]
[animation_graph_datum=<datum>\n]
animation_fields=base_animation,base_frame,transition_frame,transition_length,state,stance\n
detached_vehicle_capture=1\n
detached_vehicle_fields=x,y,z,yaw,pitch,roll\n
--- BINARY ---\n
\n
<sample stream>
```

Both LF and CRLF header line endings are accepted by the current decoder.

### Binary boundary

There is **one blank line** between the `--- BINARY ---` sentinel and the binary
payload. In byte terms, the decoder searches for either:

```text
--- BINARY ---\n\n
```

or:

```text
--- BINARY ---\r\n\r\n
```

Binary data begins immediately after that complete marker. This differs from older
format documentation that described only one newline after the sentinel.

### Required header fields

The current Chimera decoder requires:

- magic exactly `HRLREPLAY3`;
- `encoding=delta-varint-v7`;
- a positive numeric `tick_rate`;
- a non-negative numeric `sample_count`.

Other known fields are parsed when present. Unknown header fields can be ignored by
forward-compatible consumers.

---

## Quantization and decoder state

The v7 stream is stateful. Before the first record, the decoder state is:

```text
tick = -1
x = y = z = 0
yaw = pitch = roll = 0
vehicle_turn = tire_position = 0
checkpoint = 0
animation fields = 0
detached transform = 0, inactive
```

Current scales:

- position: `100` integer units per world unit;
- angles: `1000` integer units per radian;
- vehicle turn/tire position: `1000` integer units per recorded value.

Values are quantized before deltas are calculated, so quantization error does not
accumulate across the replay.

Yaw deltas use the shortest route across the `-π`/`π` boundary for both the primary
object and detached vehicle.

Unsigned integers use base-128 varints. Signed deltas use ZigZag encoding:

```text
0 -> 0
-1 -> 1
1 -> 2
-2 -> 3
2 -> 4
...
```

---

## HRLREPLAY3/v7 sample record

Every record begins with one control byte.

| Bit | Mask | Meaning |
| ---: | ---: | --- |
| 0 | `0x01` | Player is in a vehicle. Two vehicle-dynamics deltas are present. |
| 1 | `0x02` | Checkpoint changed. An unsigned checkpoint ID follows. |
| 2 | `0x04` | Tick delta is explicit. An unsigned positive varint follows the control byte. |
| 3 | `0x08` | Compact animation payload is present. |
| 4 | `0x10` | Detached-vehicle update. Six transform deltas are present. |
| 5 | `0x20` | Detached-vehicle clear. No detached payload follows; its state resets. |
| 6–7 | `0xC0` | Reserved; must be zero. |

Bits 4 and 5 are mutually exclusive. A decoder should reject a record that sets
both.

### Record field order

Fields appear in this exact order:

1. control byte;
2. optional unsigned tick delta when bit 2 is set; otherwise tick delta is `1`;
3. six signed ZigZag deltas, always present:
   - X;
   - Y;
   - Z;
   - yaw;
   - pitch;
   - roll;
4. when bit 0 is set, two signed ZigZag deltas:
   - vehicle turn;
   - tire position;
5. when bit 1 is set, unsigned checkpoint ID;
6. when bit 3 is set, compact animation block;
7. when bit 4 is set, six detached-vehicle transform deltas;
8. bit 5 carries no payload and clears detached-vehicle state.

There is no fixed sample size and no separator between records. Decode exactly
`sample_count` records, then require the binary payload to be fully consumed.
Trailing bytes indicate a format mismatch or corrupt file.

---

## Compact animation block

When control bit 3 is set, one animation-mask byte follows.

| Bit | Mask | Field |
| ---: | ---: | --- |
| 0 | `0x01` | base animation index (`object + 0xD0`) |
| 1 | `0x02` | base animation frame (`object + 0xD2`) |
| 2 | `0x04` | transition frame (`object + 0xD4`) |
| 3 | `0x08` | transition length (`object + 0xD6`) |
| 4 | `0x10` | unit animation state (`unit + 0x2A3`) |
| 5 | `0x20` | unit stance (`unit + 0x2A0`) |
| 6–7 | `0xC0` | reserved; must be zero |

A zero animation mask is invalid when control bit 3 is set.

For each selected bit, one signed ZigZag delta follows in ascending bit order.
Unselected fields retain their previous decoded values. If no animation field
changed, the recorder omits the entire animation block and leaves control bit 3
clear.

Vehicle samples normally omit on-foot animation updates, preserving the previous
animation state until another animation event is recorded.

### Playback modes

`exact` mode is the production default. It applies the recorded base animation and
frame during playback, making animation deterministic for the current replay.

`native` mode writes animation state less frequently and expects Halo to advance the
spawned biped naturally. It is currently experimental because client-spawned bipeds
can fail to enter or remain in the engine's native animation update path.

---

## Vehicle fields

When control bit 0 is set, vehicle turn and tire-position deltas follow the primary
transform deltas. Their running state is retained between vehicle samples.

When bit 0 is clear, those two values are not encoded in the record. Consumers may
expose zero for the current on-foot sample while retaining the internal delta
baseline for a later vehicle sample.

The header's `vehicle` field is a lap-level list of distinct vehicle tag paths. It
is not a per-sample occupancy field; occupancy is control bit 0.

---

## Detached-vehicle events

V7 can continue recording the transform of a vehicle after the player exits it.
This is separate from the primary player/vehicle transform.

### Update: control bit 4

Six signed ZigZag deltas follow:

1. X;
2. Y;
3. Z;
4. yaw;
5. pitch;
6. roll.

The decoder accumulates them into a detached-vehicle transform and marks the
vehicle active.

### Clear: control bit 5

No payload follows. The decoder:

- marks the detached vehicle inactive;
- resets all six detached transform values to zero;
- resets the detached delta baseline.

A clear is emitted when tracking ends, such as re-entering the same vehicle,
entering a different vehicle, or the detached object disappearing.

The format records these events, but Chimera detached-vehicle spawning/playback is
not yet implemented.

---

## Checkpoints and timing

The first implicit tick delta advances decoder tick `-1` to tick `0`. Therefore a
normal first sample appears at tick zero without requiring an explicit tick field.

For each decoded sample:

```text
seconds = tick / tick_rate
```

Checkpoint ID persists until control bit 1 supplies a replacement. A value of zero
means no checkpoint has yet been reached.

---

## Validation requirements

A strict v7 decoder should reject:

- wrong magic or encoding;
- missing binary marker/blank-line boundary;
- invalid `tick_rate` or `sample_count`;
- truncated control bytes or varints;
- explicit tick deltas of zero;
- reserved control bits 6–7;
- detached update and clear bits set together;
- zero animation mask with animation control bit set;
- reserved animation-mask bits 6–7;
- fewer than `sample_count` records;
- trailing bytes after exactly `sample_count` records.

The current Lua decoder includes regression tests for the main record paths,
including tick handling, animation persistence, stance bit 5, vehicle alignment,
detached update/clear, malformed control combinations, truncated varints, LF/CRLF
headers and tick-rate-derived sample time.

---

## Chimera playback files

The client-side implementation consists of:

```text
hrl_ghost.lua
replay_decode.lua
ghost_playback.lua
```

Install all three under:

```text
Documents\My Games\Halo\chimera\lua\scripts\global\
```

Replay data belongs under:

```text
Documents\My Games\Halo\chimera\lua\data\global\
```

Useful commands:

```text
hrl_ghost_replay_load <filename[.hrlreplay3]>
hrl_ghost_replay_status
hrl_ghost_replay_start
hrl_ghost_replay_stop
hrl_ghost_replay_restart
hrl_ghost_replay_mode <exact|native|off>

hrl_ghost_replay_decoder_test
hrl_ghost_replay_cursor_test
hrl_ghost_replay_animation_test
```

---

## Previous formats

Older files may use:

- `HRLREPLAY1`: fixed-size legacy binary records;
- `HRLREPLAY2`: compact delta-varint encodings v1–v5;
- `.hrlreplay` rather than `.hrlreplay3`.

Those versions remain relevant to the browser player's compatibility decoder, but
they are not accepted by the current strict Chimera `replay_decode.lua`, which
requires `HRLREPLAY3` with `delta-varint-v7`.

The older HRLREPLAY1 24-byte layout was:

| Bytes | Field | Type |
| ---: | --- | --- |
| 0–1 | tick | `uint16` |
| 2–5 | X | `float32` |
| 6–9 | Y | `float32` |
| 10–13 | Z | `float32` |
| 14–17 | yaw | `float32` |
| 18–21 | pitch | `float32` |
| 22 | flags | `uint8` |
| 23 | checkpoint ID | `uint8` |

Some still older v1 files used 20- or 19-byte records. Consumers supporting those
files must branch on the historical `sample_size` header rather than assuming 24
bytes.
