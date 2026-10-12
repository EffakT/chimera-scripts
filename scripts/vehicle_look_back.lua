-- Vehicle look-back prototype for Chimera.
-- Install as: chimera/lua/scripts/global/vehicle_look_back.lua
-- Hold the configured reload input while driving to look behind the vehicle.

clua_version = 2.056

local BASE_ADDRESS = 0x400000
local OBJECT_POSITION = 0x5C
local OBJECT_UP = 0x80
local OBJECT_TYPE = 0xB4
local OBJECT_PARENT_ID = 0x11C
local VEHICLE_DRIVER_ID = 0x324
local CONTROLS_RELOAD = 0x0D
local BIPED_HEAD_POSITION = 0x7E8

local OBJECT_TYPE_VEHICLE = 1
local NULL_ID = 0xFFFFFFFF
local FIRST_PERSON_DISTANCE_SQUARED = 0.35 * 0.35
local FIRST_PERSON_LOOKBACK_FORWARD_OFFSET = 0.22
local reload_held = false
local controls_address = nil

local function matches_controls_signature(address)
    local signature = {
        0x0F, 0xBF, 0xCE, 0x8A, 0x14, 0x01,
        0x0F, 0xB6, 0xC2, 0x88, 0x85
    }
    for index = 1, #signature do
        if read_u8(address + index - 1) ~= signature[index] then
            return false
        end
    end
    return true
end

local function find_controls_address()
    local pe_header = BASE_ADDRESS + read_u32(BASE_ADDRESS + 0x3C)
    local section_count = read_u16(pe_header + 0x06)
    local optional_header_size = read_u16(pe_header + 0x14)
    local section_table = pe_header + 0x18 + optional_header_size

    for section_index = 0, section_count - 1 do
        local section = section_table + section_index * 0x28
        local virtual_size = read_u32(section + 0x08)
        local virtual_address = read_u32(section + 0x0C)
        local characteristics = read_u32(section + 0x24)
        local executable = math.floor(characteristics / 0x20000000) % 2 == 1
        if executable then
            local first = BASE_ADDRESS + virtual_address
            local last = first + virtual_size - 15
            for address = first, last do
                if matches_controls_signature(address) then
                    return read_u32(address + 0x0B)
                end
            end
        end
    end
    return nil
end

local function rotate_180(x, y, z, axis_x, axis_y, axis_z)
    local length = math.sqrt(axis_x * axis_x + axis_y * axis_y + axis_z * axis_z)
    if length == 0 then
        return -x, -y, -z
    end

    axis_x = axis_x / length
    axis_y = axis_y / length
    axis_z = axis_z / length

    local projection = 2 * (x * axis_x + y * axis_y + z * axis_z)
    return projection * axis_x - x,
           projection * axis_y - y,
           projection * axis_z - z
end

local function driver_vehicle()
    local player = get_dynamic_player()
    if player == nil then
        return nil
    end

    local parent_id = read_u32(player + OBJECT_PARENT_ID)
    if parent_id == NULL_ID then
        return nil
    end

    local vehicle = get_object(parent_id)
    if vehicle == nil or read_u16(vehicle + OBJECT_TYPE) ~= OBJECT_TYPE_VEHICLE then
        return nil
    end

    local driver_id = read_u32(vehicle + VEHICLE_DRIVER_ID)
    if driver_id == NULL_ID or get_object(driver_id) ~= player then
        return nil
    end

    return vehicle, player
end

function sample_input()
    local control_reload = controls_address and read_u8(controls_address + CONTROLS_RELOAD) or 0
    reload_held = control_reload ~= 0
end

function on_precamera(camera_x, camera_y, camera_z, fov,
                      forward_x, forward_y, forward_z,
                      up_x, up_y, up_z)
    if not reload_held then
        return camera_x, camera_y, camera_z, fov,
               forward_x, forward_y, forward_z,
               up_x, up_y, up_z
    end

    local vehicle, player = driver_vehicle()
    if vehicle == nil then
        return camera_x, camera_y, camera_z, fov,
               forward_x, forward_y, forward_z,
               up_x, up_y, up_z
    end

    local vehicle_x = read_f32(vehicle + OBJECT_POSITION)
    local vehicle_y = read_f32(vehicle + OBJECT_POSITION + 0x04)
    local vehicle_z = read_f32(vehicle + OBJECT_POSITION + 0x08)
    local axis_x = read_f32(vehicle + OBJECT_UP)
    local axis_y = read_f32(vehicle + OBJECT_UP + 0x04)
    local axis_z = read_f32(vehicle + OBJECT_UP + 0x08)

    -- If another camera script has already placed us at the driver's head,
    -- this is first-person. Keep that position fixed and rotate only the view;
    -- orbiting the position around the vehicle would move it into the opposite
    -- (usually passenger-side) seat.
    local head_x = read_f32(player + BIPED_HEAD_POSITION)
    local head_y = read_f32(player + BIPED_HEAD_POSITION + 0x04)
    local head_z = read_f32(player + BIPED_HEAD_POSITION + 0x08)
    local head_dx = camera_x - head_x
    local head_dy = camera_y - head_y
    local head_dz = camera_z - head_z
    local first_person = head_dx * head_dx + head_dy * head_dy + head_dz * head_dz
                       <= FIRST_PERSON_DISTANCE_SQUARED

    local result_x, result_y, result_z = camera_x, camera_y, camera_z
    if first_person then
        -- Move in front of the driver's face using the forward direction from
        -- before look-back is applied, then turn the view back towards them.
        result_x = result_x + forward_x * FIRST_PERSON_LOOKBACK_FORWARD_OFFSET
        result_y = result_y + forward_y * FIRST_PERSON_LOOKBACK_FORWARD_OFFSET
        result_z = result_z + forward_z * FIRST_PERSON_LOOKBACK_FORWARD_OFFSET
    else
        local offset_x, offset_y, offset_z = rotate_180(
            camera_x - vehicle_x,
            camera_y - vehicle_y,
            camera_z - vehicle_z,
            axis_x, axis_y, axis_z
        )
        result_x = vehicle_x + offset_x
        result_y = vehicle_y + offset_y
        result_z = vehicle_z + offset_z
    end
    forward_x, forward_y, forward_z = rotate_180(
        forward_x, forward_y, forward_z,
        axis_x, axis_y, axis_z
    )
    up_x, up_y, up_z = rotate_180(
        up_x, up_y, up_z,
        axis_x, axis_y, axis_z
    )

    return result_x,
           result_y,
           result_z,
           fov,
           forward_x, forward_y, forward_z,
           up_x, up_y, up_z
end

controls_address = find_controls_address()
if controls_address ~= nil then
    set_callback("precamera", "on_precamera")
    set_callback("preframe", "sample_input")
end
