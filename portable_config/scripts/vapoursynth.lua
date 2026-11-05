local mp = require 'mp'
local utils = require 'mp.utils'

-- Per-file FPS preferences: path|fps, one entry per line.
-- This is the single source of truth — the .vpy reads it directly.
local PREFS_FILE         = mp.command_native({"expand-path", "~~/"}) .. "/VapourSynth/vapoursynth_fps.txt"
-- Tells the .vpy which file is currently playing so it can look up the right entry.
-- Written at start-file (before watch-later restores the vf chain).
local CURRENT_PATH_FILE  = mp.command_native({"expand-path", "~~/"}) .. "/VapourSynth/vapoursynth_current_path.txt"
-- The interpolation knobs. Written to vapoursynth_params.json at start-file;
-- the .vpy merges this over its built-in defaults, so a key omitted here
-- (or an old conf) keeps the .vpy's default.
local PARAMS_FILE        = mp.command_native({"expand-path", "~~/"}) .. "/VapourSynth/vapoursynth_params.json"
local BUFFERED_FRAMES    = 6
local VS_FILTER          = "vapoursynth=~~/VapourSynth/vapoursynth.vpy:buffered-frames=" .. BUFFERED_FRAMES

mp.msg.info("VapourSynth script initialized. Prefs file: " .. PREFS_FILE)

-- ---------------------------------------------------------------------------
-- Options (portable_config/script-opts/vapoursynth.conf). Everything under
-- [vapoursynth] in that file overrides these. The interpolation keys are
-- passed to the open-svpflow parameter JSON built by vapoursynth.vpy.
-- ---------------------------------------------------------------------------
local options = {
    enabled = true,
    auto_apply = false,
    auto_fps = "60,30",
    auto_max_res = "1920,3840", -- automatically apply if resolution is equal to or less than

    -- hardware: render path. gpu = the open-svpflow wgpu/DX render (fast);
    -- gpu=no renders on the CPU (slower; cubic/gpuid keys are dropped).
    hardware_gpu = "yes",
    hardware_gpuid = 11,

    -- super: motion pyramid
    super_pel = 2,
    super_full = "yes",
    super_scale_up = 2,
    super_scale_down = 4,
    super_rc = 0,
    super_lean = "no",   -- open-svpflow: GPU analyse builds its own pyramid parts (fast, more VRAM)

    -- analyse: motion search. analyse_quality seeds the granular keys;
    -- explicit keys in the conf win over the preset.
    analyse_quality = "balanced",  -- fast | balanced | quality
    analyse_vectors = nil,         -- 1 = fast, 3 = best (preset default)
    analyse_levels = nil,          -- 0 = automatic
    analyse_distance = nil,        -- negative = adaptive search, -8 = widest
    analyse_coarse_width = nil,    -- 1050 = typical
    analyse_coarse_satd = "yes",
    analyse_refine_distance = nil, -- preset default

    -- smooth: render and masking
    smooth_algo = 23,          -- 23 = standard high quality; 13 = faster
    smooth_block = "no",
    smooth_linear = "yes",
    smooth_cubic = "no",       -- GPU-only; ignored when hardware_gpu=no
    smooth_mask_cover = 100,
    smooth_mask_area = 0,
    smooth_mask_area_sharp = 1.0,
    smooth_scene_mode = 3,
    smooth_scene_blend = "yes",
    smooth_limit_m1 = 1600,
    smooth_limit_m2 = 2800,
    smooth_limit_scene = 4000,
    smooth_limit_zero = 200,
    smooth_limit_blocks = 20,
    smooth_luma = 1.5,

    -- open-svpflow extras (all off by default)
    feature_dedup = 0,          -- try 0.4 for anime with repeated frames
    feature_still_mask = "no",  -- keep static text/logos crisp
    feature_still_limit = 4.5,
    feature_still_edge = 5,
    feature_still_tolerance = 30,
    feature_peel_mask = "no",   -- learn and lift a static HUD
    feature_peel_limit = 6,
}
require("mp.options").read_options(options, "vapoursynth")

-- ---------------------------------------------------------------------------
-- Build the parameter dict the .vpy reads. Section and key names MUST match
-- vapoursynth.vpy's DEFAULTS. An option left at its default (nil) falls back
-- to the .vpy's own default for that key.
-- ---------------------------------------------------------------------------
local ANALYSE_PRESETS = {
    fast     = { vectors = 1, distance = -2, refine_distance = 1, coarse_width = 1050 },
    balanced = { vectors = 3, distance = -4, refine_distance = 2, coarse_width = 1050 },
    quality  = { vectors = 3, distance = -8, refine_distance = 2, coarse_width = 1050 },
}

local function opt_bool(name)
    local v = options[name]
    if v == "yes" or v == true then return true end
    if v == "no" or v == false then return false end
    return nil
end

