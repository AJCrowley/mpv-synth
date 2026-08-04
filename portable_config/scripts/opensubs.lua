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
    -- Colors for the manual-search prompt's [Search]/[Cancel] hint text,
    -- in ASS/SSA hex format (&HBBGGRR&). Defaults: green / red.
    manualsearch_searchcolor = "&H00C800&",
    manualsearch_cancelcolor = "&H0000FF&",

    -- ------------------------------------------------------------------
    -- Custom OSD prompt box (used by manual_search): position, size,
    -- and colors. All colors are ASS/SSA hex (&HBBGGRR&), all alphas are
    -- ASS hex (&H00& = fully opaque, &HFF& = fully transparent).
    -- ------------------------------------------------------------------
    prompt_x = 0.5,             -- horizontal position of box CENTER, 0-1 (fraction of screen width)
    prompt_y = 0.15,            -- vertical position of box TOP edge, 0-1 (fraction of screen height)
    prompt_width = 640,         -- box width in pixels
    prompt_height = 76,         -- box height in pixels
    prompt_corner_radius = 8,   -- rounded-corner radius in pixels (0 = sharp corners)
    prompt_fill_color = "&H262626&",
    prompt_fill_alpha = "40",
    prompt_border_color = "&H0A0A0A&",
    prompt_border_alpha = "00",
    prompt_border_width = 2,
    prompt_text_color = "&HFFFFFF&",
    prompt_label_color = "&HAAAAAA&",
    prompt_font_size = 30,
}

options.read_options(opts, "opensubs")

if not opts.enabled then
    return
end

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

function download_selected_subtitle(subtitle, search_text)
    if not subtitle then
        log('Invalid subtitle selection')
        return
    end
    log("Downloading subtitle ID " .. subtitle['id'] .. " from " .. subtitle['provider'] .. ", please be patient...", 30)
    directory, filename = utils.split_path(mp.get_property("path"))
    language = subtitle.language

    local result = utils.subprocess({ args = {
        'python',
        HELPER_SCRIPT,
        'download',
        filename,
        language,
        subtitle['id'],
        subtitle['provider'],
        directory,
        search_text,
    }})

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

function show_subtitle_selection(language, subtitles, title_text)
    
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
            download_selected_subtitle(subtitles[index], title_text)
        end,
    })
end

-- ============================================================================
-->>    MANUAL SUBTITLE SEARCH:
-- ============================================================================

local prompt = {
    active = false,
    text = "",
    cursor = 1,          -- 1-based index; caret sits BEFORE this character
    label = "",
    on_submit = nil,
    on_cancel = nil,
    key_bindings = {},
}

