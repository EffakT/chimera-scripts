-- HRL Replay Decoder — client-side Chimera Lua module.
--
-- Parses the finalized HRLREPLAY3 binary format produced by server-lua/replay.lua
-- and returns an immutable decoded replay object with per-sample snapshots.
--
-- Install: lua/scripts/global/replay_decode.lua under Chimera's global scripts.

clua_version = 2.056

local ReplayDecode = {}

-- ============================================================
-- Quantization constants — must match server-lua/replay.lua exactly.
-- ============================================================
local POSITION_SCALE    = 100
local ANGLE_SCALE       = 1000
local VEHICLE_VALUE_SCALE = 1000

-- ============================================================
-- Varint helpers — unsigned and signed (ZigZag).
-- Uses arithmetic multiplication only (no <<, &, | operators)
-- for compatibility with Chimera's Lua runtime.
-- ============================================================
local function decode_unsigned_varint(data, offset)
    local value = 0
    local shift_count = 0
    local multiplier = 1

    for _ = 1, 10 do
        if offset > #data then
            return nil, offset, "truncated varint: unexpected end of data"
        end
        local byte = data:byte(offset)
        offset = offset + 1
        value = value + (byte % 128) * multiplier

        if byte < 128 then
            return value, offset, nil
        end

        shift_count = shift_count + 7
        if shift_count > 63 then
            return nil, offset - 1, "varint too long (shift count exceeded 63 bits)"
        end
        multiplier = multiplier * 128
    end

    return nil, offset, "invalid varint"
end

local function decode_signed_varint(data, offset)
    local zigzag, new_offset, err = decode_unsigned_varint(data, offset)
    if err then
        return nil, new_offset, err
    end
    if math.floor(zigzag % 2) == 0 then
        return zigzag / 2, new_offset, nil
    else
        return -math.floor((zigzag + 1) / 2), new_offset, nil
    end
end

-- ============================================================
-- Bit-test helper (no bit library assumed).
-- Uses arithmetic to avoid Lua 5.3 bitwise operators.
-- ============================================================
local function has_bit(byte, power_of_two)
    return math.floor(byte / power_of_two) % 2 >= 1
end

-- ============================================================
-- Header parsing — literal LF and CRLF marker detection.
-- No pattern tricks; no \x0D or %f markers.
-- ============================================================
local MAGIC = "HRLREPLAY3"
local REQUIRED_ENCODING = "delta-varint-v7"

