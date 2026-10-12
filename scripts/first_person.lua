-- Vehicle first-person camera for Chimera.
-- Command: first_person [on|off]

clua_version = 2.056

local COMMAND = "first_person"
local enabled = false

local OBJECT_TYPE = 0xB4
local OBJECT_PARENT_ID = 0x11C
local OBJECT_TYPE_VEHICLE = 1
local NULL_ID = 0xFFFFFFFF

-- Confirmed world-space translation of the stock Halo PC cyborg head node.
local HEAD_NODE_POSITION = 0x7E8
local OBJECT_CENTRE = 0xA0
local UNIT_DESIRED_AIM = 0x230

local EYE_FORWARD_OFFSET = 0.08
local EYE_VERTICAL_OFFSET = 0.08

local function get_view_orientation(player, fallback_up_x, fallback_up_y, fallback_up_z)
    local forward_x = read_f32(player + UNIT_DESIRED_AIM)
    local forward_y = read_f32(player + UNIT_DESIRED_AIM + 0x04)
    local forward_z = read_f32(player + UNIT_DESIRED_AIM + 0x08)
    local forward_length = math.sqrt(
        forward_x * forward_x + forward_y * forward_y + forward_z * forward_z
    )
    if forward_length < 0.001 then
        return nil
    end

    forward_x = forward_x / forward_length
    forward_y = forward_y / forward_length
    forward_z = forward_z / forward_length

    -- Preserve vehicle roll while removing the forward component from the
    -- supplied up vector so it remains perpendicular to the direct aim vector.
    local projection = fallback_up_x * forward_x
                     + fallback_up_y * forward_y
                     + fallback_up_z * forward_z
    local up_x = fallback_up_x - projection * forward_x
    local up_y = fallback_up_y - projection * forward_y
    local up_z = fallback_up_z - projection * forward_z
    local up_length = math.sqrt(up_x * up_x + up_y * up_y + up_z * up_z)

    if up_length < 0.001 then
        projection = forward_z
        up_x = -projection * forward_x
        up_y = -projection * forward_y
        up_z = 1 - projection * forward_z
        up_length = math.sqrt(up_x * up_x + up_y * up_y + up_z * up_z)
        if up_length < 0.001 then
            return nil
        end
    end

    return forward_x, forward_y, forward_z,
           up_x / up_length, up_y / up_length, up_z / up_length
end

local function get_occupied_vehicle(player)
    local parent_id = read_u32(player + OBJECT_PARENT_ID)
    if parent_id == NULL_ID then
        return nil
    end

    local vehicle = get_object(parent_id)
    if vehicle == nil or read_u16(vehicle + OBJECT_TYPE) ~= OBJECT_TYPE_VEHICLE then
        return nil
    end

    return vehicle
end

local function get_head_position(player)
    local head_x = read_f32(player + HEAD_NODE_POSITION)
    local head_y = read_f32(player + HEAD_NODE_POSITION + 0x04)
    local head_z = read_f32(player + HEAD_NODE_POSITION + 0x08)

    local centre_x = read_f32(player + OBJECT_CENTRE)
    local centre_y = read_f32(player + OBJECT_CENTRE + 0x04)
    local centre_z = read_f32(player + OBJECT_CENTRE + 0x08)
    local dx = head_x - centre_x
    local dy = head_y - centre_y
    local dz = head_z - centre_z
    if dx * dx + dy * dy + dz * dz > 2.25 then
        return nil
    end

    return head_x, head_y, head_z
end

function on_precamera(camera_x, camera_y, camera_z, fov,
                      forward_x, forward_y, forward_z,
                      up_x, up_y, up_z)
    if not enabled then
        return camera_x, camera_y, camera_z, fov,
               forward_x, forward_y, forward_z,
               up_x, up_y, up_z
    end

    local player = get_dynamic_player()
    if player == nil or get_occupied_vehicle(player) == nil then
        return camera_x, camera_y, camera_z, fov,
               forward_x, forward_y, forward_z,
               up_x, up_y, up_z
    end

    local head_x, head_y, head_z = get_head_position(player)
    local aim_x, aim_y, aim_z, aim_up_x, aim_up_y, aim_up_z =
        get_view_orientation(player, up_x, up_y, up_z)
    if head_x == nil or aim_x == nil then
        return camera_x, camera_y, camera_z, fov,
               forward_x, forward_y, forward_z,
               up_x, up_y, up_z
    end

    camera_x = head_x + aim_x * EYE_FORWARD_OFFSET
    camera_y = head_y + aim_y * EYE_FORWARD_OFFSET
    camera_z = head_z + aim_z * EYE_FORWARD_OFFSET + EYE_VERTICAL_OFFSET

    return camera_x, camera_y, camera_z, fov,
           aim_x, aim_y, aim_z,
           aim_up_x, aim_up_y, aim_up_z
end

function on_command(command)
    local name, argument = command:match("^(%S+)%s*(.-)%s*$")
    name = name and name:lower() or ""
    argument = argument and argument:lower() or ""

    if name ~= COMMAND then
        return
    end

    if argument == "on" then
        enabled = true
        console_out("Vehicle first-person camera enabled")
    elseif argument == "off" then
        enabled = false
        console_out("Vehicle first-person camera disabled")
    else
        console_out("Usage: " .. COMMAND .. " [on|off]")
    end

    return false
end

set_callback("precamera", "on_precamera")
set_callback("command", "on_command")
