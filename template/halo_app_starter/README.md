# halo_app_starter

The smallest useful Halo app: connect, type text, show it on the display.
Use it as the starting point for your own app.

## Use it

```bash
cp -r template/halo_app_starter ~/my_halo_app        # copy out of this repo
cd ~/my_halo_app
flutter create --platforms=android --org com.example .
```

Then add cleartext WebSockets to `android/app/src/main/AndroidManifest.xml`
(needed for `ws://`), on the `<application>` tag:

```xml
<application android:usesCleartextTraffic="true" ... >
```

```bash
flutter pub get
flutter run          # simulator auto-discovered (emulator / adb-reverse / localhost)
```

## The switch

`pubspec.yaml` has one block:

```yaml
dependency_overrides:
  brilliant_ble:
    git:
      url: https://github.com/DaryeDev/halo-ws-simulator.git
      path: flutter/brilliant_ble_ws
      ref: main
```

Keep it → the app connects to `halo-ws-sim` on your PC.
Delete it → the app connects to real Halo glasses over Bluetooth LE.
Either way, **nothing in `lib/` changes**.

## Simulator

```bash
pip install halo-ws-simulator
halo-ws-sim
```

See the [main README](../../README.md) for connection details (Wi-Fi vs USB vs
emulator) and the microphone / speaker / camera bridges.
