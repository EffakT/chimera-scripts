-- HRL Ghost Playback — client-side Chimera Lua module.
--
-- Loads a decoded replay, spawns a biped ghost, and drives position/orientation
-- + native animation per tick during racing laps.
--
-- Install: lua/scripts/global/ghost_playback.lua under Chimera's global scripts.

clua_version = 2.056

local GhostPlayback = {}

-- ============================================================
-- Constants — match hrl_ghost.lua proven values.
-- ============================================================
local BIPED_CLASS     = "bipd"
local BIPED_TAG       = "characters\\cyborg_mp\\cyborg_mp"

local POSITION_OFFSET = 0x5C
local VELOCITY_OFFSET = 0x68
local OBJECT_FORWARD_OFFSET = 0x74
local OBJECT_UP_OFFSET = 0x80

-- Animation offsets (mirrored from hrl_ghost.lua).
local ANIMATION_TAG_OFFSET    = 0xCC
local BASE_ANIMATION_OFFSET   = 0xD0
local BASE_FRAME_OFFSET       = 0xD2
local TRANSITION_FRAME_OFFSET = 0xD4
local TRANSITION_LENGTH_OFFSET= 0xD6
local ANIMATION_STANCE_OFFSET = 0x2A0
local ANIMATION_STATE_OFFSET  = 0x2A3

-- Unit aim/facing offsets.
local UNIT_FACING_OFFSET      = 0x224
local UNIT_DESIRED_AIM_OFFSET = 0x230
local UNIT_AIM_OFFSET         = 0x23C

-- ============================================================
-- Math helpers.
-- ============================================================
local function angle_lerp(a, b, alpha)
    local tau = math.pi * 2
    local diff = (b - a + math.pi) % tau - math.pi
    return a + diff * alpha
end

-- ============================================================
-- Logging helper.
-- ============================================================
local function format_hex32(value)
    local number = tonumber(value)
    if not number then
        return tostring(value or "(nil)")
    end

    -- Lua 5.3+ requires an actual integer for %X. Chimera APIs may expose
    -- integral IDs/pointers using the floating-number representation.
    local integer = math.tointeger and math.tointeger(number) or nil
    if not integer and number == math.floor(number) then
        integer = math.floor(number)
    end

    if not integer then
        return tostring(number)
    end

    -- Normalize signed values to their unsigned 32-bit representation.
    if integer < 0 then
        integer = integer + 0x100000000
    end

    return string.format("0x%08X", integer)
end

local function dbg(self, fmt, ...)
    if not self.log_enabled then return end
    local msg = string.format(fmt, ...)
    if type(console_out) == "function" then
        console_out("[GhostPlayback] " .. msg, 0.5, 0.8, 1.0)
    else
        print(msg)
    end
end

local function log(self, fmt, ...)
    dbg(self, fmt, ...)
end

-- ============================================================
-- Playback state constructor.
-- Cursor fields use numeric indices as authoritative; sample references kept for convenience.
-- last_base_animation is NOT reset to -1 after apply_sample_events — the write records it there.
-- ============================================================
local function new_playback()
    local self = {
        -- Configuration.
        animation_mode  = "native",   -- "native" | "exact" | "off"
        apply_transition= false,       -- optional: write D4/D6 (experimental)
        apply_state     = false,       -- optional: write +0x2A3 (experimental)
        apply_stance    = false,       -- optional: write +0x2A0  (experimental)

        -- Loaded data.
        replay          = nil,
        filename        = nil,
        loaded          = false,

        -- Playback cursor / timing — numeric indices authoritative.
        playing         = false,
        start_tick      = 0,
        current_sample_index = nil,
        next_sample_index      = nil,
        current_sample  = nil,     -- latest past sample (used for transform)
        next_sample     = nil,     -- first future sample (for interpolation)
        last_applied_sample = nil,

        -- Animation tracking — native mode only.
        -- Initialized to -1 so the first forced write in apply_animation is recognized as a change.
        -- This field is NOT reset after applying sample zero events; start() relies on that.
        last_base_animation   = -1,

        -- Spawned objects.
        biped_object_id     = nil,
        biped_pointer       = nil,
        vehicle_object_id   = nil,
        detached_object_id  = nil,

        -- Callback hooks.
        on_sample_crossed = nil,
        on_playback_end   = nil,
        on_biped_spawn    = nil,
        on_error          = nil,

        log_enabled       = true,
        interpolate       = false,
    }
    return self
end

