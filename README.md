# halo-ws-simulator

**Develop and debug Flutter apps for the [Brilliant Labs Halo](https://brilliant.xyz/)
with no glasses.** Your app connects to a simulator running on your PC over a
WebSocket, exactly as it would connect to real hardware over Bluetooth LE — and
switching between the two is **one dependency block, no code changes**.

```
   ┌──────────────────────┐       WebSocket        ┌────────────────────────────────┐
   │  your Flutter app     │      ws://…:8765       │  halo-ws-sim (this repo)        │
   │  brilliant_sdk        │  ──────────────────►   │   protocol ⇄ bridge ⇄ emulator  │
   │    └ brilliant_ble    │  ◄──────────────────   │              (real Lua 5.4 VM,  │
   │      = brilliant_ble_ws (WebSocket transport)  │               frame.* API, fb)  │
   └──────────────────────┘   device / rx frames   │   web view :8766 · pygame window│
                                                    │   PC mic / speaker / webcam ►   │
                                                    └────────────────────────────────┘
```

The device runtime is the upstream
[`halo-emulator`](https://pypi.org/project/halo-emulator/) package (a real Lua
5.4 VM + the full `frame.*` API + a 256×256 framebuffer), used here as a library.
This repo adds the wireless link, the REPL/message bridge, a desktop + web view,
and optional bridges from the PC's real microphone / speaker / webcam.

| Path | What it is |
|------|------------|
| [`python/`](python/) | the simulator — `halo-ws-sim` CLI (`pip install halo-ws-simulator`) |
| [`flutter/brilliant_ble_ws/`](flutter/brilliant_ble_ws/) | a WebSocket-transport build of `brilliant_ble`, same public API, consumed via a git dependency override |
| [`example/halo_demo_app/`](example/halo_demo_app/) | a full demo app (text to display + tap counter) |
| [`template/halo_app_starter/`](template/halo_app_starter/) | a minimal starter you copy to begin your own app |

---

## Quick start

### 1. Run the simulator

Python 3.10–3.13.

```bash
pip install halo-ws-simulator          # or: pipx install halo-ws-simulator
#   from a clone:  pip install -e "python/[msg]"
halo-ws-sim
```

On startup it prints every URL a client can use. It opens a pygame window and a
web view on `http://localhost:8766`.

### 2. Point your app at it

In your app's `pubspec.yaml`:

```yaml
dependencies:
  brilliant_sdk: ^2.0.0        # unchanged — the official package

# ── SIMULATOR: delete this block for real Halo hardware ──
dependency_overrides:
  brilliant_ble:
    git:
      url: https://github.com/DaryeDev/halo-ws-simulator.git
      path: flutter/brilliant_ble_ws
      ref: main                # pin a tag once releases exist, e.g. v0.2.0
```

`brilliant_ble_ws` declares `name: brilliant_ble`, so the override redirects
every `import 'package:brilliant_ble/...'` (and the `brilliant_sdk` re-export) to
it. **Your imports and code are unchanged.** To go back to hardware, delete the
block and `flutter pub get`.

> New app? Start from [`template/halo_app_starter`](template/halo_app_starter/)
> instead of writing the boilerplate.

### 3. Connect

```bash
flutter pub get
flutter run
```

The transport **auto-discovers** the simulator — it probes, in order:

| Candidate | Covers |
|-----------|--------|
| `ws://10.0.2.2:8765` | Android emulator |
| `ws://127.0.0.1:8765` | USB device with `adb reverse tcp:8765 tcp:8765` |
| `ws://localhost:8765` | desktop / web |

So the emulator and desktop need **zero configuration**. A USB device needs one
command:

```bash
adb reverse tcp:8765 tcp:8765
```

#### Using a LAN IP instead of `adb reverse`

If the phone and PC are on the **same Wi-Fi**, skip `adb reverse` and point the
app straight at the PC. The simulator binds `0.0.0.0` and prints its LAN URLs on
startup; pass the matching one:

```bash
flutter run --dart-define=HALO_SIM_URL=ws://192.168.1.16:8765
```

`HALO_SIM_URL` may be a comma-separated list (tried in order). At runtime you can
also set `HaloSimConfig.urls` before connecting.

---

## Microphone, speaker and camera (optional)

By default `frame.microphone` / `frame.speaker` / `frame.camera` are API-only
(the same as the upstream emulator). Add `--mic` / `--speaker` / `--camera` to
bridge them to the **real devices on the PC running the simulator**. Formats are
converted to what the Halo hardware produces / consumes, so device-side Lua and
the SDK's `RxPhoto` / audio helpers work unchanged.

### Install the extra

```bash
pip install "halo-ws-simulator[media]"      # sounddevice + opencv + numpy
#   from a clone:  pip install -e "python/[media]"   (or [all] for msg + media)
```

On Linux, `sounddevice` needs PortAudio: `sudo apt install libportaudio2`.
The camera bridge needs a webcam OpenCV can open.

### Enable per device

```bash
halo-ws-sim --mic --speaker --camera        # default devices
halo-ws-sim --mic "Razer Seiren Mini"       # pick input by name…
halo-ws-sim --mic 7                          # …or by index
halo-ws-sim --camera 1                       # second webcam
```

List audio device names / indices:

```bash
python -c "import sounddevice; print(sounddevice.query_devices())"
```

### What each bridge does

| Bridge | Halo API | Behaviour |
|--------|----------|-----------|
| `--mic` | `frame.microphone.start{sample_rate=8000\|16000}` then `read(n)` | captures the PC mic, resamples to the requested rate, delivers mono 16-bit PCM in `read()`-sized chunks. `aec` / `voice` / `gain` are accepted (no processing). LC3 encoding is not implemented — request `encoder='pcm'`. |
| `--speaker` | `frame.speaker.start{sample_rate=,channels=,bit_depth=}` then `play(pcm)` | plays the PCM you send on the PC's default (or chosen) output device. |
| `--camera` | `frame.camera.capture{resolution=,quality=,pan=}`, `image_ready()`, `read(n)` / `read_raw(n)` | grabs a webcam frame, centre-crops to square, resizes to `resolution`, rotates so the SDK's `RxPhoto` (which rotates −90°) yields an upright image, JPEG-encodes at the `quality` enum (`VERY_LOW`…`VERY_HIGH`). `read` returns the full JPEG; `read_raw` returns it minus the fixed 623-byte header, which `RxPhoto` re-prepends. `pan`, manual exposure and auto-exposure are accepted as no-ops. |

### End-to-end example (device-side Lua)

```lua
-- microphone: stream to the host
frame.microphone.start({ sample_rate = 16000 })
while true do
  local chunk = frame.microphone.read(frame.bluetooth.max_length() - 1)
  if chunk == nil then break end          -- stopped
  if #chunk > 0 then
    frame.bluetooth.send('\x0c' .. chunk)  -- your own msg code
  end
  frame.sleep(0.005)
end
```

```lua
-- camera: the standard brilliant_msg photo flow just works
local camera = require('camera.min')
camera.capture_and_send(camera.parse_capture_settings(raw))
```

Host side, use `brilliant_msg`'s `RxPhoto` exactly as you would with hardware.

> **Caveats.** Audio latency is best-effort (this is a dev tool, not a real-time
> pipeline). LC3 in/out and metering data are not modelled. The webcam frame is
> a still per `capture()` — there is no continuous video feed.

---

## Simulator reference

### CLI

| Flag | Meaning |
|------|---------|
| `--port 8765` | WebSocket port (web view is `port + 1`) |
| `--sandbox ./halo_sandbox` | device "flash" — uploaded Lua files persist here |
| `--fresh` | wipe the sandbox on startup |
| `--libs data,plain_text` | preload `brilliant_msg` libs as `<name>.min.lua` (needs `[msg]`) |
| `--mic` / `--speaker` / `--camera` `[DEVICE]` | PC media bridges (needs `[media]`) |
| `--headless` | no pygame window |
| `--no-web` | no HTTP view |
| `--window-main-thread` | window on the main thread (needed on macOS) |
| `-v` / `-vv` | INFO / DEBUG logging |

Window keys: `SPACE` single click · `D` double · `L` long · `T`/`2`/`3` IMU
single/double/triple tap · `S` save a PNG.

### Web view — `http://localhost:8766`

A no-dependency page showing the live 256×256 display, with buttons to inject
taps and button presses. Also drivable from scripts (the device WebSocket link
is single-client, so this is how you inject events without displacing the app):

```
GET /                                  live view + inject buttons
GET /shot.png                          current framebuffer (PNG)
GET /inject?event=tap&arg=double
GET /inject?event=button_single
```

### What is faithful, what is not

Faithful — it *is* the real emulator runtime:

* Lua 5.4 execution of everything you `sendString` / `uploadScript`.
* `frame.display.*` rendering (pixel-accurate Dogica fonts, real palette).
* `frame.bluetooth.*`, `frame.imu.*` taps, `frame.button.*`, `frame.file.*`,
  `frame.time.*`, compression.
* The `brilliant_msg` chunked message protocol and its `\x01\x00\x00` ACKs.
* With `[media]`: `frame.microphone` / `frame.speaker` / `frame.camera` as above.

Not modelled: LC3 audio, camera video feed / metering, DFU / OTA firmware update,
and exact BLE timing / MTU renegotiation / bonding. While a Lua main loop is
running, send a break (`sendBreakSignal()`) before further REPL strings — same as
the documented hardware workflow.

---

## Compatibility

`brilliant_ble_ws` tracks the upstream `brilliant_ble` public API. Pin the git
`ref:` to a tag that matches the `brilliant_ble` your `brilliant_sdk` resolves:

| upstream `brilliant_ble` | this repo |
|--------------------------|-----------|
| `^5.x` | `main` (until the first tagged release) |

---

## Publishing your own copy

This repo is set up to push straight to
`https://github.com/DaryeDev/halo-ws-simulator.git` (remote `origin`). To fork it
elsewhere, change the URLs in `template/halo_app_starter/pubspec.yaml`,
`example/halo_demo_app/pubspec.yaml` (commented git block) and this README.

## Licenses

* `python/` and the repo: MIT.
* `flutter/brilliant_ble_ws/`: BSD-3-Clause — it is derived from
  `brilliant_ble` (© 2025 CitizenOneX); see its `LICENSE`.
