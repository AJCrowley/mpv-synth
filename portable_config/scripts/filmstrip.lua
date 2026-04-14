-- filmstrip.lua
--
-- TouchBar-style filmstrip thumbnail overlay for the mpv seekbar.
-- Sits underneath the uosc Timeline element, filling it with evenly-spaced
-- thumbnail slices, showing and hiding in sync with the uosc Timeline —
-- including a combined slide-from-bottom animation.
--
-- ── ANIMATION ──────────────────────────────────────────────────────────────
--   slide_progress (0→1):  controls Y position
--     0 = overlay at off_screen_y (below the visible OSD edge)
--     1 = overlay at bar_y (its final resting position)
--     Duration: animation_duration (default 100ms)
--
-- ── LOAD BEHAVIOUR ─────────────────────────────────────────────────────────
--   The filmstrip stays hidden until every thumbnail has been generated.
--   The animation triggers automatically once the last tile is ready AND
--   the cursor is in the proximity zone.
--
-- ── LAYERING ───────────────────────────────────────────────────────────────
--   overlay-add renders ABOVE the video but BELOW the OSD/ASS layer.
--   uosc draws in the OSD layer, so seekbar, timecode and controls are
--   always fully visible above the filmstrip.
--
-- ── CONFIG FILE ────────────────────────────────────────────────────────────
--   script-opts/filmstrip.conf
--
-- ── PROCESS PRIORITY ───────────────────────────────────────────────────────
--   process_priority_map defines height → priority thresholds.
--   Format: comma-separated "height=priority" pairs.
--   The highest threshold that is <= the video height wins.
--   Valid priority values: idle, low, normal, high
--   Example: "720=high,1080=normal,1440=normal,2160=low"
--
-- ── SCRIPT MESSAGES ────────────────────────────────────────────────────────
--   script-message filmstrip-show       force-show
--   script-message filmstrip-hide       force-hide
--   script-message filmstrip-rebuild    full regeneration + re-read conf
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- Options
-- ─────────────────────────────────────────────────────────────────────────────

local options = {
    -- easy kill switch to disable script from config file
    enabled      = true,
    -- ── Thumbnail count ────────────────────────────────────────────────────
    thumbnail_count = 125,

    -- ── Thumbnail height ───────────────────────────────────────────────────
    --   Controls how tall the filmstrip is, as a percentage of the uosc
    --   timeline height.
    thumbnail_height_percent = 80,

    -- ── Slice alignment ────────────────────────────────────────────────────
    slice_align = "centre",

    -- ── Resize behaviour ───────────────────────────────────────────────────
    --   remap      → FAST. Cached thumbnails re-composited.
    --   regenerate → ACCURATE. Full rebuild at new geometry.
    resize_behavior = "remap",

    -- ── Slide animation ────────────────────────────────────────────────────
    -- Duration of the Y-position slide in milliseconds. 0 = no animation.
    animation_duration = 100,

    -- Frames per second for animation.
    animation_fps = 30,

    -- ── Timeout before starting hide animation──────────────────────────────
    idle_timeout = 0,

    -- ── uosc Timeline auto-detection ───────────────────────────────────────
    uosc_timeline_size_max = 78,
    uosc_scale             = 1,
    uosc_scale_fullscreen  = 1,

    -- ── Manual position ────────────────────────────────────────────────────
    --   When manual_position=yes you can override individual values below.
    --   bar_height: absolute pixel height (0 = use thumbnail_height_percent
    --               of the auto-detected timeline height instead).
    --   bar_y:      -1 = auto-pin to bottom of screen.
    manual_position = false,
    bar_x      = 0,
    bar_y      = -1,   -- -1 = auto pin to bottom
    bar_width  = 0,
    bar_height = 0,    -- 0 = derive from thumbnail_height_percent (recommended)

    -- ── Generation ─────────────────────────────────────────────────────────
    --   max_concurrent: number of simultaneous ffmpeg processes for generation
    --  hwdec: "auto" (default) enables hardware decoding for thumbnail generation
    max_concurrent = 4,
    hwdec          = "auto",

    -- ── Process priority by video height ───────────────────────────────────
    -- Valid priorities: idle, low, normal, high
    process_priority_map     = "720=normal,1080=low,1440=idle,2160=idle",
    process_priority_default = "normal",

    -- ── Misc ───────────────────────────────────────────────────────────────
    -- overlay_id must be 0-63.
    overlay_id = 10,
    mpv_path   = "mpv",
    temp_dir   = "",
}

