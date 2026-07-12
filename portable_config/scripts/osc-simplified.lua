local assdraw = require 'mp.assdraw'
local msg = require 'mp.msg'
local opt = require 'mp.options'

--
-- Parameters
--
-- default user option values
-- do not touch, change them in osc.conf
local user_opts = {
    light_mode = false,          -- when true: white bg, black controls
    border = true,               -- draw border on main box
    box_radius = 10,             -- corner radius of main box
    box_width = 200,             -- width
    box_height = 55,     -- height (taller to fit tooltip below seekbar)
    box_padding = 8,      -- padding
    seek_bar_radius = 2,              -- corner radius of timeline
    seek_bar_knob_radius = 6,         -- corner radius of timeline knob
    showwindowed = true,        -- show OSC when windowed?
    showfullscreen = true,      -- show OSC when fullscreen?
    scalewindowed = 0,          -- scaling of the controller when windowed
    scalefullscreen = 0,        -- scaling of the controller when fullscreen
    valign = 0.8,               -- vertical alignment, -1 (top) to 1 (bottom)
    halign = 0,                 -- horizontal alignment, -1 (left) to 1 (right)
    boxalpha = 80,              -- alpha of the background box,
                                -- 0 (opaque) to 255 (fully transparent)
    hidetimeout = 500,          -- duration in ms until the OSC hides if no
                                -- mouse movement. enforced non-negative for the
                                -- user, but internally negative is "always-on".
    fadeduration = 200,         -- duration of fade out (and fade in, if enabled) in ms, 0 = no fade
    fadein = true,             -- whether to enable fade-in effect
    deadzonesize = 0.5,         -- size of deadzone
    minmousemove = 0,           -- minimum amount of pixels the mouse has to
                                -- move between ticks to make the OSC show up
    -- layout is hardcoded to box
    seekbarkeyframes = true,    -- use keyframes when dragging the seekbar
    scrollcontrols = true,      -- allow scrolling when hovering certain OSC elements
    tooltipborder = 1,          -- border of tooltip in bottom/topbar
    timetotal = false,          -- display total time instead of remaining time?
    remaining_playtime = true,  -- display the remaining time in playtime or video-time mode
                                -- playtime takes speed into account, whereas video-time doesn't
    timems = false,             -- display timecodes with milliseconds?
    visibility = "auto",        -- only used at init to set visibility_mode(...)
    visibility_modes = "never_auto_always", -- visibility modes to cycle through
    boxvideo = false,           -- apply osc_param.video_margins to video
    livemarkers = true,         -- update seekbar chapter markers on duration change
    chapter_fmt = "Chapter: %s", -- chapter print format for seekbar-hover. "no" to disable
    unicodeminus = false,       -- whether to use the Unicode minus sign character

    background_color = "#111111",     -- background color of the osc
    timecode_color = "#FFFFFF",       -- color of the progress bar and time color
    time_pos_color = "#FFFFFF",       -- color of the timecode at hovered position
    buttons_color = "#FFFFFF",        -- color of big buttons, wc buttons, and bar small buttons
    top_buttons_color = "#FFFFFF",    -- color of top buttons
    held_element_color = "#999999",   -- color of an element while held down

    time_pos_outline_color = "#000000",   -- color of the border timecodes in slimbox and TimePosBar

    tick_delay = 1 / 60,                   -- minimum interval between OSC redraws in seconds
    tick_delay_follow_display_fps = false, -- use display fps as the minimum interval

    playlist_prev_mbtn_left_command = "playlist-prev",
    playlist_prev_mbtn_right_command = "script-binding select/select-playlist; script-message-to osc-simplified osc-hide",

    playlist_next_mbtn_left_command = "playlist-next",
    playlist_next_mbtn_right_command = "script-binding select/select-playlist; script-message-to osc osc-hide",

    skip_forward_mbtn_left_command = "seek 300",
    skip_forward_mbtn_right_command = "seek 60",
    skip_backward_mbtn_left_command = "seek -300",
    skip_backward_mbtn_right_command = "seek -60",

    play_pause_mbtn_left_command = "cycle pause",
}

local icon_font = "IINAOSC"

-- Running this in Lua 5.3+ or LuaJIT converts a hexadecimal Unicode code point
-- to the decimal value of every byte for Lua 5.1 and 5.2 compatibility:
-- glyph='\u{e000}' output=''
-- for i = 1, #glyph do output = output .. '\\' .. string.byte(glyph, i) end
-- print(output)
local icons = {
    prev          = "\238\128\128",  -- U+E000 previous track
    rewind        = "\238\128\129",  -- U+E001 rewind (-300s)
    play          = "\238\128\130",  -- U+E002
    pause         = "\238\128\131",  -- U+E003
    forward       = "\238\128\132",  -- U+E004 fast forward (+300s)
    next          = "\238\128\133",  -- U+E005 next track
    clock         = "\238\128\130",  -- U+E002 (fallback for cache)
    play_backward = "\238\128\130",  -- U+E002
    skip_backward = "\238\128\129",  -- U+E001 (alias for rewind)
    skip_forward  = "\238\128\132",  -- U+E004 (alias for forward)
}

local osc_param = { -- calculated by osc_init()
    playresy = 0,                           -- canvas size Y
    playresx = 0,                           -- canvas size X
    display_aspect = 1,
    unscaled_y = 0,
    areas = {},
    video_margins = {
        l = 0, r = 0, t = 0, b = 0,         -- left/right/top/bottom
    },
}

local margins_opts = {
    {"l", "video-margin-ratio-left"},
    {"r", "video-margin-ratio-right"},
    {"t", "video-margin-ratio-top"},
    {"b", "video-margin-ratio-bottom"},
}

local tick_delay = 1 / 60
-- layouts table removed — single hardcoded box layout below
local UNICODE_MINUS = string.char(0xe2, 0x88, 0x92)  -- UTF-8 for U+2212 MINUS SIGN

local function osc_color_convert(color)
    return color:sub(6,7) .. color:sub(4,5) ..  color:sub(2,3)
end

-- luacheck: push ignore
-- luacheck: max line length
local osc_styles

local function set_osc_styles()
    osc_styles = {
        bigButtons = "{\\blur0\\bord0\\1c&H" .. osc_color_convert(user_opts.buttons_color) .. "\\3c&HFFFFFF\\fs18\\fn" .. icon_font .. "}",
        topButtons = "{\\blur0\\bord0\\1c&H" .. osc_color_convert(user_opts.top_buttons_color) .. "\\3c&HFFFFFF\\fs14\\fn" .. icon_font .. "}",

        elementDown = "{\\1c&H" .. osc_color_convert(user_opts.held_element_color) .."}",
        timecodes = "{\\blur0\\bord0\\1c&H" .. osc_color_convert(user_opts.timecode_color) .. "\\3c&HFFFFFF\\fs9}",
        box = "{\\rDefault\\blur0\\bord2\\1c&H" .. osc_color_convert(user_opts.background_color) .. "\\3c&HFFFFFF}",

        topButtonsBar = "{\\blur0\\bord0\\1c&H" .. osc_color_convert(user_opts.top_buttons_color) .. "\\3c&HFFFFFF\\fs18\\fn" .. icon_font .. "}",
        timecodesBar = "{\\blur0\\bord0\\1c&H" .. osc_color_convert(user_opts.timecode_color) .."\\3c&HFFFFFF\\fs27}",
        timePosBar = "{\\blur0\\bord".. user_opts.tooltipborder .."\\1c&H" .. osc_color_convert(user_opts.time_pos_color) .. "\\3c&H" .. osc_color_convert(user_opts.time_pos_outline_color) .. "\\fs8}",
        
        wcButtons = "{\\1c&H" .. osc_color_convert(user_opts.buttons_color) .. "\\fs24\\fn" .. icon_font .. "}",
        wcBar = "{\\1c&H" .. osc_color_convert(user_opts.background_color) .. "}",
    }

    -- light mode overrides: white background, black controls
    if user_opts.light_mode then
        local black = osc_color_convert("#000000")
        local white = osc_color_convert("#FFFFFF")
        osc_styles.bigButtons       = "{\\blur0\\bord0\\1c&H" .. black .. "\\3c&HFFFFFF\\fs20\\fn" .. icon_font .. "}"
        osc_styles.topButtons       = "{\\blur0\\bord0\\1c&H" .. black .. "\\3c&HFFFFFF\\fs12\\fn" .. icon_font .. "}"
        osc_styles.timecodes        = "{\\blur0\\bord0\\1c&H" .. black .. "\\3c&HFFFFFF\\fs9}"
        osc_styles.vidtitle         = "{\\blur0\\bord0\\1c&H" .. black .. "\\3c&HFFFFFF\\fs16\\q2}"
        osc_styles.box              = "{\\rDefault\\blur0\\bord2\\1c&H" .. white .. "\\3c&H000000}"
        osc_styles.topButtonsBar    = "{\\blur0\\bord0\\1c&H" .. black .. "\\3c&HFFFFFF\\fs18\\fn" .. icon_font .. "}"
        osc_styles.timecodesBar     = "{\\blur0\\bord0\\1c&H" .. black .. "\\3c&HFFFFFF\\fs27}"
        osc_styles.vidtitleBar      = "{\\blur0\\bord0\\1c&H" .. black .. "\\3c&HFFFFFF\\fs18\\q2}"
        osc_styles.wcButtons        = "{\\1c&H" .. black .. "\\fs24\\fn" .. icon_font .. "}"
        osc_styles.wcTitle           = "{\\1c&H" .. black .. "\\fs24\\q2}"
        osc_styles.wcBar             = "{\\1c&H" .. white .. "}"
    end

    -- border toggle on box style
    if not user_opts.border then
        osc_styles.box = osc_styles.box:gsub("\\bord%d+", "\\bord0")
    end
