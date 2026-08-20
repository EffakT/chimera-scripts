clua_version = 2.042

local LAP_LIMIT_ADDRESS = 0x006F1CE0

local function detect_lap_limit(message)
    if not message then
        return nil
    end

    message = string.lower(message)

    local patterns = {
        -- [LAPLIMIT] Score limit changed to 25 laps (HRL)
        "%[laplimit%]%s*score limit changed to%s*(%d+)%s*laps?",

        -- The score limit has been changed to 25 laps (Lickity)
        "the score limit has been changed to%s*(%d+)%s*laps?",
        
        -- Generic lap-limit formats
        "lap limit%s*[:=]%s*(%d+)",
        "lap limit%s+changed to%s+(%d+)%s*laps?",
        "lap limit%s+set to%s+(%d+)%s*laps?",
        "race limit%s*[:=]%s*(%d+)%s*laps?",
    }

    for _, pattern in ipairs(patterns) do
        local limit = string.match(message, pattern)

        if limit then
            return tonumber(limit)
        end
    end

    return nil
end

local function set_lap_limit(limit)
    write_dword(LAP_LIMIT_ADDRESS, limit)

    console_out(string.format(
        "[LapLimit] Set client lap limit to %d",
        limit
    ))
end

function on_rcon_message(message)
    local limit = detect_lap_limit(message)

    if limit then
        console_out(
            "[LapLimit] Detected server lap limit: " .. tostring(limit)
        )

        set_lap_limit(limit)
    end
end

set_callback("rcon message", "on_rcon_message")