import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:logging/logging.dart';

import 'package:brilliant_sdk/brilliant_sdk.dart';

// NOTE: there is nothing simulator-specific in this file. The same code runs
// against real Halo glasses; only `pubspec.yaml`'s dependency_overrides block
// decides which transport `brilliant_ble` resolves to.

void main() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) {
    // ignore: avoid_print
    print('${r.level.name.padRight(7)} ${r.loggerName}: ${r.message}');
  });
  runApp(const HaloDemoApp());
}

class HaloDemoApp extends StatelessWidget {
  const HaloDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Halo Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

/// Device-side msg codes shared with `assets/lua/frame_app.lua`.
const int kTextMsg = 0x0a;
const int kCaptureMsg = 0x0d;
const int kMicMsg = 0x0e;
const int kSpeakerMsg = 0x0f;
const int kTapSubsMsg = 0x10;

/// The standard brilliant_msg device libs this demo uploads, plus the app.
const List<String> kLuaLibs = [
  'data.min.lua',
  'plain_text.min.lua',
  'code.min.lua',
  'tap.min.lua',
  'camera.min.lua',
  'audio.min.lua',
];

enum Phase { idle, connecting, uploading, starting, ready, error }

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  BrilliantDevice? _device;
  StreamSubscription<int>? _tapSub;
  StreamSubscription<BrilliantDevice>? _connSub;

  Phase _phase = Phase.idle;
  String? _error;
  int _taps = 0;
  bool _busy = false; // a photo/mic/beep round-trip is in flight
  Uint8List? _photo;
  String? _micResult;
  final List<String> _log = [];
  final TextEditingController _text =
      TextEditingController(text: 'Hello\nHalo!');

  /// Auto-connect on launch (handy when developing against the simulator).
  /// Pass --dart-define=HALO_AUTOCONNECT=false to disable.
  static const bool _autoConnect =
      bool.fromEnvironment('HALO_AUTOCONNECT', defaultValue: true);