end

-- internal states, do not touch
local state = {
    showtime = nil,                         -- time of last invocation (last mouse move)
    touchtime = nil,                        -- time of last invocation (last touch event)
    touchpoints = {},                       -- current touch points
    osc_visible = false,
    anistart = nil,                         -- time when the animation started
    anitype = nil,                          -- current type of animation
    animation = nil,                        -- current animation alpha
    mouse_down_counter = 0,                 -- used for softrepeat
    active_element = nil,                   -- nil = none, 0 = background, 1+ = see elements[]
    active_event_source = nil,              -- the "button" that issued the current event
    rightTC_trem = not user_opts.timetotal, -- if the right timecode should display total or remaining time
    tc_ms = user_opts.timems,               -- Should the timecodes display their time with milliseconds
    screen_sizeX = nil, screen_sizeY = nil, -- last screen-resolution, to detect resolution changes to issue reINITs
    initREQ = false,                        -- is a re-init request pending?
    marginsREQ = false,                     -- is a margins update pending?
    last_mouseX = nil, last_mouseY = nil,   -- last mouse position, to detect significant mouse movement
    last_touchX = -1, last_touchY = -1,     -- last touch position
    mouse_in_window = false,
    fullscreen = false,
    tick_timer = nil,
    tick_last_time = 0,                     -- when the last tick() was run
    hide_timer = nil,
    cache_state = nil,
    idle = false,
    enabled = true,
    input_enabled = true,
    showhide_enabled = false,
    windowcontrols_buttons = false,
    windowcontrols_title = false,
    dmx_cache = 0,
    using_video_margins = false,
    border = true,
    maximized = false,
    osd = mp.create_osd_overlay("ass-events"),
    chapter_list = {},                      -- sorted by time
    visibility_modes = {},                  -- visibility_modes to cycle through
    osc_message_warned = false,             -- deprecation warnings
    osc_chapterlist_warned = false,
    osc_playlist_warned = false,
    osc_tracklist_warned = false,
}

-- luacheck: pop


--
-- Helper functions
--

local function kill_animation()
    state.anistart = nil
    state.animation = nil
    state.anitype =  nil
end

local function set_osd(res_x, res_y, text, z)
    if state.osd.res_x == res_x and
       state.osd.res_y == res_y and
       state.osd.data == text then
        return
    end
    state.osd.res_x = res_x
    state.osd.res_y = res_y
    state.osd.data = text
    state.osd.z = z
    state.osd:update()
end

local function set_time_styles(timetotal_changed, timems_changed)
    if timetotal_changed then
        state.rightTC_trem = not user_opts.timetotal
    end
    if timems_changed then
        state.tc_ms = user_opts.timems
    end
end

-- scale factor for translating between real and virtual ASS coordinates
local function get_virt_scale_factor()
    local w, h = mp.get_osd_size()
    if w <= 0 or h <= 0 then
        return 0, 0
    end
    return osc_param.playresx / w, osc_param.playresy / h
end

local function recently_touched()
    if state.touchtime == nil then
        return false
    end
    return state.touchtime + 1 >= mp.get_time()
end

-- return mouse position in virtual ASS coordinates (playresx/y)
local function get_virt_mouse_pos()
    if recently_touched() then
        local sx, sy = get_virt_scale_factor()
        return state.last_touchX * sx, state.last_touchY * sy
    elseif state.mouse_in_window then
        local sx, sy = get_virt_scale_factor()
        local x, y = mp.get_mouse_pos()
        return x * sx, y * sy
    else
        return -1, -1
    end
end

local function set_virt_mouse_area(x0, y0, x1, y1, name)
    local sx, sy = get_virt_scale_factor()
    mp.set_mouse_area(x0 / sx, y0 / sy, x1 / sx, y1 / sy, name)
end

local function scale_value(x0, x1, y0, y1, val)
    local m = (y1 - y0) / (x1 - x0)
    local b = y0 - (m * x0)
    return (m * val) + b
end

-- returns hitbox spanning coordinates (top left, bottom right corner)
-- according to alignment
local function get_hitbox_coords(x, y, an, w, h)

    local alignments = {
      [1] = function () return x, y-h, x+w, y end,
      [2] = function () return x-(w/2), y-h, x+(w/2), y end,
      [3] = function () return x-w, y-h, x, y end,

      [4] = function () return x, y-(h/2), x+w, y+(h/2) end,
      [5] = function () return x-(w/2), y-(h/2), x+(w/2), y+(h/2) end,
      [6] = function () return x-w, y-(h/2), x, y+(h/2) end,

      [7] = function () return x, y, x+w, y+h end,
      [8] = function () return x-(w/2), y, x+(w/2), y+h end,
      [9] = function () return x-w, y, x, y+h end,
    }

    return alignments[an]()
end

local function get_hitbox_coords_geo(geometry)
    return get_hitbox_coords(geometry.x, geometry.y, geometry.an,
        geometry.w, geometry.h)
end

local function get_element_hitbox(element)
    return element.hitbox.x1, element.hitbox.y1,
        element.hitbox.x2, element.hitbox.y2
end

local function mouse_hit_coords(bX1, bY1, bX2, bY2)
    local mX, mY = get_virt_mouse_pos()
    return (mX >= bX1 and mX <= bX2 and mY >= bY1 and mY <= bY2)
end

local function mouse_hit(element)
    return mouse_hit_coords(get_element_hitbox(element))
end

local function limit_range(min, max, val)
    if val > max then
        val = max
    elseif val < min then
        val = min
    end
    return val
end

-- translate value into element coordinates
local function get_slider_ele_pos_for(element, val)

    local ele_pos = scale_value(
        element.slider.min.value, element.slider.max.value,
        element.slider.min.ele_pos, element.slider.max.ele_pos,
        val)

    return limit_range(
        element.slider.min.ele_pos, element.slider.max.ele_pos,
        ele_pos)
end

-- translates global (mouse) coordinates to value
local function get_slider_value_at(element, glob_pos)

    local val = scale_value(
        element.slider.min.glob_pos, element.slider.max.glob_pos,
        element.slider.min.value, element.slider.max.value,
        glob_pos)

    return limit_range(
        element.slider.min.value, element.slider.max.value,
        val)
end

-- get value at current mouse position
local function get_slider_value(element)
    return get_slider_value_at(element, get_virt_mouse_pos())
end

-- align:  -1 .. +1
-- frame:  size of the containing area
-- obj:    size of the object that should be positioned inside the area
-- margin: min. distance from object to frame (as long as -1 <= align <= +1)
local function get_align(align, frame, obj, margin)
    return (frame / 2) + (((frame / 2) - margin - (obj / 2)) * align)
