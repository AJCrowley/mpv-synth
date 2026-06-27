local mp = require 'mp'
local utils = require 'mp.utils'

local options = {
    editor = "notepad.exe",
}
require("mp.options").read_options(options, "config-editor")

local editor = function()
    if options.editor and options.editor ~= "" then
        local info = utils.file_info(options.editor)
        -- Full path exists
        if info and not info.is_dir then
            return options.editor
        end
        -- Looks like a command rather than a path
        if not options.editor:match("[/\\]") then
            return options.editor
        end
    end
    -- Fallback to notepad.exe
    return "notepad.exe"
end

mp.register_script_message('edit_input', function()
    local path = mp.find_config_file("input.conf")
    if path then
        utils.subprocess({
            args = {"cmd.exe", "/c", editor(), path}
        })
    end
end)

mp.register_script_message('edit_conf', function()
    local path = mp.find_config_file("mpv.conf")
    if path then
        utils.subprocess({
            args = {"cmd.exe", "/c", editor(), path}
        })
    end
end)

mp.register_script_message('edit_settings', function()
    mp.msg.info("Editor: " ..editor())
    local path = mp.find_config_file("script-opts/config-editor.conf")
    if path then
        utils.subprocess({
            args = {"cmd.exe", "/c", editor(), path}
        })
    end
end)