mp.utils   = require "mp.utils"
mp.options = require "mp.options"
mp.options.read_options(options, "filmstrip")
-- disable script if disabled or if thumbnail_count is invalid
if not options.enabled or options.thumbnail_count < 1 then return end

-- ─────────────────────────────────────────────────────────────────────────────
-- Platform
-- ─────────────────────────────────────────────────────────────────────────────

local function detect_os()
    local p = mp.get_property("platform")
    if p then return p end
    if package.config:sub(1, 1) == "\\" then return "windows" end
    local r = mp.command_native({
        name = "subprocess", playback_only = false, capture_stdout = true,
        args = {"uname", "-s"},
    })
    local s = (r and r.stdout or ""):lower()
    if s:find("darwin") then return "darwin" end
    return "linux"
end

local os_name = detect_os()
local sep     = (os_name == "windows") and "\\" or "/"
local pid     = mp.utils.getpid()

if options.temp_dir == "" then
    options.temp_dir = (os_name == "windows")
        and (os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp")
        or "/tmp"
end

local function tmpfile(label)
    return options.temp_dir .. sep .. "filmstrip_" .. pid .. "_" .. tostring(label)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Process priority
-- ─────────────────────────────────────────────────────────────────────────────

local CPU_VALUES = { high = -10, normal = 0, low = 10, idle = 19 }

-- Resolved once at build() time and reused for every subprocess in that session.
local current_cpu = 0

local function resolve_priority()
    local vp     = mp.get_property_native("video-out-params")
    local height = (vp and (vp.dh or vp.h)) or 0

    -- Parse "h=priority,..." into a sorted-descending list.
    local thresholds = {}
    for entry in options.process_priority_map:gmatch("[^,]+") do
        local h, p = entry:match("^%s*(%d+)%s*=%s*(%a+)%s*$")
        if h then
            thresholds[#thresholds + 1] = { tonumber(h), p:lower() }
        end
    end
    table.sort(thresholds, function(a, b) return a[1] > b[1] end)

    local label = options.process_priority_default:lower()
    for _, tp in ipairs(thresholds) do
        if height >= tp[1] then label = tp[2]; break end
    end

    current_cpu = CPU_VALUES[label] or 0
    mp.msg.info(string.format(
        "filmstrip: video height %dpx → priority '%s' (cpu %d)",
        height, label, current_cpu))
end

-- Prepend nice(1) on Linux/macOS; no-op on Windows.
local function priority_wrap(args)
    if os_name == "windows" or current_cpu == 0 then return args end
    local wrapped = { "nice", "-n", tostring(current_cpu) }
    for _, v in ipairs(args) do wrapped[#wrapped + 1] = v end
    return wrapped
end

-- ─────────────────────────────────────────────────────────────────────────────
-- uosc.conf reader
-- ─────────────────────────────────────────────────────────────────────────────

local uosc_conf_cache = nil

local function read_uosc_conf()
    if uosc_conf_cache then return uosc_conf_cache end
    uosc_conf_cache = {}
    local path = mp.command_native({ "expand-path", "~~/script-opts/uosc.conf" })
    if not path then return uosc_conf_cache end
    local f = io.open(path, "r")
    if not f then
        mp.msg.info("filmstrip: uosc.conf not found — using fallback defaults")
        return uosc_conf_cache
    end
    for line in f:lines() do
        local stripped = line:match("^([^#]*)") or ""
        local k, v    = stripped:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and v and v ~= "" then uosc_conf_cache[k] = v end
    end
    f:close()
    return uosc_conf_cache
end

local function uosc_timeline_height()
    local conf = read_uosc_conf()
    local fs   = mp.get_property_bool("fullscreen") or false
    local size = tonumber(conf.timeline_size_max) or options.uosc_timeline_size_max
    local scale
    if fs then
        scale = tonumber(conf.scale_fullscreen) or tonumber(conf.scale) or options.uosc_scale_fullscreen
    else
        scale = tonumber(conf.scale) or options.uosc_scale
    end
    local h = math.max(1, math.floor(size * scale + 0.5))
    mp.msg.info(string.format(
        "filmstrip: timeline height = %dpx  (size_max=%g × scale=%g, fs=%s)",
        h, size, scale, tostring(fs)))
    return h
end

local function uosc_persistency_flags()
    local conf  = read_uosc_conf()
    local raw   = conf.timeline_persistency or ""
    local flags = {}
    for token in raw:gmatch("[^,]+") do
        flags[token:match("^%s*(.-)%s*$")] = true
    end
    return flags
end

-- ─────────────────────────────────────────────────────────────────────────────
-- State
-- ─────────────────────────────────────────────────────────────────────────────

local thumbs       = {}
local active_procs = 0
local current_path = nil
local all_ready    = false

local bar_x, bar_y, bar_w, bar_h
local canvas_w, canvas_h
local composite_path = nil
local composite_shown = false

-- Animation
local anim_state     = "hidden"   -- "hidden" | "showing" | "shown" | "hiding"
local anim_timer     = nil
local slide_progress = 0.0
local last_anim_y    = nil

local idle_timer  = nil
local force_state = nil

local last_osd_w, last_osd_h
local resize_timer  = nil
local build_pending = false

-- ─────────────────────────────────────────────────────────────────────────────
-- Easing (cubic ease-in-out)
-- ─────────────────────────────────────────────────────────────────────────────

local function ease(t)
    t = math.max(0, math.min(1, t))
    return t < 0.5 and 4*t*t*t or 1 - (-2*t + 2)^3 / 2
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Overlay management
-- ─────────────────────────────────────────────────────────────────────────────

local function push_composite_at_y(y)
    if not composite_path then return end
    local info = mp.utils.file_info(composite_path)
    if not info or info.size ~= canvas_w * canvas_h * 4 then return end

    local iy = math.floor(y + 0.5)
    if iy == last_anim_y and anim_state == "shown" then return end
    last_anim_y = iy

    mp.command_native_async({
        "overlay-add", options.overlay_id,
        bar_x, iy,
        composite_path, 0, "bgra",
        canvas_w, canvas_h, canvas_w * 4,
    }, function() end)
    composite_shown = true
end

local function remove_composite()
    if not composite_shown then return end
    mp.command_native_async({ "overlay-remove", options.overlay_id }, function() end)
    composite_shown = false
    last_anim_y     = nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Animation engine
-- ─────────────────────────────────────────────────────────────────────────────

local function off_screen_y()
    return (last_osd_h and last_osd_h > 0) and last_osd_h or (bar_y + canvas_h + 10)
end

local function kill_anim_timer()
    if anim_timer then anim_timer:kill(); anim_timer = nil end
end

local function apply_anim_state()
    local offy = off_screen_y()
    local y    = offy + (bar_y - offy) * ease(slide_progress)
    push_composite_at_y(y)
end

local function start_show_anim()
    if anim_state == "shown" then return end
    kill_anim_timer()
    if anim_state ~= "hiding" then slide_progress = 0.0 end
    anim_state = "showing"

    local frame_dt   = 1.0 / options.animation_fps
    local slide_step = options.animation_duration > 0
                       and frame_dt / (options.animation_duration / 1000.0) or 2.0

    if slide_step >= 2.0 then
        slide_progress = 1.0
        anim_state     = "shown"
        push_composite_at_y(bar_y)
        return
    end

    anim_timer = mp.add_periodic_timer(frame_dt, function()
        slide_progress = math.min(1.0, slide_progress + slide_step)
        apply_anim_state()
        if slide_progress >= 1.0 then
            kill_anim_timer()
            anim_state = "shown"
        end
    end)
end

local function start_hide_anim()
    if anim_state == "hidden" then return end
    kill_anim_timer()
    if anim_state ~= "showing" then slide_progress = 1.0 end
    anim_state = "hiding"

    local frame_dt   = 1.0 / options.animation_fps
    local slide_step = options.animation_duration > 0
                       and frame_dt / (options.animation_duration / 1000.0) or 2.0

    if slide_step >= 2.0 then
        remove_composite()
        anim_state = "hidden"; slide_progress = 0.0
        return
    end

    anim_timer = mp.add_periodic_timer(frame_dt, function()
        slide_progress = math.max(0.0, slide_progress - slide_step)
        apply_anim_state()
        if slide_progress <= 0.0 then
            kill_anim_timer()
            remove_composite()
            anim_state = "hidden"; slide_progress = 0.0
        end
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Geometry
-- ─────────────────────────────────────────────────────────────────────────────

-- Apply thumbnail_height_percent to a raw timeline height, clamped to [1, tl_h].
local function apply_height_percent(tl_h)
    local pct = math.max(1, math.min(100, options.thumbnail_height_percent))
    return math.max(1, math.floor(tl_h * pct / 100 + 0.5))
end

local function resolve_geometry()
    local osd   = mp.get_property_native("osd-dimensions")
    local osd_w = (osd and osd.w) or mp.get_property_number("osd-width")  or 0
    local osd_h = (osd and osd.h) or mp.get_property_number("osd-height") or 0

    if osd_w <= 0 or osd_h <= 0 then return false, "OSD dimensions unavailable" end

    last_osd_h = osd_h; last_osd_w = osd_w

    local tl_h = uosc_timeline_height()

    if options.manual_position then
        bar_x = options.bar_x
        bar_w = options.bar_width > 0 and options.bar_width or osd_w

        -- bar_height > 0: use it as an absolute pixel override.
        -- bar_height = 0 (default/recommended): derive from thumbnail_height_percent.
        if options.bar_height > 0 then
            bar_h = options.bar_height
        else
            bar_h = apply_height_percent(tl_h)
        end

        -- bar_y >= 0: explicit Y.  bar_y = -1: pin filmstrip to screen bottom.
        bar_y = options.bar_y >= 0 and options.bar_y or (osd_h - bar_h)
    else
        bar_x = 0
        bar_w = osd_w
        bar_h = apply_height_percent(tl_h)
        bar_y = osd_h - bar_h
    end

    if bar_w < 2 then return false, "bar_width < 2" end
    if bar_h < 1 then return false, "bar_height < 1" end
    if bar_y < 0 then bar_y = 0 end

    mp.msg.info(string.format(
        "filmstrip: geometry → x=%d y=%d w=%d h=%d  (timeline=%dpx, pct=%d%%)",
        bar_x, bar_y, bar_w, bar_h, tl_h, options.thumbnail_height_percent))

    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Visibility / proximity logic
-- ─────────────────────────────────────────────────────────────────────────────

local function cancel_idle_timer()
    if idle_timer then idle_timer:kill(); idle_timer = nil end
end

local function schedule_hide()
    cancel_idle_timer()
    idle_timer = mp.add_timeout(options.idle_timeout, function()
        idle_timer = nil
        if anim_state == "shown" or anim_state == "showing" then
            start_hide_anim()
        end
    end)
end

local function update_visibility()
    if not all_ready then return end
    -- A resize debounce is pending. Rather than blocking visibility for up
    -- to 500 ms (which causes the filmstrip to silently ignore hovers until
    -- the timer happens to fire while the mouse is still in zone), accelerate
    -- it: resolve geometry right now, remap, then re-enter update_visibility
    -- with a correct bar_y. remap() is cheap — it just re-composites cached
    -- thumbnails — so calling it here on demand is fine.
    if resize_timer then
        resize_timer:kill(); resize_timer = nil
        remap(); return
    end

    if force_state == "hide" then
        cancel_idle_timer()
        if anim_state ~= "hidden" and anim_state ~= "hiding" then start_hide_anim() end
        return
    end
    if force_state == "show" then
        cancel_idle_timer()
        if anim_state ~= "shown" and anim_state ~= "showing" then start_show_anim() end
        return
    end

    if not current_path then return end

    local flags  = uosc_persistency_flags()
    local paused = mp.get_property_bool("pause") or false
    local idle   = mp.get_property_bool("idle-active") or false

    if flags["always"]
    or (flags["paused"] and paused)
    or (flags["idle"]   and idle)
    then
        cancel_idle_timer()
        if anim_state ~= "shown" and anim_state ~= "showing" then start_show_anim() end
        return
    end

    local osd   = mp.get_property_native("osd-dimensions")
    local osd_h = (osd and osd.h) or 0
    if osd_h <= 0 then return end

    local tl_h    = bar_h or uosc_timeline_height()
    local prox_top = osd_h - tl_h - 4
    local mpos    = mp.get_property_native("mouse-pos")
    local in_zone = mpos and mpos.hover and (mpos.y >= prox_top)

    if in_zone then
        cancel_idle_timer()
        if anim_state ~= "shown" and anim_state ~= "showing" then start_show_anim() end
    else
        if (anim_state == "shown" or anim_state == "showing") and not idle_timer then
            schedule_hide()
        end
    end
end

local function on_all_ready()
    all_ready = true
    mp.msg.info("filmstrip: all thumbnails ready")

    -- Cancel any pending resize_timer — we will handle the geometry check
    -- ourselves right now rather than waiting for it to fire.
    if resize_timer then resize_timer:kill(); resize_timer = nil end

    -- Check whether geometry has changed since build() started. We resolve
    -- fresh and compare bar_w / bar_y rather than OSD pixel dimensions,
    -- because going fullscreen can change bar_y even when OSD pixels are
    -- identical (e.g. when uosc_scale ~= uosc_scale_fullscreen).
    local saved_bar_w = bar_w
    local saved_bar_y = bar_y
    local ok = resolve_geometry()
    if ok and (bar_w ~= canvas_w or bar_y ~= saved_bar_y or bar_w ~= saved_bar_w) then
        mp.msg.info("filmstrip: geometry changed during generation — remapping")
        if remap() == false then build(); return end
    end

    update_visibility()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Thumbnail size
-- ─────────────────────────────────────────────────────────────────────────────

local function calc_thumb_size()
    local vp = mp.get_property_native("video-out-params")
    local dw = vp and vp.dw or 0
    local dh = vp and vp.dh or 0
    local th = bar_h
    local tw
    if dw > 0 and dh > 0 then
        tw = math.floor(dw / dh * th + 0.5)
    else
        tw = math.floor(16 / 9 * th + 0.5)
    end
    local max_tile_w = math.ceil(bar_w / options.thumbnail_count) + 2
    if tw < max_tile_w then tw = max_tile_w end
    if tw % 2 ~= 0 then tw = tw + 1 end
    if th % 2 ~= 0 then th = th + 1 end
    return tw, th
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Tile geometry helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function tile_dest(i, n)
    local x0 = math.floor((i - 1) * bar_w / n)
    local x1 = math.floor(i       * bar_w / n)
    return x0, x1 - x0
end

local function tile_sample_time(i, n, duration)
    local align = (options.slice_align or "centre"):lower()
    if     align == "left"  then return (i - 1) * duration / n
    elseif align == "right" then return i       * duration / n
    else                         return (i - 0.5) * duration / n
    end
end

local function slice_src_x(thumb_w, tile_w)
    local align = (options.slice_align or "centre"):lower()
    if   align == "right" then
        return math.max(0, thumb_w - tile_w)
    elseif align == "centre" or align == "center" then
        return math.max(0, math.floor((thumb_w - tile_w) / 2))
    end
    return 0
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Composite BGRA file
-- ─────────────────────────────────────────────────────────────────────────────

local function init_composite()
    local f = io.open(composite_path, "wb")
    if not f then
        mp.msg.error("filmstrip: cannot create composite: " .. composite_path)
        return false
    end
    local total = canvas_w * canvas_h * 4
    local chunk = string.rep("\0", 65536)
    local done  = 0
    while done < total do
        local n = math.min(65536, total - done)
        f:write(n == 65536 and chunk or string.rep("\0", n))
        done = done + n
    end
    f:close()
    return true
end

-- Blit a single thumbnail slice into the composite BGRA file.
-- The source file is read fully into memory to minimise I/O overhead;
-- only the destination file requires per-row seeking.
local function blit_thumb_to_composite(t)
    -- Read the entire source thumbnail into a Lua string (typically < 100 KB).
    local src = io.open(t.file_bgra, "rb")
    if not src then return false end
    local src_data = src:read("*a")
    src:close()
    if not src_data or #src_data == 0 then return false end

    local n              = options.thumbnail_count
    local dest_x, tile_w = tile_dest(t.index, n)
    local src_x          = slice_src_x(t.actual_w, tile_w)
    local copy_px        = math.min(tile_w, t.actual_w - src_x)
    if copy_px <= 0 then return false end

    local copy_bytes = copy_px * 4
    local src_stride = t.actual_w * 4
    local dst_stride = canvas_w   * 4
    local src_off    = src_x  * 4 + 1  -- Lua strings are 1-indexed
    local dst_off    = dest_x * 4

    local dst = io.open(composite_path, "r+b")
    if not dst then return false end

    local src_h = t.actual_h
    for row = 0, canvas_h - 1 do
        -- Nearest-neighbour row mapping: 1:1 when heights match, scaled
        -- otherwise (e.g. different uosc scale in fullscreen vs windowed).
        local src_row = (src_h == canvas_h) and row
                        or math.min(math.floor(row * src_h / canvas_h), src_h - 1)
        local row_start = src_row * src_stride + src_off
        local row_end   = row_start + copy_bytes - 1
        if row_end > #src_data then break end
        dst:seek("set", row * dst_stride + dst_off)
        dst:write(src_data:sub(row_start, row_end))
    end
    dst:close()
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Cleanup
-- ─────────────────────────────────────────────────────────────────────────────

local function cleanup()
    cancel_idle_timer(); kill_anim_timer(); remove_composite()
    anim_state = "hidden"; slide_progress = 0.0
    for _, t in ipairs(thumbs) do
        os.remove(t.file_out)
        os.remove(t.file_bgra)
    end
    if composite_path then os.remove(composite_path); composite_path = nil end
    thumbs = {}; active_procs = 0; current_path = nil; all_ready = false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Resize: remap
-- ─────────────────────────────────────────────────────────────────────────────

remap = function()
    local ok, reason = resolve_geometry()
    if not ok then
        mp.msg.info("filmstrip: remap skipped — " .. (reason or "?"))
        return true
    end
    -- Height may differ from original generation (e.g. different
    -- scale/scale_fullscreen in uosc). blit_thumb_to_composite handles
    -- this via nearest-neighbour row scaling, so no rebuild is needed.
    canvas_w = bar_w; canvas_h = bar_h
    if not init_composite() then return true end

    local reblitted = 0
    for _, t in ipairs(thumbs) do
        if t.status == "done" then blit_thumb_to_composite(t); reblitted = reblitted + 1 end
    end
    mp.msg.info(string.format(
        "filmstrip: remapped %d/%d tiles → %dx%d @ (%d,%d)",
        reblitted, #thumbs, bar_w, bar_h, bar_x, bar_y))

    if anim_state ~= "hidden" then
        kill_anim_timer(); remove_composite()
        anim_state = "hidden"; slide_progress = 0.0; last_anim_y = nil
    end
    update_visibility()
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Dimension verification
-- ─────────────────────────────────────────────────────────────────────────────

local function verify_dimensions(t, req_w, req_h)
    local info = mp.utils.file_info(t.file_bgra)
    if not info or info.size < 4 then return false end

    local pixels    = info.size / 4
    local exact_match = pixels == req_w * req_h
    if exact_match then t.actual_w, t.actual_h = req_w, req_h; return true end

    -- Allow a small tolerance for encoder rounding.
    local threshold = 5
    local ls = math.max(req_w, req_h)
    local ss = math.min(req_w, req_h)
    for a = ss, math.max(1, ss - threshold), -1 do
        if pixels % a == 0 then
            local b = pixels / a
            if math.abs(ls - b) < threshold then
                t.actual_w = req_h < req_w and b or a
                t.actual_h = req_h < req_w and a or b
                return true
            end
        end
    end

    mp.msg.warn(string.format(
        "filmstrip: thumb %d unexpected size %d bytes (expected %dx%d = %d bytes)",
        t.index, info.size, req_w, req_h, req_w * req_h * 4))
    return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Progress tracking
-- ─────────────────────────────────────────────────────────────────────────────

local function check_all_ready()
    if all_ready then return end
    for _, t in ipairs(thumbs) do
        if t.status == "pending" or t.status == "generating" then return end
    end
    on_all_ready()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Subprocess spawning
-- ─────────────────────────────────────────────────────────────────────────────

local spawn_next

spawn_next = function()
    for _, t in ipairs(thumbs) do
        if active_procs >= options.max_concurrent then return end
        if t.status ~= "pending" then goto continue end

        t.status = "generating"; active_procs = active_procs + 1

        local req_w, req_h = t.req_w, t.req_h
        local vf = string.format(
            "scale=w=%d:h=%d:force_original_aspect_ratio=decrease," ..
            "pad=w=%d:h=%d:x=-1:y=-1,format=bgra",
            req_w, req_h, req_w, req_h)

        local hwdec_val = tostring(options.hwdec):lower()
        if hwdec_val == "true"  or hwdec_val == "yes" then hwdec_val = "auto"
        elseif hwdec_val == "false" then hwdec_val = "no"
        end

        local mpv_args = {
            options.mpv_path,
            "--no-config", "--msg-level=all=no", "--really-quiet",
            "--no-terminal", "--load-scripts=no", "--osc=no", "--ytdl=no",
            "--load-stats-overlay=no", "--load-osd-console=no",
            "--load-auto-profiles=no", "--no-sub", "--no-audio",
            "--start=" .. string.format("%.3f", t.time), "--hr-seek=no",
            "--demuxer-readahead-secs=0", "--demuxer-max-bytes=128KiB",
            "--vd-lavc-skiploopfilter=all", "--vd-lavc-software-fallback=1",
            "--vd-lavc-fast", "--vd-lavc-threads=2",
            "--hwdec=" .. hwdec_val,
            "--vf=" .. vf, "--sws-scaler=fast-bilinear", "--video-rotate=0",
            "--frames=1", "--ovc=rawvideo", "--of=image2", "--ofopts=update=1",
            "--o=" .. t.file_out, "--", current_path,
        }

        local args = priority_wrap(mpv_args)

        mp.command_native_async(
            { name = "subprocess", playback_only = false, args = args },
            function(success, result)
                active_procs = active_procs - 1
                if success and result.status == 0 then
                    if os_name == "windows" then os.remove(t.file_bgra) end
                    local ok = os.rename(t.file_out, t.file_bgra)
                    if ok ~= false then
                        if verify_dimensions(t, req_w, req_h) then
                            t.status = "done"
                            if composite_path then
                                local info = mp.utils.file_info(composite_path)
                                if info and info.size == canvas_w * canvas_h * 4 then
                                    blit_thumb_to_composite(t)
                                end
                            end
                        else
                            t.status = "failed"
                        end
                    else
                        t.status = "failed"
                        mp.msg.warn("filmstrip: rename failed for thumb " .. t.index)
                    end
                else
                    t.status = "failed"
                    mp.msg.warn(string.format(
                        "filmstrip: thumb %d failed (exit %s)",
                        t.index, tostring(result and result.status)))
                end
                check_all_ready()
                spawn_next()
            end)
        ::continue::
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Build
-- ─────────────────────────────────────────────────────────────────────────────

local function build()
    build_pending = false

    local ok, reason = resolve_geometry()
    if not ok then
        mp.msg.info("filmstrip: geometry not ready (" .. (reason or "?") .. ") — retry pending")
        build_pending = true; return
    end

    local duration = mp.get_property_number("duration")
    if not duration or duration <= 0 then
        mp.msg.info("filmstrip: no duration — retry pending")
        build_pending = true; return
    end

    local path     = mp.get_property("path"); if not path then return end
    local open_fn  = mp.get_property("stream-open-filename")
    if open_fn and mp.get_property_bool("demuxer-via-network") and open_fn ~= path then
        path = open_fn
    end

    cleanup()
    current_path = path

    -- Resolve priority once for this file so all spawned subprocesses share it.
    resolve_priority()

    local n = math.max(1, options.thumbnail_count)
    canvas_w       = bar_w
    canvas_h       = bar_h
    composite_path = tmpfile("composite.bgra")

    local req_w, req_h = calc_thumb_size()
    mp.msg.info(string.format(
        "filmstrip: building %d thumbs @ %dx%d, align=%s, canvas=%dx%d @ (%d,%d)",
        n, req_w, req_h, options.slice_align, canvas_w, canvas_h, bar_x, bar_y))

    if not init_composite() then return end

    for i = 1, n do
        thumbs[i] = {
            index    = i,
            time     = tile_sample_time(i, n, duration),
            file_out = tmpfile(i .. ".out"),
            file_bgra= tmpfile(i .. ".bgra"),
            req_w    = req_w,
            req_h    = req_h,
            status   = "pending",
            actual_w = nil,
            actual_h = nil,
        }
    end

    spawn_next()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Event / property handlers
-- ─────────────────────────────────────────────────────────────────────────────

local function on_file_loaded()
    cleanup()
    mp.add_timeout(0.5, build)
end

local function on_end_file()
    cleanup()
    build_pending   = false
    force_state     = nil
    uosc_conf_cache = nil
end

local function on_shutdown() cleanup() end

local function on_fullscreen()
    if not current_path then return end
    uosc_conf_cache = nil
    -- Cancel every pending timer so no stale remap or idle-hide fires
    -- from the previous windowed/fullscreen state.
    cancel_idle_timer()
    kill_anim_timer()
    if resize_timer then resize_timer:kill(); resize_timer = nil end
    -- Immediately remove the composite. on_osd_dimensions fires right
    -- after with the new OSD size and starts a fresh resize_timer.
    remove_composite()
    anim_state = "hidden"; slide_progress = 0.0; last_anim_y = nil
end

local function on_osd_dimensions(_, val)
    if not val then return end
    if val.w == last_osd_w and val.h == last_osd_h then return end
    last_osd_w = val.w; last_osd_h = val.h
    if build_pending then build(); return end
    if not current_path then return end
    if resize_timer then resize_timer:kill() end
    resize_timer = mp.add_timeout(0.5, function()
        resize_timer = nil
        if build_pending then build(); return end
        local behavior = (options.resize_behavior or "remap"):lower()
        if behavior == "regenerate" then
            build()
        else
            if remap() == false then build() end
        end
    end)
end

local function on_mouse_pos(_, _) update_visibility() end
local function on_pause(_, _)     update_visibility() end

local vp_timer = nil
local function on_video_params(_, val)
    if not val or not build_pending then return end
    if vp_timer then vp_timer:kill() end
    vp_timer = mp.add_timeout(0.2, function()
        vp_timer = nil
        if build_pending then build() end
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Script messages
-- ─────────────────────────────────────────────────────────────────────────────

mp.register_script_message("filmstrip-show", function()
    force_state = "show"; update_visibility()
    mp.msg.info("filmstrip: force-shown")
end)

mp.register_script_message("filmstrip-hide", function()
    force_state = "hide"; update_visibility()
    mp.msg.info("filmstrip: force-hidden")
end)

mp.register_script_message("filmstrip-rebuild", function()
    mp.msg.info("filmstrip: manual rebuild")
    force_state = nil; uosc_conf_cache = nil; build()
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Register
-- ─────────────────────────────────────────────────────────────────────────────

mp.observe_property("osd-dimensions",   "native", on_osd_dimensions)
mp.observe_property("video-out-params", "native", on_video_params)
mp.observe_property("mouse-pos",        "native", on_mouse_pos)
mp.observe_property("pause",            "bool",   on_pause)
mp.observe_property("fullscreen",       "bool",   function(_, v)
    if v ~= nil then on_fullscreen() end
end)

mp.register_event("file-loaded", on_file_loaded)
mp.register_event("end-file",    on_end_file)
mp.register_event("shutdown",    on_shutdown)