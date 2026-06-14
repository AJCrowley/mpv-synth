local assdraw = require 'mp.assdraw'
local msg = require 'mp.msg'
local opt = require 'mp.options'

-- Parameters from osc.conf [1]
local user_opts = {
    showwindowed = true,
    showfullscreen = true,
    scalewindowed = 1.15,
    scalefullscreen = 1.00,
    valign = 0.8,
    halign = 0,
    boxalpha = 80,
    hidetimeout = 1800,
    fadeduration = 300,
}

-- State variables
local state = {
    visible = false,
    fullscreen = false,
    anitype = nil,
}

local hide_timer = nil
local osc_margin = {l = 0, r = 0, t = 0, b = 0}

-- Helper: Format time
local function format_time(seconds)
    if not seconds or seconds < 0 then
        return "--:--"
    end
    local h = math.floor(seconds / 3600)
    local m = math.floor(seconds / 60) % 60
    local s = math.floor(seconds % 60)
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    else
        return string.format("%02d:%02d", m, s)
    end
end

-- Draw volume icon
local function draw_volume_icon(ass, x, y, color)
    ass:new_event()
    ass:pos(x, y)
    ass:an(7)
    ass:append('{\\c&H' .. color .. '&}')
    ass:draw_start()
    -- Speaker body
    ass:move_to(0, 8)
    ass:line_to(8, 8)
    ass:line_to(12, 4)
    ass:line_to(12, 20)
    ass:line_to(8, 20)
    ass:line_to(0, 20)
    ass:close()
    -- Sound waves
    ass:move_to(16, 10)
    ass:line_to(20, 10)
    ass:move_to(16, 14)
    ass:line_to(22, 14)
    ass:move_to(16, 18)
    ass:line_to(20, 18)
    ass:draw_stop()
end

-- Draw prev button (with solid bar on left)
local function draw_prev_button(ass, x, y, color)
    ass:new_event()
    ass:pos(x, y)
    ass:an(7)
    ass:append('{\\c&H' .. color .. '&}')
    ass:draw_start()
    -- Solid bar on left
    ass:rect_cw(0, 4, 3, 20)
    -- Double arrow pointing right
    ass:move_to(6, 2)
    ass:line_to(18, 12)
    ass:line_to(6, 22)
    ass:line_to(6, 16)
    ass:line_to(14, 12)
    ass:line_to(6, 8)
    ass:close()
    ass:draw_stop()
end

-- Draw rewind button
local function draw_rewind_button(ass, x, y, color)
    ass:new_event()
    ass:pos(x, y)
    ass:an(7)
    ass:append('{\\c&H' .. color .. '&}')
    ass:draw_start()
    -- Double arrow pointing left
    ass:move_to(18, 2)
    ass:line_to(6, 12)
    ass:line_to(18, 22)
    ass:line_to(18, 16)
    ass:line_to(10, 12)
    ass:line_to(18, 8)
    ass:close()
    ass:move_to(10, 2)
    ass:line_to(-2, 12)
    ass:line_to(10, 22)
    ass:line_to(10, 16)
    ass:line_to(2, 12)
    ass:line_to(10, 8)
    ass:close()
    ass:draw_stop()
end

-- Draw play/pause button
local function draw_playpause_button(ass, x, y, color, is_paused)
    ass:new_event()
    ass:pos(x, y)
    ass:an(7)
    ass:append('{\\c&H' .. color .. '&}')
    ass:draw_start()
    if is_paused then
        -- Play triangle
        ass:move_to(4, 2)
        ass:line_to(20, 12)
        ass:line_to(4, 22)
        ass:close()
    else
        -- Pause bars
        ass:rect_cw(4, 2, 10, 22)
        ass:rect_cw(14, 2, 20, 22)
    end
    ass:draw_stop()
end

-- Draw fast forward button
local function draw_ff_button(ass, x, y, color)
    ass:new_event()
    ass:pos(x, y)
    ass:an(7)
    ass:append('{\\c&H' .. color .. '&}')
    ass:draw_start()
    -- Double arrow pointing right
    ass:move_to(6, 2)
    ass:line_to(18, 12)
    ass:line_to(6, 22)
    ass:line_to(6, 16)
    ass:line_to(14, 12)
    ass:line_to(6, 8)
    ass:close()
    ass:move_to(14, 2)
    ass:line_to(26, 12)
    ass:line_to(14, 22)
    ass:line_to(14, 16)
    ass:line_to(22, 12)
    ass:line_to(14, 8)
    ass:close()
    ass:draw_stop()
