-- frame_app.lua : demo device-side app for halo_demo_app
--
-- Receives TxPlainText messages (msg code 0x0a) from the phone and renders
-- them, and reports IMU taps back (msg code 0x09 via tap.min). Modelled on the
-- upstream brilliant_msg example apps.

local data = require('data.min')
local plain_text = require('plain_text.min')
local code = require('code.min')
local tap = require('tap.min')

local TEXT_MSG      = 0x0a   -- phone -> frame : plain text to show
local TAP_SUBS_MSG  = 0x10   -- phone -> frame : 1 = subscribe to taps, 0 = stop

local function show_text(t)
    frame.display.clear(0)
    local i = 0
    for line in t.string:gmatch('([^\n]*)\n?') do
        if line ~= '' then
            frame.display.text(line, t.x, i * 50 + t.y, t.color)
            i = i + 1
        end
    end
    frame.display.show()
end

frame.display.clear(0)
frame.display.text('Demo app ready', 20, 110, 0xFFFFFF)
frame.display.show()

-- tell the host the app is up (host waits on this print)
print(0)

while true do
    local ok, err = pcall(function()
        for _, item in ipairs(data.process_raw_items()) do
            local flag, raw = item[1], item[2]
            if flag == TEXT_MSG then
                local parsed = plain_text.parse_plain_text(raw)
                if parsed and parsed.string then
                    show_text(parsed)
                end
            elseif flag == TAP_SUBS_MSG then
                local msg = code.parse_code(raw)
                if msg.value == 1 then
                    frame.imu.tap_callback(tap.send_tap)
                else
                    frame.imu.tap_callback(nil)
                end
            end
        end
        frame.sleep(0.02)
    end)
    if not ok then
        frame.display.clear(0)
        frame.display.show()
        break
    end
end