end

-- multiplies two alpha values, formular can probably be improved
local function mult_alpha(alphaA, alphaB)
    return 255 - (((1-(alphaA/255)) * (1-(alphaB/255))) * 255)
end

local function add_area(name, x1, y1, x2, y2)
    -- create area if needed
    if osc_param.areas[name] == nil then
        osc_param.areas[name] = {}
    end
    table.insert(osc_param.areas[name], {x1=x1, y1=y1, x2=x2, y2=y2})
end

local function ass_append_alpha(ass, alpha, modifier)
    local ar = {}

    for ai, av in pairs(alpha) do
        av = mult_alpha(av, modifier)
        if state.animation then
            av = mult_alpha(av, state.animation)
        end
        ar[ai] = av
    end

    ass:append(string.format("{\\1a&H%X&\\2a&H%X&\\3a&H%X&\\4a&H%X&}",
               ar[1], ar[2], ar[3], ar[4]))
end

local function ass_draw_rr_h_cw(ass, x0, y0, x1, y1, r1, hexagon, r2)
    if hexagon then
        ass:hexagon_cw(x0, y0, x1, y1, r1, r2)
    else
        ass:round_rect_cw(x0, y0, x1, y1, r1, r2)
    end
end

local function ass_draw_rr_h_ccw(ass, x0, y0, x1, y1, r1, hexagon, r2)
    if hexagon then
        ass:hexagon_ccw(x0, y0, x1, y1, r1, r2)
    else
        ass:round_rect_ccw(x0, y0, x1, y1, r1, r2)
    end
end

local function get_hidetimeout()
    if user_opts.visibility == "always" then
        return -1 -- disable autohide
    end
    return user_opts.hidetimeout
end

local function get_touchtimeout()
    if state.touchtime == nil then
        return 0
    end
    return state.touchtime + (get_hidetimeout() / 1000) - mp.get_time()
end

local function cache_enabled()
    return state.cache_state and #state.cache_state["seekable-ranges"] > 0
end

local function reset_margins()
    if state.using_video_margins then
        for _, mopt in ipairs(margins_opts) do
            mp.set_property_number(mopt[2], 0.0)
        end
        state.using_video_margins = false
    end
end

local function update_margins()
    local margins = osc_param.video_margins

    -- Don't use margins if it's visible only temporarily.
    if not state.osc_visible or get_hidetimeout() >= 0 or
       (state.fullscreen and not user_opts.showfullscreen) or
       (not state.fullscreen and not user_opts.showwindowed)
    then
        margins = {l = 0, r = 0, t = 0, b = 0}
    end

    if user_opts.boxvideo then
        -- check whether any margin option has a non-default value
        local margins_used = false

        if not state.using_video_margins then
            for _, mopt in ipairs(margins_opts) do
                if mp.get_property_number(mopt[2], 0.0) ~= 0.0 then
                    margins_used = true
                end
            end
        end

        if not margins_used then
            for _, mopt in ipairs(margins_opts) do
                local v = margins[mopt[1]]
                if v ~= 0 or state.using_video_margins then
                    mp.set_property_number(mopt[2], v)
                    state.using_video_margins = true
                end
            end
        end
    else
        reset_margins()
    end

    mp.set_property_native("user-data/osc/margins", margins)
end

local tick
-- Request that tick() is called (which typically re-renders the OSC).
-- The tick is then either executed immediately, or rate-limited if it was
-- called a small time ago.
local function request_tick()
    if state.tick_timer == nil then
        state.tick_timer = mp.add_timeout(0, tick)
    end

    if not state.tick_timer:is_enabled() then
        local now = mp.get_time()
        local timeout = tick_delay - (now - state.tick_last_time)
        if timeout < 0 then
            timeout = 0
        end
        state.tick_timer.timeout = timeout
        state.tick_timer:resume()
    end
end

local function request_init()
    state.initREQ = true
    request_tick()
end

-- Like request_init(), but also request an immediate update
local function request_init_resize()
    request_init()
    -- ensure immediate update
    state.tick_timer:kill()
    state.tick_timer.timeout = 0
    state.tick_timer:resume()
end

local function render_wipe()
    msg.trace("render_wipe()")
    state.osd.data = "" -- allows set_osd to immediately update on enable
    state.osd:remove()
end


--
-- Tracklist Management
--

-- WindowControl helpers
local function window_controls_enabled()
    return false
end

local function window_controls_alignment()
    return "right"
end


--
-- Element Management
--

local elements = {}

local function prepare_elements()

    -- remove elements without layout or invisible
    local elements2 = {}
    for _, element in pairs(elements) do
        if element.layout ~= nil and element.visible then
            table.insert(elements2, element)
        end
    end
    elements = elements2

    local function elem_compare (a, b)
        return a.layout.layer < b.layout.layer
    end

    table.sort(elements, elem_compare)


    for _,element in pairs(elements) do

        local elem_geo = element.layout.geometry

        -- Calculate the hitbox
        local bX1, bY1, bX2, bY2 = get_hitbox_coords_geo(elem_geo)

        -- For sliders, extend the hitbox vertically so the knob is fully
        -- grabbable even though the bar itself is thin.
        if element.type == "slider" then
            local knob_r = user_opts.seek_bar_knob_radius
            local midY = (bY1 + bY2) / 2
            bY1 = midY - knob_r
            bY2 = midY + knob_r
        end

        element.hitbox = {x1 = bX1, y1 = bY1, x2 = bX2, y2 = bY2}

        local style_ass = assdraw.ass_new()

        -- prepare static elements
        style_ass:append("{}") -- hack to troll new_event into inserting a \n
        style_ass:new_event()
        style_ass:pos(elem_geo.x, elem_geo.y)
        style_ass:an(elem_geo.an)
        style_ass:append(element.layout.style)

        element.style_ass = style_ass

        local static_ass = assdraw.ass_new()


        if element.type == "box" then
            --draw box
            static_ass:draw_start()
            ass_draw_rr_h_cw(static_ass, 0, 0, elem_geo.w, elem_geo.h,
                             element.layout.box.radius, element.layout.box.hexagon)
            static_ass:draw_stop()

        elseif element.type == "slider" then
            --draw static slider parts

            local r1 = 0
            local r2 = 0
            local slider_lo = element.layout.slider
            -- offset between element outline and drag-area
            local foV = slider_lo.border + slider_lo.gap
            -- calculate positions of min and max points
            r1 = user_opts.seek_bar_radius
            element.slider.min.ele_pos = elem_geo.h / 2
            element.slider.max.ele_pos = elem_geo.w - (elem_geo.h / 2)
            r2 = r1

            element.slider.min.glob_pos =
                element.hitbox.x1 + element.slider.min.ele_pos
            element.slider.max.glob_pos =
                element.hitbox.x1 + element.slider.max.ele_pos

            static_ass:draw_start()

            -- the box
            ass_draw_rr_h_cw(static_ass, 0, 0, elem_geo.w, elem_geo.h, r1, false)

            -- the "hole"
            ass_draw_rr_h_ccw(static_ass, slider_lo.border, slider_lo.border,
                              elem_geo.w - slider_lo.border, elem_geo.h - slider_lo.border,
                              r2, false)

            -- marker nibbles
            if element.slider.markerF ~= nil and slider_lo.gap > 0 then
                local markers = element.slider.markerF()
                for _,marker in pairs(markers) do
                    if marker > element.slider.min.value and
                        marker < element.slider.max.value then

                        local s = get_slider_ele_pos_for(element, marker)

                        if slider_lo.gap > 1 then -- draw triangles

                            local a = slider_lo.gap / 0.5 --0.866

                            --top
                            if slider_lo.nibbles_top then
                                static_ass:move_to(s - (a / 2), slider_lo.border)
                                static_ass:line_to(s + (a / 2), slider_lo.border)
                                static_ass:line_to(s, foV)
                            end

                            --bottom
                            if slider_lo.nibbles_bottom then
                                static_ass:move_to(s - (a / 2),
                                    elem_geo.h - slider_lo.border)
                                static_ass:line_to(s,
                                    elem_geo.h - foV)
                                static_ass:line_to(s + (a / 2),
                                    elem_geo.h - slider_lo.border)
                            end

                        else -- draw 2x1px nibbles

                            --top
                            if slider_lo.nibbles_top then
                                static_ass:rect_cw(s - 1, slider_lo.border,
                                    s + 1, slider_lo.border + slider_lo.gap);
                            end

                            --bottom
                            if slider_lo.nibbles_bottom then
                                static_ass:rect_cw(s - 1,
                                    elem_geo.h -slider_lo.border -slider_lo.gap,
                                    s + 1, elem_geo.h - slider_lo.border);
                            end
                        end
                    end
                end
            end
        end

        element.static_ass = static_ass


        -- if the element is supposed to be disabled,
        -- style it accordingly and kill the eventresponders
        if not element.enabled then
            element.layout.alpha[1] = 136
            element.eventresponder = nil
        end
    end