end

-- Draw next button (with solid bar on right)
local function draw_next_button(ass, x, y, color)
    ass:new_event()
    ass:pos(x, y)
    ass:an(7)
    ass:append('{\\c&H' .. color .. '&}')
    ass:draw_start()
    -- Double arrow pointing left
    ass:move_to(18, 2)
    ass:line_to(6, 12)
    ass:line_to(18, 22)
    ass:line_to(18, 16)
    ass:line_to(10, 12)
    ass:line_to(18, 8)
    ass:close()
    -- Solid bar on right
    ass:rect_cw(21, 4, 24, 20)
    ass:draw_stop()
end

-- Draw subtitle button (speech bubble)
local function draw_subtitle_button(ass, x, y, color)
    ass:new_event()
    ass:pos(x, y)
    ass:an(7)
    ass:append('{\\c&H' .. color .. '&}')
    ass:draw_start()
    -- Speech bubble
    ass:move_to(2, 6)
    ass:line_to(20, 6)
    ass:line_to(20, 16)
    ass:line_to(14, 16)
    ass:line_to(10, 22)
    ass:line_to(10, 16)
    ass:line_to(2, 16)
    ass:close()
    -- Lines inside
    ass:move_to(5, 10)
    ass:line_to(17, 10)
    ass:move_to(5, 13)
    ass:line_to(14, 13)
    ass:draw_stop()
end

-- Draw fullscreen button
local function draw_fullscreen_button(ass, x, y, color)
    ass:new_event()
    ass:pos(x, y)
    ass:an(7)
    ass:append('{\\c&H' .. color .. '&}')
    ass:draw_start()
    -- Rectangle
    ass:rect_cw(2, 4, 22, 20)
    -- Corner arrows
    ass:move_to(6, 8)
    ass:line_to(2, 8)
    ass:line_to(2, 4)
    ass:move_to(18, 8)
    ass:line_to(22, 8)
    ass:line_to(22, 4)
    ass:move_to(6, 16)
    ass:line_to(2, 16)
    ass:line_to(2, 20)
    ass:move_to(18, 16)
    ass:line_to(22, 16)
    ass:line_to(22, 20)
    ass:draw_stop()
end

-- Draw playlist button
local function draw_playlist_button(ass, x, y, color)
    ass:new_event()
    ass:pos(x, y)
    ass:an(7)
    ass:append('{\\c&H' .. color .. '&}')
    ass:draw_start()
    -- Rectangle
    ass:rect_cw(2, 4, 22, 20)
    -- Lines
    ass:move_to(5, 8)
    ass:line_to(19, 8)
    ass:move_to(5, 12)
    ass:line_to(19, 12)
    ass:move_to(5, 16)
    ass:line_to(14, 16)
    ass:draw_stop()
end

-- Draw menu button (gear)
local function draw_menu_button(ass, x, y, color)
    ass:new_event()
    ass:pos(x, y)
    ass:an(7)
    ass:append('{\\c&H' .. color .. '&}')
    ass:draw_start()
    -- Gear circle
    ass:move_to(12, 4)
    for i = 0, 7 do
        local angle = i * math.pi / 4
        local r = (i % 2 == 0) and 8 or 6
        local px = 12 + r * math.cos(angle)
        local py = 12 + r * math.sin(angle)
        if i == 0 then
            ass:move_to(px, py)
        else
            ass:line_to(px, py)
        end
    end
    ass:close()
    -- Center hole
    ass:move_to(12, 9)
    for i = 0, 16 do
        local angle = i * math.pi / 8
        local px = 12 + 3 * math.cos(angle)
        local py = 12 + 3 * math.sin(angle)
        if i == 0 then
            ass:move_to(px, py)
        else
            ass:line_to(px, py)
        end
    end
    ass:close()
    ass:draw_stop()
end