  @override
  void initState() {
    super.initState();
    if (_autoConnect) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
    }
  }

  void _addLog(String s) {
    setState(() {
      _log.insert(0, s);
      if (_log.length > 200) _log.removeLast();
    });
  }

  Future<void> _connect() async {
    setState(() {
      _phase = Phase.connecting;
      _error = null;
      _taps = 0;
    });
    try {
      _addLog('requesting permission…');
      await BrilliantBluetooth.requestPermission();

      _addLog('scanning…');
      final scanned = await BrilliantBluetooth.scan().first;
      _addLog('found ${scanned.name}');

      final device = await BrilliantBluetooth.connect(scanned);
      _device = device;
      _addLog('connected: ${device.type.name}, '
          'maxStr=${device.maxStringLength}');

      _connSub = device.connectionState.listen((d) {
        if (d.state == BrilliantConnectionState.disconnected) {
          _addLog('device disconnected');
          if (mounted) setState(() => _phase = Phase.idle);
        }
      });

      await device.sendBreakSignal();
      await device.drainPrintChannel();

      setState(() => _phase = Phase.uploading);
      for (final lib in kLuaLibs) {
        _addLog('upload $lib');
        await device.uploadScript(lib, await rootBundle.loadString('assets/lua/$lib'));
      }
      _addLog('upload frame_app.lua');
      await device.uploadScript(
          'frame_app.lua', await rootBundle.loadString('assets/lua/frame_app.lua'));

      setState(() => _phase = Phase.starting);
      _tapSub = RxTap().attach(device.dataResponse).listen((n) {
        setState(() => _taps += n);
        _addLog('tap ($n) → total $_taps');
      });

      // Start the device-side loop. Canonical start call (see
      // simple_brilliant_app): the app prints "0" once its callbacks are set,
      // which comes back as this sendString's response.
      final started = await device
          .sendString('require("frame_app")', awaitResponse: true)
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
      _addLog('frame app running (ack: ${started ?? "timeout"})');

      // Subscribe to taps device-side.
      await device.sendMessage(kTapSubsMsg, TxCode(value: 1).pack());

      setState(() => _phase = Phase.ready);
      await _sendText();
    } catch (e) {
      _addLog('ERROR: $e');
      setState(() {
        _phase = Phase.error;
        _error = '$e';
      });
    }
  }

  Future<void> _sendText() async {
    final device = _device;
    if (device == null || _phase != Phase.ready) return;
    final t = _text.text;
    _addLog('send text: ${t.replaceAll("\n", "⏎")}');
    await device.sendMessage(kTextMsg, TxPlainText(text: t).pack());
  }

  Future<void> _guard(String label, Future<void> Function() body) async {
    if (_device == null || _phase != Phase.ready || _busy) return;
    setState(() => _busy = true);
    _addLog('$label…');
    try {
      await body();
    } catch (e) {
      _addLog('$label failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Camera: request a photo, receive the JPEG via RxPhoto, show it.
  Future<void> _takePhoto() => _guard('photo', () async {
        final device = _device!;
        const q = 'MEDIUM', res = 256;
        final photo = RxPhoto(quality: q, resolution: res)
            .attach(device.dataResponse)
            .first
            .timeout(const Duration(seconds: 8));
        await device.sendMessage(
          kCaptureMsg,
          TxCaptureSettings(resolution: res, qualityIndex: 2).pack(),
        );
        final jpeg = await photo;
        _addLog('photo: ${jpeg.length} B JPEG');
        setState(() => _photo = jpeg);
      });

  /// Microphone: ask the device to record ~2 s and stream it back.
  Future<void> _record() => _guard('record 2s', () async {
        final device = _device!;
        final clip = RxAudio()
            .attach(device.dataResponse)
            .first
            .timeout(const Duration(seconds: 6));
        await device.sendMessage(kMicMsg, TxCode(value: 1).pack());
        final pcm = await clip;
        final rms = _rms16(pcm);
        _addLog('mic: ${pcm.length} B PCM (${(pcm.length / 2 / 16000).toStringAsFixed(2)} s), rms ${rms.toStringAsFixed(0)}');
        setState(() => _micResult =
            '${(pcm.length / 2 / 16000).toStringAsFixed(2)} s · ${pcm.length} B · level ${rms.toStringAsFixed(0)}');
      });

  /// Speaker: send a short tone for the device to play on the PC speakers.
  Future<void> _beep() => _guard('beep', () async {
        final device = _device!;
        await device.sendMessage(kSpeakerMsg, _sinePcm16(440, 0.3, 16000));
        _addLog('beep sent (440 Hz, 0.3 s)');
      });

  static double _rms16(Uint8List pcm) {
    final s = pcm.buffer.asInt16List();
    if (s.isEmpty) return 0;
    var acc = 0.0;
    for (final v in s) {
      acc += v * v;
    }
    return math.sqrt(acc / s.length);
  }

  static Uint8List _sinePcm16(double hz, double seconds, int rate) {
    final n = (seconds * rate).round();
    final out = Int16List(n);
    for (var i = 0; i < n; i++) {
      out[i] = (math.sin(2 * math.pi * hz * i / rate) * 12000).round();
    }
    return out.buffer.asUint8List();
  }

  Future<void> _disconnect() async {
    await _tapSub?.cancel();
    await _connSub?.cancel();
    _tapSub = null;
    _connSub = null;
    try {
      await _device?.sendBreakSignal();
    } catch (_) {}
    await _device?.disconnect();
    _device = null;
    setState(() {
      _phase = Phase.idle;
      _taps = 0;
    });
    _addLog('disconnected');
  }

  @override
  void dispose() {
    _tapSub?.cancel();
    _connSub?.cancel();
    _device?.disconnect();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _phase == Phase.ready ||
        _phase == Phase.uploading ||
        _phase == Phase.starting;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Halo Demo'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: Text(_phase.name)),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (_phase == Phase.connecting ||
                            _phase == Phase.uploading ||
                            _phase == Phase.starting)
                        ? null
                        : (connected ? _disconnect : _connect),
                    icon: Icon(connected ? Icons.link_off : Icons.link),
                    label: Text(connected ? 'Disconnect' : 'Connect'),
                  ),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.red, fontSize: 12)),
              ),
            const SizedBox(height: 16),
            TextField(
              controller: _text,
              maxLines: 3,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Text to show on the Halo display',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _phase == Phase.ready ? _sendText : null,
                    icon: const Icon(Icons.send),
                    label: const Text('Show on display'),
                  ),
                ),
                const SizedBox(width: 12),
                Chip(
                  avatar: const Icon(Icons.touch_app, size: 18),
                  label: Text('taps: $_taps'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Inject taps / button presses from the simulator window '
              '(keys T / 2 / 3 / SPACE) or http://localhost:8766.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: (_phase == Phase.ready && !_busy) ? _takePhoto : null,
                  icon: const Icon(Icons.photo_camera, size: 18),
                  label: const Text('Take photo'),
                ),
                OutlinedButton.icon(
                  onPressed: (_phase == Phase.ready && !_busy) ? _record : null,
                  icon: const Icon(Icons.mic, size: 18),
                  label: const Text('Record 2s'),
                ),
                OutlinedButton.icon(
                  onPressed: (_phase == Phase.ready && !_busy) ? _beep : null,
                  icon: const Icon(Icons.volume_up, size: 18),
                  label: const Text('Beep'),
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.all(6),
                    child: SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
              ],
            ),
            if (_photo != null || _micResult != null) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_photo != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(_photo!, width: 120, height: 120, fit: BoxFit.cover),
                    ),
                  if (_micResult != null)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 12, top: 4),
                        child: Text('mic clip:\n$_micResult',
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                      ),
                    ),
                ],
              ),
            ],
            const Divider(height: 32),
            const Text('Log', style: TextStyle(fontWeight: FontWeight.bold)),
            Expanded(
              child: Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  itemCount: _log.length,
                  itemBuilder: (_, i) => Text(
                    _log[i],
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 11.5),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
