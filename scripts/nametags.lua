--[[
  nametags.lua  (stub / skeleton)

  Draws a small name tag above other visible players using draw_text().

  Place in: chimera\lua\scripts\global\nametags.lua

  STRUCTURE: this is the standalone renderer (rendering, camera capture,
  projection, aspect detection). Debug tooling lives in TWO reusable sibling
  files, merged in only when testing (see the DEBUG / CALIBRATION block at the
  bottom): debug_core.lua (JSON state dump + `dbgdump`) and tagcal.lua (draw_text
  calibration overlay + `tagcal`). Lightweight ring-buffer logging (draw_log,
  vehicle_log, team_log) is kept here so debug_core can read it once merged.
--]]

clua_version = 2.056

local nametags = {}  -- module-local state

-- Every draw attempt gets logged here, newest last. debug_core.lua will
-- pick this up via the registered source below - no extra plumbing needed.
nametags.draw_log = {}
nametags.debug_log = {}
nametags.errors = {}
nametags.vehicle_log = {}   -- raw vehicle-seat memory reads, for diagnosing seat position
nametags.team_log = {}      -- DIAGNOSTIC: team-filter decisions (verify get_player+0x20 is team)

local MAX_LOG_ENTRIES = 50
local function log_draw(entry)
    table.insert(nametags.draw_log, entry)
    if #nametags.draw_log > MAX_LOG_ENTRIES then
        table.remove(nametags.draw_log, 1)
    end
end

local function log_debug(entry)
    table.insert(nametags.debug_log, entry)
    if #nametags.debug_log > MAX_LOG_ENTRIES then
        table.remove(nametags.debug_log, 1)
    end
end

local function log_vehicle(entry)
    table.insert(nametags.vehicle_log, entry)
    if #nametags.vehicle_log > MAX_LOG_ENTRIES then
        table.remove(nametags.vehicle_log, 1)
    end
end

local function log_team(entry)
    table.insert(nametags.team_log, entry)
    if #nametags.team_log > 40 then
        table.remove(nametags.team_log, 1)
    end
