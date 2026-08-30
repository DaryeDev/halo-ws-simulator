# halo-ws-simulator

A **wireless (WebSocket) simulator of the Brilliant Labs Halo**. It lets you
develop and debug Flutter apps built with the Halo SDK on a PC, with no glasses
attached — the Flutter app connects to your machine over WebSocket exactly as it
would connect to real Halo hardware over Bluetooth LE.

This is **a new project, not a fork**. The device runtime is the upstream
[`halo-emulator`](https://pypi.org/project/halo-emulator/) package (a real
Lua 5.4 VM + the full `frame.*` API + a 256×256 framebuffer), used here as a
library. This project adds:

* a **WebSocket server** that speaks the same byte protocol a Halo exposes over
  its BLE TX/RX characteristics;
* a **REPL bridge** so `sendString`, `uploadScript`, break/reset and the
  message protocol (`sendMessage` / `frame.bluetooth.send`) all behave as on
  hardware;
* a **desktop window** showing the display and injecting taps / button presses.

```
 ┌────────────────────┐   WebSocket    ┌──────────────────────────────────────┐
 │  Flutter app        │  ws://…:8765   │  halo-ws-simulator                   │
 │  brilliant_sdk      │ ─────────────► │   protocol  ⇄  bridge  ⇄  HaloEmulator│
 │  (brilliant_ble_ws) │ ◄───────────── │                          (Lua 5.4)   │
 └────────────────────┘   rx frames    │   pygame window (display + events)   │
                                        └──────────────────────────────────────┘
```

## Install

Requires Python 3.10–3.13.

```bash
cd halo_ws_simulator
python -m venv .venv && . .venv/Scripts/activate   # Windows: .venv\Scripts\activate
pip install -e .
# optional: ship the standard device-side Lua libs for --libs
pip install -e ".[msg]"
```

## Run

```bash
halo-ws-sim
```

Options:

| Flag | Meaning |
|------|---------|
| `--port 8765` | WebSocket port (default 8765) |
| `--sandbox ./halo_sandbox` | device "flash" — uploaded Lua files persist here |
| `--fresh` | wipe the sandbox on startup |
| `--libs data,plain_text` | preload `brilliant_msg` libs as `<name>.min.lua` |
| `--headless` | no pygame window (CI / servers) |
| `--no-web` | disable the HTTP view (default: on, port = `--port` + 1) |
| `--window-main-thread` | window on the main thread (needed on macOS) |
| `-v` / `-vv` | INFO / DEBUG logging |

Window keys: `SPACE` single click · `D` double · `L` long · `T`/`2`/`3` IMU
single/double/triple tap · `S` save a PNG of the display.

### Web view — http://localhost:8766

A no-dependency HTTP view of the live 256×256 display with buttons to inject
taps and button presses. Handy on a headless box, for screenshots, or to drive
events from a script **without** opening a second WebSocket (the device link is
single-client):

```
GET http://localhost:8766/                       live view + inject buttons
GET http://localhost:8766/shot.png               current framebuffer (PNG)
GET http://localhost:8766/inject?event=tap&arg=double
GET http://localhost:8766/inject?event=button_single
```

### Connecting from the Flutter app

| Where the app runs | URL to use |
|--------------------|-----------|
| Android emulator | `ws://10.0.2.2:8765` |
| physical phone (same Wi-Fi) | `ws://<your-PC-LAN-IP>:8765` |
| desktop / Chrome | `ws://localhost:8765` |

Pass it to the app with `--dart-define=HALO_SIM_URL=ws://10.0.2.2:8765`
(the SDK's WebSocket build already defaults to `ws://10.0.2.2:8765`).

## Protocol

See [`src/halo_ws_sim/protocol.py`](src/halo_ws_sim/protocol.py) for the full
JSON envelope spec. In short: `hello` → `device`, `connect` → `ready`, then
`tx` (host→device writes) and `rx` (device→host notifications) carry
base64 bytes identical to what crosses the BLE characteristics.

## What is faithful, what is approximate

Faithful — it is the real emulator runtime:

* Lua 5.4 execution of everything you `sendString` / `uploadScript`.
* `frame.display.*` rendering (pixel-accurate Dogica fonts, real palette).
* `frame.bluetooth.*`, `frame.imu.*` taps, `frame.button.*`, `frame.file.*`,
  `frame.time.*`, compression.
* The `brilliant_msg` chunked message protocol and its `\x01\x00\x00` ACKs.

Approximate / not modelled:

* No audio in or out (`frame.microphone` / `frame.speaker` are API-only).
* No camera sensor — `frame.camera.*` is not provided by the emulator.
* BLE timing, MTU renegotiation, bonding, RSSI, and disconnect reasons are
  simulated loosely.
* While a Lua main loop is running, new `sendString` REPL commands are queued
  until the next break — send `\x03` (which `sendBreakSignal()` does) first,
  same as the documented hardware workflow.
* DFU / OTA firmware update is not implemented.
