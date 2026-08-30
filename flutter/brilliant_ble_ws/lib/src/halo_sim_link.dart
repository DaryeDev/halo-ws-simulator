import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../brilliant_bluetooth_exception.dart';

final _log = Logger('HaloSimLink');

/// Where the Halo WS simulator is reachable.
///
/// If nothing is configured, [candidates] are probed in order and the first one
/// that answers the `hello` handshake wins — which covers the common setups
/// with **zero configuration**:
///
/// * Android emulator            → `ws://10.0.2.2:8765`
/// * USB device + `adb reverse`  → `ws://127.0.0.1:8765`
/// * desktop / web               → `ws://localhost:8765`
///
/// Only a phone reaching the PC **over Wi-Fi** needs an explicit address (the
/// simulator prints its LAN URLs on startup):
///
/// ```
/// flutter run --dart-define=HALO_SIM_URL=ws://192.168.1.20:8765
/// ```
///
/// `HALO_SIM_URL` may also be a comma-separated list. At runtime, set
/// [HaloSimConfig.urls] before connecting.
class HaloSimConfig {
  HaloSimConfig._();

  static const String _fromEnv =
      String.fromEnvironment('HALO_SIM_URL', defaultValue: '');

  /// Ordered list of URLs to probe. Defaults to `HALO_SIM_URL` (which may be a
  /// comma-separated list) or, when that is empty, the standard candidates.
  static List<String> urls = _fromEnv.isEmpty
      ? const [
          'ws://10.0.2.2:8765',
          'ws://127.0.0.1:8765',
          'ws://localhost:8765',
        ]
      : _fromEnv.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

  /// Back-compat single-URL setter/getter (maps to the head of [urls]).
  static String get url => urls.isEmpty ? '' : urls.first;
  static set url(String value) => urls = [value];

  /// Per-candidate probe budget (socket open + `hello` round-trip).
  static Duration probeTimeout = const Duration(seconds: 2);
  static Duration handshakeTimeout = const Duration(seconds: 5);
}

/// Identity + characteristic sizes reported by the simulator in its `device`
/// frame — the WebSocket equivalent of reading the GATT service.
class SimDeviceInfo {
  final String id;
  final String name;
  final String deviceType; // "halo" | "frame"
  final String firmware;
  final int maxStringLength;
  final int maxDataLength;

  SimDeviceInfo({
    required this.id,
    required this.name,
    required this.deviceType,
    required this.firmware,
    required this.maxStringLength,
    required this.maxDataLength,
  });

  factory SimDeviceInfo.fromJson(Map<String, dynamic> m) => SimDeviceInfo(
        id: m['id'] as String? ?? 'halo-sim',
        name: m['name'] as String? ?? 'Halo Sim',
        deviceType: m['deviceType'] as String? ?? 'halo',
        firmware: m['firmware'] as String? ?? 'unknown',
        maxStringLength: m['maxStringLength'] as int? ?? 240,
        maxDataLength: m['maxDataLength'] as int? ?? 239,
      );
}

/// Single shared WebSocket to the simulator. Stands in for the BLE GATT link:
/// [rx] replaces the RX characteristic's notification stream, and
/// [writeString] / [writeData] / [writeAudio] replace TX characteristic writes.
class HaloSimLink {
  HaloSimLink._();
  static final HaloSimLink instance = HaloSimLink._();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;

  final StreamController<Uint8List> _rx = StreamController<Uint8List>.broadcast();
  final StreamController<bool> _conn = StreamController<bool>.broadcast();

  Completer<SimDeviceInfo>? _discoverCompleter;
  Completer<void>? _readyCompleter;

  SimDeviceInfo? info;
  bool _sessionOpen = false;

  /// RX characteristic notifications. First byte `0x01` => data response,
  /// otherwise a stdout/string response (Lua `print()` output, errors).
  Stream<Uint8List> get rx => _rx.stream;

  /// `true` when a session opens, `false` when the link drops or closes.
  Stream<bool> get connectionEvents => _conn.stream;

  bool get isSessionOpen => _sessionOpen;

  // ---------------------------------------------------------------- handshake

  /// The URL the live socket is connected to (after a successful [discover]).
  String? connectedUrl;