end


--
-- Element Rendering
--

-- returns nil or a chapter element from the native property chapter-list
local function get_chapter(possec)
    local cl = state.chapter_list  -- sorted, get latest before possec, if any

    for n=#cl,1,-1 do
        if possec >= cl[n].time then
            return cl[n]
        end
    end
end

local function render_elements(master_ass)
    -- when the slider is dragged or hovered and we have a target chapter name
    -- then we use it instead of the normal title. we calculate it before the
    -- render iterations because the title may be rendered before the slider.
    state.forced_title = nil
    local se, ae = state.slider_element, elements[state.active_element]
    if user_opts.chapter_fmt ~= "no" and se and (ae == se or (not ae and mouse_hit(se))) then
        local dur = mp.get_property_number("duration", 0)
        if dur > 0 then
            local possec = get_slider_value(se) * dur / 100 -- of mouse pos
            local ch = get_chapter(possec)
            if ch and ch.title and ch.title ~= "" then
                state.forced_title = string.format(user_opts.chapter_fmt, ch.title)
            end
        end
    end

    for n=1, #elements do
        local element = elements[n]

        local style_ass = assdraw.ass_new()
        style_ass:merge(element.style_ass)
        ass_append_alpha(style_ass, element.layout.alpha, 0)

        if element.eventresponder and (state.active_element == n) then

            -- run render event functions
            if element.eventresponder.render ~= nil then
                element.eventresponder.render(element)
            end

            if mouse_hit(element) then
                -- mouse down styling
                if element.styledown then
                    style_ass:append(osc_styles.elementDown)
                end

                if element.softrepeat and state.mouse_down_counter >= 15
                    and state.mouse_down_counter % 5 == 0 then

                    element.eventresponder[state.active_event_source.."_down"](element)
                end
                state.mouse_down_counter = state.mouse_down_counter + 1
            end

        end

        local elem_ass = assdraw.ass_new()

        elem_ass:merge(style_ass)

        if element.type ~= "button" then
            elem_ass:merge(element.static_ass)
        end

        if element.type == "slider" then

            local slider_lo = element.layout.slider
            local elem_geo = element.layout.geometry
            local s_min = element.slider.min.value
            local s_max = element.slider.max.value

            -- draw pos marker
            local foH, xp
            local pos = element.slider.posF()
            local foV = slider_lo.border + slider_lo.gap
            local innerH = elem_geo.h - (2 * foV)
            local seekRanges = element.slider.seekRangesF()

            foH = elem_geo.h / 2

            if pos then
                xp = get_slider_ele_pos_for(element, pos)
                local r = user_opts.seek_bar_knob_radius
                
                ass_draw_rr_h_cw(elem_ass, xp - r, foH - r,
                                 xp + r, foH + r,
                                 r, false)
            end

            if seekRanges then
                for _,range in pairs(seekRanges) do
                    local pstart = get_slider_ele_pos_for(element, range["start"])
                    local pend = get_slider_ele_pos_for(element, range["end"])

                    -- rtype == "inverted"
                    ass_draw_rr_h_ccw(elem_ass, pstart, (elem_geo.h / 2) - 1, pend,
                                      (elem_geo.h / 2) + 1,
                                      1, false)
                end
            end

            elem_ass:draw_stop()

            -- add tooltip
            if element.slider.tooltipF ~= nil then
                if mouse_hit(element) then
                    local sliderpos = get_slider_value(element)
                    local tooltiplabel = element.slider.tooltipF(sliderpos)

                    local an = slider_lo.tooltip_an

                    local ty

                    if an == 2 then
                        ty = element.hitbox.y1 - slider_lo.border
                    else
                        ty = element.hitbox.y1 + elem_geo.h / 2
                    end

                    local tx = get_virt_mouse_pos()
                    if slider_lo.adjust_tooltip then
                        if an == 2 then
                            if sliderpos < (s_min + 3) then
                                an = an - 1
                            elseif sliderpos > (s_max - 3) then
                                an = an + 1
                            end
                        elseif sliderpos > (s_max+s_min) / 2 then
                            an = an + 1
                            tx = tx - 5
                        else
                            an = an - 1
                            tx = tx + 10
                        end
                    end

                    -- tooltip label
                    elem_ass:new_event()
                    elem_ass:pos(tx, ty)
                    elem_ass:an(an)
                    elem_ass:append(slider_lo.tooltip_style)
                    ass_append_alpha(elem_ass, slider_lo.alpha, 0)
                    elem_ass:append(tooltiplabel)

                end
            end

        elseif element.type == "button" then

            local buttontext
            if type(element.content) == "function" then
                buttontext = element.content() -- function objects
            elseif element.content ~= nil then
                buttontext = element.content -- text objects
            end

            local maxchars = element.layout.button.maxchars
            if maxchars ~= nil and #buttontext > maxchars then
                local max_ratio = 1.25  -- up to 25% more chars while shrinking
                local limit = math.max(0, math.floor(maxchars * max_ratio) - 3)
                if #buttontext > limit then
                    while (#buttontext > limit) do
                        buttontext = buttontext:gsub(".[\128-\191]*$", "")
                    end
                    buttontext = buttontext .. "..."
                end
                buttontext = string.format("{\\fscx%f}",
                    (maxchars/#buttontext)*100) .. buttontext
            end

            elem_ass:append(buttontext)
        end

        master_ass:merge(elem_ass)
    end
end


--
-- Initialisation and Layout
--

local function new_element(name, type)
    elements[name] = {}
    elements[name].type = type

    -- add default stuff
    elements[name].eventresponder = {}
    elements[name].visible = true
    elements[name].enabled = true
    elements[name].softrepeat = false
    elements[name].styledown = (type == "button")
    elements[name].state = {}

    if type == "slider" then
        elements[name].slider = {min = {value = 0}, max = {value = 100}}
    end


    return elements[name]
end

local function add_layout(name)
    if elements[name] ~= nil then
        -- new layout
        elements[name].layout = {}

        -- set layout defaults
        elements[name].layout.layer = 50
        elements[name].layout.alpha = {[1] = 0, [2] = 255, [3] = 255, [4] = 255}

        if elements[name].type == "button" then
            elements[name].layout.button = {
                maxchars = nil,
            }
        elseif elements[name].type == "slider" then
            -- slider defaults
            elements[name].layout.slider = {
                border = 1,
                gap = 1,
                nibbles_top = true,
                nibbles_bottom = true,
                stype = "slider",
                adjust_tooltip = true,
                tooltip_style = "",
                tooltip_an = 2,
                alpha = {[1] = 0, [2] = 255, [3] = 88, [4] = 255},
            }
        elseif elements[name].type == "box" then
            elements[name].layout.box = {radius = 0, hexagon = false}
        end

        return elements[name].layout
    else
        msg.error("Can't add_layout to element '"..name.."', doesn't exist.")
    end
end


--
-- Layouts
--

local function box_layout()

    local osc_geo = {
        w = user_opts.box_width,    -- width
        h = user_opts.box_height,     -- height (taller to fit tooltip below seekbar)
        r = user_opts.box_radius,     -- corner-radius
        p = user_opts.box_padding,      -- padding
    }

    -- make sure the OSC actually fits into the video
    if osc_param.playresx < (osc_geo.w + (2 * osc_geo.p)) then
        osc_param.playresy = (osc_geo.w + (2 * osc_geo.p)) / osc_param.display_aspect
        osc_param.playresx = osc_param.playresy * osc_param.display_aspect
    end

    -- position of the controller according to video aspect and valignment
    local posX = math.floor(get_align(user_opts.halign, osc_param.playresx,
        osc_geo.w, 0))
    local posY = math.floor(get_align(user_opts.valign, osc_param.playresy,
        osc_geo.h, 0)) - 30

    -- position offset for contents aligned at the borders of the box
    local pos_offsetX = (osc_geo.w - (2*osc_geo.p)) / 2
    local pos_offsetY = (osc_geo.h - (2*osc_geo.p)) / 2

    osc_param.areas = {} -- delete areas

    -- area for active mouse input
    add_area("input", get_hitbox_coords(posX, posY, 5, osc_geo.w, osc_geo.h))

    -- area for show/hide
    local sh_area_y0, sh_area_y1
    if user_opts.valign > 0 then
        -- deadzone above OSC
        sh_area_y0 = get_align(-1 + (2*user_opts.deadzonesize),
            posY - (osc_geo.h / 2), 0, 0)
        sh_area_y1 = osc_param.playresy
    else
        -- deadzone below OSC
        sh_area_y0 = 0
        sh_area_y1 = (posY + (osc_geo.h / 2)) +
            get_align(1 - (2*user_opts.deadzonesize),
            osc_param.playresy - (posY + (osc_geo.h / 2)), 0, 0)
    end
    add_area("showhide", 0, sh_area_y0, osc_param.playresx, sh_area_y1)

    -- fetch values
    local osc_w, osc_h = osc_geo.w, osc_geo.h

    local lo

    --
    -- Background box
    --

    new_element("bgbox", "box")
    lo = add_layout("bgbox")

    lo.geometry = {x = posX, y = posY, an = 5, w = osc_w, h = osc_h}
    lo.layer = 10
    lo.style = osc_styles.box
    lo.alpha[1] = user_opts.boxalpha
    lo.alpha[3] = user_opts.boxalpha
    lo.box.radius = user_opts.box_radius

    --
    -- Big buttons (5 controls: prev, rewind, play/pause, forward, next)
    --

    local bigbtnrowY = posY - pos_offsetY + 8
    local bigbtndist = 32
    local btnSize = 21

    -- play_pause (center)
    lo = add_layout("play_pause")
    lo.geometry =
        {x = posX, y = bigbtnrowY, an = 5, w = btnSize, h = btnSize}
    lo.style = osc_styles.bigButtons

    -- skip_backward (left of center)
    lo = add_layout("skip_backward")
    lo.geometry =
        {x = posX - bigbtndist, y = bigbtnrowY, an = 5, w = btnSize, h = btnSize}
    lo.style = osc_styles.bigButtons

    -- skip_forward (right of center)
    lo = add_layout("skip_forward")
    lo.geometry =
        {x = posX + bigbtndist, y = bigbtnrowY, an = 5, w = btnSize, h = btnSize}
    lo.style = osc_styles.bigButtons

    -- playlist_prev (far left of buttons)
    lo = add_layout("playlist_prev")
    lo.geometry =
        {x = posX - (bigbtndist * 2), y = bigbtnrowY, an = 5, w = btnSize, h = btnSize}
    lo.style = osc_styles.bigButtons

    -- playlist_next (far right of buttons)
    lo = add_layout("playlist_next")
    lo.geometry =
        {x = posX + (bigbtndist * 2), y = bigbtnrowY, an = 5, w = btnSize, h = btnSize}
    lo.style = osc_styles.bigButtons

    --
    -- Seekbar (below buttons, no overlap, centered)
    --

    lo = add_layout("seekbar")
    lo.geometry =
        {x = posX, y = posY + pos_offsetY - 10, an = 5, w = pos_offsetX*2, h = 5}
    lo.style = osc_styles.timecodes
    lo.slider.border = 1
    lo.slider.gap = 1
    lo.slider.tooltip_style = osc_styles.timePosBar
    lo.slider.tooltip_an = 8
    lo.slider.stype = "knob"
    lo.slider.rtype = "inverted"

    --
    -- Timecodes (below seekbar with spacing for tooltip)
    --

    local bottomrowY = posY + pos_offsetY + 2

    lo = add_layout("tc_left")
    lo.geometry =
        {x = posX - pos_offsetX, y = bottomrowY, an = 4, w = 55, h = 8}
    lo.style = osc_styles.timecodes

    lo = add_layout("tc_right")
    lo.geometry =
        {x = posX + pos_offsetX, y = bottomrowY, an = 6, w = 55, h = 8}
    lo.style = osc_styles.timecodes

end

local function bind_mouse_buttons(element_name)
    for _, button in pairs({"mbtn_left", "mbtn_mid", "mbtn_right"}) do
        local command = user_opts[element_name .. "_" .. button .. "_command"]

        if command ~= "" then
            elements[element_name].eventresponder[button .. "_up"] = function ()
                mp.command(command)
            end
        end
    end

    if user_opts.scrollcontrols then
        for _, button in pairs({"wheel_down", "wheel_up"}) do
            local command = user_opts[element_name .. "_" .. button .. "_command"]

            if command and command ~= "" then
                elements[element_name].eventresponder[button .. "_press"] = function ()
                    mp.command(command)
                end
            end
        end
    end
end

local function osc_init()
    msg.debug("osc_init")

    -- set canvas resolution according to display aspect and scaling setting
    local baseResY = 720
    local _, display_h, display_aspect = mp.get_osd_size()
    local scale = 2 --user_opts.scalefullscreen

    local scale_with_video
    scale_with_video = 1 --mp.get_property_native("osd-scale-by-window")
    osc_param.unscaled_y = display_h
    osc_param.playresy = osc_param.unscaled_y / scale
    if display_aspect > 0 then
        osc_param.display_aspect = display_aspect
    end
    osc_param.playresx = osc_param.playresy * osc_param.display_aspect

    -- stop seeking with the slider to prevent skipping files
    state.active_element = nil

    osc_param.video_margins = {l = 0, r = 0, t = 0, b = 0}

    elements = {}

    -- some often needed stuff
    local pl_count = mp.get_property_number("playlist-count", 0)
    local have_pl = (pl_count > 1)
    local pl_pos = mp.get_property_number("playlist-pos", 0) + 1
    local have_ch = (mp.get_property_number("chapters", 0) > 0)
    local loop = mp.get_property("loop-playlist", "no")

    local ne

    -- playlist buttons

    -- prev
    ne = new_element("playlist_prev", "button")

    ne.content = icons.prev
    ne.enabled = (pl_pos > 1) or (loop ~= "no")
    bind_mouse_buttons("playlist_prev")

    --next
    ne = new_element("playlist_next", "button")

    ne.content = icons.next
    ne.enabled = (have_pl and (pl_pos < pl_count)) or (loop ~= "no")
    bind_mouse_buttons("playlist_next")


    -- big buttons

    --play_pause
    ne = new_element("play_pause", "button")

    ne.content = function ()
        if mp.get_property_bool("paused-for-cache") ~= false then
            return icons.clock
        end

        if not mp.get_property_native("pause") then
            return icons.pause
        end

        return mp.get_property("play-direction") == "forward"
            and icons.play
            or icons.play_backward
    end
    bind_mouse_buttons("play_pause")

    --skip_backward
    ne = new_element("skip_backward", "button")

    ne.softrepeat = true
    ne.content = icons.skip_backward
    bind_mouse_buttons("skip_backward")

    --skip_forward
    ne = new_element("skip_forward", "button")

    ne.softrepeat = true
    ne.content = icons.skip_forward
    bind_mouse_buttons("skip_forward")

    --seekbar
    ne = new_element("seekbar", "slider")

    ne.enabled = mp.get_property("percent-pos") ~= nil
    state.slider_element = ne.enabled and ne or nil  -- used for forced_title
    ne.slider.markerF = function ()
        local duration = mp.get_property_number("duration")
        if duration ~= nil then
            local chapters = mp.get_property_native("chapter-list", {})
            local markers = {}
            for n = 1, #chapters do
                markers[n] = (chapters[n].time / duration * 100)
            end
            return markers
        else
            return {}
        end
    end
    ne.slider.posF =
        function () return mp.get_property_number("percent-pos") end
    ne.slider.tooltipF = function (pos)
        local duration = mp.get_property_number("duration")
        if duration ~= nil and pos ~= nil then
            local possec = duration * (pos / 100)
            return mp.format_time(possec)
        else
            return ""
        end
    end
    ne.slider.seekRangesF = function()
        if not cache_enabled() then
            return nil
        end
        local duration = mp.get_property_number("duration")
        if duration == nil or duration <= 0 then
            return nil
        end
        local nranges = {}
        for _, range in pairs(state.cache_state["seekable-ranges"]) do
            nranges[#nranges + 1] = {
                ["start"] = 100 * range["start"] / duration,
                ["end"] = 100 * range["end"] / duration,
            }
        end
        return nranges
    end
    ne.eventresponder["mouse_move"] = --keyframe seeking when mouse is dragged
        function (element)
            if not element.state.mbtn_left then
                return
            end

            -- mouse move events may pile up during seeking and may still get
            -- sent when the user is done seeking, so we need to throw away
            -- identical seeks
            local seekto = get_slider_value(element)
            if element.state.lastseek == nil or
                element.state.lastseek ~= seekto then
                    local flags = "absolute-percent"
                    if not user_opts.seekbarkeyframes then
                        flags = flags .. "+exact"
                    end
                    mp.commandv("seek", seekto, flags)
                    element.state.lastseek = seekto
            end

        end
    ne.eventresponder["mbtn_left_down"] = function (element)
        element.state.mbtn_left = true
        mp.commandv("seek", get_slider_value(element), "absolute-percent+exact")
    end
    ne.eventresponder["mbtn_left_up"] = function (element)
        element.state.mbtn_left = false
    end
    ne.eventresponder["mbtn_right_up"] = function (element)
        local chapter
        local pos = get_slider_value(element)
        local diff = math.huge

        for i, marker in ipairs(element.slider.markerF()) do
            if math.abs(pos - marker) < diff then
                diff = math.abs(pos - marker)
                chapter = i
            end
        end

        if chapter then
            mp.set_property("chapter", chapter - 1)
        end
    end
    ne.eventresponder["reset"] =
        function (element) element.state.lastseek = nil end

    if user_opts.scrollcontrols then
        ne.eventresponder["wheel_up_press"] =
            function () mp.commandv("osd-auto", "seek",  10) end
        ne.eventresponder["wheel_down_press"] =
            function () mp.commandv("osd-auto", "seek", -10) end
    end


    -- tc_left (current pos)
    ne = new_element("tc_left", "button")

    ne.content = function ()
        if state.tc_ms then
            return (mp.get_property_osd("playback-time/full"))
        else
            return (mp.get_property_osd("playback-time"))
        end
    end
    ne.eventresponder["mbtn_left_up"] = function ()
        state.tc_ms = not state.tc_ms
        request_init()
    end

    -- tc_right (total/remaining time)
    ne = new_element("tc_right", "button")

    ne.visible = (mp.get_property_number("duration", 0) > 0)
    ne.content = function ()
        if state.rightTC_trem then
            local minus = user_opts.unicodeminus and UNICODE_MINUS or "-"
            local property = user_opts.remaining_playtime and "playtime-remaining"
                                                           or "time-remaining"
            if state.tc_ms then
                return (minus..mp.get_property_osd(property .. "/full"))
            else
                return (minus..mp.get_property_osd(property))
            end
        else
            if state.tc_ms then
                return (mp.get_property_osd("duration/full"))
            else
                return (mp.get_property_osd("duration"))
            end
        end
    end
    ne.eventresponder["mbtn_left_up"] =
        function () state.rightTC_trem = not state.rightTC_trem end

    -- load layout (hardcoded: box)
    box_layout()

    --do something with the elements
    prepare_elements()

    update_margins()
end

local function osc_visible(visible)
    if state.osc_visible ~= visible then
        state.osc_visible = visible
        update_margins()
    end
    request_tick()
end

local function show_osc()
    -- show when disabled can happen (e.g. mouse_move) due to async/delayed unbinding
    if not state.enabled then return end

    msg.trace("show_osc")
    --remember last time of invocation (mouse move)
    state.showtime = mp.get_time()

    if user_opts.fadeduration <= 0 then
        osc_visible(true)
    elseif user_opts.fadein then
        if not state.osc_visible then
            state.anitype = "in"
            request_tick()
        end
    else
        osc_visible(true)
        state.anitype = nil
    end
end

local function hide_osc()
    msg.trace("hide_osc")
    if not state.enabled then
        -- typically hide happens at render() from tick(), but now tick() is
        -- no-op and won't render again to remove the osc, so do that manually.
        state.osc_visible = false
        render_wipe()
    elseif user_opts.fadeduration > 0 then
        if state.osc_visible then
            state.anitype = "out"
            request_tick()
        end
    else
        osc_visible(false)
    end
end

local function pause_state(_, enabled)
    state.paused = enabled
    request_tick()
end

local function cache_state(_, st)
    state.cache_state = st
    request_tick()
end

local function mouse_leave()
    if get_hidetimeout() >= 0 and get_touchtimeout() <= 0 then
        hide_osc()
    end
    -- reset mouse position
    state.last_mouseX, state.last_mouseY = nil, nil
    state.mouse_in_window = false
end

local function handle_touch(_, touchpoints)
    --remember last touch points
    if touchpoints then
        state.touchpoints = touchpoints
        if #touchpoints > 0 then
            --remember last time of invocation (touch event)
            state.touchtime = mp.get_time()
            state.last_touchX = touchpoints[1].x
            state.last_touchY = touchpoints[1].y
        end
    end
end


--
-- Eventhandling
--

local function element_has_action(element, action)
    return element and element.eventresponder and
        element.eventresponder[action]
end

local function process_event(source, what)
    local action = string.format("%s%s", source,
        what and ("_" .. what) or "")

    if what == "down" or what == "press" then

        for n = 1, #elements do

            if mouse_hit(elements[n]) and
                elements[n].eventresponder and
                (elements[n].eventresponder[source .. "_up"] or
                    elements[n].eventresponder[action]) then

                if what == "down" then
                    state.active_element = n
                    state.active_event_source = source
                end
                -- fire the down or press event if the element has one
                if element_has_action(elements[n], action) then
                    elements[n].eventresponder[action](elements[n])
                end

            end
        end

    elseif what == "up" then

        if elements[state.active_element] then
            local n = state.active_element

            if n == 0 then --luacheck: ignore 542
                --click on background (does not work)
            elseif element_has_action(elements[n], action) and
                mouse_hit(elements[n]) then

                elements[n].eventresponder[action](elements[n])
            end

            --reset active element
            if element_has_action(elements[n], "reset") then
                elements[n].eventresponder["reset"](elements[n])
            end

        end
        state.active_element = nil
        state.mouse_down_counter = 0

    elseif source == "mouse_move" then

        state.mouse_in_window = true

        local mouseX, mouseY = get_virt_mouse_pos()
        if user_opts.minmousemove == 0 or
            ((state.last_mouseX ~= nil and state.last_mouseY ~= nil) and
                ((math.abs(mouseX - state.last_mouseX) >= user_opts.minmousemove)
                    or (math.abs(mouseY - state.last_mouseY) >= user_opts.minmousemove)
                )
            ) then
            show_osc()
        end
        state.last_mouseX, state.last_mouseY = mouseX, mouseY

        local n = state.active_element
        if element_has_action(elements[n], action) then
            elements[n].eventresponder[action](elements[n])
        end
    end

    -- ensure rendering after any (mouse) event - icons could change etc
    request_tick()
end

local function do_enable_keybindings()
    if state.enabled then
        if not state.showhide_enabled then
            mp.enable_key_bindings("showhide", "allow-vo-dragging+allow-hide-cursor")
            mp.enable_key_bindings("showhide_wc", "allow-vo-dragging+allow-hide-cursor")
        end
        state.showhide_enabled = true
    end
end

local function enable_osc(enable)
    state.enabled = enable
    if enable then
        do_enable_keybindings()
    else
        hide_osc() -- acts immediately when state.enabled == false
        if state.showhide_enabled then
            mp.disable_key_bindings("showhide")
            mp.disable_key_bindings("showhide_wc")
        end
        state.showhide_enabled = false
    end
end

local function render()
    msg.trace("rendering")
    local current_screen_sizeX, current_screen_sizeY = mp.get_osd_size()
    local mouseX, mouseY = get_virt_mouse_pos()
    local now = mp.get_time()

    -- check if display changed, if so request reinit
    if state.screen_sizeX ~= current_screen_sizeX
        or state.screen_sizeY ~= current_screen_sizeY then

        request_init_resize()

        state.screen_sizeX = current_screen_sizeX
        state.screen_sizeY = current_screen_sizeY
    end

    -- init management
    if state.active_element then
        -- mouse is held down on some element - keep ticking and ignore initReq
        -- till it's released, or else the mouse-up (click) will misbehave or
        -- get ignored. that's because osc_init() recreates the osc elements,
        -- but mouse handling depends on the elements staying unmodified
        -- between mouse-down and mouse-up (using the index active_element).
        request_tick()
    elseif state.initREQ then
        osc_init()
        state.initREQ = false

        -- store initial mouse position
        if (state.last_mouseX == nil or state.last_mouseY == nil)
            and not (mouseX == nil or mouseY == nil) then

            state.last_mouseX, state.last_mouseY = mouseX, mouseY
        end
    end


    -- fade animation
    if state.anitype ~= nil then

        if state.anistart == nil then
            state.anistart = now
        end

        if now < state.anistart + (user_opts.fadeduration / 1000) then

            if state.anitype == "in" then --fade in
                osc_visible(true)
                state.animation = scale_value(state.anistart,
                    (state.anistart + (user_opts.fadeduration / 1000)),
                    255, 0, now)
            elseif state.anitype == "out" then --fade out
                state.animation = scale_value(state.anistart,
                    (state.anistart + (user_opts.fadeduration / 1000)),
                    0, 255, now)
            end

        else
            if state.anitype == "out" then
                osc_visible(false)
            end
            kill_animation()
        end
    else
        kill_animation()
    end

    --mouse show/hide area
    for _, cords in pairs(osc_param.areas["showhide"]) do
        set_virt_mouse_area(cords.x1, cords.y1, cords.x2, cords.y2, "showhide")
    end
    if osc_param.areas["showhide_wc"] then
        for _, cords in pairs(osc_param.areas["showhide_wc"]) do
            set_virt_mouse_area(cords.x1, cords.y1, cords.x2, cords.y2, "showhide_wc")
        end
    else
        set_virt_mouse_area(0, 0, 0, 0, "showhide_wc")
    end
    do_enable_keybindings()

    --mouse input area
    local mouse_over_osc = false

    for _,cords in ipairs(osc_param.areas["input"]) do
        if state.osc_visible then -- activate only when OSC is actually visible
            set_virt_mouse_area(cords.x1, cords.y1, cords.x2, cords.y2, "input")
        end
        if state.osc_visible ~= state.input_enabled then
            if state.osc_visible then
                mp.enable_key_bindings("input")
            else
                mp.disable_key_bindings("input")
            end
            state.input_enabled = state.osc_visible
        end

        if mouse_hit_coords(cords.x1, cords.y1, cords.x2, cords.y2) then
            mouse_over_osc = true
        end
    end

    if osc_param.areas["window-controls"] then
        for _,cords in ipairs(osc_param.areas["window-controls"]) do
            if state.osc_visible then -- activate only when OSC is actually visible
                set_virt_mouse_area(cords.x1, cords.y1, cords.x2, cords.y2, "window-controls")
            end
            if state.osc_visible ~= state.windowcontrols_buttons then
                if state.osc_visible then
                    mp.enable_key_bindings("window-controls")
                else
                    mp.disable_key_bindings("window-controls")
                end
                state.windowcontrols_buttons = state.osc_visible
            end

            if mouse_hit_coords(cords.x1, cords.y1, cords.x2, cords.y2) then
                mouse_over_osc = true
            end
        end
    end

    if osc_param.areas["window-controls-title"] then
        for _,cords in ipairs(osc_param.areas["window-controls-title"]) do
            if state.osc_visible then -- activate only when OSC is actually visible
                set_virt_mouse_area(cords.x1, cords.y1, cords.x2, cords.y2, "window-controls-title")
            end
            if state.osc_visible ~= state.windowcontrols_title then
                if state.osc_visible then
                    mp.enable_key_bindings("window-controls-title", "allow-vo-dragging")
                else
                    mp.disable_key_bindings("window-controls-title", "allow-vo-dragging")
                end
                state.windowcontrols_title = state.osc_visible
            end

            if mouse_hit_coords(cords.x1, cords.y1, cords.x2, cords.y2) then
                mouse_over_osc = true
            end
        end
    end

    -- autohide
    if state.showtime ~= nil and get_hidetimeout() >= 0 then
        local timeout = state.showtime + (get_hidetimeout() / 1000) - now
        if timeout <= 0 and get_touchtimeout() <= 0 then
            if state.active_element == nil and not mouse_over_osc then
                hide_osc()
            end
        else
            -- the timer is only used to recheck the state and to possibly run
            -- the code above again
            if not state.hide_timer then
                state.hide_timer = mp.add_timeout(0, tick)
            end
            state.hide_timer.timeout = timeout
            -- re-arm
            state.hide_timer:kill()
            state.hide_timer:resume()
        end
    end


    -- actual rendering
    local ass = assdraw.ass_new()

    -- actual OSC
    if state.osc_visible then
        render_elements(ass)
    end

    -- submit
    set_osd(osc_param.playresy * osc_param.display_aspect,
            osc_param.playresy, ass.text, 1000)
end

-- called by mpv on every frame
tick = function()
    if state.marginsREQ == true then
        update_margins()
        state.marginsREQ = false
    end

    if not state.enabled then return end

    if state.idle then

        -- render idle message
        msg.trace("idle message")
        local _, _, display_aspect = mp.get_osd_size()
        if display_aspect == 0 then
            return
        end
        local display_h = 360
        local display_w = display_h * display_aspect
        local ass = assdraw.ass_new()
        set_osd(display_w, display_h, ass.text, -1000)

        if state.showhide_enabled then
            mp.disable_key_bindings("showhide")
            mp.disable_key_bindings("showhide_wc")
            state.showhide_enabled = false
        end


    elseif state.fullscreen and user_opts.showfullscreen
        or (not state.fullscreen and user_opts.showwindowed) then

        -- render the OSC
        render()
    else
        -- Flush OSD
        render_wipe()
    end

    state.tick_last_time = mp.get_time()

    if state.anitype ~= nil then
        -- state.anistart can be nil - animation should now start, or it can
        -- be a timestamp when it started. state.idle has no animation.
        if not state.idle and
           (not state.anistart or
            mp.get_time() < 1 + state.anistart + user_opts.fadeduration/1000)
        then
            -- animating or starting, or still within 1s past the deadline
            request_tick()
        else
            kill_animation()
        end
    end
end

local function shutdown()
    reset_margins()
    mp.del_property("user-data/osc")
end

-- duration is observed for the sole purpose of updating chapter markers
-- positions. live streams with chapters are very rare, and the update is also
-- expensive (with request_init), so it's only observed when we have chapters
-- and the user didn't disable the livemarkers option (update_duration_watch).
local function on_duration() request_init() end

local duration_watched = false
local function update_duration_watch()
    local want_watch = user_opts.livemarkers and
                       (mp.get_property_number("chapters", 0) or 0) > 0 and
                       true or false  -- ensure it's a boolean

    if want_watch ~= duration_watched then
        if want_watch then
            mp.observe_property("duration", "native", on_duration)
        else
            mp.unobserve_property(on_duration)
        end
        duration_watched = want_watch
    end
end

local function set_tick_delay(_, display_fps)
    -- may be nil if unavailable or 0 fps is reported
    if not display_fps or not user_opts.tick_delay_follow_display_fps then
        tick_delay = user_opts.tick_delay
        return
    end
    tick_delay = 1 / display_fps
end

mp.register_event("shutdown", shutdown)
mp.register_event("start-file", request_init)
mp.observe_property("track-list", "native", request_init)
mp.observe_property("playlist-count", "native", request_init)
mp.observe_property("playlist-pos", "native", request_init)
mp.observe_property("chapter-list", "native", function(_, list)
    list = list or {}  -- safety, shouldn't return nil
    table.sort(list, function(a, b) return a.time < b.time end)
    state.chapter_list = list
    update_duration_watch()
    request_init()
end)

-- These are for backwards compatibility only.
mp.register_script_message("osc-message", function(message, dur)
    if not state.osc_message_warned then
        mp.msg.warn("osc-message is deprecated and may be removed in the future.",
                    "Use the show-text command instead.")
        state.osc_message_warned = true
    end
    mp.osd_message(message, dur)
end)
mp.register_script_message("osc-chapterlist", function(dur)
    if not state.osc_chapterlist_warned then
        mp.msg.warn("osc-chapterlist is deprecated and may be removed in the future.",
                    "Use show-text ${chapter-list} instead.")
        state.osc_chapterlist_warned = true
    end
    mp.command("show-text ${chapter-list} " .. (dur and dur * 1000 or ""))
end)
mp.register_script_message("osc-playlist", function(dur)
    if not state.osc_playlist_warned then
        mp.msg.warn("osc-playlist is deprecated and may be removed in the future.",
                    "Use show-text ${playlist} instead.")
        state.osc_playlist_warned = true
    end
    mp.command("show-text ${playlist} " .. (dur and dur * 1000 or ""))
end)
mp.register_script_message("osc-tracklist", function(dur)
    if not state.osc_tracklist_warned then
        mp.msg.warn("osc-tracklist is deprecated and may be removed in the future.",
                    "Use show-text ${track-list} instead.")
        state.osc_tracklist_warned = true
    end
    mp.command("show-text ${track-list} " .. (dur and dur * 1000 or ""))
end)

mp.observe_property("fullscreen", "bool", function(_, val)
    state.fullscreen = val
    state.marginsREQ = true
    request_init_resize()
end)
mp.observe_property("border", "bool", function(_, val)
    state.border = val
    request_init_resize()
end)
mp.observe_property("title-bar", "bool", function(_, val)
    state.title_bar = val
    request_init_resize()
end)
mp.observe_property("window-maximized", "bool", function(_, val)
    state.maximized = val
    request_init_resize()
end)
mp.observe_property("idle-active", "bool", function(_, val)
    state.idle = val
    request_tick()
end)

mp.observe_property("display-fps", "number", set_tick_delay)
mp.observe_property("pause", "bool", pause_state)
mp.observe_property("demuxer-cache-state", "native", cache_state)
mp.observe_property("vo-configured", "bool", request_tick)
mp.observe_property("playback-time", "number", request_tick)
mp.observe_property("osd-dimensions", "native", function()
    -- (we could use the value instead of re-querying it all the time, but then
    --  we might have to worry about property update ordering)
    request_init_resize()
end)
mp.observe_property('osd-scale-by-window', 'native', request_init_resize)
mp.observe_property('touch-pos', 'native', handle_touch)

-- mouse show/hide bindings
mp.set_key_bindings({
    {"mouse_move",              function() process_event("mouse_move", nil) end},
    {"mouse_leave",             mouse_leave},
}, "showhide", "force")
mp.set_key_bindings({
    {"mouse_move",              function() process_event("mouse_move", nil) end},
    {"mouse_leave",             mouse_leave},
}, "showhide_wc", "force")
do_enable_keybindings()

--mouse input bindings
mp.set_key_bindings({
    {"mbtn_left",           function() process_event("mbtn_left", "up") end,
                            function() process_event("mbtn_left", "down")  end},
    {"mbtn_mid",            function() process_event("mbtn_mid", "up") end,
                            function() process_event("mbtn_mid", "down")  end},
    {"mbtn_right",          function() process_event("mbtn_right", "up") end,
                            function() process_event("mbtn_right", "down")  end},
    -- alias shift+mbtn_left to mbtn_mid for touchpads
    {"shift+mbtn_left",     function() process_event("mbtn_mid", "up") end,
                            function() process_event("mbtn_mid", "down")  end},
    {"wheel_up",            function() process_event("wheel_up", "press") end},
    {"wheel_down",          function() process_event("wheel_down", "press") end},
    {"mbtn_left_dbl",       "ignore"},
    {"shift+mbtn_left_dbl", "ignore"},
    {"mbtn_right_dbl",      "ignore"},
}, "input", "force")
mp.enable_key_bindings("input")

mp.set_key_bindings({
    {"mbtn_left",           function() process_event("mbtn_left", "up") end,
                            function() process_event("mbtn_left", "down")  end},
}, "window-controls", "force")
mp.enable_key_bindings("window-controls")

local function always_on(val)
    if state.enabled then
        if val then
            show_osc()
        else
            hide_osc()
        end
    end
end

-- mode can be auto/always/never/cycle
-- the modes only affect internal variables and not stored on its own.
local function visibility_mode(mode, no_osd)
    if mode == "cycle" then
        for i, allowed_mode in ipairs(state.visibility_modes) do
            if i == #state.visibility_modes then
                mode = state.visibility_modes[1]
                break
            elseif user_opts.visibility == allowed_mode then
                mode = state.visibility_modes[i + 1]
                break
            end
        end
    end

    if mode == "auto" then
        always_on(false)
        enable_osc(true)
    elseif mode == "always" then
        enable_osc(true)
        always_on(true)
    elseif mode == "never" then
        enable_osc(false)
    else
        msg.warn("Ignoring unknown visibility mode '" .. mode .. "'")
        return
    end

    user_opts.visibility = mode
    mp.set_property_native("user-data/osc/visibility", mode)

    if not no_osd and tonumber(mp.get_property("osd-level")) >= 1 then
        mp.osd_message("OSC visibility: " .. mode)
    end

    -- Reset the input state on a mode change. The input state will be
    -- recalculated on the next render cycle, except in 'never' mode where it
    -- will just stay disabled.
    mp.disable_key_bindings("input")
    mp.disable_key_bindings("window-controls")
    state.input_enabled = false

    update_margins()
    request_tick()
end

mp.register_script_message("osc-visibility", visibility_mode)
mp.register_script_message("osc-show", show_osc)
mp.register_script_message("osc-hide", function ()
    if user_opts.visibility == "auto" then
        osc_visible(false)
    end
end)
mp.add_key_binding(nil, "visibility", function() visibility_mode("cycle") end)

-- Validate user options
local function validate_user_opts()
    local colors = {
        user_opts.background_color, user_opts.top_buttons_color,
        user_opts.timecode_color, user_opts.time_pos_color,
        user_opts.held_element_color, user_opts.time_pos_outline_color,
    }
    for _, color in pairs(colors) do
        if color:find("^#%x%x%x%x%x%x$") == nil then
            msg.warn("'" .. color .. "' is not a valid color")
        end
    end

    for str in string.gmatch(user_opts.visibility_modes, "([^_]+)") do
        if str ~= "auto" and str ~= "always" and str ~= "never" then
            msg.warn("Ignoring unknown visibility mode '" .. str .."' in list")
        else
            table.insert(state.visibility_modes, str)
        end
    end
end

-- read options from config and command-line
opt.read_options(user_opts, "osc-simplified", function(changed)
    validate_user_opts()
    set_osc_styles()
    set_time_styles(changed.timetotal, changed.timems)
    if changed.tick_delay or changed.tick_delay_follow_display_fps then
        set_tick_delay("display_fps", mp.get_property_number("display_fps"))
    end
    request_tick()
    visibility_mode(user_opts.visibility, true)
    update_duration_watch()
    request_init()
end)

validate_user_opts()
set_osc_styles()
set_time_styles(true, true)
set_tick_delay("display_fps", mp.get_property_number("display_fps"))
visibility_mode(user_opts.visibility, true)
update_duration_watch()

set_virt_mouse_area(0, 0, 0, 0, "input")
set_virt_mouse_area(0, 0, 0, 0, "window-controls")
set_virt_mouse_area(0, 0, 0, 0, "window-controls-title")
