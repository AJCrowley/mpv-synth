local mp = require 'mp'
local options = require 'mp.options'

local opts = {
    enabled = true,
    match = ""
}

options.read_options(opts, "auto-subs")
-- If no match terms are provided or script not enabled, the script does nothing
if not opts.enabled or not opts.match or opts.match:match("^%s*$") then
    return
end

-- Split comma-separated string into a table, trimming whitespace from each term
local function split(input)
    local t = {}
    for str in string.gmatch(input, "([^,]+)") do
        local trimmed = str:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            table.insert(t, trimmed:lower())
        end
    end
    return t
end

local patterns = split(opts.match)

-- Guard: if no valid patterns remain after trimming, do nothing
if #patterns == 0 then
    return
end

local function track_matches(track)
    if track.type ~= "sub" then
        return false
    end

    -- Combine useful fields into one searchable string
    local combined = (
        (track.title or "") .. " " ..
        (track.lang or "") .. " " ..
        (track.codec or "")
    ):lower()

    -- All patterns must match for the track to be selected
    for _, pattern in ipairs(patterns) do
        if not string.find(combined, pattern, 1, true) then
            return false
        end
    end
    return true
end

local function select_subtitle()
    local current_sid = mp.get_property("sid")
    if current_sid and current_sid ~= "no" then
        -- Subtitle track already selected, skipping auto-selection
        return
    end

    local tracks = mp.get_property_native("track-list")
    if not tracks then return end

    for _, track in ipairs(tracks) do
        if track_matches(track) then
            mp.set_property_number("sid", track.id)
            -- turn on subs if we have a match
            --mp.set_property("sid", "yes")
            return
        end
    end
end

mp.register_event("file-loaded", select_subtitle)
