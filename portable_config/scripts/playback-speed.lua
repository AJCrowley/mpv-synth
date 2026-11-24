-- speed.lua
-- Configurable, non-wrapping playback speed controls for mpv

local mp = require 'mp'
local options = require 'mp.options'

-- Default configuration
local opts = {
    speeds = "0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3"
}

-- Load script-opts/speed.conf
options.read_options(opts, "speed")

local speeds = {}
local EPSILON = 0.000001

-- Parse and validate the configured speed list
local function parse_speeds(value)
    local result = {}

    for item in value:gmatch("[^,%s]+") do
        local speed = tonumber(item)

        if not speed or speed <= 0 then
            mp.msg.error("Speed: Invalid speed value: " .. item)
            return nil
        end

        if #result > 0 and speed <= result[#result] then
            mp.msg.error("Speed: Values must be in ascending order without duplicates")
            return nil
        end

        table.insert(result, speed)
    end

    if #result == 0 then
        mp.msg.error("Speed: No playback speeds configured")
        return nil
    end

    return result
end

speeds = parse_speeds(opts.speeds)

-- Fall back to defaults if configuration is invalid
if not speeds then
    speeds = parse_speeds("0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3")
end

-- Change playback speed to the next available anchor
local function increase_speed()
    mp.msg.info("increase_speed")
    local current = mp.get_property_number("speed", 1)
    local target = nil

    -- Already at or above maximum
    if current >= speeds[#speeds] - EPSILON then
        return
    end

    for _, speed in ipairs(speeds) do
        if speed > current + EPSILON then
            target = speed
            break
        end
    end

    if target then
        mp.set_property_number("speed", target)
        mp.osd_message(string.format("Playback speed: %gx", target), 1.2)
    end
end

-- Change playback speed to the previous available anchor
local function decrease_speed()
    mp.msg.info("decrease_speed")
    local current = mp.get_property_number("speed", 1)
    local target = nil

    -- Already at or below minimum
    if current <= speeds[1] + EPSILON then
        return
    end

    for i = #speeds, 1, -1 do
        if speeds[i] < current - EPSILON then
            target = speeds[i]
            break
        end
    end

    if target then
        mp.set_property_number("speed", target)
        mp.osd_message(string.format("Playback speed: %gx", target), 1.2)
    end
end

-- Register script bindings
mp.add_key_binding(nil, "increase", increase_speed)
mp.add_key_binding(nil, "decrease", decrease_speed)

mp.msg.info("Speed controls loaded (" .. #speeds .. " presets)")