-- Draw volume slider
local function draw_volume_slider(ass, x, y, width, volume)
    local fill_width = width * (volume / 100)

    -- Background bar
    ass:new_event()
    ass:pos(x, y)
    ass:an(7)
    ass:append('{\\c&H444444&}')
    ass:draw_start()
    ass:rect_cw(0, 0, width, 4)
    ass:draw_stop()

    -- Filled portion
    ass:new_event()
    ass:pos(x, y)
    ass:an(7)
    ass:append('{\\c&H4A90E2&}')
    ass:draw_start()
    ass:rect_cw(0, 0, fill_width, 4)
    ass:draw_stop()

    -- Knob
    ass:new_event()
    ass:pos(x + fill_width, y + 2)
    ass:an(5)
    ass:append('{\\c&HFFFFFF&}')
    ass:draw_start()
    ass:rect_cw(-5, -5, 5, 5)
    ass:draw_stop()
end

-- Draw seekbar
local function draw_seekbar(ass, x, y, width, pos, dur)
    local progress = dur > 0 and (width * (pos / dur)) or 0

    -- Background bar
    ass:new_event()
    ass:pos(x, y)
    ass:an(7)
    ass:append('{\\c&H444444&}')
    ass:draw_start()
    ass:rect_cw(0, 0, width, 3)
    ass:draw_stop()

    -- Filled portion
    ass:new_event()
    ass:pos(x, y)
    ass:an(7)
    ass:append('{\\c&H4A90E2&}')
    ass:draw_start()
    ass:rect_cw(0, 0, progress, 3)
    ass:draw_stop()

    -- Progress indicator
    ass:new_event()
    ass:pos(x + progress, y + 1.5)
    ass:an(5)
    ass:append('{\\c&HFFFFFF&}')
    ass:draw_start()
    ass:rect_cw(-1.5, -6, 1.5, 6)
    ass:draw_stop()
end

-- Main render function
local function render_osc()
    local display_w, display_h = mp.get_osd_size()
    if display_w <= 0 then
        return
    end

    local scale = state.fullscreen and user_opts.scalefullscreen or user_opts.scalewindowed
    local box_w = 450 * scale
    local box_h = 70 * scale
    local box_x = (display_w - box_w) / 2
    local box_y = display_h - box_h - 20 * scale

    local ass = assdraw.ass_new()

    -- Background box
    ass:new_event()
    ass:pos(box_x, box_y)
    ass:an(7)
    ass:append('{\\rDefault\\c&HFFFFFF&\\3c&H000000&\\3a&H100&\\alpha&H' ..
        string.format('%02X', user_opts.boxalpha) .. '&\\bord0}')
    ass:draw_start()
    ass:rect_cw(0, 0, box_w, box_h)
    ass:draw_stop()

    local base_y = box_y + 15 * scale
    local vol_x = box_x + 15 * scale
    local control_center = box_x + box_w / 2
    local right_x = box_x + box_w - 90 * scale

    -- Volume icon and slider
    draw_volume_icon(ass, vol_x, base_y, "FFFFFF")
    draw_volume_slider(ass, vol_x + 30 * scale, base_y + 8 * scale, 80 * scale,
        mp.get_property_number('volume', 100))

    -- Playback controls
    local btn_spacing = 35 * scale
    local btn_y = base_y + 2 * scale
    local btn_color = "AAAAAA"
    local btn_color_active = "FFFFFF"

    local paused = mp.get_property_bool('pause', false)

    draw_prev_button(ass, control_center - 90 * scale, btn_y, btn_color)
    draw_rewind_button(ass, control_center - 50 * scale, btn_y, btn_color)
    draw_playpause_button(ass, control_center - 5 * scale, btn_y, btn_color_active, paused)
    draw_ff_button(ass, control_center + 40 * scale, btn_y, btn_color)
    draw_next_button(ass, control_center + 80 * scale, btn_y, btn_color)

    -- Right side buttons
    draw_subtitle_button(ass, right_x, btn_y, btn_color)
    draw_fullscreen_button(ass, right_x + 30 * scale, btn_y, btn_color)
    draw_playlist_button(ass, right_x + 60 * scale, btn_y, btn_color)
    draw_menu_button(ass, right_x + 90 * scale, btn_y, btn_color)

    -- Time display and seekbar
    local pos = mp.get_property_number('time-pos', 0) or 0
    local dur = mp.get_property_number('duration', 0) or 0
    local time_y = base_y + 35 * scale

    ass:new_event()
    ass:pos(box_x + 15 * scale, time_y)
    ass:an(7)
    ass:append('{\\rDefault\\fs' .. math.floor(14 * scale) .. '\\c&HAAAAAA&}' .. format_time(pos))

    ass:new_event()
    ass:pos(box_x + box_w - 15 * scale, time_y)
    ass:an(9)
    ass:append('{\\rDefault\\fs' .. math.floor(14 * scale) .. '\\c&HAAAAAA&}' .. format_time(dur))

    draw_seekbar(ass, box_x + 60 * scale, time_y + 5 * scale, box_w - 135 * scale, pos, dur)

    return ass.text
