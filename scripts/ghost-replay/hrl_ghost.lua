-- HRL Replay Ghost - Chimera client-side proof of concept
--
-- Install:
--   Documents\My Games\Halo CE\chimera\lua\scripts\global\hrl_ghost.lua
--
-- Commands:
--   hrl_ghost <path-to-replay>
--   hrl_ghost_stop
--   hrl_ghost_restart
--   hrl_ghost_test_animation
--   hrl_ghost_spawn_cyborg [distance]
--   hrl_ghost_set_animation_state <state> [stance] [action]
--   hrl_ghost_set_stance <stance>
--   hrl_ghost_set_action_state <state>
--   hrl_ghost_copy_live_compact
--   hrl_ghost_capture_live_animation
--   hrl_ghost_capture_in <seconds>
--   hrl_ghost_capture_on <jump|forward|back|left|right|airborne> [delay-ticks]
--   hrl_ghost_capture_cancel
--   hrl_ghost_set_base_animation <index>
--   hrl_ghost_set_frame <frame>
--   hrl_ghost_frame_sweep [start] [end] [step] [ticks-per-frame]
--   hrl_ghost_frame_sweep_stop
--   hrl_ghost_compare_cyborg
--   hrl_ghost_player_id
--   hrl_ghost_registration_diag [comparison-object-id]  # defaults to local player, writes DebugCore JSON
--   hrl_ghost_test_status
--   hrl_ghost_animation_release
--   hrl_ghost_delete_cyborg
--   hrl_ghost_anim_snapshot
--   hrl_ghost_anim_diff
--
-- Example:
--   hrl_ghost replays\1784236350_1_hash_bloodgulch.hrlreplay

clua_version = 2.056

-- ============================================================
-- DebugCore — merged drop-in JSON state-dump framework.
-- See lua/scripts/debug_core.lua for the canonical source.
-- We paste it here so this script is self-contained under
-- Chimera's isolated Lua states (no require() between scripts).
-- ============================================================
-- [debug_core.lua contents]
clua_version = 2.056
DebugCore = DebugCore or {}
DebugCore.sources = DebugCore.sources or {}

local function ensure_dir(dir)
    os.execute('mkdir "' .. dir .. '" 2>nul')
end

local function try_write_test(dir)
    local test_path = dir .. '\\.dbgcore_write_test'
    local f = io.open(test_path, "w")
    if f then
        f:close()
        os.remove(test_path)
        return true
    end
    return false
end

local function resolve_data_dir()
    local home = os.getenv("USERPROFILE")
    if not home then
        console_out("[DebugCore] USERPROFILE not set - falling back to relative path", 1.0, 0.6, 0.2)
        return "."
    end
    local plain_dir    = home .. "\\Documents\\My Games\\Halo\\chimera\\lua\\data\\global"
    local onedrive_dir  = home .. "\\OneDrive\\Documents\\My Games\\Halo\\chimera\\lua\\data\\global"
    local cache_file = home .. "\\AppData\\Local\\debugcore_resolved_dir.txt"
    local cf = io.open(cache_file, "r")
    if cf then
        local cached = cf:read("*l")
        cf:close()
        if cached and try_write_test(cached) then
            return cached
        end
    end
    local resolved
    if try_write_test(plain_dir) then
        resolved = plain_dir
    else
        ensure_dir(plain_dir)
        if try_write_test(plain_dir) then
            resolved = plain_dir
        else
            ensure_dir(onedrive_dir)
            resolved = onedrive_dir
        end
    end
    local wf = io.open(cache_file, "w")
    if wf then
        wf:write(resolved)
        wf:close()
    end
    return resolved
end

DebugCore.OUTPUT_DIR = resolve_data_dir()
DebugCore.OUTPUT_FILE = DebugCore.OUTPUT_DIR .. "\\chimera_debug_dump.json"
console_out("[DebugCore] output path: " .. DebugCore.OUTPUT_FILE, 1.0, 0.6, 1.0, 0.4)

function DebugCore.register(name, fn)
    if type(name) ~= "string" or type(fn) ~= "function" then
        console_out("[DebugCore] register() needs (string, function)", 1.0, 0.3, 0.3)
        return false
    end
    DebugCore.sources[name] = fn
    console_out("[DebugCore] registered source: " .. name, 1.0, 0.6, 1.0, 0.4)
    return true
end

function DebugCore.unregister(name)
    DebugCore.sources[name] = nil
end

