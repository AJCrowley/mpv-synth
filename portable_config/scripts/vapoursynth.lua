local mp = require 'mp'

-- Per-file FPS preferences: path|fps, one entry per line.
-- This is the single source of truth — the .vpy reads it directly.
local PREFS_FILE         = mp.command_native({"expand-path", "~~/"}) .. "/VapourSynth/vapoursynth_fps.txt"
-- Tells the .vpy which file is currently playing so it can look up the right entry.
-- Written at start-file (before watch-later restores the vf chain).
local CURRENT_PATH_FILE  = mp.command_native({"expand-path", "~~/"}) .. "/VapourSynth/vapoursynth_current_path.txt"
local BUFFERED_FRAMES    = 6
local VS_FILTER          = "vapoursynth=~~/VapourSynth/vapoursynth.vpy:buffered-frames=" .. BUFFERED_FRAMES

mp.msg.info("VapourSynth script initialized. Prefs file: " .. PREFS_FILE)

-- ---------------------------------------------------------------------------
-- Prefs file I/O
-- ---------------------------------------------------------------------------
local function read_prefs()
    local prefs = {}
    local f = io.open(PREFS_FILE, "r")
    if not f then return prefs end
    for line in f:lines() do
        local path, fps = line:match("^(.+)|(%d+)$")
        if path and fps then
            prefs[path] = tonumber(fps)
        end
    end
    f:close()
    return prefs
end

-- Write prefs back, pruning entries for files that no longer exist on disk.
local function write_prefs(prefs)
    local f = io.open(PREFS_FILE, "w")
    if not f then
        mp.msg.error("Could not write preferences to " .. PREFS_FILE)
        return
    end
    for path, fps in pairs(prefs) do
        local fh = io.open(path, "r")
        if fh then
            fh:close()
            f:write(path .. "|" .. tostring(fps) .. "\n")
        else
            mp.msg.info("Pruning stale VapourSynth entry for missing file: " .. path)
        end
    end
    f:close()
end

-- ---------------------------------------------------------------------------
-- Current path file: tells the .vpy which file is playing right now.
-- Written at start-file so it's in place before watch-later restores the vf chain.
-- ---------------------------------------------------------------------------
local function set_current_path(path)
    if path then
        local f = io.open(CURRENT_PATH_FILE, "w")
        if f then
            f:write(path)
            f:close()
        end
    else
        os.remove(CURRENT_PATH_FILE)
    end
end

-- ---------------------------------------------------------------------------
-- Apply or remove the VapourSynth filter for the current file.
-- The .vpy reads the prefs file directly, so no fps intermediary file needed.
-- ---------------------------------------------------------------------------
local function apply_fps(fps)
    mp.commandv("vf", "remove", VS_FILTER)
    if fps and fps > 0 then
        mp.commandv("vf", "add", VS_FILTER)
        mp.osd_message("VapourSynth FPS: " .. fps, 2)
        mp.msg.info("VapourSynth filter applied at " .. fps .. " fps")
    else
        mp.msg.info("VapourSynth filter removed")
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

-- start-file fires before watch-later restores the vf chain, so the .vpy
-- will already have the correct path available when the filter executes.
mp.register_event("start-file", function()
    local path = mp.get_property("path")
    if path then
        set_current_path(path)
        mp.msg.info("VapourSynth: current path set to " .. path)
    end
end)

-- file-loaded: if this file has a stored FPS preference, re-apply the filter
-- explicitly. Watch-later may have already restored it, but the remove+add
-- cycle is harmless and ensures the filter is always in a clean state.
mp.register_event("file-loaded", function()
    local path = mp.get_property("path")
    if not path then return end

    local prefs = read_prefs()
    local fps = prefs[path]
    if fps and fps > 0 then
        mp.msg.info("Restoring VapourSynth FPS " .. fps .. " for: " .. path)
        mp.add_timeout(0.5, function()
            apply_fps(fps)
        end)
    end
end)

-- end-file: remove the filter and clear the current path file.
mp.register_event("end-file", function()
    mp.commandv("vf", "remove", VS_FILTER)
    set_current_path(nil)
end)

-- ---------------------------------------------------------------------------
-- Script message: vapoursynth_set_fps <fps>
-- Called from input.conf / right-click menu to set or clear the FPS for the
-- current file, e.g.:
--   script-message vapoursynth_set_fps 60
--   script-message vapoursynth_set_fps 0   <- clears preference for this file
-- ---------------------------------------------------------------------------
mp.register_script_message("vapoursynth_set_fps", function(fps_str)
    local fps = tonumber(fps_str) or 0
    local path = mp.get_property("path")
    if not path then
        mp.msg.error("VapourSynth: no file loaded")
        return
    end

    local prefs = read_prefs()
    if fps > 0 then
        prefs[path] = fps
        mp.msg.info("Saved VapourSynth FPS " .. fps .. " for: " .. path)
    else
        prefs[path] = nil
        mp.msg.info("Cleared VapourSynth FPS for: " .. path)
    end
    write_prefs(prefs)
    apply_fps(fps)
end)