end

 
-- ============================================================
-- Seat-index detection (confirmed in part by the user's own working code)
--
-- read_word(dyn_player + 0x2F0) returns the seat index for a player
-- currently in a vehicle. CONFIRMED: 0 = driver (matches user-provided
-- is_driver() check). NOT YET CONFIRMED: which index corresponds to
-- gunner vs. passenger - guessed below as 1 = gunner, 2 = passenger,
-- by convention (driver typically loads first, gunner second since
-- many vehicles' primary weapon seat is filled before rear passenger
-- seats in seat-priority lists) - but this is an assumption, not
-- verified against this specific vehicle. If seat assignment looks
-- wrong in testing (nametag using gunner's offset for an actual
-- passenger, or vice versa), swap SEAT_INDEX_TO_NAME[1] and [2].
-- ============================================================
local SEAT_INDEX_TO_NAME = {
    [0] = "driver",
    [2] = "gunner", 
    [1] = "passenger",
}
 
-- Returns the seat name ("driver"/"gunner"/"passenger") for a player,
-- or nil if they are not currently in a vehicle.
local function get_player_seat(id)
    local dyn = get_dynamic_player(id)
    if not dyn or dyn == 0 then return nil end
 
    local vehicle_id = read_dword(dyn + 0x11C)
    if vehicle_id == 0xFFFFFFFF then return nil end -- confirmed sentinel, not in a vehicle
 
    local seat_index = read_word(dyn + 0x2F0)
    return SEAT_INDEX_TO_NAME[seat_index]
end




local function get_player_name(id)
    local obj = get_player(id)
    if not obj then return "Unknown" end
    local addr = obj + 0x4
    local chars = {}
    for j = 1, 12 do
        local b = read_byte(addr + (j - 1) * 2)
        if b == 0 then break end
        chars[#chars + 1] = string.char(b)
    end
    return table.concat(chars)
end

local _seat_log_last_tick = {}  -- per-player-id throttle state
local SEAT_LOG_INTERVAL_TICKS = 30 -- ~1 second at 30 ticks/sec
 
local function log_seat_index_if_due(id, pname, seat_index, resolved_seat)
    local now = ticks()
    local last = _seat_log_last_tick[id] or 0
    if now - last < SEAT_LOG_INTERVAL_TICKS then return end
    _seat_log_last_tick[id] = now
 
    log_debug({
        tick = now,
        player_id = id,
        player_name = pname,
        raw_seat_index = seat_index,
        resolved_seat = resolved_seat or "UNMAPPED",
    })
end
 
-- ============================================================
-- Full position resolution: standing biped OR seated-in-vehicle.
-- Drop-in replacement for the old "local x,y,z = read_float(dyn+0x5C)..."
-- block in OnPreFrame - call this instead, once, per player.
--
-- get_object_memory vs get_object: the user's is_driver() snippet used
-- get_object_memory(vehicle_id); earlier code in this conversation used
-- get_object(vehicle_id) from a different community script. These may
-- be aliases of the same function in this Chimera build, or genuinely
-- different functions - NOT verified. Using get_object_memory here
-- since it's the one confirmed working in the user's own tested code.
-- If it errors as undefined, try get_object instead.
-- ============================================================
local function get_player_world_position(id)
    local dyn = get_dynamic_player(id)
    if not dyn or dyn == 0 then return nil end
 
    local vehicle_id = read_dword(dyn + 0x11C)
 

    local pvx = read_float(dyn + 0x5C)
    local pvy = read_float(dyn + 0x60)
    local pvz = read_float(dyn + 0x64)

    if vehicle_id ~= 0xFFFFFFFF then
        local vehicle_object = get_object(vehicle_id)
        if vehicle_object and vehicle_object ~= 0 then
            local seat_index = read_word(dyn + 0x2F0)
            local seat = SEAT_INDEX_TO_NAME[seat_index]
            log_seat_index_if_due(id, get_player_name(id), seat_index, seat)
 
            -- Seated biped world position.
            --
            -- The seated biped's +0x5C is only a tiny offset relative to the
            -- SEAT node (~(-0.12, 0, 0.32)), NOT the seat's world position, so
            -- `vehicle_origin + (+0x5C)` lands near the vehicle centre, well
            -- short of the actual seat. The biped's TRUE world position is at
            -- +0xA0/0xA4/0xA8 while seated.
            --
            -- VERIFIED (gunner): +0xA0 = (17.865,-15.224,
            -- 1.551) projected to internal x=332.7, matching the target waypoint
            -- above the gunner at 329.7; the old origin+local math landed at
            -- x=242 (~90 px left). +0xA0 is roughly the biped centre/torso, so
            -- TAG_HEIGHT still lifts the tag to just above the head.
            local wx = read_float(dyn + 0xA0)
            local wy = read_float(dyn + 0xA4)
            local wz = read_float(dyn + 0xA8)

            -- +0xA0 is the biped CENTRE/torso, whereas the on-foot read (+0x5C)
            -- is the FEET. The draw code adds a single TAG_HEIGHT (0.7, tuned for
            -- feet) to whatever we return, so a raw torso z puts seated tags too
            -- high (passenger tag ~28 px above the head).
            -- Drop to a feet-equivalent so the shared +TAG_HEIGHT lands the tag
            -- just above the head for both on-foot and seated players. +0xA0
            -- projects onto the auto-aim reticle (biped centre), ~0.33 above the
            -- feet for a standing biped, so 0.35 here makes the seated anchor
            -- ≈ feet + TAG_HEIGHT. TUNABLE - verify on the next seated dump; raise
            -- if tags sit low, lower if they sit high.
            local SEAT_CENTRE_TO_FEET = 0.35
            wz = wz - SEAT_CENTRE_TO_FEET

            log_vehicle({
                tick = ticks(),
                player_id = id,
                seat_index = seat_index,
                vehicle_origin = { read_float(vehicle_object + 0x5C), read_float(vehicle_object + 0x60), read_float(vehicle_object + 0x64) },
                player_local = { pvx, pvy, pvz },   -- +0x5C/0x60/0x64 (seat-node-relative)
                biped_world  = { wx, wy, wz },       -- +0xA0/0xA4/0xA8, wz adjusted to feet-equiv
            })

            return wx, wy, wz
        end
    end
 
    -- Not in a vehicle (or vehicle object lookup failed) - normal biped read
    return
        read_float(dyn + 0x5C),
        read_float(dyn + 0x60),
        read_float(dyn + 0x64)
end

-- ============================================================
-- Head node world position.
--
-- The biped's skeletal node array holds each bone's WORLD translation. The head
-- is node 12, at biped + 0x7E8 - CONFIRMED for the player biped: among all 19 
-- position nodes (base 0x578, stride 0x34) it was
-- both the highest-z node (feet+0.561) AND the closest to the eye/camera
-- (feet+0.62), i.e. the head. Works for standing AND seated bipeds (nodes are
-- computed for rendering either way), and follows crouch/pose - unlike the
-- feet+TAG_HEIGHT anchor which is fixed to standing height.
--
-- MODEL-DEPENDENT: 0x7E8 assumes the standard player biped (fine for this mod's
-- single biped). The sanity check below guards against a different model / bad
-- read: the head must be within ~1.5 units of the object centre (0xA0); if not,
-- returns nil and the caller falls back to get_player_world_position+TAG_HEIGHT.
-- ============================================================
local HEAD_NODE_OFFSET = 0x7E8
local function get_head_position(dyn)
    if not dyn or dyn == 0 then return nil end
    local hx = read_float(dyn + HEAD_NODE_OFFSET)
    local hy = read_float(dyn + HEAD_NODE_OFFSET + 0x4)
    local hz = read_float(dyn + HEAD_NODE_OFFSET + 0x8)
    -- object centre (0xA0) as a plausibility anchor
    local cx = read_float(dyn + 0xA0)
    local cy = read_float(dyn + 0xA4)
    local cz = read_float(dyn + 0xA8)
    local dx, dy, dz = hx - cx, hy - cy, hz - cz
    if (dx * dx + dy * dy + dz * dz) > (1.5 * 1.5) then return nil end
    return hx, hy, hz
end


-- world->screen projection helpers. Camera comes from the core-owned
-- _last_camera (captured by OnPreCamera below), not from DebugCore.
local function normalize(v)
    local len = math.sqrt(v[1]^2 + v[2]^2 + v[3]^2)
    if len == 0 then return {0,0,0} end
    return {v[1]/len, v[2]/len, v[3]/len}
end

local function cross(a, b)
    return {
        a[2]*b[3] - a[3]*b[2],
        a[3]*b[1] - a[1]*b[3],
        a[1]*b[2] - a[2]*b[1]
    }
end

local function dot(a,b)
    return a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
end

-- ============================================================
-- ASPECT RATIO. Only used to derive the vertical FOV from the horizontal FOV in
-- world_to_screen. Chimera's widescreen fix keeps the internal height at 480 and
-- widens the effective width, so SCREEN_WIDTH/480 is the render aspect:
--     16:9  -> 853.333   (widescreen fix ON)
--     4:3   -> 640        (widescreen fix OFF)
-- The width MATTERS: with the widescreen fix off the world renders 4:3 and tags
-- are mis-centred if we assume 16:9. So we detect the mode at runtime rather than
-- hardcode. (An earlier heap value 0x69FBB290 that flipped 640<->746 was a red
-- herring - not the render aspect; the window measured true 16:9 959x540.)
local SCREEN_HEIGHT = 480
local WIDTH_16_9    = 853.333
local WIDTH_4_3     = 640

-- Aspect: default 16:9. Runtime auto-detection was REMOVED as unreliable.
-- The widescreen_fix (0x6D124874) / font_override (0x6D11BD44) bytes live in the
-- Chimera module ("strings.dll"), whose base is RELOCATED by ASLR each launch, so
-- those hardcoded ABSOLUTE addresses drift between runs. On a bad launch they read
-- stale 0 -> mis-detected as 4:3 -> tags shifted ~1.33x left. A failed read is
-- safe (falls back to 16:9) but a successful stale-zero read is indistinguishable
-- from real 4:3, so the addresses can't be trusted without resolving the module
-- base (no Chimera Lua API exposes it) or reading Chimera's prefs file.
--
-- For a native 4:3 setup, set the override below to 640.
local SCREEN_WIDTH_OVERRIDE = nil   -- nil = 16:9 (853.333); set 640 for 4:3
local function read_screen_width()
    return (SCREEN_WIDTH_OVERRIDE or WIDTH_16_9), nil
end

-- Current render width + raw mode, refreshed once per frame in OnPreCamera.
local SCREEN_WIDTH = WIDTH_16_9
local _widescreen_mode = nil

-- ============================================================
-- CAMERA CAPTURE (core - required for standalone operation)
--
-- nametags owns its own camera snapshot so it does NOT depend on DebugCore.
-- OnPreCamera runs every frame and stores the latest camera; world_to_screen
-- reads _last_camera directly. The optional DebugCore section below merely
-- re-exposes this same _last_camera as a dump source - deleting DebugCore does
-- not affect rendering.
-- ============================================================
local _last_camera = nil

function OnPreCamera(x, y, z, fov, ox1, oy1, oz1, ox2, oy2, oz2)
    _last_camera = {
        x = x, y = y, z = z, fov = fov,
        look = { ox1, oy1, oz1 },
        up = { ox2, oy2, oz2 },
    }
    -- Refresh render width from the widescreen-fix mode (4:3 vs 16:9).
    SCREEN_WIDTH, _widescreen_mode = read_screen_width()
    -- if cal_on then draw_calibration() end  -- uncomment when tagcal.lua is merged
    -- Draw here (not in preframe) so tags use THIS frame's camera - see
    -- DrawNametags. DrawNametags is a global defined later in the chunk; the
    -- lookup resolves at call time, after the whole file has loaded.
    DrawNametags()
    return x, y, z, fov, ox1, oy1, oz1, ox2, oy2, oz2
end

set_callback("precamera", "OnPreCamera")

local function world_to_screen(wx, wy, wz)
    local cam = _last_camera
    if not cam then return nil, nil end

    local cx, cy, cz = cam.x, cam.y, cam.z

    local function cross(a,b)
        return {
            a[2]*b[3] - a[3]*b[2],
            a[3]*b[1] - a[1]*b[3],
            a[1]*b[2] - a[2]*b[1]
        }
    end

    local function dot(a,b)
        return a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
    end

    local function norm(v)
        local l = math.sqrt(v[1]^2 + v[2]^2 + v[3]^2)
        if l == 0 then return {0,0,0} end
        return {v[1]/l, v[2]/l, v[3]/l}
    end

    local forward = norm(cam.look)
    local up_raw = norm(cam.up)

    local right = norm(cross(forward, up_raw))
    local true_up = cross(right, forward)
    -- NOTE: this order (cross(right, forward), not cross(forward, right))
    -- was verified CORRECT against real logged data - the earlier
    -- suspicion that it was flipped was wrong. Do not "fix" this again
    -- without re-deriving against real camera+target samples first.

    local dx, dy, dz = wx - cx, wy - cy, wz - cz

    local x = dot({dx,dy,dz}, right)
    local y = dot({dx,dy,dz}, true_up)
    local z = dot({dx,dy,dz}, forward)

    if z <= 0 then
        return nil, nil
    end

    local hfov = cam.fov or 1.502154
    local half_hfov = hfov / 2.0

    -- Derive vertical fov from horizontal fov + real pixel aspect ratio,
    -- rather than reusing half_hfov for both axes (the actual bug).
    local aspect = SCREEN_WIDTH / SCREEN_HEIGHT
    local half_vfov = math.atan(math.tan(half_hfov) / aspect)

    local ndc_x = (x / z) / math.tan(half_hfov)
    local ndc_y = (y / z) / math.tan(half_vfov)

    -- Horizontal draw_text coordinate space is MODE-DEPENDENT (verified by the
    -- tagcal ruler): 16:9 -> 640 wide (centre 320), 4:3 -> 480 wide (centre 240).
    -- In both, draw_width = 0.75 * SCREEN_WIDTH (640/853.333 = 480/640 = 0.75),
    -- so the horizontal half-extent is 0.375 * SCREEN_WIDTH. Vertical stays 480
    -- (centre 240) in both modes. Hardcoding 320 put 4:3 tags ~1.33x too far out.
    local half_w = SCREEN_WIDTH * 0.375   -- 320 (16:9) or 240 (4:3)
    local screen_x = half_w + ndc_x * half_w
    local screen_y = 240 - ndc_y * 240

    return screen_x, screen_y
end




-- Add alongside your other player-reading helpers (e.g. near get_player_name)
 
-- Confirmed via real working Chimera Lua (community ally-reticle script):
-- get_player(id) + 0x20 is read as a byte and compared for team equality,
-- i.e. it's the player's team index. Common Halo team mapping below -
-- this part (which number = which team) is the standard/expected
-- convention, not separately verified against this specific offset, so
-- worth a quick sanity check the first time you use it (e.g. print the
-- value for a known red-team and known blue-team player and confirm
-- 0 vs 1, not flipped).
local TEAM_NAMES = {
    [0] = "Red",
    [1] = "Blue",
}
 
local function get_player_team(id)
    local obj = get_player(id)
    if not obj then return nil end
    return read_byte(obj + 0x20)
end
 
local function get_player_team_name(id)
    local team = get_player_team(id)
    if team == nil then return "Unknown" end
    return TEAM_NAMES[team] or ("Team " .. tostring(team))
end
 
-- Usage in your OnPreFrame loop, alongside get_player_name(i):
--   local team = get_player_team(i)
--   local team_name = get_player_team_name(i)
--
-- For coloring the nametag by team (draw_text takes r,g,b,a as the last
-- 4 args after alignment):
local TEAM_COLORS = {
    [0] = {1.0, 0.3, 0.3}, -- red team
    [1] = {0.3, 0.5, 1.0}, -- blue team
}
 
local function get_team_color(team)
    local c = TEAM_COLORS[team]
    if c then return c[1], c[2], c[3] end
    return 1.0, 1.0, 1.0 -- fallback: white, e.g. for FFA / no team
end

-- Nametag rendering runs in OnPreCamera (NOT preframe). Confirmed via event_log
-- the order each frame is preframe -> precamera, so
-- drawing in preframe used the PREVIOUS frame's camera (captured at the last
-- precamera) and the tags lagged one frame behind camera motion. Calling this
-- from OnPreCamera, right after _last_camera is set from the current frame's
-- camera args, projects with the current camera and removes the lag.
function DrawNametags()
    local local_idx = local_player_index
    if not local_idx then return end

    -- Team of the local player. Anti-cheat: only teammates get a tag; enemies
    -- (different team) are hidden. Uses team EQUALITY only, so it's independent
    -- of the (unverified) 0=Red/1=Blue mapping. Fail-safe: if our own team can't
    -- be read, my_team is nil and NO tags render (never risk showing enemies).
    local my_team = get_player_team(local_idx)

    for i = 0, 15 do
        if i ~= local_idx then
            local dyn = get_dynamic_player(i)
            local pstatic = get_player(i)
            local pname = get_player_name(i)
            local team = get_player_team(i)
            local team_name = get_player_team_name(i)
            local r, g, b = get_team_color(team)

            -- teammate iff both teams are readable and equal
            local is_teammate = (my_team ~= nil and team ~= nil and team == my_team)

            -- DIAGNOSTIC (temporary): log the team decision so a team-game dump
            -- can confirm get_player+0x20 really separates friend from foe.
            log_team({
                tick = ticks(),
                player_id = i,
                player_name = pname,
                my_team = my_team,
                their_team = team,
                is_teammate = is_teammate,
            })

            if is_teammate and dyn and pstatic then
                -- Anchor: prefer the real HEAD node (follows crouch/pose, works
                -- seated & on-foot). Fall back to feet/vehicle position +
                -- TAG_HEIGHT if the head read is implausible (see get_head_position).
                -- draw_text is (text, x, y, WIDTH, HEIGHT, font, align, a,r,g,b);
                -- "center" centers text at x + WIDTH/2 (calibration 20260701_083219).
                local TAG_HEIGHT     = 0.7    -- fallback: feet + this (~just above head)
                local HEAD_CLEARANCE = 0.14   -- head node + this ≈ feet+0.70 standing

                local ax, ay, az, anchor_src
                local hx, hy, hz = get_head_position(dyn)
                if hx then
                    ax, ay, az, anchor_src = hx, hy, hz + HEAD_CLEARANCE, "head"
                else
                    local fx, fy, fz = get_player_world_position(i)
                    if fx then ax, ay, az, anchor_src = fx, fy, fz + TAG_HEIGHT, "fallback" end
                end

                if ax then
                    local sx, sy = world_to_screen(ax, ay, az)
                    if sx and sy then
                        local BOX_W  = 160         -- clip width; center => sx
                        local BOX_H  = 16          -- clip height; "smaller" font ~11px
                        local GAP    = 4           -- clearance above the anchor

                        local x_left = sx - BOX_W / 2     -- centers text on sx
                        local y_top  = sy - BOX_H - GAP   -- text sits just above sy

                        local ok, err = pcall(function()
                            draw_text(
                                pname,
                                x_left, y_top, BOX_W, BOX_H,
                                "smaller", "center",
                                0.8, r, g, b
                            )
                        end)

                        log_draw({
                            tick = ticks(),
                            player_id = i,
                            player_name = pname,
                            anchor_world = { ax, ay, az },
                            anchor_src = anchor_src,
                            screen_anchor = { sx, sy },
                            x = x_left,
                            y = y_top,
                            w = BOX_W,
                            h = BOX_H,
                            expect_center_x = x_left + BOX_W / 2,
                            drawn = ok,
                            err = err,
                        })
                    end
                end
            end
        end
    end
end

-- ============================================================
-- DEBUG / CALIBRATION  (optional - merge in for testing only)
--
-- This file renders standalone. To debug, PASTE the contents of the two sibling
-- files below this comment, then uncomment the wiring. They are kept separate so
-- other scripts can reuse them. Chimera allows only ONE OnPreCamera/OnPreFrame/
-- OnCommand per state, so both siblings are callback-free - we wire them into
-- THIS script's callbacks here.
--
--   debug_core.lua : JSON state dump + DebugCore.dump()   -> command `dbgdump`
--   tagcal.lua     : draw_calibration() overlay           -> command `tagcal`
--
-- 1) Paste debug_core.lua and tagcal.lua contents below.
-- 2) Uncomment the calibration hook in OnPreCamera (search "uncomment when tagcal").
-- 3) Uncomment this wiring:
--
-- set_callback("command", "OnCommand")
-- function OnCommand(cmd)
--     local c = cmd:lower()
--     if c == "dbgdump" then DebugCore.dump() return false end
--     if c == "tagcal"  then cal_on = not cal_on return false end
--     return true
-- end
--
-- DebugCore.register("camera", function() return _last_camera or {} end)
-- DebugCore.register("nametags", function()
--     return {
--         draw_log    = nametags.draw_log,
--         debug_log   = nametags.debug_log,
--         vehicle_log = nametags.vehicle_log,
--         team_log    = nametags.team_log,
--         screen      = { widescreen_mode = _widescreen_mode, screen_width = SCREEN_WIDTH },
--         errors      = nametags.errors,
--     }
-- end)
-- ============================================================
