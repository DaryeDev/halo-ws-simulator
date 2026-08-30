/// A "scanned" simulated Halo. Mirrors the real `BrilliantScannedDevice` for
/// the fields application code actually touches; the real one wraps a
/// `flutter_blue_plus` `BluetoothDevice`, which has no meaning over WebSocket.
class BrilliantScannedDevice {
  /// Stable identifier reported by the simulator (used for `reconnect`).
  final String id;

  /// Advertised name, e.g. "Halo Sim 01".
  final String name;

  /// Faked signal strength so UIs that show it keep working.
  final int? rssi;

  BrilliantScannedDevice({
    required this.id,
    required this.name,
    this.rssi,
  });

  @override
  String toString() => 'BrilliantScannedDevice($name, $id)';
}