  /// Open a socket to the first reachable candidate and read its identity.
  Future<SimDeviceInfo> discover() async {
    if (_channel != null && info != null) return info!;

    final tried = <String>[];
    Object? lastError;
    for (final url in HaloSimConfig.urls) {
      tried.add(url);
      try {
        final probed = await _probe(url);
        connectedUrl = url;
        _log.info('simulator at $url (${probed.name})');
        return probed;
      } catch (e) {
        lastError = e;
        _log.fine('no simulator at $url: $e');
      }
    }
    throw BrilliantBluetoothException(
        'No Halo simulator answered on any of: ${tried.join(", ")}. '
        'Is halo-ws-sim running? (last error: $lastError)');
  }

  /// Open [url], run the `hello` handshake, and on success keep the socket as
  /// the live link. On any failure the socket is closed and the error rethrown.
  Future<SimDeviceInfo> _probe(String url) async {
    final ch = WebSocketChannel.connect(Uri.parse(url));
    final c = Completer<SimDeviceInfo>();
    _discoverCompleter = c;
    try {
      await ch.ready.timeout(HaloSimConfig.probeTimeout);
      _channel = ch;
      _sub = ch.stream.listen(
        _onFrame,
        onDone: _onSocketClosed,
        onError: (Object e) {
          _log.warning('socket error: $e');
          _onSocketClosed();
        },
        cancelOnError: true,
      );
      _send({'t': 'hello'});
      return await c.future.timeout(HaloSimConfig.probeTimeout);
    } catch (e) {
      _discoverCompleter = null;
      await _sub?.cancel();
      _sub = null;
      _channel = null;
      try {
        await ch.sink.close();
      } catch (_) {}
      rethrow;
    }
  }

  /// Open a session (GATT connect + enable notifications equivalent).
  Future<SimDeviceInfo> openSession() async {
    final discovered = info ?? await discover();
    final c = _readyCompleter = Completer<void>();
    _send({'t': 'connect'});
    await c.future.timeout(
      HaloSimConfig.handshakeTimeout,
      onTimeout: () => throw const BrilliantBluetoothException(
          'Simulator did not answer "connect"'),
    );
    _sessionOpen = true;
    _conn.add(true);
    return discovered;
  }

  Future<void> closeSession() async {
    _send({'t': 'disconnect'});
    _sessionOpen = false;
    _conn.add(false);
    await _teardown();
  }

  // ---------------------------------------------------------------- TX writes

  void writeString(List<int> bytes) =>
      _send({'t': 'tx', 'kind': 'string', 'b64': base64Encode(bytes)});

  void writeData(List<int> bytes) =>
      _send({'t': 'tx', 'kind': 'data', 'b64': base64Encode(bytes)});

  void writeAudio(List<int> bytes) =>
      _send({'t': 'tx', 'kind': 'audio', 'b64': base64Encode(bytes)});

  /// Simulator-only: inject a hardware event (`button_single`, `button_double`,
  /// `button_long`, or `tap` with arg `'single'|'double'|'triple'`).
  void inject(String event, [Object? arg]) =>
      _send({'t': 'inject', 'event': event, if (arg != null) 'arg': arg});

  // ---------------------------------------------------------------- internals

  void _onFrame(dynamic raw) {
    late final Map<String, dynamic> m;
    try {
      m = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      _log.warning('dropping non-JSON frame');
      return;
    }
    switch (m['t']) {
      case 'device':
        final parsed = SimDeviceInfo.fromJson(m);
        info = parsed;
        _discoverCompleter?.complete(parsed);
        _discoverCompleter = null;
        break;
      case 'ready':
        _readyCompleter?.complete();
        _readyCompleter = null;
        break;
      case 'rx':
        _rx.add(base64Decode(m['b64'] as String));
        break;
      case 'log':
        _log.fine('[sim] ${m['level']}: ${m['msg']}');
        break;
      default:
        _log.fine('unknown frame: ${m['t']}');
    }
  }

  void _onSocketClosed() {
    _log.info('simulator link closed');
    _sessionOpen = false;
    if (!_conn.isClosed) _conn.add(false);
    final d = _discoverCompleter;
    if (d != null && !d.isCompleted) {
      d.completeError(
          const BrilliantBluetoothException('Simulator link closed'));
    }
    _discoverCompleter = null;
    _readyCompleter = null;
    _channel = null;
    _sub = null;
    info = null;
    connectedUrl = null;
  }

  Future<void> _teardown() async {
    await _sub?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _sub = null;
    info = null;
    connectedUrl = null;
  }

  void _send(Map<String, dynamic> m) {
    final ch = _channel;
    if (ch == null) {
      throw const BrilliantBluetoothException('Simulator link is not open');
    }
    ch.sink.add(jsonEncode(m));
  }
}
