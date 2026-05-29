local utils = require "mp.utils"
local options = require "mp.options"
local input = require "mp.input"

local opts = {
    enabled = true,
    subliminal = "subliminal",
    osubname1 = "forced",
    osubcode1a = "en",
    osubcode1b = "eng",
    osubname2 = "English",
    osubcode2a = "en",
    osubcode2b = "eng",
}

options.read_options(opts, "opensubs")

if not opts.enabled then
    return
end
--=============================================================================
-->>    Python Helper Script:
--=============================================================================
local HELPER_SCRIPT = mp.command_native({"expand-path", "~~/"}) .. "\\helpers\\opensubs_helper.py"
--=============================================================================
-->>    SUBTITLE LANGUAGE:
--=============================================================================
--          Specify languages in this order:
--          { 'language name', 'ISO-639-1', 'ISO-639-2' } !
--          (See: https://en.wikipedia.org/wiki/List_of_ISO_639-1_codes)
local languages = {
--          put your preferred language first:
            { opts.osubname1, opts.osubcode1a, opts.osubcode1b },
            { opts.osubname2, opts.osubcode2a, opts.osubcode2b },
}
--=============================================================================
-->>    PROVIDER LOGINS:
--=============================================================================
--          These are completely optional and not required
--          for the functioning of the script!
local logins = {
          { '--addic7ed', opts.addict7edUser, opts.addict7edPass },
          { '--legendastv', opts.legendastvUser, opts.legendastvPass },
          { '--opensubtitles', opts.opensubtitlesUser, opts.opensubtitlesPass },
          { '--subscenter', opts.subscenterUser, opts.subscenterPass },
}
-- Clean up unpopulated logins to avoid passing empty credentials to subliminal:
for i = #logins, 1, -1 do
    local row = logins[i]
    local user = row[2]

    if user == nil or user == "" then
        table.remove(logins, i)
    end
end
--=============================================================================
-->>    ADDITIONAL OPTIONS:
--=============================================================================
local bools = {
    auto = true,   -- Automatically download subtitles, no hotkeys required
    debug = false, -- Use `--debug` in subliminal command for debug output
    force = true,  -- Force download; will overwrite existing subtitle files
    utf8 = true,   -- Save all subtitle files as UTF-8
}

local excludes = {
    -- Movies with a path containing any of these strings/paths
    -- will be excluded from auto-downloading subtitles.
    -- Full paths are also allowed, e.g.:
    -- '/home/david/Videos',
    'no-subs-dl',
}

local includes = {
    -- If anything is defined here, only the movies with a path
    -- containing any of these strings/paths will auto-download subtitles.
    -- Full paths are also allowed, e.g.:
    -- '/home/david/Videos',
}
--=============================================================================

function list_subtitles(language)
    language = language or languages[1]
    log("Searching for subtitles, please be patient...", 30)
    
    local a = {
        'python',
        HELPER_SCRIPT,
        'list',
        mp.get_property("path"),
        language[2]
    }

    local result = utils.subprocess({ args = a })

    if result.status ~= 0 then
        log('Failed to retrieve subtitle list: ' .. (result.error or 'unknown'))
        return nil
    end
    log("", 0)
    return utils.parse_json(result.stdout)
end

function download_selected_subtitle(subtitle)
    if not subtitle then
        log('Invalid subtitle selection')
        return
    end
    log("Downloading subtitle ID " .. subtitle['id'] .. " from " .. subtitle['provider'] .. ", please be patient...", 30)
    directory, filename = utils.split_path(mp.get_property('path'))
    language = subtitle.language

    local a = {
        'python',
        HELPER_SCRIPT,
        'download',
        mp.get_property("path"),
        language,
        subtitle['id'],
        subtitle['provider'],
        directory,
    }

    local result = utils.subprocess({ args = a })

    if result.status ~= 0 then
        log('Failed to retrieve subtitle list: ' .. (result.error or 'unknown'))
        return nil
    else
        mp.commandv('rescan_external_files')
        local tracks = mp.get_property_native("track-list")
        local best_sid = nil

        for _, track in ipairs(tracks) do
            if track.type == "sub" and track.external then
                best_sid = track.id
            end
        end

        if best_sid then
            mp.set_property_number("sid", best_sid)
            log("Subtitle successfully downloaded and applied", 5)
        else
            log("Unable to match downloaded subtitle to track", 5)
        end
    end
end

function show_subtitle_selection(language, subtitles)
    
    local subs = {}
    local title = ""

    for i, sub in ipairs(subtitles) do
        if sub.series or sub.title or sub.season or sub.episode then
            title = tostring(sub.provider or "Unknown") .. " - " ..
            tostring(sub.series or "") .. " - " .. tostring(sub.title or "") ..
            " (" .. tostring(sub.language or "") .. ")"
            if sub.season then
                title = title .. " S" .. tostring(string.format("%02d", sub.season))
            end
            if sub.episode then
                title = title .. "E" .. tostring(string.format("%02d", sub.episode))
            end
        else
            title = tostring(sub.provider or "Unknown Provider") .. " - " .. tostring(sub.language or "") .. " subtitle " .. sub.id
        end
        subs[i] = title
    end

    input.select({
        prompt = "Select subtitle:",
        items = subs,
        submit = function (index)
            download_selected_subtitle(subtitles[index])
        end,
    })
end

function browse_subs(language)
    if not autosub_allowed() then
        return
    end

    language = language or languages[1]
    
    if #language == 0 then
        log('No Language found\n')
        return false
    end
    
    local subtitles = list_subtitles(language)
    
    if not subtitles then
        log('No subtitles found')
        return false
    end

    if #subtitles == 0 then
        log('No matching subtitles found')
        return false
    end

    show_subtitle_selection(language, subtitles)

    return true
end

-- Download function: download the best subtitles in most preferred language
function download_subs(language)
    language = language or languages[1]
    if #language == 0 then
        log('No Language found\n')
        return false
    end
            
    log('Searching ' .. language[1] .. ' subtitles ...', 30)
    
    directory, filename = utils.split_path(mp.get_property('path'))

    -- Build the `subliminal` command, starting with the executable:
    local table = { args = { opts.subliminal } }
    local a = table.args

    for _, login in ipairs(logins) do
        a[#a + 1] = login[1]
        a[#a + 1] = login[2]
        a[#a + 1] = login[3]
    end
    if bools.debug then
        -- To see `--debug` output start MPV from the terminal!
        a[#a + 1] = '--debug'
    end

    a[#a + 1] = 'download'
    if bools.force then
        a[#a + 1] = '-f'
    end
    if bools.utf8 then
        a[#a + 1] = '-e'
        a[#a + 1] = 'utf-8'
    end

    a[#a + 1] = '-l'
    a[#a + 1] = language[2]
    a[#a + 1] = '-d'
    a[#a + 1] = directory
    a[#a + 1] = mp.get_property("path") --> Subliminal command ends with the movie filename.

    local result = utils.subprocess(table)

    if string.find(result.stdout, 'Downloaded 1 subtitle') then
        -- When multiple external files are present,
        -- always activate the most recently downloaded:
        mp.set_property('slang', language[2])
        -- Subtitles are downloaded successfully, so rescan to activate them:
        mp.commandv('rescan_external_files')
        log(language[1] .. ' subtitles ready!')
        return true
    else
        log('No ' .. language[1] .. ' subtitles found\n')
        return false
    end
end

-- Control function: only download if necessary
-- function control_downloads()
--     -- Make MPV accept external subtitle files with language specifier:
--     mp.set_property('sub-auto', 'fuzzy')
--     -- Set subtitle language preference:
--     mp.set_property('slang', languages[1][2])
--     mp.msg.warn('Reactivate external subtitle files:')
--     mp.commandv('rescan_external_files')

--     if not autosub_allowed() then
--         return
--     end

--     sub_tracks = {}
--     for _, track in ipairs(mp.get_property_native('track-list')) do
--         if track['type'] == 'sub' then
--             sub_tracks[#sub_tracks + 1] = track
--         end
--     end
--     if bools.debug then -- Log subtitle properties to terminal:
--         for _, track in ipairs(sub_tracks) do
--             mp.msg.warn('Subtitle track', track['id'], ':\n{')
--             for k, v in pairs(track) do
--                 if type(v) == 'string' then v = '"' .. v .. '"' end
--                 mp.msg.warn('  "' .. k .. '":', v)
--             end
--             mp.msg.warn('}\n')
--         end
--     end

--     for _, language in ipairs(languages) do
--         if should_download_subs_in(language) then
--             if download_subs(language) then return end -- Download successful!
--         else return end -- No need to download!
--     end
--     log('No subtitles were found')
-- end

-- Check if subtitles should be auto-downloaded:
function autosub_allowed()
    local active_format = mp.get_property('file-format')
    directory, filename = utils.split_path(mp.get_property('path'))

    if not bools.auto then
        mp.msg.warn('Automatic downloading disabled!')
        return false
    elseif directory:find('^http') then
        mp.msg.warn('Automatic subtitle downloading is disabled for web streaming')
        return false
    elseif active_format:find('^cue') then
        mp.msg.warn('Automatic subtitle downloading is disabled for cue files')
        return false
    else
        local not_allowed = {'aiff', 'ape', 'flac', 'mp3', 'ogg', 'wav', 'wv', 'tta'}

        for _, file_format in pairs(not_allowed) do
            if file_format == active_format then
                mp.msg.warn('Automatic subtitle downloading is disabled for audio files')
                return false
            end
        end

        for _, exclude in pairs(excludes) do
            local escaped_exclude = exclude:gsub('%W','%%%0')
            local excluded = directory:find(escaped_exclude)

            if excluded then
                mp.msg.warn('This path is excluded from auto-downloading subs')
                return false
            end
        end

        for i, include in ipairs(includes) do
            local escaped_include = include:gsub('%W','%%%0')
            local included = directory:find(escaped_include)

            if included then break
            elseif i == #includes then
                mp.msg.warn('This path is not included for auto-downloading subs')
                return false
            end
        end
    end

    return true
end

-- Check if subtitles should be downloaded in this language:
-- function should_download_subs_in(language)
--     for i, track in ipairs(sub_tracks) do
--         local subtitles = track['external'] and
--           'subtitle file' or 'embedded subtitles'

--         if not track['lang'] and (track['external'] or not track['title'])
--           and i == #sub_tracks then
--             local status = track['selected'] and ' active' or ' present'
--             log('Unknown ' .. subtitles .. status)
--             mp.msg.warn('=> NOT downloading new subtitles')
--             return false -- Don't download if 'lang' key is absent
--         elseif track['lang'] == language[3] or track['lang'] == language[2] or
--           (track['title'] and track['title']:lower():find(language[3])) then
--             if not track['selected'] then
--                 mp.set_property('sid', track['id'])
--                 log('Enabled ' .. language[1] .. ' ' .. subtitles .. '!')
--             else
--                 log(language[1] .. ' ' .. subtitles .. ' active')
--             end
--             mp.msg.warn('=> NOT downloading new subtitles')
--             return false -- The right subtitles are already present
--         end
--     end
--     mp.msg.warn('No ' .. language[1] .. ' subtitles were detected\n' ..
--                 '=> Proceeding to download:')
--     return true
-- end

-- Log function: log to both terminal and MPV OSD (On-Screen Display)
function log(string, secs)
    secs = secs or 5  -- secs defaults to 2.5 when secs parameter is absent
    mp.msg.warn(string)          -- This logs to the terminal
    mp.osd_message(string, secs) -- This logs to MPV screen
end

mp.register_script_message('subtitle_browser', function()
    browse_subs()
end)

mp.register_script_message('download_subs', download_subs)