local function json_escape(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    return s
end

local function is_array(t)
    local n = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n == #t
end

local function encode(v, indent)
    indent = indent or 0
    local pad = string.rep("  ", indent)
    local next_pad = string.rep("  ", indent + 1)
    local t = type(v)
    if v == nil then return "null"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number" then
        if v ~= v then return "0" end
        return tostring(v)
    elseif t == "string" then return '"' .. json_escape(v) .. '"'
    elseif t == "table" then
        if is_array(v) then
            if #v == 0 then return "[]"
            else
                local parts = {}
                for i = 1, #v do
                    parts[#parts + 1] = next_pad .. encode(v[i], indent + 1)
                end
                return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
            end
        else
            local parts = {}
            for k, val in pairs(v) do
                parts[#parts + 1] = next_pad .. '"' .. json_escape(tostring(k)) .. '": ' .. encode(val, indent + 1)
            end
            if #parts == 0 then return "{}"
            else return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
            end
        end
    end
    return "null"
end

DebugCore.register("meta", function()
    return {
        tick = ticks(),
        map = map,
        gametype = gametype,
        server_type = server_type,
        build = build,
    }
end)

DebugCore.register("local_player", function()
    local dyn = get_dynamic_player()
    if not dyn then return { alive = false } end
    return {
        alive = true,
        x = read_float(dyn + 0x5C),
        y = read_float(dyn + 0x60),
        z = read_float(dyn + 0x64),
    }
end)

function DebugCore.collect()
    local out = { sources = {} }
    for name, fn in pairs(DebugCore.sources) do
        local ok, result = pcall(fn)
        if ok then out.sources[name] = result
        else out.sources[name] = { error = tostring(result) }
            console_out("[DebugCore] source '" .. name .. "' errored: " .. tostring(result), 1.0, 0.3, 0.3)
        end
    end
    return out
end

function DebugCore.dump()
    local data = DebugCore.collect()
    local json = encode(data)
    local f = io.open(DebugCore.OUTPUT_FILE, "w")
    if not f then
        console_out("[DebugCore] failed to open " .. DebugCore.OUTPUT_FILE .. " for write", 1.0, 0.3, 0.3)
        return false
    end
    f:write(json)
    f:close()
    local n = 0
    for _ in pairs(DebugCore.sources) do n = n + 1 end
    console_out("[DebugCore] dump written (" .. #json .. " bytes, " .. n .. " sources)", 1.0, 0.4, 1.0, 0.4)
    return true
end
-- [end debug_core.lua contents]

local BIPED_CLASS = "bipd"
local BIPED_TAG = "characters\\cyborg_mp\\cyborg_mp"

local POSITION_OFFSET = 0x5C
local VELOCITY_OFFSET = 0x68

-- Rendered object orientation basis.
local OBJECT_FORWARD_OFFSET = 0x74
local OBJECT_UP_OFFSET = 0x80

-- Animation offsets mirrored from the SAPP replay recorder.
local ANIMATION_TAG_OFFSET = 0xCC
local BASE_ANIMATION_OFFSET = 0xD0
local BASE_FRAME_OFFSET = 0xD2
local TRANSITION_FRAME_OFFSET = 0xD4
local TRANSITION_LENGTH_OFFSET = 0xD6
local ANIMATION_STANCE_OFFSET = 0x2A0
local ANIMATION_STATE_OFFSET = 0x2A3
local ANIMATION_CROUCH_OFFSET = 0x2A7

-- Candidate native-animation registration structures identified by static
-- analysis. These diagnostics are READ-ONLY until their indexing and ownership
-- semantics have been proven at runtime.
local SUB_OBJECT_TABLE_GLOBAL = 0x008603B0
local SUB_OBJECT_TABLE_OFFSET = 0x34
local SUB_OBJECT_ENTRY_STRIDE = 0x0C
local SUB_OBJECT_POINTER_OFFSET = 0x08
local SUB_OBJECT_STATE_OFFSET = 0xB8
local SUB_OBJECT_HANDLE_OFFSET = 0x1F4 -- decimal 500
local ANIMATION_SLOT_BASE = 0x008802C8
local ANIMATION_SLOT_STRIDE = 0x6C

-- Unit control/orientation fields. These are the inputs Halo uses when
-- resolving idle, forward, backward and strafe animation states.
local UNIT_FACING_OFFSET = 0x224
local UNIT_DESIRED_AIM_OFFSET = 0x230
local UNIT_AIM_OFFSET = 0x23C
local UNIT_FORWARD_INPUT_OFFSET = 0x278
local UNIT_LEFT_INPUT_OFFSET = 0x27C
local UNIT_UP_INPUT_OFFSET = 0x280

local BODY_PART_COUNT = 18
local BODY_PART_FLOATS = 13
local BODY_PART_BYTES = BODY_PART_COUNT * BODY_PART_FLOATS * 4

local ghost = {
    object_id = nil,
    replay = nil,
    filename = nil,
    playing = false,
    started_at = 0,
    copy_live_animation = false,
    animation_probe = nil,
}

-- ============================================================
-- HRL Replay Playback (compact native animation) modules.
-- Loaded deterministically via loadfile() because Chimera executes
-- scripts in isolated Lua states — cross-script globals and require()
-- are not reliable. Both modules must be present at startup for the
-- new replay commands to function. The decoder's self-test command
-- works regardless of whether playback is wired up.
-- ============================================================
local ReplayDecode = nil
local GhostPlaybackInstance = nil

-- Independent spawned cyborg used for direct animation-state causality tests.
-- This is intentionally separate from ghost.object_id so replay playback and
-- manual animation experiments cannot delete or overwrite each other.
local test_cyborg = {
    object_id = nil,
    hold = false,
    copy_live_compact = false,
    state = 0,
    stance = 4,
    action = 0,
    captured = nil,
    frame_sweep = {
        enabled = false,
        start_frame = 0,
        end_frame = 30,
        step = 1,
        ticks_per_frame = 1,
        tick_counter = 0,
        frame = 0,
    },
    capture_arm = {
        mode = nil,
        target_tick = nil,
        condition = nil,
        delay_ticks = 3,
        triggered = false,
        trigger_tick = nil,
    },
}

-- ============================================================
-- Animation-name string block + name/value pointer table.
--
-- Verified layout (see investigation.md):
--   String block:       0x0066C15C - 0x0066C248
--   Pointer table start: 0x006979C8, stride 8, 55 entries
--   Descriptor:          0x00697B80 { count=u32, ptr_table=u32 }
--
-- Each 8-byte entry is:
--   +0x00  uint32 pointer into the animation-name string block
--   +0x04  uint32 — observed values include 0, 1, and occasionally 0xFFFF;
--          semantic meaning undetermined from static inspection
-- ============================================================
local TABLE_START_ADDRESS = 0x006979C8
local DESCRIPTOR_ADDRESS  = 0x00697B80
local ENTRY_COUNT         = 55
local ENTRY_STRIDE        = 8

local function read_animation_table()
    local descriptor = {
        address = string.format("0x%08X", DESCRIPTOR_ADDRESS),
        count   = read_dword(DESCRIPTOR_ADDRESS + 0x00),
        ptr     = read_dword(DESCRIPTOR_ADDRESS + 0x04),
    }

    local entries = {}
    for i = 0, ENTRY_COUNT - 1 do
        local base = TABLE_START_ADDRESS + i * ENTRY_STRIDE
        entries[i + 1] = {
            index    = i,
            address  = string.format("0x%08X", base),
            ptr_name = read_dword(base + 0x00),
            field_b  = read_dword(base + 0x04),
        }
    end

    return {
        descriptor = descriptor,
        entry_count = #entries,
        entries     = entries,
    }
end

-- Register the animation table as a DebugCore source.
DebugCore.register("animation_table", read_animation_table)

-- ============================================================
-- Animation Field Investigation — dword/float probe of candidate offsets.
--
-- The byte-level animation_probe (0xC0-0x300) is useful for finding which
-- bytes change, but selectors are typically dwords or floats. This set of
-- DebugCore sources reads the specific candidates we care about as their
-- natural types so we can correlate values with activities:
--   idle, forward, backward, strafe L/R, jump, airborne/landing, crouch.
-- ============================================================

local CANDIDATE_OFFSETS = {
    -- Compact animation fields (from SAPP replay encoder).
    { offset = 0x2A0, name = "stance",        type = "word" },
    { offset = 0x2A3, name = "animation_state", type = "byte" },
    
    -- Unit control inputs — what the game reads to resolve locomotion.
    { offset = 0x224, name = "unit_facing",   type = "dword" },
    { offset = 0x230, name = "desired_aim",   type = "dword" },
    { offset = 0x23C, name = "aim",           type = "dword" },
    { offset = 0x278, name = "forward_input", type = "float" },
    { offset = 0x27C, name = "left_input",    type = "float" },
    { offset = 0x280, name = "up_input",      type = "float" },
    
    -- Gating flag — must be 3 for FUN_0056ff40 animator to fire.
    { offset = 0x289, name = "gating_flag",   type = "byte" },
}

-- Diagnostic offsets — known Halo CE PlayerObject fields used to verify
-- that get_dynamic_player() points to the same structure the game code
-- accesses at [puVar+0x2A3].
local DIAG_OFFSETS = {
    { offset = 0x14, name = "velocity_z",     type = "float" },
    { offset = 0x5C, name = "position_x",     type = "float" },
    { offset = 0x68, name = "velocity_x",     type = "float" },
    { offset = 0x6C, name = "velocity_y",     type = "float" },
    { offset = 0x70, name = "velocity_z_alt",  type = "float" },
    { offset = 0xD0, name = "base_animation",  type = "word" },
    { offset = 0xD2, name = "current_frame",   type = "word" },
    { offset = 0x106, name = "flags_byte",     type = "byte" },
    { offset = 0x13D, name = "animation_id",   type = "dword" },
    { offset = 0x289, name = "gating_flag",    type = "byte" },
    { offset = 0x2B2, name = "transition_idx", type = "word" },
}

-- Reads key PlayerObject fields and prints annotated output so we can verify
-- that Chimera's get_dynamic_player() returns the same base pointer the game
-- code accesses at [puVar+0x2A3]. Run: hrl_ghost_diag.
local function diagnose_player()
    local player = get_dynamic_player()
    if not player or player == 0 then
        console_out("[diag] no local player", 1, 0.35, 0.35)
        return nil
    end
    local diag = { pointer = player }
    for _, d in ipairs(DIAG_OFFSETS) do
        local v
        if d.type == "float" then v = read_float(player + d.offset)
        elseif d.type == "word" then v = read_word(player + d.offset)
        elseif d.type == "dword" then v = read_dword(player + d.offset)
        elseif d.type == "byte" then v = read_byte(player + d.offset)
        end
        diag[d.name] = { offset = string.format("0x%03X", d.offset), value = v }
    end
    console_out(string.format("[diag] player pointer: 0x%X", player), 1.5, 0.9, 0.3)
    for _, d in ipairs(DIAG_OFFSETS) do
        local e = diag[d.name]
        if e then
            console_out(string.format("[diag] +0x%03X %-20s = %s", d.offset, d.name, tostring(e.value or "nil")), 1.5, 0.9, 0.3)
        end
    end
    return diag
end
DebugCore.register("player_diag", diagnose_player)

local function read_candidate_fields()
    local player = get_dynamic_player()
    if not player or player == 0 then return { error = "local player biped is unavailable" } end
    
    local result = {}
    for _, cand in ipairs(CANDIDATE_OFFSETS) do
        local value
        if cand.type == "dword" then
            value = read_dword(player + cand.offset)
        elseif cand.type == "float" then
            value = read_float(player + cand.offset)
        elseif cand.type == "word" then
            value = read_word(player + cand.offset)
        elseif cand.type == "byte" then
            value = read_byte(player + cand.offset)
        else
            value = nil
        end
        result[cand.name] = {
            offset = string.format("0x%03X", cand.offset),
            type   = cand.type,
            value  = value,
        }
    end
    return result
end

DebugCore.register("animation_fields", read_candidate_fields)

local animation_field_records = {}  -- hoisted above consumers so the dump source can always iterate it safely.

-- ============================================================
-- Per-tick auto-sampler for movement-correlation data.
--
-- Runs every game tick, captures all candidate fields plus a small
-- "input_state" label derived from forward_input/left_input/up_input
-- (>0 means that axis is held). Tagged by tick number so we can
-- correlate with replay timestamps later if needed.
-- ============================================================
local auto_movement_samples = {}
local AUTO_SAMPLE_ENABLED = false

local function classify_input_state(forward, left, up)
    local parts = {}
    if forward > 0.1 then table.insert(parts, "f") end
    if forward < -0.1 then table.insert(parts, "b") end
    if left < -0.1 then table.insert(parts, "l") end   -- Chimera flips Y input sign conventionally
    if left > 0.1 then table.insert(parts, "r") end
    if up > 0.1 then table.insert(parts, "j") end      -- jumping / upward
    return #parts == 0 and "idle" or table.concat(parts, "+")
end

local function tick_sample()
    if not AUTO_SAMPLE_ENABLED then return end
    local player = get_dynamic_player()
    if not player or player == 0 then return end
    
    local forward = read_float(player + 0x278)
    local left    = read_float(player + 0x27C)
    local up      = read_float(player + 0x280)
    
    local state = classify_input_state(forward, left, up)
    
    -- Capture all candidate fields in one pass.
    local f = {}
    for _, cand in ipairs(CANDIDATE_OFFSETS) do
        local v
        if cand.type == "dword" then v = read_dword(player + cand.offset)
        elseif cand.type == "float" then v = read_float(player + cand.offset)
        elseif cand.type == "word" then v = read_word(player + cand.offset)
        elseif cand.type == "byte" then v = read_byte(player + cand.offset)
        end
        f[cand.name] = { offset = string.format("0x%03X", cand.offset), value = v }
    end
    
    auto_movement_samples[#auto_movement_samples + 1] = {
        tick     = ticks(),
        state    = state,
        inputs   = { forward = forward, left = left, up = up },
        fields   = f,
    }
end

-- ============================================================
local function read_animation_records()
    local out = {}
    for name, rec in pairs(animation_field_records) do
        out[name] = rec.fields
    end
    return { count = #animation_field_records, records = out }
end
DebugCore.register("animation_records", read_animation_records)

local function read_auto_samples()
    local by_state = {}
    for _, s in ipairs(auto_movement_samples) do
        by_state[s.state] = by_state[s.state] or {}
        by_state[s.state][#by_state[s.state] + 1] = { tick = s.tick, inputs = s.inputs, fields = s.fields }
    end
    local summary = {}
    for state, list in pairs(by_state) do summary[#summary + 1] = { state = state, count = #list } end
    return { enabled = AUTO_SAMPLE_ENABLED, total = #auto_movement_samples, by_state = summary, samples = by_state }
end
DebugCore.register("auto_movement_samples", read_auto_samples)

-- ============================================================
-- Labeled activity recording for animation-field correlation.
--
-- Instead of snapshot/diff (which requires fiddling with console state
-- between exercises), you record one labelled snapshot per activity in
-- a single session, then dump a comparison matrix at the end:
--
--   hrl_ghost_anim_record idle       # stand still
--   <walk forward>
--   hrl_ghost_anim_record forward
--   ...
--   hrl_ghost_anim_compare           # prints correlation table
--   hrl_ghost_anim_reset             # clear all records
-- ============================================================

local function read_all_candidate_values()
    local player = get_dynamic_player()
    if not player or player == 0 then return nil, "local player biped is unavailable" end
    
    local values = {}
    for _, cand in ipairs(CANDIDATE_OFFSETS) do
        local v
        if cand.type == "dword" then
            v = read_dword(player + cand.offset)
        elseif cand.type == "float" then
            v = read_float(player + cand.offset)
        elseif cand.type == "word" then
            v = read_word(player + cand.offset)
        elseif cand.type == "byte" then
            v = read_byte(player + cand.offset)
        else
            v = nil
        end
        values[cand.name] = { offset = string.format("0x%03X", cand.offset), value = v }
    end
    return values
end

local function record_activity(name)
    local player = get_dynamic_player()
    if not player or player == 0 then 
        console_out("[HRL Ghost] Record failed: local player biped is unavailable", 1.0, 0.35, 0.35)
        return false
    end
    if type(name) ~= "string" or name == "" then
        console_out("[HRL Ghost] Usage: hrl_ghost_anim_record <name>", 1.0, 0.75, 0.25)
        return false
    end
    local values, read_err = read_all_candidate_values()
    if not values then
        console_out("[HRL Ghost] Record failed: " .. tostring(read_err), 1.0, 0.35, 0.35)
        return false
    end
    animation_field_records[name] = { tick = ticks(), fields = values }
    console_out(string.format("[HRL Ghost] Recorded activity '%s' (%d candidates) at tick %g", name, #CANDIDATE_OFFSETS, ticks()), 1.0, 0.75, 0.25)
    return true
end

local function format_value(v)
    if v == nil then return "nil"
    elseif type(v) == "number" and v ~= math.floor(v) then return string.format("%.3f", v)
    else return tostring(v)
    end
end

local function compare_activities()
    local names = {}
    for n, _ in pairs(animation_field_records) do names[#names + 1] = n end
    if #names == 0 then
        log("No activities recorded yet. Use hrl_ghost_anim_record <name> first", 1.0, 0.75, 0.25)
        return false
    end
    
    -- Header row.
    local header = string.format("%-6s %-14s", "off", "field")
    for _, n in ipairs(names) do header = header .. string.format("  %12s", n) end
    console_out(header, 1.0, 1.0, 0.5)
    
    local changed_count = 0
    -- One row per candidate field.
    for _, cand in ipairs(CANDIDATE_OFFSETS) do
        local base_record = animation_field_records[names[1]]
        local offset_label = (base_record and base_record.fields[cand.name] and base_record.fields[cand.name].offset) or "??"
        local row = string.format("%-6s %-14s", offset_label, cand.name)
        for _, n in ipairs(names) do
            local rec = animation_field_records[n]
            local v = (rec and rec.fields[cand.name])
            if v then row = row .. string.format("  %12s", format_value(v.value))
            else row = row .. "         nil"
            end
        end
        console_out(row, 0.85, 0.9, 1.0)
    end
    
    -- Summary: which fields changed across activities.
    local selectors = {}
    for _, cand in ipairs(CANDIDATE_OFFSETS) do
        local seen = {}
        local unique_count = 0
        for _, n in ipairs(names) do
            local v = animation_field_records[n].fields[cand.name]
            if v then
                local key = format_value(v.value)
                if not seen[key] then seen[key] = true; unique_count = unique_count + 1 end
            end
        end
        -- Heuristic: a selector has <= 8 distinct values across all activities.
        if unique_count > 0 and unique_count <= 8 then
            selectors[#selectors + 1] = string.format("  +0x%s %-12s %d distinct value(s)", cand.offset, cand.name, unique_count)
            changed_count = changed_count + 1
        end
    end
    if changed_count > 0 then
        log(string.format("Fields with <= 8 distinct values across %d activities (likely selectors):", #names))
        for _, s in ipairs(selectors) do console_out(s, 1.0, 0.85, 0.4) end
    else
        log("No field showed <= 8 distinct values — none looks like a small discrete selector yet.", 1.0, 0.75, 0.25)
    end
    return true
end

local function reset_activity_records()
    animation_field_records = {}
    log("Animation activity records cleared", 1.0, 0.75, 0.25)
end

local function log(message, r, g, b)
    console_out("[HRL Ghost] " .. tostring(message), r or 0.65, g or 0.85, b or 1.0)
end

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parse_integer(value)
    value = trim(tostring(value or ""))
    if value == "" then return nil end

    local hex = value:match("^0[xX]([0-9a-fA-F]+)$")
    if hex then
        return tonumber(hex, 16)
    end

    return tonumber(value)
end

local function clear_capture_arm()
    test_cyborg.capture_arm.mode = nil
    test_cyborg.capture_arm.target_tick = nil
    test_cyborg.capture_arm.condition = nil
    test_cyborg.capture_arm.delay_ticks = 3
    test_cyborg.capture_arm.triggered = false
    test_cyborg.capture_arm.trigger_tick = nil
end

local function delete_test_cyborg(message)
    if test_cyborg.object_id then
        pcall(delete_object, test_cyborg.object_id)
    end

    test_cyborg.object_id = nil
    test_cyborg.hold = false
    test_cyborg.copy_live_compact = false
    test_cyborg.frame_sweep.enabled = false
    clear_capture_arm()

    if message then
        log(message)
    end
end

local function get_test_cyborg_object()
    if not test_cyborg.object_id then
        return nil, "no test cyborg; run hrl_ghost_spawn_cyborg first"
    end

    local object = get_object(test_cyborg.object_id)
    if not object then
        test_cyborg.object_id = nil
        test_cyborg.hold = false
        return nil, "test cyborg object disappeared"
    end

    return object
end

local function spawn_test_cyborg(distance)
    delete_test_cyborg()

    local player = get_dynamic_player()
    if not player or player == 0 then
        log("Cannot spawn test cyborg: local player biped is unavailable", 1.0, 0.35, 0.35)
        return false
    end

    if not get_tag(BIPED_CLASS, BIPED_TAG) then
        log("Cannot spawn test cyborg: biped tag not found: " .. BIPED_TAG, 1.0, 0.35, 0.35)
        return false
    end

    distance = tonumber(distance) or 2.5
    if distance < 0.5 then distance = 0.5 end
    if distance > 20 then distance = 20 end

    local px = read_float(player + POSITION_OFFSET)
    local py = read_float(player + POSITION_OFFSET + 4)
    local pz = read_float(player + POSITION_OFFSET + 8)

    local fx = read_float(player + OBJECT_FORWARD_OFFSET)
    local fy = read_float(player + OBJECT_FORWARD_OFFSET + 4)
    local fz = read_float(player + OBJECT_FORWARD_OFFSET + 8)

    local object_id = spawn_object(
        BIPED_CLASS,
        BIPED_TAG,
        px + fx * distance,
        py + fy * distance,
        pz + fz * distance
    )

    if not object_id then
        log("Cannot spawn test cyborg: spawn_object failed", 1.0, 0.35, 0.35)
        return false
    end

    local object = get_object(object_id)
    if not object then
        pcall(delete_object, object_id)
        log("Cannot spawn test cyborg: spawned object has no pointer", 1.0, 0.35, 0.35)
        return false
    end

    test_cyborg.object_id = object_id
    test_cyborg.state = read_byte(player + ANIMATION_STATE_OFFSET)
    test_cyborg.stance = read_byte(player + ANIMATION_STANCE_OFFSET)
    test_cyborg.action = read_byte(player + ANIMATION_STATE_OFFSET + 1)
    test_cyborg.hold = false

    -- Give the spawned object the same animation graph context as the player.
    -- The later test commands alter only the compact state fields.
    write_dword(object + ANIMATION_TAG_OFFSET, read_dword(player + ANIMATION_TAG_OFFSET))
    write_byte(object + ANIMATION_STANCE_OFFSET, test_cyborg.stance)
    write_byte(object + ANIMATION_STATE_OFFSET, test_cyborg.state)
    write_byte(object + ANIMATION_STATE_OFFSET + 1, test_cyborg.action)

    -- Face the spawned cyborg back toward the player so its full-body result is visible.
    write_float(object + OBJECT_FORWARD_OFFSET, -fx)
    write_float(object + OBJECT_FORWARD_OFFSET + 4, -fy)
    write_float(object + OBJECT_FORWARD_OFFSET + 8, -fz)

    log(string.format(
        "Spawned test cyborg id=0x%08X ptr=0x%08X distance=%.2f; use hrl_ghost_set_animation_state <state> [stance] [action]",
        object_id,
        object,
        distance
    ))

    return true
end

local function copy_live_compact_animation_to_test()
    if not test_cyborg.copy_live_compact then return end

    local object, object_err = get_test_cyborg_object()
    if not object then
        log("Compact animation copy stopped: " .. tostring(object_err), 1.0, 0.35, 0.35)
        return
    end

    local player = get_dynamic_player()
    if not player or player == 0 then
        return
    end

    -- Animation graph/context and compact playback state only.
    -- No bone/body-part matrices are copied.
    write_dword(object + ANIMATION_TAG_OFFSET, read_dword(player + ANIMATION_TAG_OFFSET))
    write_word(object + BASE_ANIMATION_OFFSET, read_word(player + BASE_ANIMATION_OFFSET))
    write_word(object + BASE_FRAME_OFFSET, read_word(player + BASE_FRAME_OFFSET))
    write_word(object + TRANSITION_FRAME_OFFSET, read_word(player + TRANSITION_FRAME_OFFSET))
    write_word(object + TRANSITION_LENGTH_OFFSET, read_word(player + TRANSITION_LENGTH_OFFSET))
    write_byte(object + ANIMATION_STANCE_OFFSET, read_byte(player + ANIMATION_STANCE_OFFSET))
    write_byte(object + ANIMATION_STATE_OFFSET, read_byte(player + ANIMATION_STATE_OFFSET))
    write_byte(object + ANIMATION_STATE_OFFSET + 1, read_byte(player + ANIMATION_STATE_OFFSET + 1))
    write_byte(object + ANIMATION_CROUCH_OFFSET, read_byte(player + ANIMATION_CROUCH_OFFSET))

    -- Copy the compact control inputs and velocity that may be required by
    -- the native animation updater. These are still tiny compared with poses.
    write_float(object + UNIT_FORWARD_INPUT_OFFSET, read_float(player + UNIT_FORWARD_INPUT_OFFSET))
    write_float(object + UNIT_LEFT_INPUT_OFFSET, read_float(player + UNIT_LEFT_INPUT_OFFSET))
    write_float(object + UNIT_UP_INPUT_OFFSET, read_float(player + UNIT_UP_INPUT_OFFSET))
    write_float(object + VELOCITY_OFFSET, read_float(player + VELOCITY_OFFSET))
    write_float(object + VELOCITY_OFFSET + 4, read_float(player + VELOCITY_OFFSET + 4))
    write_float(object + VELOCITY_OFFSET + 8, read_float(player + VELOCITY_OFFSET + 8))
end

local function toggle_live_compact_copy()
    local object, err = get_test_cyborg_object()
    if not object then
        log("Cannot toggle compact copy: " .. tostring(err), 1.0, 0.35, 0.35)
        return false
    end

    test_cyborg.copy_live_compact = not test_cyborg.copy_live_compact
    test_cyborg.hold = false

    if test_cyborg.copy_live_compact then
        copy_live_compact_animation_to_test()
        log("Live compact animation copy ON (graph, indices, frames, state, stance, controls, velocity; no bones)")
    else
        log("Live compact animation copy OFF")
    end

    return true
end

local function print_test_status()
    local object, err = get_test_cyborg_object()
    if not object then
        log("Cannot report test status: " .. tostring(err), 1.0, 0.35, 0.35)
        return false
    end

    local player = get_dynamic_player()
    if not player or player == 0 then
        log("Cannot report test status: local player unavailable", 1.0, 0.35, 0.35)
        return false
    end

    local function compact(prefix, ptr)
        return string.format(
            "%s ptr=0x%08X tag=0x%08X base=%d frame=%d trans=%d/%d stance=%d state=%d action=%d crouch=%d input=(%.2f,%.2f,%.2f) vel=(%.3f,%.3f,%.3f)",
            prefix,
            ptr,
            read_dword(ptr + ANIMATION_TAG_OFFSET),
            read_word(ptr + BASE_ANIMATION_OFFSET),
            read_word(ptr + BASE_FRAME_OFFSET),
            read_word(ptr + TRANSITION_FRAME_OFFSET),
            read_word(ptr + TRANSITION_LENGTH_OFFSET),
            read_byte(ptr + ANIMATION_STANCE_OFFSET),
            read_byte(ptr + ANIMATION_STATE_OFFSET),
            read_byte(ptr + ANIMATION_STATE_OFFSET + 1),
            read_byte(ptr + ANIMATION_CROUCH_OFFSET),
            read_float(ptr + UNIT_FORWARD_INPUT_OFFSET),
            read_float(ptr + UNIT_LEFT_INPUT_OFFSET),
            read_float(ptr + UNIT_UP_INPUT_OFFSET),
            read_float(ptr + VELOCITY_OFFSET),
            read_float(ptr + VELOCITY_OFFSET + 4),
            read_float(ptr + VELOCITY_OFFSET + 8)
        )
    end

    console_out("[HRL Ghost Test] " .. compact("player", player), 0.75, 0.9, 1.0)
    console_out("[HRL Ghost Test] " .. compact("cyborg", object), 0.75, 0.9, 1.0)
    log(string.format(
        "Modes: manual_hold=%s compact_copy=%s",
        tostring(test_cyborg.hold),
        tostring(test_cyborg.copy_live_compact)
    ))
    return true
end

local function read_compact_animation(ptr)
    return {
        animation_tag = read_dword(ptr + ANIMATION_TAG_OFFSET),
        base_animation = read_word(ptr + BASE_ANIMATION_OFFSET),
        base_frame = read_word(ptr + BASE_FRAME_OFFSET),
        transition_frame = read_word(ptr + TRANSITION_FRAME_OFFSET),
        transition_length = read_word(ptr + TRANSITION_LENGTH_OFFSET),
        stance = read_byte(ptr + ANIMATION_STANCE_OFFSET),
        state = read_byte(ptr + ANIMATION_STATE_OFFSET),
        action = read_byte(ptr + ANIMATION_STATE_OFFSET + 1),
        crouch = read_byte(ptr + ANIMATION_CROUCH_OFFSET),
    }
end

local function write_compact_animation(ptr, anim)
    write_dword(ptr + ANIMATION_TAG_OFFSET, anim.animation_tag or 0)
    write_word(ptr + BASE_ANIMATION_OFFSET, anim.base_animation or 0)
    write_word(ptr + BASE_FRAME_OFFSET, anim.base_frame or 0)
    write_word(ptr + TRANSITION_FRAME_OFFSET, anim.transition_frame or 0)
    write_word(ptr + TRANSITION_LENGTH_OFFSET, anim.transition_length or 0)
    write_byte(ptr + ANIMATION_STANCE_OFFSET, anim.stance or 4)
    write_byte(ptr + ANIMATION_STATE_OFFSET, anim.state or 0)
    write_byte(ptr + ANIMATION_STATE_OFFSET + 1, anim.action or 0)
    write_byte(ptr + ANIMATION_CROUCH_OFFSET, anim.crouch or 2)
end

local function arm_capture_in(argument)
    local seconds = tonumber(trim(tostring(argument or "")))
    if not seconds or seconds < 0.1 or seconds > 30 then
        log("Usage: hrl_ghost_capture_in <0.1-30 seconds>", 1.0, 0.75, 0.25)
        return false
    end

    test_cyborg.capture_arm.mode = "delay"
    test_cyborg.capture_arm.target_tick = ticks() + seconds * tick_rate()
    test_cyborg.capture_arm.condition = nil

    log(string.format(
        "Capture armed for %.2f second(s). Close console and perform the action now.",
        seconds
    ))
    return true
end

local VALID_CAPTURE_CONDITIONS = {
    jump = true,
    forward = true,
    back = true,
    left = true,
    right = true,
    airborne = true,
}

local function arm_capture_on(argument)
    local condition, delay_text =
        tostring(argument or ""):match("^%s*(%S+)%s*(%S*)%s*$")

    condition = trim(tostring(condition or "")):lower()
    local delay_ticks = delay_text ~= "" and parse_integer(delay_text) or 3

    if not VALID_CAPTURE_CONDITIONS[condition] then
        log("Usage: hrl_ghost_capture_on <jump|forward|back|left|right|airborne> [delay-ticks]", 1.0, 0.75, 0.25)
        return false
    end

    if delay_ticks == nil or delay_ticks < 0 or delay_ticks > 60 then
        log("Capture delay must be between 0 and 60 ticks", 1.0, 0.75, 0.25)
        return false
    end

    test_cyborg.capture_arm.mode = "condition"
    test_cyborg.capture_arm.target_tick = nil
    test_cyborg.capture_arm.condition = condition
    test_cyborg.capture_arm.delay_ticks = math.floor(delay_ticks)
    test_cyborg.capture_arm.triggered = false
    test_cyborg.capture_arm.trigger_tick = nil

    log(string.format(
        "Capture armed for '%s'; snapshot will be taken %d tick(s) after detection. Close console and perform the action.",
        condition,
        test_cyborg.capture_arm.delay_ticks
    ))
    return true
end

local function capture_condition_met(player, condition)
    local forward = read_float(player + UNIT_FORWARD_INPUT_OFFSET)
    local left = read_float(player + UNIT_LEFT_INPUT_OFFSET)
    local up = read_float(player + UNIT_UP_INPUT_OFFSET)
    local state = read_byte(player + ANIMATION_STATE_OFFSET)

    if condition == "jump" then
        return up > 0.1
    elseif condition == "forward" then
        return forward > 0.1
    elseif condition == "back" then
        return forward < -0.1
    elseif condition == "left" then
        return left < -0.1
    elseif condition == "right" then
        return left > 0.1
    elseif condition == "airborne" then
        return state == 20
    end

    return false
end

local function capture_live_animation()
    local player = get_dynamic_player()
    if not player or player == 0 then
        log("Cannot capture animation: local player unavailable", 1.0, 0.35, 0.35)
        return false
    end

    test_cyborg.captured = read_compact_animation(player)

    log(string.format(
        "Captured live animation: tag=0x%08X base=%d frame=%d transition=%d/%d stance=%d state=%d action=%d crouch=%d",
        test_cyborg.captured.animation_tag,
        test_cyborg.captured.base_animation,
        test_cyborg.captured.base_frame,
        test_cyborg.captured.transition_frame,
        test_cyborg.captured.transition_length,
        test_cyborg.captured.stance,
        test_cyborg.captured.state,
        test_cyborg.captured.action,
        test_cyborg.captured.crouch
    ))
    return true
end

local function update_armed_capture()
    local arm = test_cyborg.capture_arm
    if not arm.mode then return end

    local player = get_dynamic_player()
    if not player or player == 0 then return end

    local should_capture = false

    if arm.mode == "delay" then
        should_capture = ticks() >= arm.target_tick

    elseif arm.mode == "condition" then
        if not arm.triggered then
            if capture_condition_met(player, arm.condition) then
                arm.triggered = true
                arm.trigger_tick = ticks()
                log(string.format(
                    "Detected '%s'; capturing in %d tick(s)",
                    tostring(arm.condition),
                    arm.delay_ticks
                ))
            end
            return
        end

        should_capture = ticks() >= (arm.trigger_tick + arm.delay_ticks)
    end

    if not should_capture then return end

    local mode = arm.mode
    local condition = arm.condition
    local delay_ticks = arm.delay_ticks
    clear_capture_arm()

    if capture_live_animation() then
        if mode == "condition" then
            log(string.format(
                "Automatic capture completed %d tick(s) after '%s'",
                delay_ticks,
                tostring(condition)
            ))
        else
            log("Delayed animation capture completed")
        end
    end
end

local function apply_captured_animation()
    local object, err = get_test_cyborg_object()
    if not object then
        log("Cannot apply captured animation: " .. tostring(err), 1.0, 0.35, 0.35)
        return false
    end
    if not test_cyborg.captured then
        log("No captured animation; run hrl_ghost_capture_live_animation first", 1.0, 0.75, 0.25)
        return false
    end

    test_cyborg.copy_live_compact = false
    test_cyborg.hold = false
    test_cyborg.frame_sweep.enabled = false
    write_compact_animation(object, test_cyborg.captured)
    log("Applied captured compact animation snapshot to test cyborg")
    return true
end

local function set_test_base_animation(argument)
    local value = parse_integer(argument)
    if value == nil or value < 0 or value > 65535 then
        log("Usage: hrl_ghost_set_base_animation <0-65535>", 1.0, 0.75, 0.25)
        return false
    end

    local object, err = get_test_cyborg_object()
    if not object then
        log("Cannot set base animation: " .. tostring(err), 1.0, 0.35, 0.35)
        return false
    end

    test_cyborg.copy_live_compact = false
    test_cyborg.hold = false
    test_cyborg.frame_sweep.enabled = false
    write_word(object + BASE_ANIMATION_OFFSET, math.floor(value))
    log(string.format("Set test cyborg base animation=%d", math.floor(value)))
    return true
end

local function set_test_frame(argument)
    local value = parse_integer(argument)
    if value == nil or value < 0 or value > 65535 then
        log("Usage: hrl_ghost_set_frame <0-65535>", 1.0, 0.75, 0.25)
        return false
    end

    local object, err = get_test_cyborg_object()
    if not object then
        log("Cannot set frame: " .. tostring(err), 1.0, 0.35, 0.35)
        return false
    end

    test_cyborg.copy_live_compact = false
    test_cyborg.hold = false
    test_cyborg.frame_sweep.enabled = false
    write_word(object + BASE_FRAME_OFFSET, math.floor(value))
    log(string.format(
        "Set test cyborg frame=%d (base animation=%d)",
        math.floor(value),
        read_word(object + BASE_ANIMATION_OFFSET)
    ))
    return true
end

local function start_frame_sweep(argument)
    local a, b, c, d = tostring(argument or ""):match("^%s*(%S*)%s*(%S*)%s*(%S*)%s*(%S*)%s*$")
    local start_frame = a ~= "" and parse_integer(a) or 0
    local end_frame = b ~= "" and parse_integer(b) or 30
    local step = c ~= "" and parse_integer(c) or 1
    local ticks_per_frame = d ~= "" and parse_integer(d) or 1

    if start_frame == nil or end_frame == nil or step == nil or ticks_per_frame == nil
        or start_frame < 0 or start_frame > 65535
        or end_frame < 0 or end_frame > 65535
        or step == 0
        or ticks_per_frame < 1 or ticks_per_frame > 600 then
        log("Usage: hrl_ghost_frame_sweep [start] [end] [step] [ticks-per-frame]", 1.0, 0.75, 0.25)
        return false
    end

    local object, err = get_test_cyborg_object()
    if not object then
        log("Cannot start frame sweep: " .. tostring(err), 1.0, 0.35, 0.35)
        return false
    end

    test_cyborg.copy_live_compact = false
    test_cyborg.hold = false
    test_cyborg.frame_sweep.enabled = true
    test_cyborg.frame_sweep.start_frame = math.floor(start_frame)
    test_cyborg.frame_sweep.end_frame = math.floor(end_frame)
    test_cyborg.frame_sweep.step = math.floor(step)
    test_cyborg.frame_sweep.ticks_per_frame = math.floor(ticks_per_frame)
    test_cyborg.frame_sweep.tick_counter = 0
    test_cyborg.frame_sweep.frame = math.floor(start_frame)

    write_word(object + BASE_FRAME_OFFSET, test_cyborg.frame_sweep.frame)

    log(string.format(
        "Frame sweep ON: animation=%d frames=%d..%d step=%d every %d tick(s)",
        read_word(object + BASE_ANIMATION_OFFSET),
        test_cyborg.frame_sweep.start_frame,
        test_cyborg.frame_sweep.end_frame,
        test_cyborg.frame_sweep.step,
        test_cyborg.frame_sweep.ticks_per_frame
    ))
    return true
end

local function stop_frame_sweep()
    test_cyborg.frame_sweep.enabled = false
    log("Frame sweep OFF")
    return true
end

local function update_frame_sweep()
    local sweep = test_cyborg.frame_sweep
    if not sweep.enabled then return end

    local object, err = get_test_cyborg_object()
    if not object then
        log("Frame sweep stopped: " .. tostring(err), 1.0, 0.35, 0.35)
        return
    end

    sweep.tick_counter = sweep.tick_counter + 1
    if sweep.tick_counter < sweep.ticks_per_frame then
        return
    end
    sweep.tick_counter = 0

    write_word(object + BASE_FRAME_OFFSET, sweep.frame)

    local next_frame = sweep.frame + sweep.step
    if sweep.step > 0 and next_frame > sweep.end_frame then
        next_frame = sweep.start_frame
    elseif sweep.step < 0 and next_frame < sweep.end_frame then
        next_frame = sweep.start_frame
    end
    sweep.frame = next_frame
end

local COMPARE_RANGES = {
    { start_offset = 0x100, end_offset = 0x140 },
    { start_offset = 0x260, end_offset = 0x2C0 },
}

local function safe_read_dword(address)
    local ok, value = pcall(read_dword, address)
    if ok then return value end
    return nil
end

local function safe_read_word(address)
    local ok, value = pcall(read_word, address)
    if ok then return value end
    return nil
end

local function safe_read_byte(address)
    local ok, value = pcall(read_byte, address)
    if ok then return value end
    return nil
end

local function fmt_hex(value, width)
    if value == nil then return "unreadable" end
    return string.format("0x%0" .. tostring(width or 8) .. "X", value)
end

local function datum_index(object_id)
    -- Candidate Halo datum index convention: low 16 bits are the table index.
    -- This is printed as a hypothesis and is not used for any writes.
    return object_id % 0x10000
end

local function inspect_registration_for_id(label, object_id)
    local index = datum_index(object_id)
    local object = get_object(object_id)

    local global_value = safe_read_dword(SUB_OBJECT_TABLE_GLOBAL)
    local direct_entry = SUB_OBJECT_TABLE_GLOBAL
        + SUB_OBJECT_TABLE_OFFSET
        + index * SUB_OBJECT_ENTRY_STRIDE

    local indirect_base = global_value
        and (global_value + SUB_OBJECT_TABLE_OFFSET)
        or nil
    local indirect_entry = indirect_base
        and (indirect_base + index * SUB_OBJECT_ENTRY_STRIDE)
        or nil

    local result = {
        label = label,
        object_id = object_id,
        candidate_index = index,
        object_ptr = object,
        table = {
            global_address = SUB_OBJECT_TABLE_GLOBAL,
            global_value = global_value,
            direct_entry = direct_entry,
            indirect_entry = indirect_entry,
        },
        entries = {},
    }

    local candidates = {
        { name = "direct", address = direct_entry },
        { name = "indirect", address = indirect_entry },
    }

    for _, candidate in ipairs(candidates) do
        if candidate.address then
            local entry_ptr = safe_read_dword(
                candidate.address + SUB_OBJECT_POINTER_OFFSET
            )

            local entry = {
                address = candidate.address,
                dword_0 = safe_read_dword(candidate.address + 0x00),
                dword_4 = safe_read_dword(candidate.address + 0x04),
                pointer_8 = entry_ptr,
            }

            if entry_ptr and entry_ptr ~= 0 and entry_ptr ~= 0xFFFFFFFF then
                entry.resolved = {
                    address = entry_ptr,
                    state_b8 = safe_read_byte(entry_ptr + SUB_OBJECT_STATE_OFFSET),
                    handle_1f4 = safe_read_dword(entry_ptr + SUB_OBJECT_HANDLE_OFFSET),
                }
            end

            result.entries[candidate.name] = entry
        end
    end

    local animation_slot = ANIMATION_SLOT_BASE + index * ANIMATION_SLOT_STRIDE
    result.animation_slot = {
        address = animation_slot,
        dword_0 = safe_read_dword(animation_slot + 0x00),
        dword_4 = safe_read_dword(animation_slot + 0x04),
        dword_8 = safe_read_dword(animation_slot + 0x08),
        dword_c = safe_read_dword(animation_slot + 0x0C),
    }

    return result
end

local function get_local_player_object_id()
    if type(get_player) ~= "function" then
        return nil, "get_player() is unavailable"
    end

    local player_entry = get_player()
    if not player_entry or player_entry == 0 then
        return nil, "local player table entry is unavailable"
    end

    local object_id = read_dword(player_entry + 0x34)
    if not object_id or object_id == 0 or object_id == 0xFFFFFFFF then
        return nil, "local player object ID is invalid"
    end

    local resolved = get_object(object_id)
    local dynamic = get_dynamic_player()

    if not resolved or resolved == 0 then
        return nil, string.format(
            "object ID 0x%08X does not resolve",
            object_id
        )
    end

    if not dynamic or dynamic == 0 then
        return nil, "get_dynamic_player() is unavailable"
    end

    if resolved ~= dynamic then
        return nil, string.format(
            "player object mismatch: id=0x%08X resolves=0x%08X dynamic=0x%08X",
            object_id,
            resolved,
            dynamic
        )
    end

    return object_id, nil, {
        player_entry = player_entry,
        resolved = resolved,
        dynamic = dynamic,
    }
end

local function print_local_player_object_id()
    local object_id, err, info = get_local_player_object_id()
    if not object_id then
        log("Could not resolve local player object ID: " .. tostring(err), 1.0, 0.35, 0.35)
        return false
    end

    log(string.format(
        "player_entry=0x%08X object_id=0x%08X object=0x%08X dynamic=0x%08X match=true",
        info.player_entry,
        object_id,
        info.resolved,
        info.dynamic
    ))

    return true
end

local registration_diag_comparison_id = nil

local function collect_registration_diag()
    local result = {
        note = "READ-ONLY diagnostic; low-16-bit datum indexing remains a hypothesis",
        cyborg = nil,
        comparison = nil,
    }

    if test_cyborg.object_id then
        result.cyborg = inspect_registration_for_id("cyborg", test_cyborg.object_id)
    else
        result.cyborg = { error = "no test cyborg spawned" }
    end

    if registration_diag_comparison_id then
        result.comparison = inspect_registration_for_id(
            "comparison",
            registration_diag_comparison_id
        )
    end

    return result
end

DebugCore.register("registration_diag", collect_registration_diag)

local function registration_diag(argument)
    local raw = trim(tostring(argument or ""))

    if raw ~= "" then
        local comparison_id = parse_integer(raw)
        if not comparison_id then
            log("Comparison object ID must be decimal or 0x-prefixed hexadecimal", 1.0, 0.75, 0.25)
            return false
        end
        registration_diag_comparison_id = comparison_id
    else
        local local_object_id, err = get_local_player_object_id()
        if not local_object_id then
            log("Could not resolve local player for comparison: " .. tostring(err), 1.0, 0.35, 0.35)
            return false
        end
        registration_diag_comparison_id = local_object_id
    end

    if not test_cyborg.object_id then
        log("No test cyborg; run hrl_ghost_spawn_cyborg first", 1.0, 0.35, 0.35)
        return false
    end

    log(string.format(
        "Writing cyborg/player registration comparison to JSON (player object ID=0x%08X)...",
        registration_diag_comparison_id
    ))

    local ok = DebugCore.dump()
    if ok then
        log("Registration diagnostic written to " .. DebugCore.OUTPUT_FILE)
    else
        log("Registration diagnostic dump failed", 1.0, 0.35, 0.35)
    end

    return ok
end

local function compare_player_and_cyborg()
    local object, err = get_test_cyborg_object()
    if not object then
        log("Cannot compare cyborg: " .. tostring(err), 1.0, 0.35, 0.35)
        return false
    end

    local player = get_dynamic_player()
    if not player or player == 0 then
        log("Cannot compare cyborg: local player unavailable", 1.0, 0.35, 0.35)
        return false
    end

    local changes = {}
    for _, range in ipairs(COMPARE_RANGES) do
        for offset = range.start_offset, range.end_offset do
            local player_value = read_byte(player + offset)
            local cyborg_value = read_byte(object + offset)
            if player_value ~= cyborg_value then
                changes[#changes + 1] = {
                    offset = offset,
                    player = player_value,
                    cyborg = cyborg_value,
                }
            end
        end
    end

    log(string.format("Player/cyborg comparison found %d differing bytes", #changes))
    local limit = math.min(#changes, 120)
    for i = 1, limit do
        local item = changes[i]
        console_out(string.format(
            "[HRL Compare] +0x%03X player=%3d (0x%02X) cyborg=%3d (0x%02X)",
            item.offset,
            item.player,
            item.player,
            item.cyborg,
            item.cyborg
        ), 0.8, 0.9, 1.0)
    end
    if #changes > limit then
        log(string.format("%d additional differences omitted", #changes - limit), 1.0, 0.75, 0.25)
    end
    return true
end

local function apply_test_animation()
    if not test_cyborg.hold then return end

    local object, err = get_test_cyborg_object()
    if not object then
        log("Animation test stopped: " .. tostring(err), 1.0, 0.35, 0.35)
        return
    end

    write_byte(object + ANIMATION_STATE_OFFSET, test_cyborg.state)
    write_byte(object + ANIMATION_STANCE_OFFSET, test_cyborg.stance)
    write_byte(object + ANIMATION_STATE_OFFSET + 1, test_cyborg.action)
end

local function set_test_animation_state(argument)
    local state_text, stance_text, action_text =
        tostring(argument or ""):match("^%s*(%S+)%s*(%S*)%s*(%S*)%s*$")

    local state = parse_integer(state_text)
    local stance = stance_text ~= "" and parse_integer(stance_text) or test_cyborg.stance
    local action = action_text ~= "" and parse_integer(action_text) or test_cyborg.action

    if state == nil or state < 0 or state > 255 then
        log("Usage: hrl_ghost_set_animation_state <0-255|0x00-0xFF> [stance] [action]", 1.0, 0.75, 0.25)
        return false
    end

    if stance == nil or stance < 0 or stance > 255 then
        log("Invalid stance; expected byte value 0-255", 1.0, 0.35, 0.35)
        return false
    end

    if action == nil or action < 0 or action > 255 then
        log("Invalid action state; expected byte value 0-255", 1.0, 0.35, 0.35)
        return false
    end

    local object, err = get_test_cyborg_object()
    if not object then
        log("Cannot set animation: " .. tostring(err), 1.0, 0.35, 0.35)
        return false
    end

    test_cyborg.copy_live_compact = false
    test_cyborg.state = math.floor(state)
    test_cyborg.copy_live_compact = false
    test_cyborg.stance = math.floor(stance)
    test_cyborg.copy_live_compact = false
    test_cyborg.action = math.floor(action)
    test_cyborg.hold = true
    apply_test_animation()

    log(string.format(
        "Holding test cyborg animation: state=%d (0x%02X), stance=%d, action=%d",
        test_cyborg.state,
        test_cyborg.state,
        test_cyborg.stance,
        test_cyborg.action
    ))

    return true
end

local function set_test_stance(argument)
    local stance = parse_integer(argument)
    if stance == nil or stance < 0 or stance > 255 then
        log("Usage: hrl_ghost_set_stance <0-255>", 1.0, 0.75, 0.25)
        return false
    end

    local object, err = get_test_cyborg_object()
    if not object then
        log("Cannot set stance: " .. tostring(err), 1.0, 0.35, 0.35)
        return false
    end

    test_cyborg.stance = math.floor(stance)
    test_cyborg.hold = true
    apply_test_animation()
    log(string.format("Holding test cyborg stance=%d", test_cyborg.stance))
    return true
end

local function set_test_action_state(argument)
    local action = parse_integer(argument)
    if action == nil or action < 0 or action > 255 then
        log("Usage: hrl_ghost_set_action_state <0-255|0x00-0xFF>", 1.0, 0.75, 0.25)
        return false
    end

    local object, err = get_test_cyborg_object()
    if not object then
        log("Cannot set action state: " .. tostring(err), 1.0, 0.35, 0.35)
        return false
    end

    test_cyborg.action = math.floor(action)
    test_cyborg.hold = true
    apply_test_animation()
    log(string.format(
        "Holding test cyborg action=%d (0x%02X)",
        test_cyborg.action,
        test_cyborg.action
    ))
    return true
end

local function release_test_animation()
    local object, err = get_test_cyborg_object()
    if not object then
        log("Cannot release animation hold: " .. tostring(err), 1.0, 0.35, 0.35)
        return false
    end

    test_cyborg.hold = false
    test_cyborg.copy_live_compact = false
    test_cyborg.frame_sweep.enabled = false
    log(string.format(
        "Released animation controls; current state=%d stance=%d action=%d",
        read_byte(object + ANIMATION_STATE_OFFSET),
        read_byte(object + ANIMATION_STANCE_OFFSET),
        read_byte(object + ANIMATION_STATE_OFFSET + 1)
    ))
    return true
end

local function normalize_map_name(value)
    value = tostring(value or ""):lower()
    value = value:gsub("%.map$", "")
    return value
end

local function read_all(filename)
    local file, err = io.open(OUTPUT_DIR .. "\\" .. filename, "rb")
    if not file then
        return nil, err or "unable to open file"
    end

    local data = file:read("*a")
    file:close()
    return data
end

local function parse_header(data)
    local marker = "\n--- BINARY ---\n"
    local marker_start, marker_end = data:find(marker, 1, true)
    if not marker_start then
        return nil, nil, "missing binary marker"
    end

    local header_text = data:sub(1, marker_start - 1)
    local binary_start = marker_end + 1

    local header = {}
    local first = true

    for line in header_text:gmatch("[^\r\n]+") do
        if first then
            header.magic = trim(line)
            first = false
        else
            local key, value = line:match("^([^=]+)=(.*)$")
            if key then
                header[trim(key)] = trim(value)
            end
        end
    end

    if header.magic ~= "HRLREPLAY2" then
        return nil, nil, "unsupported replay magic: " .. tostring(header.magic)
    end

    return header, binary_start
end

local function decode_unsigned_varint(data, cursor)
    local value = 0
    local multiplier = 1

    for _ = 1, 10 do
        local byte = data:byte(cursor)
        if not byte then
            error("unexpected end of replay while reading varint")
        end

        cursor = cursor + 1
        value = value + (byte % 128) * multiplier

        if byte < 128 then
            return value, cursor
        end

        multiplier = multiplier * 128
    end

    error("invalid varint")
end

local function decode_signed_varint(data, cursor)
    local zigzag
    zigzag, cursor = decode_unsigned_varint(data, cursor)

    if zigzag % 2 == 0 then
        return zigzag / 2, cursor
    end

    return -((zigzag + 1) / 2), cursor
end

local function skip_bytes(data, cursor, count)
    if cursor + count - 1 > #data then
        error("unexpected end of replay while skipping payload")
    end
    return cursor + count
end

local function decode_replay(filename)
    local data, read_error = read_all(filename)
    if not data then
        return nil, "could not read replay: " .. tostring(read_error)
    end

    local header, cursor, header_error = parse_header(data)
    if not header then
        return nil, header_error
    end

    local encoding = header.encoding or "delta-varint-v3"
    local sample_count = tonumber(header.sample_count) or 0
    local position_scale = tonumber(header.position_scale) or 100
    local angle_scale = tonumber(header.angle_scale) or 1000
    local vehicle_scale = tonumber(header.vehicle_value_scale) or 1000
    local tick_rate_value = tonumber(header.tick_rate) or 30

    local has_animation = encoding == "delta-varint-v5" or encoding == "delta-varint-v6"
    local has_biped = encoding == "delta-varint-v4" or has_animation
    local has_detached = encoding == "delta-varint-v6"

    local state = {
        tick = -1,
        x = 0,
        y = 0,
        z = 0,
        yaw = 0,
        pitch = 0,
        roll = 0,
        vehicle_turn = 0,
        tire_position = 0,
        checkpoint = 0,
        animation = {
            base_animation = 0,
            base_frame = 0,
            transition_frame = 0,
            transition_length = 0,
            state = 0,
            stance = 0,
        },
        detached = {
            x = 0,
            y = 0,
            z = 0,
            yaw = 0,
            pitch = 0,
            roll = 0,
        },
    }

    local samples = {}

    local ok, decode_error = pcall(function()
        for index = 1, sample_count do
            local control = data:byte(cursor)
            if not control then
                error("unexpected end of replay at sample " .. index)
            end
            cursor = cursor + 1

            local in_vehicle = control % 2 == 1
            local checkpoint_changed = math.floor(control / 2) % 2 == 1
            local explicit_tick = math.floor(control / 4) % 2 == 1

            -- In v3/v4 bit 3 represented biped data. In v5/v6 it represents animation.
            local bit3 = math.floor(control / 8) % 2 == 1
            local bit4 = math.floor(control / 16) % 2 == 1
            local detached_included = math.floor(control / 32) % 2 == 1

            local animation_included = has_animation and bit3
            local biped_included = has_animation and bit4 or (not has_animation and has_biped and bit3)

            local tick_delta = 1
            if explicit_tick then
                tick_delta, cursor = decode_unsigned_varint(data, cursor)
            end
            state.tick = state.tick + tick_delta

            local delta
            delta, cursor = decode_signed_varint(data, cursor); state.x = state.x + delta
            delta, cursor = decode_signed_varint(data, cursor); state.y = state.y + delta
            delta, cursor = decode_signed_varint(data, cursor); state.z = state.z + delta
            delta, cursor = decode_signed_varint(data, cursor); state.yaw = state.yaw + delta
            delta, cursor = decode_signed_varint(data, cursor); state.pitch = state.pitch + delta
            delta, cursor = decode_signed_varint(data, cursor); state.roll = state.roll + delta
            delta, cursor = decode_signed_varint(data, cursor); state.vehicle_turn = state.vehicle_turn + delta
            delta, cursor = decode_signed_varint(data, cursor); state.tire_position = state.tire_position + delta

            if checkpoint_changed then
                state.checkpoint, cursor = decode_unsigned_varint(data, cursor)
            end

            if animation_included then
                local mask = data:byte(cursor)
                if not mask then error("missing animation mask") end
                cursor = cursor + 1

                local fields = {
                    "base_animation",
                    "base_frame",
                    "transition_frame",
                    "transition_length",
                    "state",
                    "stance",
                }

                for field_index, field in ipairs(fields) do
                    if math.floor(mask / (2 ^ (field_index - 1))) % 2 == 1 then
                        delta, cursor = decode_signed_varint(data, cursor)
                        state.animation[field] = state.animation[field] + delta
                    end
                end
            end

            if biped_included then
                cursor = skip_bytes(data, cursor, BODY_PART_BYTES)
            end

            if has_detached and detached_included then
                delta, cursor = decode_signed_varint(data, cursor); state.detached.x = state.detached.x + delta
                delta, cursor = decode_signed_varint(data, cursor); state.detached.y = state.detached.y + delta
                delta, cursor = decode_signed_varint(data, cursor); state.detached.z = state.detached.z + delta
                delta, cursor = decode_signed_varint(data, cursor); state.detached.yaw = state.detached.yaw + delta
                delta, cursor = decode_signed_varint(data, cursor); state.detached.pitch = state.detached.pitch + delta
                delta, cursor = decode_signed_varint(data, cursor); state.detached.roll = state.detached.roll + delta
            end

            samples[index] = {
                tick = state.tick,
                x = state.x / position_scale,
                y = state.y / position_scale,
                z = state.z / position_scale,
                yaw = state.yaw / angle_scale,
                pitch = state.pitch / angle_scale,
                roll = state.roll / angle_scale,
                in_vehicle = in_vehicle,
                checkpoint = state.checkpoint,
                vehicle_turn = state.vehicle_turn / vehicle_scale,
                tire_position = state.tire_position / vehicle_scale,
                animation = {
                    base_animation = state.animation.base_animation,
                    base_frame = state.animation.base_frame,
                    transition_frame = state.animation.transition_frame,
                    transition_length = state.animation.transition_length,
                    state = state.animation.state,
                    stance = state.animation.stance,
                },
            }
        end
    end)

    if not ok then
        return nil, tostring(decode_error)
    end

    if #samples == 0 then
        return nil, "replay contains no samples"
    end

    return {
        header = header,
        samples = samples,
        tick_rate = tick_rate_value,
        duration_ticks = samples[#samples].tick,
    }
end

local function delete_ghost()
    if ghost.object_id then
        pcall(delete_object, ghost.object_id)
    end
    ghost.object_id = nil
end

local function stop_ghost(message)
    ghost.playing = false
    delete_ghost()
    if message then log(message) end
end

-- ============================================================
-- Replay playback helpers — bridge between hrl_ghost state and
-- the ghost_playback module for native animation replay.
-- ============================================================
local function load_lua_module(filename)
    local candidates = {}
    local seen = {}

    local function add_candidate(path)
        if path and path ~= "" and not seen[path] then
            seen[path] = true
            candidates[#candidates + 1] = path
        end
    end

    local user_profile = os.getenv("USERPROFILE")
    if user_profile and user_profile ~= "" then
        -- Standard Halo CE Chimera install.
        add_candidate(
            user_profile
                .. "\\Documents\\My Games\\Halo CE\\chimera\\lua\\scripts\\global\\"
                .. filename
        )

        -- Some installations use "Halo" rather than "Halo CE".
        add_candidate(
            user_profile
                .. "\\Documents\\My Games\\Halo\\chimera\\lua\\scripts\\global\\"
                .. filename
        )

        -- OneDrive-backed Documents variants.
        add_candidate(
            user_profile
                .. "\\OneDrive\\Documents\\My Games\\Halo CE\\chimera\\lua\\scripts\\global\\"
                .. filename
        )
        add_candidate(
            user_profile
                .. "\\OneDrive\\Documents\\My Games\\Halo\\chimera\\lua\\scripts\\global\\"
                .. filename
        )
    end

    -- Relative fallbacks for unusual Chimera working directories.
    add_candidate("lua\\scripts\\global\\" .. filename)
    add_candidate("chimera\\lua\\scripts\\global\\" .. filename)
    add_candidate(filename)

    local errors = {}

    for _, path in ipairs(candidates) do
        local chunk, load_err = loadfile(path)

        if chunk then
            local ok, result = pcall(chunk)
            if not ok then
                return nil, string.format(
                    "module '%s' failed while executing: %s",
                    path,
                    tostring(result)
                )
            end

            if type(result) ~= "table" then
                return nil, string.format(
                    "module '%s' returned %s instead of a table",
                    path,
                    type(result)
                )
            end

            log("Loaded Lua module: " .. path)
            return result, nil, path
        end

        errors[#errors + 1] =
            path .. " -> " .. tostring(load_err)
    end

    return nil,
        "cannot locate " .. tostring(filename)
        .. "; tried:\n"
        .. table.concat(errors, "\n")
end

local function ensure_modules()
    if ReplayDecode and GhostPlaybackInstance then return true end

    local rd, rd_err, rd_path = load_lua_module("replay_decode.lua")
    if not rd or type(rd) ~= "table" then
        log("Replay decoder unavailable: " .. tostring(rd_err), 1.0, 0.35, 0.35)
        ReplayDecode = nil
        return false
    end
    ReplayDecode = rd

    local gb, gb_err, gb_path = load_lua_module("ghost_playback.lua")
    if not gb or type(gb) ~= "table" then
        log("Ghost playback module unavailable: " .. tostring(gb_err), 1.0, 0.35, 0.35)
        return false
    end
    GhostPlaybackInstance = gb.new({ animation_mode = "exact", debug_log = true })
    return true
end

local function resolve_replay_path(filename)
    filename = trim(tostring(filename or ""))

    if filename == "" then
        return nil, "replay filename is empty"
    end

    -- This command intentionally accepts only a filename from lua\data\global.
    -- Prevent absolute paths and traversal outside the replay directory.
    if filename:find("[/\\]") or filename:find("%.%.", 1, true) then
        return nil, "use only a replay filename, not a path"
    end

    if not filename:lower():match("%.hrlreplay3$") then
        filename = filename .. ".hrlreplay3"
    end

    local home = os.getenv("USERPROFILE")
    if not home or home == "" then
        return nil, "USERPROFILE is unavailable"
    end

    local candidates = {
        home .. "\\Documents\\My Games\\Halo CE\\chimera\\lua\\data\\global\\" .. filename,
        home .. "\\Documents\\My Games\\Halo\\chimera\\lua\\data\\global\\" .. filename,
        home .. "\\OneDrive\\Documents\\My Games\\Halo CE\\chimera\\lua\\data\\global\\" .. filename,
        home .. "\\OneDrive\\Documents\\My Games\\Halo\\chimera\\lua\\data\\global\\" .. filename,
    }

    for _, candidate in ipairs(candidates) do
        local fh = io.open(candidate, "rb")
        if fh then
            fh:close()
            return candidate
        end
    end

    return nil,
        "cannot find '" .. filename .. "' in Chimera lua\\data\\global"
end

local function playback_load(filename)
    if not ensure_modules() then return false end

    local path, path_err = resolve_replay_path(filename)
    if not path then
        log("Replay playback: " .. tostring(path_err), 1.0, 0.35, 0.35)
        return false
    end

    -- Read the replay file.
    local fh = io.open(path, "rb")
    if not fh then
        log("Replay playback: cannot open file '" .. path .. "'", 1.0, 0.35, 0.35)
        return false
    end
    local data = fh:read("*a")
    fh:close()
    if not data or #data == 0 then
        log("Replay playback: empty replay file", 1.0, 0.35, 0.35)
        return false
    end

    -- Decode via ReplayDecode module.
    local replay, decode_err = ReplayDecode.from_string(data)
    if not replay then
        log("Replay playback: decode error: " .. tostring(decode_err), 1.0, 0.35, 0.35)
        return false
    end

    -- Load into ghost_playback instance.
    local ok, load_err = GhostPlaybackInstance:load(replay, path)
    if not ok then
        log("Replay playback: " .. tostring(load_err), 1.0, 0.35, 0.35)
        return false
    end

    ghost.replay = replay
    ghost.filename = path
    log(string.format("Replay loaded: %d samples (%.2fs) from %s", #replay.samples, replay.duration, path), 1.0, 0.75, 0.3)
    return true
end

local function playback_start(current_tick)
    if not ghost.replay then
        log("Replay playback: no replay loaded; use hrl_ghost_replay_load first", 1.0, 0.75, 0.25)
        return false
    end
    local ok, err = GhostPlaybackInstance:start(current_tick or ticks())
    if not ok then
        log("Replay playback: " .. tostring(err), 1.0, 0.35, 0.35)
        return false
    end
    ghost.playing = true
    ghost.started_at = current_tick or ticks()
    log("Replay playback started", 1.0, 0.75, 0.3)
    return true
end

local function playback_update(current_tick)
    if not ghost.playing or not GhostPlaybackInstance then return end
    GhostPlaybackInstance:update(current_tick or ticks())
end

-- Pause: retain objects (for restart without re-spawn).
local function playback_pause()
    if GhostPlaybackInstance then
        GhostPlaybackInstance:pause()
    end
    ghost.playing = false
end

-- Stop: delete ALL spawned objects.
local function playback_stop(message)
    if GhostPlaybackInstance then
        GhostPlaybackInstance:stop(message or "Stopped")
    end
    ghost.playing = false
end

local function playback_reset()
    if GhostPlaybackInstance then
        GhostPlaybackInstance:reset()
    end
    ghost.replay = nil
    ghost.filename = nil
    ghost.playing = false
end

local function playback_set_mode(mode)
    mode = tostring(mode or "native"):lower()
    if mode ~= "native" and mode ~= "exact" and mode ~= "off" then
        log("Invalid animation mode: " .. mode .. ". Use native|exact|off", 1.0, 0.75, 0.25)
        return false
    end
    if GhostPlaybackInstance then
        GhostPlaybackInstance.animation_mode = mode
    end
    log(string.format("Replay animation mode: %s", mode), 1.0, 0.75, 0.3)
    return true
end

local function playback_status()
    local s = { loaded = ghost.replay ~= nil, playing = ghost.playing }
    if GhostPlaybackInstance then
        local st = GhostPlaybackInstance:status()
        for k, v in pairs(st) do s[k] = v end
    end
    return s
end

local function playback_test()
    -- Spawn a cyborg at the first sample position and apply the first animation.
    if not ghost.replay then
        log("No replay loaded", 1.0, 0.75, 0.25)
        return false
    end
    local rd = ReplayDecode or (type(require) == "function" and require("replay_decode"))
    if not rd then
        log("Decoder unavailable", 1.0, 0.35, 0.35)
        return false
    end
    local first = ghost.replay.samples[1]
    delete_test_cyborg()
    if not spawn_test_cyborg(0) then return false end
    local obj, err = get_test_cyborg_object()
    if not obj then
        log("Cannot get test cyborg: " .. tostring(err), 1.0, 0.35, 0.35)
        return false
    end
    write_word(obj + BASE_ANIMATION_OFFSET, first.animation.base_animation or 0)
    write_word(obj + BASE_FRAME_OFFSET, first.animation.base_frame or 0)
    log(string.format("Test: wrote base_anim=%d frame=%d at (%.2f,%.2f,%.2f)",
        first.animation.base_animation or 0, first.animation.base_frame or 0,
        first.x, first.y, first.z), 1.0, 0.75, 0.3)
    return true
end

local function playback_decoder_test()
    if not ensure_modules() then return false end
    local ok, errs = ReplayDecode.self_test()
    if ok then
        log("Replay decoder self-test: PASS")
    else
        for _, e in ipairs(errs or {}) do
            console_out(e, 1.0, 0.35, 0.35)
        end
        log("Replay decoder self-test: FAIL (" .. tostring(#(errs or {})) .. " failures)")
    end
    return ok
end

local function spawn_ghost_object(sample)
    delete_ghost()

    local tag = get_tag(BIPED_CLASS, BIPED_TAG)
    if not tag then
        return nil, "biped tag not found: " .. BIPED_TAG
    end

    -- Use the class + path signature. This Chimera build rejects the
    -- tag-address/tag-ID form returned by get_tag().
    local object_id = spawn_object(
        BIPED_CLASS,
        BIPED_TAG,
        sample.x,
        sample.y,
        sample.z
    )
    if not object_id then
        return nil, "spawn_object failed"
    end

    local object = get_object(object_id)
    if not object then
        pcall(delete_object, object_id)
        return nil, "spawned biped has no object pointer"
    end

    ghost.object_id = object_id
    return object
end

local function copy_live_animation_to_ghost(object)
    if type(get_dynamic_player) ~= "function" then
        return false, "get_dynamic_player() is unavailable"
    end

    local player = get_dynamic_player()
    if not player or player == 0 then
        return false, "local player biped is unavailable"
    end

    if player == object then
        return false, "local player pointer is the ghost"
    end

    -- Copy the animation graph context and the compact animation fields.
    write_dword(object + ANIMATION_TAG_OFFSET, read_dword(player + ANIMATION_TAG_OFFSET))
    write_word(object + BASE_ANIMATION_OFFSET, read_word(player + BASE_ANIMATION_OFFSET))
    write_word(object + BASE_FRAME_OFFSET, read_word(player + BASE_FRAME_OFFSET))
    write_word(object + TRANSITION_FRAME_OFFSET, read_word(player + TRANSITION_FRAME_OFFSET))
    write_word(object + TRANSITION_LENGTH_OFFSET, read_word(player + TRANSITION_LENGTH_OFFSET))
    write_byte(object + ANIMATION_STANCE_OFFSET, read_byte(player + ANIMATION_STANCE_OFFSET))
    write_byte(object + ANIMATION_STATE_OFFSET, read_byte(player + ANIMATION_STATE_OFFSET))
    write_byte(object + ANIMATION_CROUCH_OFFSET, read_byte(player + ANIMATION_CROUCH_OFFSET))

    -- Locomotion is resolved from live movement data, not only the compact
    -- animation index/frame fields. Copy those inputs for this diagnostic.
    write_float(object + UNIT_FORWARD_INPUT_OFFSET, read_float(player + UNIT_FORWARD_INPUT_OFFSET))
    write_float(object + UNIT_LEFT_INPUT_OFFSET, read_float(player + UNIT_LEFT_INPUT_OFFSET))
    write_float(object + UNIT_UP_INPUT_OFFSET, read_float(player + UNIT_UP_INPUT_OFFSET))

    write_float(object + VELOCITY_OFFSET, read_float(player + VELOCITY_OFFSET))
    write_float(object + VELOCITY_OFFSET + 4, read_float(player + VELOCITY_OFFSET + 4))
    write_float(object + VELOCITY_OFFSET + 8, read_float(player + VELOCITY_OFFSET + 8))

    return true
end

local function write_animation(object, animation)
    if ghost.copy_live_animation then
        copy_live_animation_to_ghost(object)
        return
    end

    if not animation then
        return
    end

    local stance = animation.stance or 4

    write_byte(object + ANIMATION_STANCE_OFFSET, stance)
    write_byte(object + ANIMATION_CROUCH_OFFSET, stance == 3 and 3 or 2)
    write_byte(object + ANIMATION_STATE_OFFSET, animation.state or 0)
    write_word(object + BASE_ANIMATION_OFFSET, animation.base_animation or 0)
    write_word(object + BASE_FRAME_OFFSET, animation.base_frame or 0)
    write_word(object + TRANSITION_FRAME_OFFSET, animation.transition_frame or 0)
    write_word(object + TRANSITION_LENGTH_OFFSET, animation.transition_length or 0)
end

local function write_unit_controls(object, sample)
    local forward = sample.move_forward or 0
    local left = sample.move_left or 0

    write_float(object + UNIT_FORWARD_INPUT_OFFSET, forward)
    write_float(object + UNIT_LEFT_INPUT_OFFSET, left)
    write_float(object + UNIT_UP_INPUT_OFFSET, 0)
end

local function write_transform(object, sample)
    write_float(object + POSITION_OFFSET, sample.x)
    write_float(object + POSITION_OFFSET + 4, sample.y)
    write_float(object + POSITION_OFFSET + 8, sample.z)

    -- In normal replay mode, prevent client physics from carrying the ghost
    -- between updates. Live diagnostic mode copies the player's velocity later.
    if not ghost.copy_live_animation then
        write_float(object + VELOCITY_OFFSET, 0)
        write_float(object + VELOCITY_OFFSET + 4, 0)
        write_float(object + VELOCITY_OFFSET + 8, 0)
    end

    local cy = math.cos(sample.yaw)
    local sy = math.sin(sample.yaw)
    local cp = math.cos(sample.pitch)
    local sp = math.sin(sample.pitch)
    local cr = math.cos(sample.roll)
    local sr = math.sin(sample.roll)

    -- Forward vector from yaw and pitch.
    local fx = cp * cy
    local fy = cp * sy
    local fz = sp

    -- Right vector at zero roll, then rotate the up vector around forward.
    local rx = -sy
    local ry = cy
    local rz = 0

    local base_up_x = -sp * cy
    local base_up_y = -sp * sy
    local base_up_z = cp

    local ux = base_up_x * cr + rx * sr
    local uy = base_up_y * cr + ry * sr
    local uz = base_up_z * cr + rz * sr

    -- These two vectors rotate the rendered object.
    write_float(object + OBJECT_FORWARD_OFFSET, fx)
    write_float(object + OBJECT_FORWARD_OFFSET + 4, fy)
    write_float(object + OBJECT_FORWARD_OFFSET + 8, fz)

    write_float(object + OBJECT_UP_OFFSET, ux)
    write_float(object + OBJECT_UP_OFFSET + 4, uy)
    write_float(object + OBJECT_UP_OFFSET + 8, uz)

    -- Also keep unit aim/facing values coherent for animation logic.
    for _, offset in ipairs({
        UNIT_FACING_OFFSET,
        UNIT_DESIRED_AIM_OFFSET,
        UNIT_AIM_OFFSET,
    }) do
        write_float(object + offset, fx)
        write_float(object + offset + 4, fy)
        write_float(object + offset + 8, fz)
    end

    -- Replay-derived controls are useful in normal playback. During the live
    -- diagnostic, write_animation() copies the player's actual controls and
    -- velocity after this call, so they are the final values for the tick.
    write_unit_controls(object, sample)
    write_animation(object, sample.animation)
end

local function angle_lerp(a, b, alpha)
    local tau = math.pi * 2
    local difference = (b - a + math.pi) % tau - math.pi
    return a + difference * alpha
end

local function interpolate(a, b, alpha)
    local yaw = angle_lerp(a.yaw, b.yaw, alpha)
    local dx = b.x - a.x
    local dy = b.y - a.y
    local horizontal_speed = math.sqrt(dx * dx + dy * dy)

    local move_forward = 0
    local move_left = 0

    if horizontal_speed > 0.0001 then
        -- Convert world-space travel into the biped's local forward/left axes.
        local inv = 1 / horizontal_speed
        local nx = dx * inv
        local ny = dy * inv
        local facing_x = math.cos(yaw)
        local facing_y = math.sin(yaw)
        local left_x = -facing_y
        local left_y = facing_x

        move_forward = nx * facing_x + ny * facing_y
        move_left = nx * left_x + ny * left_y

        -- Halo expects control magnitudes in the -1..1 range.
        move_forward = math.max(-1, math.min(1, move_forward))
        move_left = math.max(-1, math.min(1, move_left))
    end

    return {
        x = a.x + dx * alpha,
        y = a.y + dy * alpha,
        z = a.z + (b.z - a.z) * alpha,
        yaw = yaw,
        pitch = angle_lerp(a.pitch, b.pitch, alpha),
        roll = angle_lerp(a.roll, b.roll, alpha),
        move_forward = move_forward,
        move_left = move_left,
        -- IDs and state values are discrete, so retain the current replay sample.
        animation = a.animation,
    }
end

local function sample_at(replay_tick)
    local samples = ghost.replay.samples
    local count = #samples

    if replay_tick <= samples[1].tick then
        local first = samples[1]
        first.move_forward = 0
        first.move_left = 0
        return first
    end

    if replay_tick >= samples[count].tick then
        local last = samples[count]
        last.move_forward = 0
        last.move_left = 0
        return last
    end

    -- Cache-friendly linear advancement: playback normally moves forward by one sample.
    local index = ghost.replay.cursor or 1
    if replay_tick < samples[index].tick then
        index = 1
    end

    while index < count and samples[index + 1].tick <= replay_tick do
        index = index + 1
    end

    ghost.replay.cursor = index

    local a = samples[index]
    local b = samples[math.min(index + 1, count)]
    local span = b.tick - a.tick
    local alpha = span > 0 and (replay_tick - a.tick) / span or 0

    return interpolate(a, b, alpha)
end

local function start_ghost(filename)
    stop_ghost()

    local replay, decode_error = decode_replay(filename)
    if not replay then
        log("Failed to load replay: " .. tostring(decode_error), 1.0, 0.35, 0.35)
        return false
    end

    local replay_map = normalize_map_name(replay.header.map)
    local loaded_map = normalize_map_name(map)
    if replay_map ~= "" and loaded_map ~= "" and replay_map ~= loaded_map then
        log(string.format("Replay is for '%s', but '%s' is loaded", replay_map, loaded_map), 1.0, 0.5, 0.25)
        return false
    end

    local first = replay.samples[1]
    local object, spawn_error = spawn_ghost_object(first)
    if not object then
        log("Could not spawn ghost: " .. tostring(spawn_error), 1.0, 0.35, 0.35)
        return false
    end

    ghost.replay = replay
    ghost.filename = filename
    ghost.started_at = ticks()
    ghost.playing = true
    replay.cursor = 1

    write_transform(object, first)

    log(string.format(
        "Playing %d samples (%.2fs) from %s",
        #replay.samples,
        replay.duration_ticks / replay.tick_rate,
        filename
    ))

    return true
end

function OnTick()
    -- Standalone animation tests must run even when no replay ghost is playing.
    tick_sample()
    update_armed_capture()
    apply_test_animation()
    copy_live_compact_animation_to_test()
    update_frame_sweep()

    -- Advance the new compact-animation ghost_playback module each tick.
    if GhostPlaybackInstance and GhostPlaybackInstance.playing then
        playback_update(ticks())
    end

    if not ghost.playing or not ghost.replay or not ghost.object_id then
        return
    end

    local object = get_object(ghost.object_id)
    if not object then
        stop_ghost("Ghost object disappeared")
        return
    end

    local elapsed_seconds = (ticks() - ghost.started_at) / tick_rate()
    local replay_tick = elapsed_seconds * ghost.replay.tick_rate

    if replay_tick > ghost.replay.duration_ticks then
        stop_ghost("Replay finished")
        return
    end

    write_transform(object, sample_at(replay_tick))
end


local PROBE_START_OFFSET = 0xC0
local PROBE_END_OFFSET = 0x300

local function get_local_player_object()
    if type(get_dynamic_player) ~= "function" then
        return nil, "get_dynamic_player() is unavailable"
    end

    local object = get_dynamic_player()
    if not object or object == 0 then
        return nil, "local player biped is unavailable"
    end

    return object
end

local function capture_animation_probe()
    local player, err = get_local_player_object()
    if not player then
        log("Probe failed: " .. tostring(err), 1.0, 0.35, 0.35)
        return false
    end

    local snapshot = {}
    for offset = PROBE_START_OFFSET, PROBE_END_OFFSET do
        snapshot[offset] = read_byte(player + offset)
    end

    ghost.animation_probe = snapshot
    log(string.format(
        "Animation baseline captured (0x%X-0x%X). Start walking, then run hrl_ghost_anim_diff",
        PROBE_START_OFFSET,
        PROBE_END_OFFSET
    ))
    return true
end

local function format_probe_value(player, ghost_object, offset)
    local current = read_byte(player + offset)
    local ghost_value = ghost_object and read_byte(ghost_object + offset) or nil

    if ghost_value ~= nil then
        return string.format(
            "+0x%03X: %3d -> %3d | ghost=%3d",
            offset,
            ghost.animation_probe[offset],
            current,
            ghost_value
        )
    end

    return string.format(
        "+0x%03X: %3d -> %3d",
        offset,
        ghost.animation_probe[offset],
        current
    )
end

local function diff_animation_probe()
    if not ghost.animation_probe then
        log("No baseline. Stand idle and run hrl_ghost_anim_snapshot first", 1.0, 0.75, 0.25)
        return false
    end

    local player, err = get_local_player_object()
    if not player then
        log("Probe failed: " .. tostring(err), 1.0, 0.35, 0.35)
        return false
    end

    local ghost_object = ghost.object_id and get_object(ghost.object_id) or nil
    local changes = {}

    for offset = PROBE_START_OFFSET, PROBE_END_OFFSET do
        local current = read_byte(player + offset)
        if current ~= ghost.animation_probe[offset] then
            changes[#changes + 1] = format_probe_value(player, ghost_object, offset)
        end
    end

    log(string.format("Animation probe found %d changed bytes:", #changes))

    -- Console output is intentionally capped so a pointer/timer-heavy region
    -- cannot flood Chimera. Locomotion fields should appear near the known
    -- unit control and animation offsets.
    local limit = math.min(#changes, 80)
    for index = 1, limit do
        console_out("[HRL Anim Probe] " .. changes[index], 0.8, 0.9, 1.0)
    end

    if #changes > limit then
        log(string.format("%d additional changes omitted", #changes - limit), 1.0, 0.75, 0.25)
    end

    return true
end

function OnCommand(command)
    local name, argument = command:match("^(%S+)%s*(.-)%s*$")
    name = name and name:lower() or ""

    if name == "hrl_ghost" then
        argument = trim(argument or "")
        argument = argument:gsub('^"(.*)"$', '%1')

        if argument == "" then
            log("Usage: hrl_ghost <path-to-replay>", 1.0, 0.75, 0.25)
        else
            start_ghost(argument)
        end
        return false
    end

    if name == "hrl_ghost_anim_snapshot" then
        capture_animation_probe()
        return false
    end

    if name == "hrl_ghost_anim_diff" then
        diff_animation_probe()
        return false
    end

    if name == "hrl_ghost_test_animation" then
        ghost.copy_live_animation = not ghost.copy_live_animation

        if ghost.copy_live_animation then
            log("Live animation + controls + velocity copy enabled")
        else
            log("Live animation copy disabled: using replay animation fields")
        end

        return false
    end

    if name == "hrl_ghost_spawn_cyborg" then
        spawn_test_cyborg(parse_integer(argument) or tonumber(argument))
        return false
    end

    if name == "hrl_ghost_set_animation_state" then
        set_test_animation_state(argument)
        return false
    end

    if name == "hrl_ghost_set_stance" then
        set_test_stance(argument)
        return false
    end

    if name == "hrl_ghost_set_action_state" then
        set_test_action_state(argument)
        return false
    end

    if name == "hrl_ghost_copy_live_compact" then
        toggle_live_compact_copy()
        return false
    end

    if name == "hrl_ghost_capture_live_animation" then
        capture_live_animation()
        return false
    end

    if name == "hrl_ghost_capture_in" then
        arm_capture_in(argument)
        return false
    end

    if name == "hrl_ghost_capture_on" then
        arm_capture_on(argument)
        return false
    end

    if name == "hrl_ghost_capture_cancel" then
        clear_capture_arm()
        log("Armed animation capture cancelled")
        return false
    end

    if name == "hrl_ghost_apply_captured_animation" then
        apply_captured_animation()
        return false
    end

    if name == "hrl_ghost_set_base_animation" then
        set_test_base_animation(argument)
        return false
    end

    if name == "hrl_ghost_set_frame" then
        set_test_frame(argument)
        return false
    end

    if name == "hrl_ghost_frame_sweep" then
        start_frame_sweep(argument)
        return false
    end

    if name == "hrl_ghost_frame_sweep_stop" then
        stop_frame_sweep()
        return false
    end

    if name == "hrl_ghost_player_id" then
        print_local_player_object_id()
        return false
    end

    if name == "hrl_ghost_registration_diag" then
        registration_diag(argument)
        return false
    end

    if name == "hrl_ghost_compare_cyborg" then
        compare_player_and_cyborg()
        return false
    end

    if name == "hrl_ghost_test_status" then
        print_test_status()
        return false
    end

    if name == "hrl_ghost_animation_release" then
        release_test_animation()
        return false
    end

    if name == "hrl_ghost_delete_cyborg" then
        delete_test_cyborg("Deleted test cyborg")
        return false
    end

    if name == "hrl_ghost_stop" then
        stop_ghost("Stopped")
        return false
    end

    if name == "hrl_ghost_restart" then
        if ghost.filename then
            start_ghost(ghost.filename)
        else
            log("No replay has been loaded", 1.0, 0.75, 0.25)
        end
        return false
    end

    -- ============================================================
    -- HRL Replay Playback commands (compact native animation).
    -- Requires: lua/scripts/global/replay_decode.lua and
    --           lua/scripts/global/ghost_playback.lua present.
    -- ============================================================

    if name == "hrl_ghost_replay_load" then
        local filename = trim(argument or "")
        if filename == "" then
            log("Usage: hrl_ghost_replay_load <filename[.hrlreplay3]>", 1.0, 0.75, 0.25)
        else
            -- Stop any existing playback first.
            playback_stop("replacing replay")
            playback_reset()
            playback_load(filename)
        end
        return false
    end

    if name == "hrl_ghost_replay_start" then
        playback_start(ticks())
        return false
    end

    if name == "hrl_ghost_replay_stop" then
        playback_stop("Stopped by command")
        return false
    end

    if name == "hrl_ghost_replay_mode" then
        local mode = trim(argument or "native")
        playback_set_mode(mode)
        return false
    end

    if name == "hrl_ghost_replay_status" then
        local s = playback_status()

        local biped_id = tonumber(s.biped_id)
        local biped_text = biped_id
            and string.format("0x%08X", biped_id)
            or tostring(s.biped_id or "(none)")

        log(string.format(
            "Replay: loaded=%s playing=%s file=%s samples=%d duration=%.2fs mode=%s cursor=%d biped_id=%s",
            tostring(s.loaded),
            tostring(s.playing),
            tostring(s.filename or "(none)"),
            tonumber(s.sample_count) or 0,
            tonumber(s.duration) or 0,
            tostring(s.mode or "(none)"),
            tonumber(s.cursor) or 0,
            biped_text
        ), 1.0, 0.75, 0.3)
        return false
    end

    if name == "hrl_ghost_replay_test" then
        playback_test()
        return false
    end

    if name == "hrl_ghost_replay_decoder_test" then
        playback_decoder_test()
        return false
    end

    if name == "hrl_ghost_replay_cursor_test" then
        if not ensure_modules() then
            log("Cursor test: module unavailable", 1.0, 0.35, 0.35)
            return false
        end
        local ok, errs = GhostPlaybackInstance.cursor_self_test()
        if ok then
            log("Ghost cursor self-test: PASS")
        else
            for _, e in ipairs(errs or {}) do
                console_out(e, 1.0, 0.35, 0.35)
            end
            log("Ghost cursor self-test: FAIL (" .. tostring(#(errs or {})) .. " failures)")
        end
        return false
    end

    if name == "hrl_ghost_replay_animation_test" then
        if not ensure_modules() then
            log("Animation test: module unavailable", 1.0, 0.35, 0.35)
            return false
        end
        local ok, errs = GhostPlaybackInstance.animation_self_test()
        if ok then
            log("Ghost animation self-test: PASS")
        else
            for _, e in ipairs(errs or {}) do
                console_out(e, 1.0, 0.35, 0.35)
            end
            log("Ghost animation self-test: FAIL (" .. tostring(#(errs or {})) .. " failures)")
        end
        return false
    end

    -- Animation table inspector (uses DebugCore JSON dump).
    if name == "hrl_ghost_dump_table" then
        dump_animation_table()
        return false
    end

    -- Dump all registered DebugCore sources to the output file.
    if name == "hrl_ghost_dump_debug" then
        log("Dumping all debug sources...", 1.0, 0.75, 0.25)
        local ok = DebugCore.dump()
        if not ok then
            log("Debug dump failed", 1.0, 0.35, 0.35)
        end
        return false
    end

    -- Animation field investigation helpers.
    if name == "hrl_ghost_anim_record" then
        record_activity(trim(argument or ""))
        return false
    end

    if name == "hrl_ghost_anim_compare" then
        compare_activities()
        return false
    end

    if name == "hrl_ghost_anim_reset" then
        reset_activity_records()
        return false
    end

    -- Player-object diagnostic: reads key offsets from get_dynamic_player()
    -- to verify the pointer matches what game code accesses at [puVar+0x2A3].
    if name == "hrl_ghost_diag" then
        diagnose_player()
        return false
    end

    -- Per-tick auto-sampler for movement-correlation data.
    if name == "hrl_ghost_auto_sample_start" then
        AUTO_SAMPLE_ENABLED = true
        log("Auto sample ON — capturing ~30 ticks/sec, tagged by held input state", 1.0, 0.75, 0.25)
        return false
    end

    if name == "hrl_ghost_auto_sample_stop" then
        AUTO_SAMPLE_ENABLED = false
        log(string.format("Auto sample OFF — captured %d samples total", #auto_movement_samples), 1.0, 0.75, 0.25)
        return false
    end

    -- Print runtime address of animation_state for dbg32 hardware breakpoint.
    if name == "hrl_ghost_anim_addr" then
        local player = get_dynamic_player()
        if not player or player == 0 then
            log("No dynamic player — not in game?", 1.0, 0.35, 0.35)
            return false
        end
        local anim_state_addr = player + 0x2A3
        -- Also dump a few nearby bytes so we can verify the value matches.
        log(string.format(
            "[anim_addr] get_dynamic_player()=0x%08X  animation_state addr=0x%08X  current_value=%d",
            player, anim_state_addr, read_byte(anim_state_addr)
        ), 1.0, 0.75, 0.25)
        return false
    end

    if name == "hrl_ghost_auto_sample_clear" then
        auto_movement_samples = {}
        log("Auto sample buffer cleared", 1.0, 0.75, 0.25)
        return false
    end

    return true
end

function OnMapLoad()
    stop_ghost()
    delete_test_cyborg()
end

function OnUnload()
    stop_ghost()
    delete_test_cyborg()
end

set_callback("tick", "OnTick")
set_callback("command", "OnCommand")
set_callback("map load", "OnMapLoad")
set_callback("unload", "OnUnload")

log("Loaded. Use capture_in or capture_on so actions can be performed with console closed")