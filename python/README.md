# halo-ws-simulator (Python package)

The simulator itself — a WebSocket server that stands in for a Halo's BLE link,
wrapping the upstream [`halo-emulator`](https://pypi.org/project/halo-emulator/)
runtime.

```bash
pip install halo-ws-simulator          # + [msg] for --libs, [media] for mic/cam/speaker, [all] for both
halo-ws-sim
```

Full usage, the `dependency_overrides` setup for your Flutter app, and the
microphone / speaker / camera bridges are documented in the
**[repository README](../README.md)**.

## Layout

| Module | Role |
|--------|------|
| `server.py` | WebSocket server, one connection = one session |
| `bridge.py` | owns the single Lua worker thread; TX ⇄ REPL / messages, media stubs |
| `protocol.py` | JSON envelope spec |
| `media.py` | PC microphone / speaker / webcam bridges (`[media]` extra) |
| `window.py` | pygame desktop view |
| `observe.py` | HTTP view + event injection on `port + 1` |

## Dev

```bash
pip install -e "python/[all]"
python -m halo_ws_sim --headless -vv
```
