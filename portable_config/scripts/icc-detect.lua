-- icc-detect.lua
-- Detects video colour space / HDR metadata using ffprobe and applies
-- appropriate mpv settings automatically on each file load.
--
-- When the OS/display pipeline is HDR-capable (Windows HDR mode on),
-- HDR content is passed through natively and tone mapping is skipped.
-- When the display is SDR, HDR content is tone mapped to SDR.
--
-- Options (set in script-opts/icc-detect.conf):
--   enabled=yes              -- master on/off switch
--   icc_for_sdr=yes          -- enable icc-profile-auto for SDR content
--                               (useful if you have a calibrated display)
--   tone_mapping=bt.2390        -- tone mapping algorithm for HDR->SDR conversion
--                               bt.2390 / reinhard / hable / mobius / linear / none
--   osd_notify=yes           -- show OSD messages on detection
--   osd_duration=5           -- OSD message duration in seconds

local mp    = require 'mp'
local utils = require 'mp.utils'

local o = {
    enabled      = true,
    icc_for_sdr  = true,
    tone_mapping = "bt.2390",
    osd_notify   = true,
    osd_duration = 5,
}

require("mp.options").read_options(o, "icc-detect")

if not o.enabled then return end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local current_profile = nil
local ffprobe_path = "ffprobe"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function notify(msg)
    mp.msg.info("[icc-detect] " .. msg)
    if o.osd_notify then
        mp.osd_message("[icc-detect] " .. msg, o.osd_duration)
    end
end

local function display_is_hdr()
    local trc = mp.get_property("target-trc")
    if not trc then return false end

    -- Explicit SDR values
    if trc == "srgb" or trc == "gamma2.2" or trc == "bt.1886" then
        return false
    end

    -- Anything else we treat as HDR-capable output
    return true
end

local function apply_profile(profile)
    if profile == current_profile then return end
    current_profile = profile

    if profile == "hdr-pass" then
        mp.set_property("icc-profile-auto", "yes")
        mp.set_property("target-colorspace-hint", "yes")
        mp.set_property("hdr-compute-peak", "yes")
        notify("HDR passthrough")

    elseif profile == "hdr-tonemap" then
        mp.set_property("icc-profile-auto", "yes")
        mp.set_property("tone-mapping", o.tone_mapping)
        mp.set_property("hdr-compute-peak", "yes")
        mp.set_property("target-colorspace-hint", "no")
        notify("HDR → SDR tone mapping (" .. o.tone_mapping .. ")")

    elseif profile == "wide-sdr" then
        if o.icc_for_sdr then
            mp.set_property("icc-profile-auto", "yes")
        end
        notify("Wide gamut SDR (BT.2020)")

    else -- SDR
        if o.icc_for_sdr then
            mp.set_property("icc-profile-auto", "yes")
        end
    end
end

-- ---------------------------------------------------------------------------
-- Detect content
-- ---------------------------------------------------------------------------
local function detect_content(filename)
    local result = utils.subprocess({
        args = {
            ffprobe_path,
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries",
            "stream=color_transfer,color_primaries:stream_side_data=type",
            "-of", "json",
            filename,
        },
        capture_stdout = true,
    })

    if result.status ~= 0 or not result.stdout then return "sdr" end

    local data = utils.parse_json(result.stdout)
    if not data or not data.streams or #data.streams == 0 then
        return "sdr"
    end

    local s = data.streams[1]
    local transfer  = s.color_transfer or ""
    local primaries = s.color_primaries or ""
    local side_data = s.side_data_list or {}

    -- Dolby Vision
    for _, d in ipairs(side_data) do
        if d.side_data_type and d.side_data_type:find("DOVI") then
            return "hdr"
        end
    end

    if transfer == "smpte2084" or transfer == "arib-std-b67" then
        return "hdr"
    end

    if primaries == "bt2020" then
        return "wide-sdr"
    end

    return "sdr"
end

-- ---------------------------------------------------------------------------
-- Core logic
-- ---------------------------------------------------------------------------
local content_type = "sdr"

local function update_output()
    if content_type == "hdr" then
        if display_is_hdr() then
            apply_profile("hdr-pass")
        else
            apply_profile("hdr-tonemap")
        end
    else
        apply_profile(content_type)
    end
end

local function on_file_loaded()
    local filename = mp.get_property("path")
    if not filename then return end

    current_profile = nil -- reset
    content_type = detect_content(filename)

    -- Delay once for VO init
    mp.add_timeout(0.2, update_output)
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
mp.register_event("file-loaded", on_file_loaded)

-- React to display changes ONLY (no ffprobe here)
mp.observe_property("target-peak", "number", function()
    update_output()
end)