function ass_escape(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub("{", "\\{")
    s = s:gsub("}", "\\}")
    s = s:gsub("\n", "\\N")
    return s
end

-- Builds an ASS vector-drawing path for a rectangle with rounded corners.
-- Uses corner control points equal to the corner itself, which gives a
-- pleasant "rounded" approximation without needing true circular math.
function rounded_rect_path(w, h, r)
    r = math.floor(math.max(0, math.min(r, w / 2, h / 2)))
    w = math.floor(w)
    h = math.floor(h)

    if r == 0 then
        return string.format("m 0 0 l %d 0 l %d %d l 0 %d", w, w, h, h)
    end

    return string.format(
        "m %d 0 " ..
        "l %d 0 b %d 0 %d 0 %d %d " ..
        "l %d %d b %d %d %d %d %d %d " ..
        "l %d %d b %d %d %d %d %d %d " ..
        "l 0 %d b 0 0 0 0 %d 0",
        r,
        w - r, w, w, w, r,
        w, h - r, w, h, w, h, w - r, h,
        r, h, 0, h, 0, h, 0, h - r,
        r, r
    )
end

function draw_prompt()
    local w, h = mp.get_osd_size()
    if not w or w == 0 then
        w, h = 1280, 720
    end

    local box_w = opts.prompt_width
    local box_h = opts.prompt_height
    local box_x = math.floor((w * opts.prompt_x) - (box_w / 2))
    local box_y = math.floor(h * opts.prompt_y)
    local pad = 14

    -- Background + border box:
    local box_ass = string.format(
        "{\\an7\\pos(%d,%d)\\1c%s\\1a&H%s&\\3c%s\\3a&H%s&\\bord%d\\shad0\\p1}%s{\\p0}",
        box_x, box_y,
        opts.prompt_fill_color, opts.prompt_fill_alpha,
        opts.prompt_border_color, opts.prompt_border_alpha,
        opts.prompt_border_width,
        rounded_rect_path(box_w, box_h, opts.prompt_corner_radius)
    )

    -- Field label (small, top-left inside the box):
    local label_ass = string.format(
        "{\\an7\\pos(%d,%d)\\1c%s\\bord0\\shad0\\fs%d}%s",
        box_x + pad, box_y + pad - 4,
        opts.prompt_label_color, math.floor(opts.prompt_font_size * 0.55),
        ass_escape(prompt.label)
    )

    -- Entered text with a caret character inserted at the cursor position:
    local display_text = prompt.text:sub(1, prompt.cursor - 1) .. "|" .. prompt.text:sub(prompt.cursor)
    local text_ass = string.format(
        "{\\an7\\pos(%d,%d)\\1c%s\\bord0\\shad0\\fs%d}%s",
        box_x + pad, box_y + pad + math.floor(opts.prompt_font_size * 0.7),
        opts.prompt_text_color, opts.prompt_font_size,
        ass_escape(display_text)
    )

    -- Search/Cancel hint, bottom-right inside the box:
    local hint_ass = string.format(
        "{\\an9\\pos(%d,%d)\\bord0\\shad0\\fs%d}{\\c%s}Enter: Search{\\c}  {\\c%s}Esc: Cancel{\\c}",
        box_x + box_w - pad, box_y + box_h - pad,
        math.floor(opts.prompt_font_size * 0.5),
        opts.manualsearch_searchcolor, opts.manualsearch_cancelcolor
    )

    mp.set_osd_ass(w, h, table.concat({ box_ass, label_ass, text_ass, hint_ass }, "\n"))
end

function clear_prompt_osd()
    local w, h = mp.get_osd_size()
    mp.set_osd_ass(w or 1280, h or 720, "")
end

function prompt_insert(text)
    if not prompt.active or text == nil or text == "" then
        return
    end
    prompt.text = prompt.text:sub(1, prompt.cursor - 1) .. text .. prompt.text:sub(prompt.cursor)
    prompt.cursor = prompt.cursor + #text
    draw_prompt()
end

function prompt_backspace()
    if prompt.cursor > 1 then
        prompt.text = prompt.text:sub(1, prompt.cursor - 2) .. prompt.text:sub(prompt.cursor)
        prompt.cursor = prompt.cursor - 1
        draw_prompt()
    end
end

function prompt_delete_forward()
    if prompt.cursor <= #prompt.text then
        prompt.text = prompt.text:sub(1, prompt.cursor - 1) .. prompt.text:sub(prompt.cursor + 1)
        draw_prompt()
    end
end

function prompt_delete_word()
    if prompt.cursor <= 1 then
        return
    end
    local before = prompt.text:sub(1, prompt.cursor - 1)
    local trimmed = before:gsub("%s*%S+%s*$", "")
    prompt.cursor = prompt.cursor - (#before - #trimmed)
    prompt.text = trimmed .. prompt.text:sub(prompt.cursor + (#before - #trimmed))
    draw_prompt()
end

function prompt_move(delta)
    prompt.cursor = math.max(1, math.min(#prompt.text + 1, prompt.cursor + delta))
    draw_prompt()
end

function prompt_submit()
    if not prompt.active then
        return
    end
    local result = prompt.text
    local callback = prompt.on_submit
    close_prompt()
    if callback then
        callback(result)
    end
end

function prompt_cancel()
    if not prompt.active then
        return
    end
    local callback = prompt.on_cancel
    close_prompt()
    if callback then
        callback()
    end
end

function bind_prompt_keys()
    local function bind(key, fn)
        local name = "_manualsearch_" .. key:gsub("%W", "_")
        mp.add_forced_key_binding(key, name, fn, { repeatable = true })
        table.insert(prompt.key_bindings, name)
    end

    bind("ENTER", prompt_submit)
    bind("KP_ENTER", prompt_submit)
    bind("ESC", prompt_cancel)
    bind("BS", prompt_backspace)
    bind("DEL", prompt_delete_forward)
    bind("LEFT", function() prompt_move(-1) end)
    bind("RIGHT", function() prompt_move(1) end)
    bind("HOME", function() prompt.cursor = 1; draw_prompt() end)
    bind("END", function() prompt.cursor = #prompt.text + 1; draw_prompt() end)
    bind("CTRL+BS", prompt_delete_word)

    local text_name = "_manualsearch_any_unicode"
    mp.add_forced_key_binding("any_unicode", text_name, function(e)
        if e.event ~= "up" then
            prompt_insert(e.key_text)
        end
    end, { repeatable = true, complex = true })
    table.insert(prompt.key_bindings, text_name)
end

function unbind_prompt_keys()
    for _, name in ipairs(prompt.key_bindings) do
        mp.remove_key_binding(name)
    end
    prompt.key_bindings = {}
end

function close_prompt()
    prompt.active = false
    unbind_prompt_keys()
    clear_prompt_osd()
end

-- Opens the OSD prompt. `on_submit(text)` fires on ENTER; `on_cancel()`
-- fires on ESC. Only one prompt can be open at a time.
function open_prompt(label, default_text, on_submit, on_cancel)
    if prompt.active then
        close_prompt()
    end

    prompt.active = true
    prompt.label = label
    prompt.text = default_text or ""
    prompt.cursor = #prompt.text + 1
    prompt.on_submit = on_submit
    prompt.on_cancel = on_cancel

    bind_prompt_keys()
    draw_prompt()
end

function manual_search()
    local default_title = mp.get_property("media-title") or ""
    -- Strip a trailing extension for a cleaner default guess:
    default_title = default_title:gsub("%.%w+$", "")

    open_prompt("Subtitle title / search terms", default_title,
        function(title_text)
            ask_for_language(title_text)
        end,
        function()
            log("Manual subtitle search cancelled")
        end
    )
end

function ask_for_language(title_text)
    local default_lang = languages[1][2]
    open_prompt("Language code", default_lang,
        function(lang_text)
            run_manual_search(title_text, lang_text)
        end,
        function()
            log("Manual subtitle search cancelled")
        end
    )
end

function run_manual_search(title_text, lang_code)
    if title_text == nil or title_text == "" then
        log("No title entered, cancelling search")
        return
    end
    if lang_code == nil or lang_code == "" then
        lang_code = languages[1][2]
    end

    log("Searching for '" .. title_text .. "' subtitles (" .. lang_code .. "), please be patient...", 30)

    local a = {
        'python',
        HELPER_SCRIPT,
        'search',
        mp.get_property("path"),
        title_text,
        lang_code
    }

    local result = utils.subprocess({ args = a })

    if result.status ~= 0 then
        log('Failed to retrieve subtitle list: ' .. (result.error or 'unknown'))
        return
    end
    log("", 0)

    local subtitles = utils.parse_json(result.stdout)

    if not subtitles or #subtitles == 0 then
        log('No matching subtitles found')
        return
    end
    mp.msg.info("Found " .. #subtitles .. " matching subtitles for '" .. title_text .. "' (" .. lang_code .. ")")
    show_subtitle_selection(lang_code, subtitles, title_text)
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

    search_path = mp.get_property("path")
    
    directory, filename = utils.split_path(search_path)

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
    a[#a + 1] = search_path --> Subliminal command ends with the movie filename.

    local result = utils.subprocess(table)

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

-- Check if subtitles should be auto-downloaded:
function autosub_allowed()
    local active_format = mp.get_property('file-format')
    directory, filename = utils.split_path(mp.get_property("path"))

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
    end

    return true
end

-- Log function: log to both terminal and MPV OSD (On-Screen Display)
function log(string, secs)
    secs = secs or 5  -- secs defaults to 5 when secs parameter is absent
    mp.msg.warn(string)          -- This logs to the terminal
    mp.osd_message(string, secs) -- This logs to MPV screen
end

mp.register_script_message('subtitle_browser', browse_subs)
mp.register_script_message('manual_subtitle_search', manual_search)
mp.register_script_message('download_subs', download_subs)