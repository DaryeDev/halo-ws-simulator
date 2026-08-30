# halo-ws-simulator

**Wireless (WebSocket) simulator of the [Brilliant Labs Halo](https://brilliant.xyz/).**
Develop and debug Flutter apps for the glasses on your PC with no hardware — your
app connects over a WebSocket exactly as it would to a real Halo over Bluetooth
LE, and switching between the two is one dependency block, no code changes.

The device runtime is the upstream
[`halo-emulator`](https://pypi.org/project/halo-emulator/) package (a real Lua
5.4 VM + the full `frame.*` API + a 256×256 framebuffer). This package adds the
wireless link, a REPL/message bridge, a desktop + web view, and optional bridges
from the PC's real **microphone / speaker / webcam** (including
acoustic-activity / voice detection).

Full docs, the Flutter-side setup and the media bridges:
**https://github.com/DaryeDev/halo-ws-simulator**

## Install

```bash
pip install halo-ws-simulator
```

Not on PyPI yet? `pip install "halo-ws-simulator[all] @ git+https://github.com/DaryeDev/halo-ws-simulator.git#subdirectory=python"`

Extras: `msg` (ship the `brilliant_msg` device libs for `--libs`), `media`
(mic / speaker / camera bridges — pulls `sounddevice`, `opencv-python-headless`,
`numpy`), or `all`:

```bash
pip install "halo-ws-simulator[all]"
```

On Linux, `sounddevice` needs PortAudio: `sudo apt install libportaudio2`.

## Run

```bash
halo-ws-sim                    # pygame window + web view on http://localhost:8766
halo-ws-sim --mic --speaker --camera
halo-ws-sim --headless -vv
```

It prints every URL a client can use on startup. The Flutter transport
auto-discovers it (Android emulator / `adb reverse` / localhost need no config).

## Point your Flutter app at it

```yaml
# pubspec.yaml — the only change vs. real hardware
dependencies:
  brilliant_sdk: ^2.0.0

dependency_overrides:
  brilliant_ble:
    git:
      url: https://github.com/DaryeDev/halo-ws-simulator.git
      path: flutter/brilliant_ble_ws
      ref: main
```

## Layout

| Module | Role |
|--------|------|
| `server.py` | WebSocket server, one connection = one session |
| `bridge.py` | owns the single Lua worker thread; TX ⇄ REPL / messages, media stubs |
| `protocol.py` | JSON envelope spec |
| `media.py` | PC microphone / speaker / webcam bridges + acoustic activity detection |
| `window.py` | pygame desktop view |
| `observe.py` | HTTP view + event injection + `/mic_level` on `port + 1` |

## Develop

```bash
git clone https://github.com/DaryeDev/halo-ws-simulator.git
cd halo-ws-simulator
pip install -e "python/[all]"
python -m halo_ws_sim --headless -vv
```

## Release to PyPI

```bash
cd python
python -m pip install --upgrade build twine
python -m build                 # -> dist/*.whl and dist/*.tar.gz
python -m twine check dist/*
python -m twine upload dist/*    # needs a PyPI API token
```

Bump `version` in `pyproject.toml` first, and tag the repo (`git tag vX.Y.Z`).
