-- frame_app.lua : demo device-side app for halo_demo_app
--
-- Exercises text, taps, camera, microphone and speaker so the whole
-- frame.* surface can be tested against the simulator (or hardware).

local data = require('data.min')
local plain_text = require('plain_text.min')
local code = require('code.min')
local tap = require('tap.min')
local camera = require('camera.min')
local audio = require('audio.min')

local TEXT_MSG     = 0x0a   -- phone -> frame : TxPlainText
local TAP_SUBS_MSG = 0x10   -- phone -> frame : TxCode 1/0 subscribe to taps
local CAPTURE_MSG  = 0x0d   -- phone -> frame : TxCaptureSettings, take a photo
local MIC_MSG      = 0x0e   -- phone -> frame : TxCode, record ~2s and stream it
local SPEAKER_MSG  = 0x0f   -- phone -> frame : raw PCM to play

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

local function banner(s)
    frame.display.clear(0)
    frame.display.text(s, 20, 110, 0xFFFFFF)
    frame.display.show()
end

frame.speaker.start({ sample_rate = 16000, bit_depth = 16, channels = 1 })
banner('Demo app ready')
print(0)

while true do
    local ok, err = pcall(function()
        for _, item in ipairs(data.process_raw_items()) do
            local flag, raw = item[1], item[2]

            if flag == TEXT_MSG then
                local parsed = plain_text.parse_plain_text(raw)
                if parsed and parsed.string then show_text(parsed) end

            elseif flag == TAP_SUBS_MSG then
                local m = code.parse_code(raw)
                frame.imu.tap_callback(m.value == 1 and tap.send_tap or nil)

            elseif flag == CAPTURE_MSG then
                banner('Taking photo...')
                camera.capture_and_send(camera.parse_capture_settings(raw))
                banner('Demo app ready')

            elseif flag == MIC_MSG then
                banner('Recording...')
                audio.start({ sample_rate = 16000, bit_depth = 16 })
                local until_t = frame.time.utc() + 2.0
                while frame.time.utc() < until_t do
                    audio.read_and_send_audio()
                    frame.sleep(0.005)
                end
                audio.stop()
                audio.read_and_send_audio()   -- flush + final marker
                banner('Demo app ready')

            elseif flag == SPEAKER_MSG then
                frame.speaker.play(raw)
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
