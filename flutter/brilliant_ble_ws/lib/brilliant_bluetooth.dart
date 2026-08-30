import 'dart:async';

import 'package:logging/logging.dart';

import 'brilliant_bluetooth_exception.dart';
import 'brilliant_connection_state.dart';
import 'brilliant_device.dart';
import 'brilliant_scanned_device.dart';
import 'src/halo_sim_link.dart';

final _log = Logger('Bluetooth');

/// WebSocket-transport equivalent of the real `BrilliantBluetooth`.
///
/// "Scanning" opens the socket to the simulator and reads its identity;
/// "connecting" opens a session. There is only ever one simulated device.
class BrilliantBluetooth {
  /// No BLE adapter is involved — nothing to request.
  static Future<void> requestPermission() async {}

  static Stream<BrilliantScannedDevice> scan() async* {
    try {
      final info = await HaloSimLink.instance.discover();
      _log.info('Found simulated device ${info.name} (${info.id})');
      yield BrilliantScannedDevice(id: info.id, name: info.name, rssi: -40);
    } catch (error) {
      _log.warning('Scanning failed. $error');
      throw BrilliantBluetoothException(error.toString());
    }
  }

  static Future<void> stopScan() async {}

  static Future<BrilliantDevice> connect(BrilliantScannedDevice scanned) async {
    try {
      _log.info('Connecting');
      final info = await HaloSimLink.instance.openSession();
      return BrilliantDevice(
        state: BrilliantConnectionState.connected,
        id: info.id,
        name: info.name,
        type: info.deviceType == 'frame'
            ? BrilliantDeviceType.frame
            : BrilliantDeviceType.halo,
        maxStringLength: info.maxStringLength,
        maxDataLength: info.maxDataLength,
      );
    } catch (error) {
      await HaloSimLink.instance.closeSession();
      _log.warning("Couldn't connect. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  /// Re-open a session. [uuid] is accepted for API compatibility; there is only
  /// one simulated device so it is not used for selection.
  static Future<BrilliantDevice> reconnect(String uuid) async {
    _log.info('Will re-connect to simulated device: $uuid');
    return connect(BrilliantScannedDevice(id: uuid, name: 'Halo Sim', rssi: -40));
  }

  /// No OS-held connections exist for the simulator.
  static Future<List<Object>> getSystemConnectedDevices() async => const [];

  static Future<Object?> getSystemConnectedDevice(String uuid) async => null;
}