local function parse_header(data)
    local marker_lf   = "--- BINARY ---\n\n"
    local marker_crlf = "--- BINARY ---\r\n\r\n"

    local marker_start, marker_end = data:find(marker_crlf, 1, true)
    if not marker_start then
        marker_start, marker_end = data:find(marker_lf, 1, true)
    end

    if not marker_start then
        return nil, "missing binary marker (--- BINARY ---)"
    end

    local header_text = data:sub(1, marker_start - 1)
    local binary_start = marker_end + 1

    local header = { magic = nil }
    local first_line = true
    for line in header_text:gmatch("[^\r\n]+") do
        if first_line then
            header.magic = line:match("^%s*(.-)%s*$")
            first_line = false
        else
            local key, value = line:match("^%s*([^=]+)%s*=%s*(.*)$")
            if key then
                header[key] = value
            end
        end
    end

    if header.magic ~= MAGIC then
        return nil, "unsupported replay magic: '" .. tostring(header.magic) .. "'"
    end

    local encoding = (header.encoding or ""):match("^%s*(.-)%s*$")
    if encoding ~= REQUIRED_ENCODING then
        return nil, string.format(
            "unsupported encoding '%s'; HRLREPLAY3 requires '%s'",
            tostring(encoding), REQUIRED_ENCODING)
    end

    local tick_rate = tonumber(header.tick_rate)
    local sample_count = tonumber(header.sample_count)
    if not tick_rate or tick_rate <= 0 then
        return nil, "invalid tick_rate: '" .. tostring(header.tick_rate) .. "'"
    end
    if not sample_count or sample_count < 0 then
        return nil, "invalid sample_count: '" .. tostring(header.sample_count) .. "'"
    end

    local warp = header.warp_discarded == "1" and true or false

    local vehicle_tags = {}
    if header.vehicle then
        for tag in tostring(header.vehicle):gmatch("[^,]+") do
            local normalized_tag = tag:match("^%s*(.-)%s*$")
            if #normalized_tag > 0 then
                vehicle_tags[#vehicle_tags + 1] = normalized_tag
            end
        end
    end

    local biped_tag_path = header.biped_tag_path
    local animation_graph_datum = header.animation_graph_datum
        and tonumber(header.animation_graph_datum) or nil

    return {
        magic         = MAGIC,
        encoding      = REQUIRED_ENCODING,
        map           = (header.map or ""):match("^%s*(.-)%s*$"),
        race_type     = tonumber(header.race_type) or 0,
        player_hash   = (header.player_hash or ""):match("^%s*(.-)%s*$"),
        player_name   = (header.player_name or ""):match("^%s*(.-)%s*$"),
        lap_time      = tonumber(header.lap_time) or 0.0,
        warp_discarded = warp,
        vehicle_tags  = vehicle_tags,
        tick_rate     = tick_rate,
        sample_count  = sample_count,
        biped_tag_path    = biped_tag_path and (biped_tag_path:match("^%s*(.-)%s*$")) or nil,
        animation_graph_datum = animation_graph_datum,
        animation_fields  = header.animation_fields,
        detached_vehicle_capture = header.detached_vehicle_capture,
        detached_vehicle_fields = header.detached_vehicle_fields,
    }, binary_start
end

-- ============================================================
-- Decoder state — mutable running values.
-- ============================================================
local function new_decoder_state()
    return {
        tick            = -1,
        x               = 0, y = 0, z = 0,
        yaw             = 0, pitch = 0, roll = 0,
        vehicle_turn    = 0, tire_position = 0,
        checkpoint      = 0,

        animation = {
            base_animation  = 0,
            base_frame      = 0,
            transition_frame= 0,
            transition_length= 0,
            state           = 0,
            stance          = 0,
        },

        detached = {
            active          = false,
            x               = 0, y = 0, z = 0,
            yaw             = 0, pitch = 0, roll = 0,
        },
    }
end

-- ============================================================
-- Decode a single sample.
-- Every temporary variable is declared local at function entry
-- to avoid leaking into the global Chimera Lua environment.
-- ============================================================
local function decode_sample(data, offset, state)
    -- Declare all locals upfront so no assignments leak globally.
    local control
    local err
    local in_vehicle
    local checkpoint_changed
    local explicit_tick
    local animation_included
    local detached_update
    local detached_clear
    local tick_delta
    local d
    local cp
    local new_off
    local cerr
    local anim_mask
    local anim_event
    local dx, dy, dz, dyaw, dpitch, droll

    control = data:byte(offset)
    if not control then
        return nil, offset, "truncated sample at byte boundary"
    end
    offset = offset + 1

    -- Reserved bits check (bits 6-7 of control byte).
    if has_bit(control, 64) or has_bit(control, 128) then
        return nil, offset - 1, string.format(
            "reserved control bits set: 0x%02X", control)
    end

    -- Mutual exclusion: bits 4 and 5 cannot both be set.
    if has_bit(control, 16) and has_bit(control, 32) then
        return nil, offset - 1, string.format(
            "control byte 0x%02X sets both update (bit4) and clear (bit5); must not co-exist", control)
    end

    in_vehicle             = has_bit(control, 1)
    checkpoint_changed     = has_bit(control, 2)
    explicit_tick          = has_bit(control, 4)
    animation_included     = has_bit(control, 8)
    detached_update        = has_bit(control, 16)
    detached_clear         = has_bit(control, 32)

    -- Tick delta.
    tick_delta = 1
    if explicit_tick then
        tick_delta, offset, err = decode_unsigned_varint(data, offset)
        if err then return nil, offset - 1, string.format("explicit tick varint: %s", err) end
        if not tick_delta or tick_delta <= 0 then
            return nil, offset, "explicit tick delta must be positive"
        end
    end

    -- Accumulate tick.
    state.tick = state.tick + tick_delta

    -- Primary position/orientation deltas (always present).
    d, offset, err = decode_signed_varint(data, offset)
    if err then return nil, offset - 1, string.format("x delta: %s", err) end
    state.x = state.x + d

    d, offset, err = decode_signed_varint(data, offset)
    if err then return nil, offset - 1, string.format("y delta: %s", err) end
    state.y = state.y + d

    d, offset, err = decode_signed_varint(data, offset)
    if err then return nil, offset - 1, string.format("z delta: %s", err) end
    state.z = state.z + d

    d, offset, err = decode_signed_varint(data, offset)
    if err then return nil, offset - 1, string.format("yaw delta: %s", err) end
    state.yaw = state.yaw + d

    d, offset, err = decode_signed_varint(data, offset)
    if err then return nil, offset - 1, string.format("pitch delta: %s", err) end
    state.pitch = state.pitch + d

    d, offset, err = decode_signed_varint(data, offset)
    if err then return nil, offset - 1, string.format("roll delta: %s", err) end
    state.roll = state.roll + d

    -- Optional vehicle fields (only when in_vehicle).
    if in_vehicle then
        d, offset, err = decode_signed_varint(data, offset)
        if err then return nil, offset - 1, string.format("vehicle_turn delta: %s", err) end
        state.vehicle_turn = state.vehicle_turn + d

        d, offset, err = decode_signed_varint(data, offset)
        if err then return nil, offset - 1, string.format("tire_position delta: %s", err) end
        state.tire_position = state.tire_position + d
    end

    -- Optional checkpoint.
    if checkpoint_changed then
        cp, new_off, cerr = decode_unsigned_varint(data, offset)
        if cerr then return nil, offset - 1, string.format("checkpoint varint: %s", cerr) end
        state.checkpoint = cp
        offset = new_off
    end

    -- Optional animation payload.
    anim_mask = 0
    anim_event = false
    if animation_included then
        anim_mask = data:byte(offset)
        if not anim_mask then return nil, offset, "animation mask byte missing" end
        offset = offset + 1

        -- Reserved bits check (bits 6-7 of animation mask).
        -- Bits 0-5 are valid: D0=bit0, D2=bit1, D4=bit2, D6=bit3, state=bit4, stance=bit5.
        if has_bit(anim_mask, 64) or has_bit(anim_mask, 128) then
            return nil, offset - 1, string.format(
                "reserved animation mask bits set: 0x%02X", anim_mask)
        end

        -- Mask zero with bit 3 set is invalid.
        if anim_mask == 0 then
            return nil, offset - 1, "animation mask byte is zero (no fields to decode)"
        end

        anim_event = true

        -- Decode deltas in mask-bit order: D0, D2, D4, D6, state, stance.
        if has_bit(anim_mask, 1) then
            d, offset, err = decode_signed_varint(data, offset)
            if err then return nil, offset - 1, string.format("base_animation delta: %s", err) end
            state.animation.base_animation = state.animation.base_animation + d
        end
        if has_bit(anim_mask, 2) then
            d, offset, err = decode_signed_varint(data, offset)
            if err then return nil, offset - 1, string.format("base_frame delta: %s", err) end
            state.animation.base_frame = state.animation.base_frame + d
        end
        if has_bit(anim_mask, 4) then
            d, offset, err = decode_signed_varint(data, offset)
            if err then return nil, offset - 1, string.format("transition_frame delta: %s", err) end
            state.animation.transition_frame = state.animation.transition_frame + d
        end
        if has_bit(anim_mask, 8) then
            d, offset, err = decode_signed_varint(data, offset)
            if err then return nil, offset - 1, string.format("transition_length delta: %s", err) end
            state.animation.transition_length = state.animation.transition_length + d
        end
        if has_bit(anim_mask, 16) then
            d, offset, err = decode_signed_varint(data, offset)
            if err then return nil, offset - 1, string.format("state delta: %s", err) end
            state.animation.state = state.animation.state + d
        end
        if has_bit(anim_mask, 32) then
            -- stance is bit 5 and must remain valid (NOT reserved).
            d, offset, err = decode_signed_varint(data, offset)
            if err then return nil, offset - 1, string.format("stance delta: %s", err) end
            state.animation.stance = state.animation.stance + d
        end
    end

    -- Optional detached vehicle update (bit 4): six transform deltas.
    local detached_event = nil
    if detached_update then
        dx, offset, err = decode_signed_varint(data, offset)
        if err then return nil, offset - 1, string.format("detached x delta: %s", err) end
        state.detached.x = state.detached.x + dx

        dy, offset, err = decode_signed_varint(data, offset)
        if err then return nil, offset - 1, string.format("detached y delta: %s", err) end
        state.detached.y = state.detached.y + dy

        dz, offset, err = decode_signed_varint(data, offset)
        if err then return nil, offset - 1, string.format("detached z delta: %s", err) end
        state.detached.z = state.detached.z + dz

        dyaw, offset, err = decode_signed_varint(data, offset)
        if err then return nil, offset - 1, string.format("detached yaw delta: %s", err) end
        state.detached.yaw = state.detached.yaw + dyaw

        dpitch, offset, err = decode_signed_varint(data, offset)
        if err then return nil, offset - 1, string.format("detached pitch delta: %s", err) end
        state.detached.pitch = state.detached.pitch + dpitch

        droll, offset, err = decode_signed_varint(data, offset)
        if err then return nil, offset - 1, string.format("detached roll delta: %s", err) end
        state.detached.roll = state.detached.roll + droll

        state.detached.active = true
        detached_event = "update"
    end

    -- Detached clear (bit 5): no payload follows; reset baseline.
    if detached_clear then
        state.detached.active = false
        state.detached.x = 0
        state.detached.y = 0
        state.detached.z = 0
        state.detached.yaw = 0
        state.detached.pitch = 0
        state.detached.roll = 0
        detached_event = "clear"
    end

    -- Build immutable snapshot. Time is NOT computed here — it uses header.tick_rate,
    -- which this function does not have access to. Caller in decode_all sets sample.time.
    local sample = {
        tick          = state.tick,
        x             = state.x     / POSITION_SCALE,
        y             = state.y     / POSITION_SCALE,
        z             = state.z     / POSITION_SCALE,
        yaw           = state.yaw   / ANGLE_SCALE,
        pitch         = state.pitch / ANGLE_SCALE,
        roll          = state.roll  / ANGLE_SCALE,

        in_vehicle    = in_vehicle,
        vehicle_turn  = in_vehicle and (state.vehicle_turn / VEHICLE_VALUE_SCALE) or 0,
        tire_position = in_vehicle and (state.tire_position / VEHICLE_VALUE_SCALE) or 0,
        checkpoint    = state.checkpoint,

        animation = {
            base_animation   = state.animation.base_animation,
            base_frame       = state.animation.base_frame,
            transition_frame = state.animation.transition_frame,
            transition_length= state.animation.transition_length,
            state            = state.animation.state,
            stance           = state.animation.stance,
        },

        animation_event  = anim_event,
        animation_mask   = anim_mask,

        detached = {
            active          = state.detached.active,
            x               = state.detached.x     / POSITION_SCALE,
            y               = state.detached.y     / POSITION_SCALE,
            z               = state.detached.z     / POSITION_SCALE,
            yaw             = state.detached.yaw   / ANGLE_SCALE,
            pitch           = state.detached.pitch / ANGLE_SCALE,
            roll            = state.detached.roll  / ANGLE_SCALE,
        },

        detached_event  = detached_event,
    }

    return sample, offset, nil
end

-- ============================================================
-- Decode all samples from a decoded replay binary.
-- Returns the fully built replay object or (nil, error).
-- ============================================================
local function decode_all(data)
    local header, binary_start, header_err = parse_header(data)
    if not header then
        return nil, header_err
    end

    local state = new_decoder_state()
    local samples = {}
    local count = 0

    local ok, decode_err = pcall(function()
        for i = 1, header.sample_count do
            local sample, new_offset, err = decode_sample(data, binary_start + count, state)
            if not sample then
                error(string.format("sample %d: %s", i, err))
            end
            -- Compute time using the recorded tick_rate from the header.
            sample.time = sample.tick / header.tick_rate
            samples[i] = sample
            count = new_offset - binary_start
        end
    end)

    if not ok then
        return nil, tostring(decode_err)
    end

    if #samples == 0 then
        return nil, "replay contains no samples"
    end

    -- Validate tick sequence.
    if samples[1].tick ~= 0 then
        return nil, string.format("first sample tick is %d, expected 0", samples[1].tick)
    end
    for i = 2, #samples do
        if samples[i].tick <= samples[i - 1].tick then
            return nil, string.format(
                "non-increasing ticks: sample[%d]=%d after sample[%d]=%d",
                i, samples[i].tick, i - 1, samples[i - 1].tick)
        end
    end

    -- Validate sample-count match and trailing bytes.
    if #samples ~= header.sample_count then
        return nil, string.format(
            "sample count mismatch: decoded %d but header says %d",
            #samples, header.sample_count)
    end

    -- `count` is relative to binary_start, while #data is the full file size.
    -- Compare against the binary payload length, not the complete header + payload.
    local binary_length = #data - binary_start + 1

    if count < binary_length then
        return nil, string.format(
            "trailing binary bytes after samples: %d bytes remaining at binary offset %d of %d",
            binary_length - count,
            count,
            binary_length)
    elseif count > binary_length then
        return nil, string.format(
            "decoder consumed beyond binary payload: %d bytes consumed of %d",
            count,
            binary_length)
    end

    local final_tick = samples[#samples].tick
    local duration_seconds = final_tick / header.tick_rate

    return {
        header      = header,
        samples     = samples,
        final_tick  = final_tick,
        duration    = duration_seconds,
    }, nil
end

-- ============================================================
-- Public API — from_string(data) → replay or err
-- ============================================================
function ReplayDecode.from_string(data)
    if type(data) ~= "string" then
        return nil, "expected string data"
    end
    if #data == 0 then
        return nil, "empty replay data"
    end
    return decode_all(data)
end

local function read_file_bytes(path)
    local file = io.open(path, "rb")
    if not file then
        return nil, string.format("cannot open '%s'", path)
    end
    local bytes = file:read("*a")
    file:close()
    if not bytes or #bytes == 0 then
        return nil, "file is empty"
    end
    return bytes
end

function ReplayDecode.from_file(path)
    if type(path) ~= "string" or path == "" then
        return nil, "invalid file path"
    end
    local data, read_err = read_file_bytes(path)
    if not data then
        return nil, string.format("read error: %s", tostring(read_err))
    end
    return decode_all(data)
end

-- ============================================================
-- Lookup helper — cursor-based forward scan.
-- ============================================================
function ReplayDecode.get_sample_at_or_before_tick(replay, tick)
    if not replay or not replay.samples then
        return nil
    end
    local samples = replay.samples
    if #samples == 0 then
        return nil
    end

    if tick <= samples[1].tick then
        return copy_sample(samples[1])
    end
    if tick >= samples[#samples].tick then
        return copy_sample(samples[#samples])
    end

    for i = 1, #samples do
        if samples[i].tick > tick then
            return copy_sample(samples[i - 1] or samples[1])
        end
    end
    return copy_sample(samples[#samples])
end

-- ============================================================
-- Deep-copy a sample — used for immutable output.
-- ============================================================
local function copy_sample(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            out[k] = {v} -- shallow copy of sub-tables
        else
            out[k] = v
        end
    end
    return out
end

-- ============================================================
-- Self-test — builds binary fixtures and verifies round-trip.
-- Runs without any game state.
-- ============================================================
local function encode_unsigned_varint(value)
    local bytes = {}
    repeat
        local byte = value % 128
        value = math.floor(value / 128)
        if value > 0 then
            byte = byte + 128
        end
        bytes[#bytes + 1] = string.char(byte)
    until value == 0
    return table.concat(bytes)
end

local function encode_signed_varint(value)
    local zigzag = value >= 0 and (value * 2) or ((-value) * 2 - 1)
    return encode_unsigned_varint(zigzag)
end

-- Build a minimal HRLREPLAY3 binary fixture with LF line endings.
local function build_fixture(sample_count, sample_builder)
    local header_lines = {
        "HRLREPLAY3",
        "encoding=delta-varint-v7",
        "animation_capture=raw-biped-animation-v1",
        "map=test_map",
        "race_type=0",
        "player_hash=testhash",
        "player_name=tester",
        "lap_time=60.0000",
        "warp_discarded=0",
        "vehicle=",
        "tick_rate=30",
        "sample_count=" .. tostring(sample_count),
        "animation_fields=base_animation,base_frame,transition_frame,transition_length,state,stance",
        "detached_vehicle_capture=1",
        "detached_vehicle_fields=x,y,z,yaw,pitch,roll",
    }

    local state = new_decoder_state()
    local payload_parts = {}

    for i = 1, sample_count do
        local builder_result = sample_builder(state, i)
        if not builder_result then break end

        local control = builder_result.control or 0
        payload_parts[#payload_parts + 1] = string.char(control)

        if builder_result.explicit_tick_delta and builder_result.explicit_tick_delta ~= 1 then
            payload_parts[#payload_parts + 1] = encode_unsigned_varint(builder_result.explicit_tick_delta)
        end

        local pdx, pdy, pdz, pdyaw, pdpitch, pdroll =
            builder_result.x or 0, builder_result.y or 0, builder_result.z or 0,
            builder_result.yaw or 0, builder_result.pitch or 0, builder_result.roll or 0
        payload_parts[#payload_parts + 1] = encode_signed_varint(pdx)
        payload_parts[#payload_parts + 1] = encode_signed_varint(pdy)
        payload_parts[#payload_parts + 1] = encode_signed_varint(pdz)
        payload_parts[#payload_parts + 1] = encode_signed_varint(pdyaw)
        payload_parts[#payload_parts + 1] = encode_signed_varint(pdpitch)
        payload_parts[#payload_parts + 1] = encode_signed_varint(pdroll)

        if builder_result.in_vehicle then
            local pvturn, ptire = builder_result.vehicle_turn or 0, builder_result.tire_position or 0
            payload_parts[#payload_parts + 1] = encode_signed_varint(pvturn)
            payload_parts[#payload_parts + 1] = encode_signed_varint(ptire)
        end

        if builder_result.checkpoint_changed then
            local cp_id = builder_result.checkpoint_id or 0
            payload_parts[#payload_parts + 1] = encode_unsigned_varint(cp_id)
        end

        if builder_result.animation_mask and builder_result.animation_mask ~= 0 then
            payload_parts[#payload_parts + 1] = string.char(builder_result.animation_mask)
            local anim_deltas = builder_result.animation_deltas or {}
            for mask_bit = 1, 6 do
                if has_bit(builder_result.animation_mask, 2 ^ (mask_bit - 1)) then
                    local dv = anim_deltas[mask_bit] or 0
                    payload_parts[#payload_parts + 1] = encode_signed_varint(dv)
                end
            end
        end

        if builder_result.detached_update then
            local dd = builder_result.detached_deltas or {0,0,0,0,0,0}
            for j = 1, 6 do
                payload_parts[#payload_parts + 1] = encode_signed_varint(dd[j])
            end
        end
    end

    -- LF binary boundary: "--- BINARY ---\n\n" then payload.
    header_lines[#header_lines + 1] = "--- BINARY ---"
    return table.concat(header_lines, "\n") .. "\n\n" .. table.concat(payload_parts)
end

-- Build a CRLF variant of the same fixture for cross-line-ending tests.
local function build_fixture_crlf(sample_count, sample_builder)
    local header_lines = {
        "HRLREPLAY3",
        "encoding=delta-varint-v7",
        "animation_capture=raw-biped-animation-v1",
        "map=test_map",
        "race_type=0",
        "player_hash=testhash",
        "player_name=tester",
        "lap_time=60.0000",
        "warp_discarded=0",
        "vehicle=",
        "tick_rate=30",
        "sample_count=" .. tostring(sample_count),
        "animation_fields=base_animation,base_frame,transition_frame,transition_length,state,stance",
        "detached_vehicle_capture=1",
        "detached_vehicle_fields=x,y,z,yaw,pitch,roll",
    }

    local state = new_decoder_state()
    local payload_parts = {}

    for i = 1, sample_count do
        local builder_result = sample_builder(state, i)
        if not builder_result then break end

        local control = builder_result.control or 0
        payload_parts[#payload_parts + 1] = string.char(control)

        if builder_result.explicit_tick_delta and builder_result.explicit_tick_delta ~= 1 then
            payload_parts[#payload_parts + 1] = encode_unsigned_varint(builder_result.explicit_tick_delta)
        end

        local pdx, pdy, pdz, pdyaw, pdpitch, pdroll =
            builder_result.x or 0, builder_result.y or 0, builder_result.z or 0,
            builder_result.yaw or 0, builder_result.pitch or 0, builder_result.roll or 0
        payload_parts[#payload_parts + 1] = encode_signed_varint(pdx)
        payload_parts[#payload_parts + 1] = encode_signed_varint(pdy)
        payload_parts[#payload_parts + 1] = encode_signed_varint(pdz)
        payload_parts[#payload_parts + 1] = encode_signed_varint(pdyaw)
        payload_parts[#payload_parts + 1] = encode_signed_varint(pdpitch)
        payload_parts[#payload_parts + 1] = encode_signed_varint(pdroll)

        if builder_result.in_vehicle then
            local pvturn, ptire = builder_result.vehicle_turn or 0, builder_result.tire_position or 0
            payload_parts[#payload_parts + 1] = encode_signed_varint(pvturn)
            payload_parts[#payload_parts + 1] = encode_signed_varint(ptire)
        end

        if builder_result.checkpoint_changed then
            local cp_id = builder_result.checkpoint_id or 0
            payload_parts[#payload_parts + 1] = encode_unsigned_varint(cp_id)
        end

        if builder_result.animation_mask and builder_result.animation_mask ~= 0 then
            payload_parts[#payload_parts + 1] = string.char(builder_result.animation_mask)
            local anim_deltas = builder_result.animation_deltas or {}
            for mask_bit = 1, 6 do
                if has_bit(builder_result.animation_mask, 2 ^ (mask_bit - 1)) then
                    local dv = anim_deltas[mask_bit] or 0
                    payload_parts[#payload_parts + 1] = encode_signed_varint(dv)
                end
            end
        end

        if builder_result.detached_update then
            local dd = builder_result.detached_deltas or {0,0,0,0,0,0}
            for j = 1, 6 do
                payload_parts[#payload_parts + 1] = encode_signed_varint(dd[j])
            end
        end
    end

    header_lines[#header_lines + 1] = "--- BINARY ---"
    return table.concat(header_lines, "\r\n") .. "\r\n\r\n" .. table.concat(payload_parts)
end

function ReplayDecode.self_test()
    local passed = 0
    local failed = 0
    local errors = {}

    local function check(name, condition, msg)
        if condition then
            passed = passed + 1
        else
            failed = failed + 1
            errors[#errors + 1] = string.format("FAIL [%s]: %s", name, msg or "")
        end
    end

    -- Test 1: tick zero on first sample.
    do
        local fixture = build_fixture(3, function(state, i)
            return { control = 0 }
        end)
        local replay, err = ReplayDecode.from_string(fixture)
        check("tick_zero", replay ~= nil and replay.samples[1].tick == 0,
            (replay and ("samples[1].tick=" .. replay.samples[1].tick) or ("err=" .. tostring(err))))

        check("tick_sequence", replay and replay.samples[#replay.samples].tick == 2,
            (replay and ("last tick=" .. replay.samples[#replay.samples].tick) or ""))
    end

    -- Test 2: primary transform reconstruction.
    do
        local fixture = build_fixture(1, function(state, i)
            return { control = 0, x = 50, y = -100, z = 75, yaw = 500, pitch = -250, roll = 10 }
        end)
        local replay, err = ReplayDecode.from_string(fixture)
        check("transform_reconstruct", replay ~= nil and
            math.abs(replay.samples[1].x - 0.5) < 0.01 and
            math.abs(replay.samples[1].y - (-1.0)) < 0.01 and
            math.abs(replay.samples[1].z - 0.75) < 0.01,
            (replay and string.format("x=%.3f y=%.3f z=%.3f", replay.samples[1].x, replay.samples[1].y, replay.samples[1].z) or tostring(err)))
    end

    -- Test 3: animation reconstruction with D0/D2 delta.
    do
        local fixture = build_fixture(2, function(state, i)
            if i == 1 then
                return { control = 8, animation_mask = 3, animation_deltas = {173, 5} } -- bit0=D0, bit1=D2
            else
                return { control = 0 } -- no payload; preserve previous
            end
        end)
        local replay, err = ReplayDecode.from_string(fixture)
        check("animation_reconstruct", replay ~= nil and
            replay.samples[1].animation.base_animation == 173 and
            replay.samples[1].animation.base_frame == 5 and
            replay.samples[2].animation.base_animation == 173 and -- preserved
            replay.samples[2].animation.base_frame == 5,          -- preserved
            (replay and string.format("s1=(%d,%d) s2=(%d,%d)",
                replay.samples[1].animation.base_animation, replay.samples[1].animation.base_frame,
                replay.samples[2].animation.base_animation, replay.samples[2].animation.base_frame) or tostring(err)))
    end

    -- Test 4: animation preservation when no event present.
    do
        local fixture = build_fixture(1, function(state, i)
            return { control = 0 }
        end)
        local replay, err = ReplayDecode.from_string(fixture)
        check("animation_preserved", replay ~= nil and
            replay.samples[1].animation.base_animation == 0 and
            replay.samples[1].animation_event == false,
            (replay and "ok" or tostring(err)))
    end

    -- Test 5: stance delta (bit 5) is valid — not reserved.
    do
        local fixture = build_fixture(1, function(state, i)
            return {
                control = 8,
                animation_mask = 32,
                animation_deltas = {
                    [6] = 7,
                },
            } -- bit5=stance
        end)
        local replay, err = ReplayDecode.from_string(fixture)
        check("stance_bit_valid", replay ~= nil and
            replay.samples[1].animation.stance == 7 and
            replay.samples[1].animation.base_animation == 0,
            (replay and string.format("stance=%d base_anim=%d",
                replay.samples[1].animation.stance,
                replay.samples[1].animation.base_animation) or tostring(err)))
    end

    -- Test 6: vehicle payload alignment.
    do
        local fixture = build_fixture(1, function(state, i)
            return { control = 1, in_vehicle = true, x = 0, y = 0, z = 0, yaw = 0, pitch = 0, roll = 0, vehicle_turn = 500, tire_position = -300 }
        end)
        local replay, err = ReplayDecode.from_string(fixture)
        check("vehicle_fields", replay ~= nil and replay.samples[1].in_vehicle == true and
            math.abs(replay.samples[1].vehicle_turn - 0.5) < 0.01 and
            math.abs(replay.samples[1].tire_position - (-0.3)) < 0.01,
            (replay and string.format("turn=%.2f tire=%.2f", replay.samples[1].vehicle_turn, replay.samples[1].tire_position) or tostring(err)))
    end

    -- Test 7: detached update.
    do
        local fixture = build_fixture(1, function(state, i)
            return { control = 16, detached_update = true, detached_deltas = {100, -200, 50, 300, -150, 75} }
        end)
        local replay, err = ReplayDecode.from_string(fixture)
        check("detached_update", replay ~= nil and
            replay.samples[1].detached.active == true and
            math.abs(replay.samples[1].detached.x - 1.0) < 0.02 and
            math.abs(replay.samples[1].detached.y - (-2.0)) < 0.02 and
            replay.samples[1].detached_event == "update",
            (replay and string.format("active=%s x=%.2f y=%.2f ev=%s",
                tostring(replay.samples[1].detached.active),
                replay.samples[1].detached.x, replay.samples[1].detached.y,
                replay.samples[1].detached_event) or tostring(err)))
    end

    -- Test 8: detached clear.
    do
        local fixture = build_fixture(2, function(state, i)
            if i == 1 then
                return { control = 16, detached_update = true, detached_deltas = {100, 0, 0, 0, 0, 0} }
            else
                return { control = 32 } -- clear event
            end
        end)
        local replay, err = ReplayDecode.from_string(fixture)
        check("detached_clear", replay ~= nil and
            replay.samples[1].detached.active == true and
            replay.samples[2].detached.active == false and
            replay.samples[2].detached_event == "clear" and
            replay.samples[2].detached.x == 0,
            (replay and string.format("s1_active=%s s2_active=%s s2_ev=%s",
                tostring(replay.samples[1].detached.active),
                tostring(replay.samples[2].detached.active),
                replay.samples[2].detached_event) or tostring(err)))
    end

    -- Test 9: invalid simultaneous update/clear.
    do
        local fixture = build_fixture(1, function(state, i)
            return { control = 48 } -- bits 4 and 5 both set
        end)
        local replay, err = ReplayDecode.from_string(fixture)
        check("reject_simultaneous", replay == nil and err ~= nil,
            (replay and "should have rejected" or tostring(err)))
    end

    -- Test 10: truncated varint rejection.
    do
        local fixture = build_fixture(1, function(state, i)
            return { control = 0 }
        end)
        fixture = fixture:sub(1, #fixture - 1)
        local replay, err = ReplayDecode.from_string(fixture)
        check("truncated_varint", replay == nil and err ~= nil,
            (replay and "should have errored" or tostring(err)))
    end

    -- Test 11: CRLF header boundary works.
    do
        local fixture = build_fixture_crlf(2, function(state, i)
            if i == 1 then
                return { control = 8, animation_mask = 3, animation_deltas = {42, 9} }
            else
                return { control = 0 }
            end
        end)
        local replay, err = ReplayDecode.from_string(fixture)
        check("crlf_header", replay ~= nil and
            replay.samples[1].animation.base_animation == 42 and
            replay.samples[1].animation.base_frame == 9,
            (replay and string.format("D0=%d D2=%d err=%s",
                replay.samples[1].animation.base_animation,
                replay.samples[1].animation.base_frame,
                tostring(err)) or tostring(err)))
    end

    -- Test 12: time uses tick_rate from header.
    do
        local fixture = build_fixture(1, function(state, i)
            return { control = 0 }
        end)
        local replay, err = ReplayDecode.from_string(fixture)
        check("time_uses_tick_rate", replay ~= nil and math.abs(replay.samples[1].time - (0 / 30)) < 0.001,
            (replay and string.format("time=%.6f", replay.samples[1].time) or tostring(err)))
    end

    -- Summary.
    print(string.format("[ReplayDecode self_test] %d passed, %d failed", passed, failed))
    for _, e in ipairs(errors) do
        console_out(e, 1.0, 0.35, 0.35)
    end

    return failed == 0, errors
end

return ReplayDecode