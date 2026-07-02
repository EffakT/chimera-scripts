--[[
  debug_core.lua  -  reusable JSON state-dump framework for Chimera Lua.

  DROP-IN LIBRARY (callback-free). Chimera global scripts run in ISOLATED Lua
  states, so this cannot be a separate auto-loaded script and still see another
  script's data. Instead, MERGE this file's contents into the script you want to
  debug (paste it in), then wire it up in THAT script's own callbacks:

    -- in your command callback:
    if cmd:lower() == "dbgdump" then DebugCore.dump() return false end

    -- register your data (fn returns a plain table, no functions/userdata):
    DebugCore.register("mytag", function() return { ... } end)

  This file defines NO callbacks (no set_callback) on purpose, so it never
  clashes with the host script's OnPreCamera/OnPreFrame/OnCommand.

  Built-in generic sources: "meta" and "local_player" (self-registered).
  Output: <Documents>\My Games\Halo\chimera\lua\data\global\chimera_debug_dump.json
  (path auto-resolved; OneDrive-aware; cached in AppData).
--]]

clua_version = 2.056

DebugCore = DebugCore or {}
DebugCore.sources = DebugCore.sources or {}   -- name -> function

-- ============================================================
-- Dynamic, per-user output path resolution
--
-- We avoid writing into the Halo install folder (Program Files) because
-- on an unelevated process Windows silently redirects writes there into
-- AppData\Local\VirtualStore - invisible unless you know to look for it.
--
-- Instead we resolve the user's home dir from the environment and target:
--   <home>\Documents\My Games\Halo\chimera\lua\data\global\
-- with a fallback to the OneDrive-redirected Documents path, since some
-- users have Documents moved under OneDrive and there is no portable way
-- to detect that from Lua alone (it's a registry/shell setting, not an
-- env var).
--
-- IMPORTANT (perf): we do NOT probe the filesystem with os.execute on
-- every script load/reload - each call spawns a real cmd.exe subprocess,
-- which is slow (worse under antivirus scanning) and was causing multi-
-- second hitches on every chimera_lua_scripts_reload. Instead we just
-- attempt the real write directly via io.open. If that succeeds, we're
-- done with zero subprocess cost. We only fall back to the OneDrive path
-- (and only then call os.execute, to mkdir the missing tree) if the
-- direct write actually fails - a rare, one-time cost instead of a
-- guaranteed cost on every single reload.
-- ============================================================

local function ensure_dir(dir)
    -- mkdir with the Windows-specific syntax to create nested dirs in one go.
    -- 2>nul suppresses the "already exists" error. Only called on the
    -- fallback path, i.e. when the direct write attempt has already failed.
    os.execute('mkdir "' .. dir .. '" 2>nul')
end

local function try_write_test(dir)
    -- Cheap existence/writability probe: try opening a throwaway file for
    -- write in `dir`. No subprocess involved - just io.open, which is fast
    -- and fails immediately (no hang) if the directory doesn't exist.
    local test_path = dir .. "\\.dbgcore_write_test"
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

    -- Cache which dir worked last time, in a fixed, always-creatable
    -- location (AppData, not redirected by OneDrive), so repeat reloads
    -- never need to re-probe or fall back again - just read one small file.
    local cache_file = home .. "\\AppData\\Local\\debugcore_resolved_dir.txt"

    local cf = io.open(cache_file, "r")
    if cf then
        local cached = cf:read("*l")
        cf:close()
        if cached and try_write_test(cached) then
            return cached
        end
        -- Cached dir no longer writable (moved, deleted, etc.) - fall
        -- through and re-resolve below.
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

    -- Cache the result so the next reload skips straight to the success
    -- case above with a single io.open, no os.execute at all.
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

-- Register a named data source. Last registration for a given name wins,
-- so reloading a script safely replaces its own source.
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

-- ============================================================
-- Minimal JSON encoder (no external deps; Lua tables only)
-- Handles: nil, boolean, number, string, array-like tables, map-like tables
-- ============================================================
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

    if v == nil then
        return "null"

    elseif t == "boolean" then
        return v and "true" or "false"

    elseif t == "number" then
        if v ~= v then return "0" end
        return tostring(v)

    elseif t == "string" then
        return '"' .. json_escape(v) .. '"'

    elseif t == "table" then

        if is_array(v) then
            if #v == 0 then
                return "[]"
            end

            local parts = {}

            for i = 1, #v do
                parts[#parts + 1] =
                    next_pad .. encode(v[i], indent + 1)
            end

            return "[\n"
                .. table.concat(parts, ",\n")
                .. "\n" .. pad .. "]"

        else
            local parts = {}

            for k, val in pairs(v) do
                parts[#parts + 1] =
                    next_pad
                    .. '"'
                    .. json_escape(tostring(k))
                    .. '": '
                    .. encode(val, indent + 1)
            end

            if #parts == 0 then
                return "{}"
            end

            return "{\n"
                .. table.concat(parts, ",\n")
                .. "\n" .. pad .. "}"
        end
    end

    return "null"
end

-- ============================================================
-- Built-in always-on sources (cheap, generally useful baseline)
-- ============================================================
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

-- ============================================================
-- Dump logic
-- ============================================================
function DebugCore.collect()
    local out = { sources = {} }
    for name, fn in pairs(DebugCore.sources) do
        local ok, result = pcall(fn)
        if ok then
            out.sources[name] = result
        else
            out.sources[name] = { error = tostring(result) }
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

    console_out("[DebugCore] dump written (" .. #json .. " bytes, " ..
        (function() local n=0; for _ in pairs(DebugCore.sources) do n=n+1 end; return n end)() ..
        " sources)", 1.0, 0.4, 1.0, 0.4)
    return true
end
