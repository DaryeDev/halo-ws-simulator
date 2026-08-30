# halo_demo_app

A demo Halo app: connect, push text to the display (`TxPlainText`), count IMU
taps (`RxTap`). **The same code runs against real glasses or the WebSocket
simulator** — the only difference is the `dependency_overrides` block in
[`pubspec.yaml`](pubspec.yaml).

Nothing in `lib/` is simulator-aware. For a minimal starting point for your own
app, use [`template/halo_app_starter`](../../template/halo_app_starter/) instead.

## Run

```bash
cd example/halo_demo_app
flutter pub get
```

The `android/` scaffolding is committed (with `android:usesCleartextTraffic="true"`,
needed for `ws://`).

```bash
# simulator on the PC
( cd ../../python && pip install -e ".[msg]" && python -m halo_ws_sim --libs data,plain_text,code,tap )

# app — auto-discovers the simulator (emulator / adb-reverse / localhost)
flutter run
#   USB device first needs:  adb reverse tcp:8765 tcp:8765
#   phone over Wi-Fi:        flutter run --dart-define=HALO_SIM_URL=ws://<PC-LAN-IP>:8765
```

The app **auto-connects on launch** (`--dart-define=HALO_AUTOCONNECT=false` to
disable). Watch the display in the pygame window or at `http://localhost:8766`,
and inject taps there — the app's counter updates.

## Real hardware

Delete the `dependency_overrides` block in `pubspec.yaml`, `flutter pub get`,
grant Bluetooth + location permissions, `flutter run`.

## What it exercises

| SDK surface | Used for |
|-------------|----------|
| `BrilliantBluetooth.scan/connect` | discovery + connection |
| `device.sendBreakSignal` / `drainPrintChannel` | stop any running Lua, clean the channel |
| `device.uploadScript` | push `data.min.lua`, `plain_text.min.lua`, `code.min.lua`, `tap.min.lua`, `frame_app.lua` |
| `device.sendString('require("frame_app")')` | start the device-side loop |
| `device.sendMessage` + `TxPlainText` / `TxCode` | show text, subscribe to taps |
| `RxTap().attach(device.dataResponse)` | receive tap events |
| `device.connectionState` | react to disconnects |
