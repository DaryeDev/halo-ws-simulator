/// WebSocket-transport build of `brilliant_ble` for the Halo WS simulator.
///
/// Exposes the exact same surface as the real package
/// (`BrilliantBluetooth`, `BrilliantDevice`, `BrilliantScannedDevice`,
/// `BrilliantConnectionState`, `BrilliantBluetoothException`), so switching is
/// purely a `dependency_overrides` change — no import or code changes.
library brilliant_ble;

export 'brilliant_bluetooth.dart';
export 'brilliant_bluetooth_exception.dart';
export 'brilliant_connection_state.dart';
export 'brilliant_device.dart';
export 'brilliant_scanned_device.dart';
export 'src/halo_sim_link.dart' show HaloSimLink, HaloSimConfig, SimDeviceInfo;
