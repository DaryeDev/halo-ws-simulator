import 'dart:async';

import 'package:flutter/material.dart';
import 'package:brilliant_sdk/brilliant_sdk.dart';

// The same code runs against real Halo glasses or the WebSocket simulator.
// Nothing here is simulator-aware — see pubspec.yaml's dependency_overrides.

void main() => runApp(const StarterApp());

class StarterApp extends StatelessWidget {
  const StarterApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Halo Starter',
        theme: ThemeData(useMaterial3: true),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  BrilliantDevice? _halo;
  String _status = 'disconnected';
  final _text = TextEditingController(text: 'Hello, Halo!');

  Future<void> _connect() async {
    setState(() => _status = 'connecting…');
    try {
      await BrilliantBluetooth.requestPermission();
      final scanned = await BrilliantBluetooth.scan().first;
      final halo = await BrilliantBluetooth.connect(scanned);
      await halo.sendBreakSignal();
      setState(() {
        _halo = halo;
        _status = 'connected (${halo.type.name})';
      });
    } catch (e) {
      setState(() => _status = 'error: $e');
    }
  }

  Future<void> _show() async {
    final halo = _halo;
    if (halo == null) return;
    final t = _text.text.replaceAll("'", r"\'").replaceAll('\n', ' ');
    // Drive the display straight from the REPL — no device-side app needed.
    await halo.sendString(
      "frame.display.clear(0) "
      "frame.display.text('$t', 10, 110, 0xFFFFFF) "
      "frame.display.show()",
      awaitResponse: false,
    );
  }

  @override
  void dispose() {
    _halo?.disconnect();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _halo != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Halo Starter')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_status),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: connected ? null : _connect,
              child: const Text('Connect'),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _text,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Text',
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: connected ? _show : null,
              child: const Text('Show on display'),
            ),
          ],
        ),
      ),
    );
  }
}