-- ============================================================
-- Load an already-decoded replay object.
-- hrl_ghost.lua owns file-reading and decoding; this module receives the table directly.
-- Returns (ok, err).
-- ============================================================
function GhostPlayback.load(self, replay, filename)
    if type(replay) ~= "table" or not replay.samples then
        return nil, "expected a decoded replay table with .samples field"
    end

    self:stop() -- clear runtime state but keep loaded data until reset

    self.replay         = replay
    self.filename       = filename
    self.loaded         = true
    self.biped_object_id     = nil
    self.biped_pointer       = nil
    self.vehicle_object_id   = nil
    self.detached_object_id  = nil
    self.current_sample_index = nil
    self.next_sample_index      = nil
    self.current_sample  = nil
    self.next_sample     = nil
    self.last_applied_sample = nil

    log(self, "Loaded %d samples (%.2fs) from %s", #replay.samples, replay.duration, filename or "<decoded>")
    return true
end

-- ============================================================
-- Spawn the ghost biped at sample 1's position/orientation.
-- Returns (ok, err).
-- ============================================================
function GhostPlayback.spawn_biped(self, sample)
    if not sample then
        return nil, "no sample provided"
    end

    self:cleanup_objects()

    local object_id = spawn_object(BIPED_CLASS, BIPED_TAG, sample.x, sample.y, sample.z)
    if not object_id then
        return nil, "spawn_object failed"
    end

    local pointer = get_object and get_object(object_id)
    if not pointer or pointer == 0 then
        pcall(delete_object, object_id)
        return nil, "spawned biped has no pointer"
    end

    self.biped_object_id = object_id
    self.biped_pointer   = pointer

    -- Give the client-side ghost the same animation graph context as the
    -- local player. Exact mode then drives D0/D2 from the replay.
    local player = get_dynamic_player and get_dynamic_player()
    if player and player ~= 0 then
        write_dword(
            pointer + ANIMATION_TAG_OFFSET,
            read_dword(player + ANIMATION_TAG_OFFSET)
        )
    end

    -- last_base_animation intentionally NOT reset here; start() sets it after applying sample-zero events.

    if type(self.on_biped_spawn) == "function" then
        pcall(self.on_biped_spawn, pointer)
    end

    log(
        self,
        "Spawned ghost biped id=%s ptr=%s",
        format_hex32(object_id),
        format_hex32(pointer)
    )
    return true
end

-- ============================================================
-- Delete all spawned objects. Idempotent.
-- ============================================================
function GhostPlayback.cleanup_objects(self)
    if self.biped_object_id then
        pcall(delete_object, self.biped_object_id)
        self.biped_object_id = nil
    end
    self.biped_pointer = nil

    if self.vehicle_object_id then
        pcall(delete_object, self.vehicle_object_id)
        self.vehicle_object_id = nil
    end

    if self.detached_object_id then
        pcall(delete_object, self.detached_object_id)
        self.detached_object_id = nil
    end
end

-- ============================================================
-- Write sample transform to the biped object.
-- Uses proven forward/up vector computation from hrl_ghost.lua.
-- Returns true on success. NO animation logic lives here.
-- ============================================================
function GhostPlayback.apply_transform(self, pointer, sample)
    if not pointer or not sample then return false end

    write_float(pointer + POSITION_OFFSET,          sample.x)
    write_float(pointer + POSITION_OFFSET + 4,      sample.y)
    write_float(pointer + POSITION_OFFSET + 8,      sample.z)

    write_float(pointer + VELOCITY_OFFSET,         0)
    write_float(pointer + VELOCITY_OFFSET + 4,     0)
    write_float(pointer + VELOCITY_OFFSET + 8,     0)

    local cy = math.cos(sample.yaw)
    local sy = math.sin(sample.yaw)
    local cp = math.cos(sample.pitch or 0)
    local sp = math.sin(sample.pitch or 0)
    local cr = math.cos(sample.roll or 0)
    local sr = math.sin(sample.roll or 0)

    -- Forward vector.
    local fx = cp * cy
    local fy = cp * sy
    local fz = sp

    -- Up vector rotated by roll around forward axis.
    local rx = -sy
    local ry = cy
    local rz = 0

    local base_up_x = -sp * cy
    local base_up_y = -sp * sy
    local base_up_z = cp

    local ux = base_up_x * cr + rx * sr
    local uy = base_up_y * cr + ry * sr
    local uz = base_up_z * cr + rz * sr

    write_float(pointer + OBJECT_FORWARD_OFFSET, fx)
    write_float(pointer + OBJECT_FORWARD_OFFSET + 4, fy)
    write_float(pointer + OBJECT_FORWARD_OFFSET + 8, fz)

    write_float(pointer + OBJECT_UP_OFFSET, ux)
    write_float(pointer + OBJECT_UP_OFFSET + 4, uy)
    write_float(pointer + OBJECT_UP_OFFSET + 8, uz)

    -- Keep unit aim/facing coherent for the native animation selector.
    for _, off in ipairs({ UNIT_FACING_OFFSET, UNIT_DESIRED_AIM_OFFSET, UNIT_AIM_OFFSET }) do
        write_float(pointer + off, fx)
        write_float(pointer + off + 4, fy)
        write_float(pointer + off + 8, fz)
    end

    return true
end

-- ============================================================
-- Apply native biped animation to the ghost.
-- Exclusive branches per mode: "native", "exact", or "off".
-- In native mode, only writes D0/D2 when base_animation changes
-- or on explicit force request (spawn / restart / seek).
-- Returns true if a write occurred.
-- ============================================================
function GhostPlayback.apply_animation(self, pointer, sample, force)
    if not pointer or not sample or not sample.animation then return false end

    local anim = sample.animation
    local new_index = anim.base_animation or 0

    -- Off mode: write nothing.
    if self.animation_mode == "off" then
        return false
    end

    local wrote = false

    -- Native mode: only on change or forced request.
    if self.animation_mode == "native" then
        if force or new_index ~= self.last_base_animation then
            write_word(pointer + BASE_ANIMATION_OFFSET,   new_index)
            write_word(pointer + BASE_FRAME_OFFSET,       anim.base_frame or 0)
            self.last_base_animation = new_index
            wrote = true
        end
    elseif self.animation_mode == "exact" then
        -- Exact mode: always write current sample (diagnostic).
        write_word(pointer + BASE_ANIMATION_OFFSET,   new_index)
        write_word(pointer + BASE_FRAME_OFFSET,       anim.base_frame or 0)
        self.last_base_animation = new_index
        wrote = true
    else
        return false
    end

    -- Optional experimental fields should only accompany an actual animation application.
    if wrote and self.apply_transition then
        write_word(pointer + TRANSITION_FRAME_OFFSET, anim.transition_frame or 0)
        write_word(pointer + TRANSITION_LENGTH_OFFSET,anim.transition_length or 0)
    end
    if wrote and self.apply_state then
        write_byte(pointer + ANIMATION_STATE_OFFSET, anim.state or 0)
    end
    if wrote and self.apply_stance then
        write_byte(pointer + ANIMATION_STANCE_OFFSET, anim.stance or 4)
    end

    return wrote
end

-- ============================================================
-- Vehicle handling — PLACEHOLDERS. Tag-based spawning not yet wired.
-- These functions exist to structure the event handler but do not
-- actually spawn vehicles until tag resolution is implemented.
-- ============================================================
function GhostPlayback.spawn_vehicle_for_sample(self, sample)
    if not sample or not sample.in_vehicle then return nil end
    dbg(self, "Vehicle spawning requested at tick %.0f — not yet implemented", sample.tick)
    return nil -- placeholder
end

function GhostPlayback.update_vehicle_transform(self, pointer, sample)
    if not pointer or not sample then return false end
    write_float(pointer + POSITION_OFFSET,          sample.x)
    write_float(pointer + POSITION_OFFSET + 4,      sample.y)
    write_float(pointer + POSITION_OFFSET + 8,      sample.z)

    local cy = math.cos(sample.yaw)
    local sy = math.sin(sample.yaw)
    local cp = math.cos(sample.pitch or 0)
    local sp = math.sin(sample.pitch or 0)
    local fx = cp * cy; local fy = cp * sy; local fz = sp
    write_float(pointer + OBJECT_FORWARD_OFFSET, fx)
    write_float(pointer + OBJECT_FORWARD_OFFSET + 4, fy)
    write_float(pointer + OBJECT_FORWARD_OFFSET + 8, fz)

    return true
end

function GhostPlayback.clear_vehicle(self)
    if self.vehicle_object_id then
        pcall(delete_object, self.vehicle_object_id)
        self.vehicle_object_id = nil
    end
    dbg(self, "Cleared vehicle ghost")
end

-- Detached-vehicle update: PLACEHOLDER. Tag-based spawning not yet wired.
function GhostPlayback.update_detached_vehicle(self, sample)
    if not sample or not sample.detached or not sample.detached.active then return end
    dbg(self, "Detached vehicle at tick %.0f — not yet implemented", sample.tick)
end

function GhostPlayback.clear_detached_vehicle(self)
    if self.detached_object_id then
        pcall(delete_object, self.detached_object_id)
        self.detached_object_id = nil
    end
    dbg(self, "Cleared detached vehicle ghost")
end

-- ============================================================
-- Apply events for a crossed sample. Separated from transform application.
-- The `initial` flag controls whether D2 is written in native mode:
--   initial=true  → write D0/D2 (used for sample-zero at start)
--   initial=false → only write if base_animation changed since last write
-- Returns true if any event was applied.
-- ============================================================
function GhostPlayback.apply_sample_events(self, sample, initial)
    if not sample or not self.biped_pointer then return false end

    local anim = sample.animation
    local base_changed = (anim and (anim.base_animation or 0)) ~= self.last_base_animation
    local any_event = false

    -- Animation: apply based on mode and whether D0 changed.
    if self.animation_mode == "native" then
        if initial or base_changed then
            if self:apply_animation(self.biped_pointer, sample, initial == true) then
                any_event = true
            end
        end
    elseif self.animation_mode == "exact" then
        -- In exact mode, apply every tick for diagnostic comparison.
        if self:apply_animation(self.biped_pointer, sample, initial == true) then
            any_event = true
        end
    end

    -- Vehicle transitions.
    if sample.in_vehicle and not self.vehicle_object_id then
        local vobj = self:spawn_vehicle_for_sample(sample)
        if vobj then
            self.vehicle_object_id = vobj
            any_event = true
        end
    elseif not sample.in_vehicle and self.vehicle_object_id then
        self:clear_vehicle()
        any_event = true
    end

    -- Detached vehicle events.
    if sample.detached_event == "update" then
        self:update_detached_vehicle(sample)
        any_event = true
    elseif sample.detached_event == "clear" then
        self:clear_detached_vehicle()
        any_event = true
    end

    -- Notify host of crossed event.
    if any_event and type(self.on_sample_crossed) == "function" then
        pcall(self.on_sample_crossed, sample)
    end

    return any_event
end

-- ============================================================
-- Initialize cursor state for a loaded replay without spawning objects.
-- Used by start() and pure-Lua self-tests.
-- Returns (ok, err).
-- ============================================================
function GhostPlayback.initialize_cursor(self)
    if not self.replay or not self.replay.samples then
        return nil, "no replay loaded"
    end

    local samples = self.replay.samples
    local count = #samples

    if count == 0 then
        return nil, "replay contains no samples"
    end

    self.current_sample_index = 1
    self.current_sample       = samples[1]

    if count >= 2 then
        self.next_sample_index = 2
        self.next_sample       = samples[2]
    else
        self.next_sample_index = nil
        self.next_sample       = nil
    end

    self.last_applied_sample = nil

    return true
end

-- ============================================================
-- Advance cursor past all newly crossed future samples.
-- Returns the list of crossed samples (may be empty). Does not apply events.
-- This is a pure cursor-advancement helper — no object or animation logic here.
-- ============================================================
function GhostPlayback.advance_cursor(self, elapsed_tick)
    if not self.replay then
        return nil, "no replay loaded"
    end

    local samples = self.replay.samples
    local count = #samples
    local crossed = {}

    while self.next_sample_index
        and self.next_sample_index <= count
        and samples[self.next_sample_index].tick <= elapsed_tick
    do
        local sample = samples[self.next_sample_index]

        self.current_sample_index = self.next_sample_index
        self.current_sample       = sample
        crossed[#crossed + 1]     = sample

        -- Move next forward by one.
        local following_idx = self.next_sample_index + 1
        if following_idx <= count then
            self.next_sample_index = following_idx
            self.next_sample       = samples[following_idx]
        else
            self.next_sample_index = nil
            self.next_sample       = nil
        end
    end

    return crossed
end

-- ============================================================
-- Start playback from tick 0 of the loaded replay.
-- `current_tick` is the local client tick when lap starts.
-- Returns (ok, err).
--
-- Sequence: spawn biped → initialize cursor → apply sample-zero events once → apply transform.
-- last_base_animation is set by apply_sample_events (via apply_animation) — NOT reset afterwards.
-- ============================================================
function GhostPlayback.start(self, current_tick)
    if not self.loaded or not self.replay then
        return nil, "no replay loaded; call load() first"
    end

    local samples = self.replay.samples
    local count = #samples

    if count == 0 then
        return nil, "replay has no samples to start from"
    end

    -- Spawn biped at the first sample.
    local ok, spawn_err = self:spawn_biped(samples[1])
    if not ok then
        return nil, "failed to spawn ghost biped: " .. tostring(spawn_err)
    end

    -- Initialize cursor state (numeric indices authoritative).
    local cursor_ok, cursor_err = self:initialize_cursor()
    if not cursor_ok then
        self:cleanup_objects()
        return nil, cursor_err
    end

    -- Apply sample-zero events exactly once. This writes D0/D2 in native mode
    -- and sets last_base_animation to samples[1].base_animation. We intentionally
    -- do NOT reset last_base_animation afterwards — that is the whole point of
    -- native mode: subsequent same-D0 samples must no-op.
    self:apply_sample_events(samples[1], true)
    self.last_applied_sample = samples[1]

    -- Apply initial transform immediately so the ghost appears at sample 0.
    if self.biped_pointer then
        self:apply_transform(self.biped_pointer, samples[1])
    end

    self.start_tick   = current_tick or 0
    self.playing      = true
    -- last_base_animation is now set correctly by apply_sample_events → apply_animation; do NOT reset.

    log(self, "Started playback at client tick %.0f; %d samples total", current_tick or 0, count)
    return true
end

-- ============================================================
-- Pause playback — retains all spawned objects for later resume/restart.
-- ============================================================
function GhostPlayback.pause(self)
    self.playing = false
    log(self, "Paused")
end

-- ============================================================
-- Stop playback — delete ALL spawned objects. Cursor state is cleared.
-- last_base_animation is reset so a future start() begins fresh.
-- ============================================================
function GhostPlayback.stop(self, message)
    self.playing = false
    if message then log(self, "Stopped: %s", tostring(message)) end
    self:cleanup_objects()

    -- Clear cursor runtime state and animation tracking for clean restart.
    self.current_sample_index  = nil
    self.next_sample_index     = nil
    self.current_sample        = nil
    self.next_sample           = nil
    self.last_applied_sample   = nil
    self.last_base_animation   = -1
end

-- ============================================================
-- Full reset — clears everything including spawned objects and loaded replay.
-- ============================================================
function GhostPlayback.reset(self)
    self:stop("reset")
    self.replay         = nil
    self.filename       = nil
    self.loaded         = false
end

-- ============================================================
-- Unload — full teardown. Called on map change / script unload.
-- ============================================================
function GhostPlayback.unload(self)
    self:stop("unloaded")
    self.replay         = nil
    self.filename       = nil
    self.loaded         = false
    log(self, "Unloaded")
end

-- ============================================================
-- Per-tick update. Returns (ok, err).
--
-- Update sequence (strictly separated):
--   1. advance cursor → get crossed samples list
--   2. apply events for every crossed sample (animation + vehicle/detached)
--   3. apply current/interpolated transform (NO animation logic here)
--   4. check playback completion
-- ============================================================
function GhostPlayback.update(self, current_client_tick)
    if not self.playing or not self.replay then return false end

    local elapsed_tick = current_client_tick - self.start_tick
    if elapsed_tick < 0 then elapsed_tick = 0 end

    local samples = self.replay.samples
    local count = #samples

    -- Step 1: advance cursor.
    local crossed, cursor_err = self:advance_cursor(elapsed_tick)
    if not crossed then
        dbg(self, "Cursor advancement failed: %s", tostring(cursor_err))
        return false
    end

    -- Step 2: apply events for every crossed sample.
    for _, sample in ipairs(crossed) do
        self:apply_sample_events(sample, false)
        self.last_applied_sample = sample
    end

    -- Step 3: apply transform from latest past sample (NO animation logic here).
    local current = self.current_sample

    if current and self.biped_pointer then
        -- Development invariant check.
        if current.tick > elapsed_tick then
            dbg(self, "INVARIANT VIOLATION: current_sample.tick (%.0f) > elapsed_tick (%.0f)",
                current.tick, elapsed_tick)
        end

        if self.interpolate and self.next_sample
            and self.next_sample.tick > current.tick
        then
            -- Interpolate between current → next using a temporary transform table.
            local next = self.next_sample
            local num = elapsed_tick - current.tick
            local den = next.tick - current.tick
            local alpha = 0
            if den > 0 then
                alpha = math.max(0, math.min(1, num / den))
            end

            -- Create temporary interpolated sample.
            local ix = current.x + (next.x - current.x) * alpha
            local iy = current.y + (next.y - current.y) * alpha
            local iz = current.z + (next.z - current.z) * alpha
            local iyaw = angle_lerp(current.yaw, next.yaw, alpha)
            local ipitch = (current.pitch or 0) + ((next.pitch or 0) - (current.pitch or 0)) * alpha
            local iroll = angle_lerp(current.roll or 0, next.roll or 0, alpha)

            local interp_sample = {
                x = ix, y = iy, z = iz,
                yaw = iyaw, pitch = ipitch, roll = iroll,
            }

            self:apply_transform(self.biped_pointer, interp_sample)
        else
            -- No interpolation: apply transform directly from current sample.
            self:apply_transform(self.biped_pointer, current)
        end
    end

    -- Step 4: check playback completion.
    if elapsed_tick > (self.replay.final_tick or 0) then
        self:stop("replay complete")

        if type(self.on_playback_end) == "function" then
            pcall(self.on_playback_end)
        end

        return false
    end

    return true
end

-- ============================================================
-- Lap integration hooks.
-- ============================================================
function GhostPlayback.on_lap_start(self, current_client_tick)
    if not self.loaded then return nil, "no replay loaded" end
    return self:start(current_client_tick)
end

function GhostPlayback.on_lap_restart(self, current_client_tick)
    self:stop("lap restart")
    return self:start(current_client_tick)
end

function GhostPlayback.on_lap_end(self)
    self:stop("lap ended")
end

-- ============================================================
-- Status query. Vehicle/detached explicitly marked as not implemented.
-- ============================================================
function GhostPlayback.status(self)
    return {
        loaded              = self.loaded,
        playing             = self.playing,
        mode                = self.animation_mode,
        filename            = self.filename,
        sample_count        = (self.replay and #self.replay.samples) or 0,
        duration            = (self.replay and self.replay.duration) or 0,
        start_tick          = self.start_tick,
        current_sample_tick = self.current_sample and self.current_sample.tick or nil,
        next_sample_tick    = self.next_sample and self.next_sample.tick or nil,
        biped_id            = self.biped_object_id,
        vehicle_id          = self.vehicle_object_id,
        detached_id         = self.detached_object_id,
        vehicle_playback_wired     = false, -- not yet implemented
        detached_playback_wired    = false, -- not yet implemented
    }
end

-- ============================================================
-- Constructor.
-- ============================================================
function GhostPlayback.new(config)
    config = config or {}

    local self = new_playback()

    setmetatable(self, {
        __index = GhostPlayback,
    })

    self.animation_mode = config.animation_mode or "exact"
    self.apply_transition = config.apply_transition or false
    self.apply_state = config.apply_state or false
    self.apply_stance = config.apply_stance or false
    self.log_enabled = config.debug_log ~= false
    self.interpolate = config.interpolate or false

    return self
end

-- ============================================================
-- Cursor regression self-test. Pure-Lua, no Halo objects required.
-- Verifies cursor selection logic using advance_cursor() on a sparse fixture.
-- ============================================================
function GhostPlayback.cursor_self_test()
    local passed = 0
    local failed = 0
    local errors = {}

    -- Fixture: sparse tick samples [0, 2, 4].
    local fixture_replay = {
        header = { tick_rate = 30 },
        samples = {
            { tick = 0 },
            { tick = 2 },
            { tick = 4 },
        },
        final_tick = 4,
        duration = 4 / 30,
    }

    local function check(name, condition, msg)
        if condition then
            passed = passed + 1
        else
            failed = failed + 1
            errors[#errors + 1] = string.format("FAIL [%s]: %s", name, msg or "")
        end
    end

    -- Drive cursor through elapsed ticks [0..5].
    local test_cases = {
        { elapsed = 0, exp_cur_tick = 0, exp_next_tick = 2 },
        { elapsed = 1, exp_cur_tick = 0, exp_next_tick = 2 },
        { elapsed = 2, exp_cur_tick = 2, exp_next_tick = 4 },
        { elapsed = 3, exp_cur_tick = 2, exp_next_tick = 4 },
        { elapsed = 4, exp_cur_tick = 4, exp_next_tick = nil }, -- past last sample
    }

    for _, tc in ipairs(test_cases) do
        local pb = GhostPlayback.new({ animation_mode = "native", debug_log = false })

        local load_ok, load_err = pb:load(fixture_replay, "<cursor-test>")
        check("load_elapsed_" .. tostring(tc.elapsed), load_ok == true, load_err or "")
        if not load_ok then goto continue_end end

        local cursor_ok, cursor_err = pb:initialize_cursor()
        check("cursor_init_elapsed_" .. tostring(tc.elapsed), cursor_ok == true, cursor_err or "")
        if not cursor_ok then goto continue_end end

        pb.start_tick = 0
        pb.playing    = true

        -- Call advance_cursor directly — pure cursor advancement, no object logic.
        local crossed, adv_err = pb:advance_cursor(tc.elapsed)
        check("advance_elapsed_" .. tostring(tc.elapsed), not adv_err, adv_err or "")

        if crossed then
            -- Verify current sample is the expected past sample (or nil if we ran off end).
            local cur_tick = pb.current_sample and pb.current_sample.tick
            check(
                string.format("cur_tick_elapsed_%d", tc.elapsed),
                cur_tick == tc.exp_cur_tick,
                string.format("expected cur=%d got %s (idx=%s)",
                    tc.exp_cur_tick or "nil", tostring(cur_tick), tostring(pb.current_sample_index)))

            -- Verify next sample is the expected future sample.
            local next_tick = pb.next_sample and pb.next_sample.tick
            check(
                string.format("next_tick_elapsed_%d", tc.elapsed),
                ((tc.exp_next_tick == nil and pb.next_sample_index == nil) or
                 (pb.next_sample_index ~= nil and pb.next_sample.tick == tc.exp_next_tick)),
                string.format("expected next=%s got %s (idx=%s)",
                    tostring(tc.exp_next_tick), tostring(next_tick), tostring(pb.next_sample_index)))

            -- Invariant: current <= elapsed < next (when next exists).
            if pb.current_sample and pb.current_sample.tick > tc.elapsed then
                check(
                    string.format("invariant_elapsed_%d", tc.elapsed), false,
                    string.format("cur=%d > elapsed=%d", pb.current_sample.tick, tc.elapsed))
            end
        else
            -- advance_cursor returned nil — that's fine if we're past the last sample.
            check(
                string.format("past_end_elapsed_%d", tc.elapsed),
                tc.elapsed >= 4,
                "expected advance_cursor to return nil for elapsed >= final_tick")
        end

        ::continue_end::
    end

    print(string.format("[GhostPlayback cursor_self_test] %d passed, %d failed", passed, failed))
    for _, e in ipairs(errors) do
        console_out(e, 1.0, 0.35, 0.35)
    end

    return failed == 0, errors
end

-- ============================================================
-- Native animation regression self-test. Pure-Lua, no Halo objects required.
-- Mocks write_word via a recorder function to verify D0/D2 write behavior in native mode.
-- ============================================================
function GhostPlayback.animation_self_test()
    local passed = 0
    local failed = 0
    local errors = {}

    -- Local check helper — cannot depend on cursor_self_test's scope.
    local function check(name, condition, message)
        if condition then
            passed = passed + 1
        else
            failed = failed + 1
            errors[#errors + 1] = string.format(
                "FAIL [%s]: %s",
                name,
                message or ""
            )
        end
    end

    -- Capture writes to verify actual memory addresses and values.
    local writes_word = {}   -- for write_word mock
    local writes_byte = {}   -- for write_byte mock
    local original_write_word = write_word
    local original_write_byte = write_byte

    local ok, runtime_error = pcall(function()
        -- Mock both Chimera APIs with the correct production signatures.
        write_word = function(address, value)
            writes_word[#writes_word + 1] = { address = address, value = value }
        end
        write_byte = function(address, value)
            writes_byte[#writes_byte + 1] = { address = address, value = value }
        end

        local pb = GhostPlayback.new({
            animation_mode = "native",
            debug_log      = false,
        })
        pb.biped_pointer = 0x12345678
        pb.last_base_animation = -1

        -- Pre-compute D0 and D2 addresses for assertion checks.
        local d0_address = pb.biped_pointer + BASE_ANIMATION_OFFSET   -- mock_pointer + 0xD0
        local d2_address = pb.biped_pointer + BASE_FRAME_OFFSET       -- mock_pointer + 0xD2

        -- Sample definitions.
        local sample0 = {
            animation = { base_animation = 173, base_frame = 0 },
        }
        local sample1 = {
            animation = { base_animation = 173, base_frame = 1 },
        }
        local sample2 = {
            animation = { base_animation = 174, base_frame = 0 },
        }

        -- Phase A: forced initial sample → should write D0=173 and D2=0.
        writes_word = {}
        writes_byte = {}
        local was_written = pb:apply_animation(pb.biped_pointer, sample0, true)
        check("sample0_return", was_written == true, "expected true")
        check("sample0_write_count", #writes_word == 2,
            string.format("expected exactly two writes, got %d (last: addr=0x%X val=%d)",
                #writes_word,
                writes_word[1] and writes_word[1].address or 0,
                writes_word[1] and writes_word[1].value or 0))
        check("sample0_d0", writes_word[1]
            and writes_word[1].address == d0_address
            and writes_word[1].value == 173, "expected D0=173")
        check("sample0_d2", writes_word[2]
            and writes_word[2].address == d2_address
            and writes_word[2].value == 0, "expected D2=0")

        -- Phase B: same D0 → should NOT write.
        writes_word = {}
        writes_byte = {}
        was_written = pb:apply_animation(pb.biped_pointer, sample1, false)
        check("sample1_return", was_written == false,
            "expected false for unchanged D0")
        check("sample1_write_count", #writes_word == 0,
            string.format("expected no writes, got %d", #writes_word))

        -- Phase C: changed D0 → should write D0=174 and D2=0.
        writes_word = {}
        writes_byte = {}
        was_written = pb:apply_animation(pb.biped_pointer, sample2, false)
        check("sample2_return", was_written == true,
            "expected true for changed D0")
        check("sample2_write_count", #writes_word == 2,
            string.format("expected exactly two writes, got %d", #writes_word))
        check("sample2_d0", writes_word[1]
            and writes_word[1].address == d0_address
            and writes_word[1].value == 174, "expected D0=174")
        check("sample2_d2", writes_word[2]
            and writes_word[2].address == d2_address
            and writes_word[2].value == 0, "expected D2=0")

        -- Phase D: experimental fields — exact mode with all flags enabled.
        local experimental = GhostPlayback.new({
            animation_mode   = "exact",
            apply_transition = true,
            apply_state      = true,
            apply_stance     = true,
            debug_log        = false,
        })
        experimental.biped_pointer = 0x12345678
        experimental.last_base_animation = -1

        local exp_sample = {
            animation = {
                base_animation   = 42,
                base_frame       = 7,
                transition_frame = 3,
                transition_length= 10,
                state            = 5,
                stance           = 4,
            },
        }

        local exp_d0_addr = experimental.biped_pointer + BASE_ANIMATION_OFFSET
        local exp_d2_addr = experimental.biped_pointer + BASE_FRAME_OFFSET
        local exp_d4_addr = experimental.biped_pointer + TRANSITION_FRAME_OFFSET
        local exp_d6_addr = experimental.biped_pointer + TRANSITION_LENGTH_OFFSET
        local exp_s_addr  = experimental.biped_pointer + ANIMATION_STATE_OFFSET
        local exp_st_addr = experimental.biped_pointer + ANIMATION_STANCE_OFFSET

        writes_word = {}
        writes_byte = {}
        was_written = experimental:apply_animation(
            experimental.biped_pointer, exp_sample, false)
        check("experimental_return", was_written == true,
            "expected true for exact mode")
        check("experimental_write_count", #writes_word == 4,
            string.format("expected four word writes (D0,D2,D4,D6), got %d",
                #writes_word))
        check("experimental_d0", writes_word[1]
            and writes_word[1].address == exp_d0_addr
            and writes_word[1].value == 42, "expected D0=42")
        check("experimental_d2", writes_word[2]
            and writes_word[2].address == exp_d2_addr
            and writes_word[2].value == 7, "expected D2=7")
        check("experimental_d4", writes_word[3]
            and writes_word[3].address == exp_d4_addr
            and writes_word[3].value == 3, "expected D4=3")
        check("experimental_d6", writes_word[4]
            and writes_word[4].address == exp_d6_addr
            and writes_word[4].value == 10, "expected D6=10")
        check("experimental_state", writes_byte[1]
            and writes_byte[1].address == exp_s_addr
            and writes_byte[1].value == 5, "expected state=5 at 0x2A3")
        check("experimental_stance", writes_byte[2]
            and writes_byte[2].address == exp_st_addr
            and writes_byte[2].value == 4, "expected stance=4 at 0x2A0")
    end)

    -- Always restore original write functions regardless of test outcome.
    if original_write_word then
        write_word = original_write_word
    else
        write_word = nil
    end
    if original_write_byte then
        write_byte = original_write_byte
    else
        write_byte = nil
    end

    if not ok then
        failed = failed + 1
        errors[#errors + 1] = string.format(
            "FAIL [runtime]: %s", tostring(runtime_error))
    end

    print(string.format(
        "[GhostPlayback animation_self_test] %d passed, %d failed",
        passed, failed))

    for _, e in ipairs(errors) do
        console_out(e, 1.0, 0.35, 0.35)
    end

    return failed == 0, errors
end

return GhostPlayback
