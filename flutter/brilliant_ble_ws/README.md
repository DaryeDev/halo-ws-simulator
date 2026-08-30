# brilliant_ble (WebSocket build)

A **drop-in replacement for `brilliant_ble`** that talks to
[`halo-ws-simulator`](../../README.md) over a WebSocket instead of Bluetooth LE.

It declares `name: brilliant_ble` and exposes the identical public surface —
`BrilliantBluetooth`, `BrilliantDevice`, `BrilliantScannedDevice`,
`BrilliantConnectionState`, `BrilliantDeviceType`, `BrilliantBluetoothException` —
so you select it with **`dependency_overrides` only**. No import or code changes.

## Use it

```yaml
# your app's pubspec.yaml
dependencies:
  brilliant_sdk: ^2.0.0

dependency_overrides:
  # delete this block for real Halo hardware
  brilliant_ble:
    git:
      url: https://github.com/DaryeDev/halo-ws-simulator.git
      path: flutter/brilliant_ble_ws
      ref: main            # pin a tag once releases exist
```

`flutter pub get`, then `flutter run`. Nothing else changes.

## Configuration

The transport **auto-discovers** the simulator by probing, in order:
`ws://10.0.2.2:8765` (Android emulator), `ws://127.0.0.1:8765` (USB +
`adb reverse`), `ws://localhost:8765` (desktop/web).

Override for Wi-Fi (the simulator prints its LAN URLs on startup):

```bash
flutter run --dart-define=HALO_SIM_URL=ws://192.168.1.16:8765
```

`HALO_SIM_URL` may be a comma-separated list. At runtime, set
`HaloSimConfig.urls` before connecting.

Android: `ws://` is cleartext — the app needs
`android:usesCleartextTraffic="true"` in `AndroidManifest.xml`.

## Mapping to the real transport

| Real `brilliant_ble` | Here |
|----------------------|------|
| GATT scan / connect | probe candidates, `hello` / `connect` handshake |
| TX characteristic write (string / data) | `{t:tx, kind:string|data}` frame |
| RX characteristic notification | `{t:rx}` frame |
| `sendMessage` MTU chunking | unchanged — re-assembled device-side by `data.lua` |
| DFU / OTA (`BrilliantDfuDevice`) | not implemented |
| `BrilliantScannedDevice.device` (flutter_blue_plus handle) | not present — the documented SDK flow never touches it |

## License

BSD-3-Clause — derived from `brilliant_ble` (© 2025 CitizenOneX). See `LICENSE`.