end

-- Set OSD
local function set_osd(w, h, text, z)
    mp.set_osd_ass(w, h, text)
end

-- Render wipe
local function render_wipe()
    mp.set_osd_ass(0, 0, '')
end

-- Toggle visibility
local function toggle_osc()
    state.visible = not state.visible
    if state.visible then
        local display_w, display_h = mp.get_osd_size()
        set_osd(display_w, display_h, render_osc(), -1000)
        if hide_timer then
            hide_timer:kill()
            hide_timer:resume()
        end
    else
        render_wipe()
        if hide_timer then
            hide_timer:kill()
        end
    end
end

-- Hide OSC
local function hide_osc()
    state.visible = false
    render_wipe()
end

-- Show OSC
local function show_osc()
    state.visible = true
    local display_w, display_h = mp.get_osd_size()
    set_osd(display_w, display_h, render_osc(), -1000)
    if hide_timer then
        hide_timer:kill()
        hide_timer:resume()
    end
end

-- Button click handlers
mp.add_key_binding('MBTN_LEFT', 'volume_click', function()
    mp.commandv('cycle', 'mute')
end)

mp.add_key_binding('MBTN_LEFT', 'prev_track', function()
    mp.commandv('playlist-prev')
end)

mp.add_key_binding('MBTN_LEFT', 'next_track', function()
    mp.commandv('playlist-next')
end)

mp.add_key_binding('MBTN_LEFT', 'toggle_subtitles', function()
    mp.commandv('cycle', 'sub-visibility')
end)

mp.add_key_binding('MBTN_LEFT', 'toggle_fullscreen', function()
    mp.commandv('cycle', 'fullscreen')
end)

mp.add_key_binding('MBTN_LEFT', 'show_playlist', function()
    mp.command('script-binding playlist/show')
end)

mp.add_key_binding('MBTN_LEFT', 'show_menu', function()
    mp.commandv('script-message-to', 'menu_native', 'show')
end)

-- Initialize hide timer
hide_timer = mp.add_timer(user_opts.hidetimeout / 1000, hide_osc)

-- Event handlers
mp.register_event('file-loaded', function()
    show_osc()
end)

mp.observe_property('pause', 'bool', function()
    if state.visible then
        local display_w, display_h = mp.get_osd_size()
        set_osd(display_w, display_h, render_osc(), -1000)
    end
end)

mp.observe_property('time-pos', 'number', function()
    if state.visible then
        local display_w, display_h = mp.get_osd_size()
        set_osd(display_w, display_h, render_osc(), -1000)
    end
end)

mp.observe_property('volume', 'number', function()
    if state.visible then
        local display_w, display_h = mp.get_osd_size()
        set_osd(display_w, display_h, render_osc(), -1000)
    end
end)

mp.observe_property('fullscreen', 'bool', function(_, val)
    state.fullscreen = val or false
    if state.visible then
        local display_w, display_h = mp.get_osd_size()
        set_osd(display_w, display_h, render_osc(), -1000)
    end
end)

-- Mouse movement
mp.register_event('mouse-move', function()
    if not state.visible then
        show_osc()
    else
        if hide_timer then
            hide_timer:kill()
            hide_timer:resume()
        end
    end
end)

-- Mouse leave
mp.register_event('mouse-leave', function()
    if hide_timer then
        hide_timer:kill()
        hide_timer:resume()
    end
end)

-- OSC toggle key
mp.add_key_binding('i', 'toggle_osc', toggle_osc)

msg.info('Custom OSC loaded successfully')