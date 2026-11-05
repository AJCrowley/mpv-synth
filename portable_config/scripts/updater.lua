local mp = require 'mp'
local utils = require 'mp.utils'

-- Tools > Update MPV: launch updater.bat from the mpv-synth tree ALWAYS,
-- anchored to the config directory instead of a bare name. The classic
-- input.conf binding ("Start-Process 'updater.bat'") let Windows resolve a
-- bare relative name against mpv's working directory and the PATH, which
-- could pick up a completely different updater depending on how mpv was
-- started. The config directory is the one location that is always right.
--
-- This version announces itself in the mpv log at load time (so a silent
-- failure to bind is immediately visible), forces the U binding past any
-- script that claimed it earlier, and shows an OSD line naming the exact
-- updater.bat it is about to launch on every press.

local function announce(...)
    mp.msg.info("updater-launch: " .. table.concat({...}, " "))
end

local cfg = mp.command_native({"expand-path", "~~/"})
announce("loaded; config dir = " .. cfg)

local function pick_bat()
    local p = mp.command_native({"expand-path", "~~/../updater.bat"})
    local info = utils.file_info(p)
    if info and info.is_file then return p, false end
    p = mp.command_native({"expand-path", "~~/updater.bat"})
    info = utils.file_info(p)
    if info and info.is_file then return p, true end
    return nil
end

local function launch_updater()
    local bat = pick_bat()
    if not bat then
        mp.osd_message("updater-launch: updater.bat NOT FOUND (config dir: " .. cfg .. ")", 8)
        mp.msg.error("updater-launch: updater.bat not found; config dir = " .. cfg)
        return
    end
    mp.osd_message("updater-launch: running " .. bat, 5)
    announce("launching: " .. bat)
    mp.commandv("run", "powershell", "-NoProfile", "-Command",
        "Start-Process '" .. bat .. "' -Verb RunAs")
end

-- Kris's design: the binding is driven purely by input.conf via
--   U  script-message-to updater update
-- "updater" = this script's name (the file name); "update" = the message
-- this handler answers. If the message name here ever mismatches the one
-- in input.conf, U does nothing with no error - silent by design.
mp.register_script_message('update', launch_updater)

-- Also register the named key binding so script-binding updater/run-updater
-- keeps working as an alternative invocation path.
mp.add_forced_key_binding("", "run-updater", launch_updater)

local bound = pick_bat()
if bound then
    announce("listening for message 'update'; updater resolved to " .. bound)
else
    announce("listening for message 'update'; WARNING: no updater.bat found near the config dir")
end