local function build_params()
    local preset = ANALYSE_PRESETS[options.analyse_quality] or ANALYSE_PRESETS.balanced
    local params = {
        hardware = {
            gpu   = opt_bool("hardware_gpu") and 1 or 0,
            gpuid = tonumber(options.hardware_gpuid) or 11,
        },
        super = {
            pel        = tonumber(options.super_pel) or 2,
            full       = opt_bool("super_full"),
            scale_up   = tonumber(options.super_scale_up) or 2,
            scale_down = tonumber(options.super_scale_down) or 4,
            rc         = tonumber(options.super_rc) or 0,
            lean       = opt_bool("super_lean"),
        },
        analyse = {
            vectors         = tonumber(options.analyse_vectors) or preset.vectors,
            levels          = tonumber(options.analyse_levels) or 0,
            search_distance = tonumber(options.analyse_distance) or preset.distance,
            coarse_width    = tonumber(options.analyse_coarse_width) or preset.coarse_width,
            coarse_satd     = opt_bool("analyse_coarse_satd"),
            refine_distance = tonumber(options.analyse_refine_distance) or preset.refine_distance,
        },
        smooth = {
            algo            = tonumber(options.smooth_algo) or 23,
            block           = opt_bool("smooth_block"),
            linear          = opt_bool("smooth_linear"),
            mask_cover      = tonumber(options.smooth_mask_cover) or 100,
            mask_area       = tonumber(options.smooth_mask_area) or 0,
            mask_area_sharp = tonumber(options.smooth_mask_area_sharp) or 1.0,
            scene_mode      = tonumber(options.smooth_scene_mode) or 3,
            scene_blend     = opt_bool("smooth_scene_blend"),
            limit_m1        = tonumber(options.smooth_limit_m1) or 1600,
            limit_m2        = tonumber(options.smooth_limit_m2) or 2800,
            limit_scene     = tonumber(options.smooth_limit_scene) or 4000,
            limit_zero      = tonumber(options.smooth_limit_zero) or 200,
            limit_blocks    = tonumber(options.smooth_limit_blocks) or 20,
            luma            = tonumber(options.smooth_luma) or 1.5,
        },
        features = {
            dedup           = tonumber(options.feature_dedup) or 0,
            still_mask      = opt_bool("feature_still_mask"),
            still_limit     = tonumber(options.feature_still_limit) or 4.5,
            still_edge      = tonumber(options.feature_still_edge) or 5,
            still_tolerance = tonumber(options.feature_still_tolerance) or 30,
            peel_mask       = opt_bool("feature_peel_mask"),
            peel_limit      = tonumber(options.feature_peel_limit) or 6,
        },
    }
    return params
end

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
-- Interpolation params: written every start-file so edits to vapoursynth.conf
-- are picked up by simply opening the next file, with no mpv restart.
-- ---------------------------------------------------------------------------
local function write_params()
    local json = utils.format_json(build_params())
    if not json then
        mp.msg.error("Could not encode interpolation params as JSON")
        return
    end
    local f = io.open(PARAMS_FILE, "w")
    if not f then
        mp.msg.error("Could not write interpolation params to " .. PARAMS_FILE)
        return
    end
    f:write(json)
    f:close()
end

local function split_csv(str)
    local result = {}
    for value in tostring(str):gmatch("([^,]+)") do
        table.insert(result, value:match("^%s*(.-)%s*$"))
    end
    return result
end

local function validate_auto_lists(max_res_str, fps_str)
    local max_res_list = split_csv(max_res_str)
    local fps_list = split_csv(fps_str)
    local ok = true
    if #max_res_list ~= #fps_list then
        mp.msg.warn(string.format(
            "auto_max_res has %d value(s) but auto_fps has %d value(s); they should match 1:1",
            #max_res_list, #fps_list
        ))
        ok = false
    end
    for i, max_res in ipairs(max_res_list) do
        if not tonumber(max_res) then
            mp.msg.warn("auto_max_res entry '" .. tostring(max_res) .. "' is not a valid number")
            ok = false
        end
    end
    return ok, max_res_list, fps_list
end

local function get_matching_fps(width, max_res_list, fps_list)
    local best_res = nil
    local best_fps = nil
    for i, max_res in ipairs(max_res_list) do
        local res_num = tonumber(max_res)
        if res_num and width <= res_num then
            if best_res == nil or res_num < best_res then
                best_res = res_num
                best_fps = fps_list[i]
            end
        end
    end
    return best_fps
end

-- ---------------------------------------------------------------------------
-- Apply or remove the VapourSynth filter for the current file.
-- The .vpy reads the params + prefs files directly when the filter runs, so
-- no intermediary files are needed at apply time.
-- ---------------------------------------------------------------------------
local function apply_fps(fps)
    mp.commandv("vf", "remove", VS_FILTER)
    if fps and fps > 0 then
        mp.commandv("vf", "add", VS_FILTER)
        mp.osd_message("VapourSynth FPS: " .. fps, 5)
        mp.msg.info("VapourSynth filter applied at " .. fps .. " fps")
    else
        mp.msg.info("VapourSynth filter removed")
    end
end

if options.enabled then
    -- ---------------------------------------------------------------------------
    -- Events
    -- ---------------------------------------------------------------------------
    -- start-file fires before watch-later restores the vf chain, so the params
    -- and current-path files are already in place when the .vpy evaluates.
    mp.register_event("start-file", function()
        write_params()
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
        write_params()
        apply_fps(fps)
    end)

    -- watch video width property to auto-apply VapourSynth filter if enabled and resolution is below threshold
    mp.observe_property("video-params/w", "native", function(_, width)
        if options.auto_apply then
            if width then
                local valid, max_res_list, fps_list = validate_auto_lists(options.auto_max_res, options.auto_fps)
                if not valid then
                    mp.msg.warn("auto_fps / auto_max_res configuration looks inconsistent; proceeding best-effort")
                end

                local matched_fps = get_matching_fps(width, max_res_list, fps_list)

                if matched_fps then
                    mp.msg.info("Auto-applying VapourSynth filter at " .. matched_fps)
                    mp.commandv("script-message", "vapoursynth_set_fps", tostring(matched_fps))
                else
                    mp.msg.info("Width " .. width .. " exceeds all configured auto_max_res thresholds; skipping auto-apply")
                end
            end
        end
    end)
end
