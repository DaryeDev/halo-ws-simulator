import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'brilliant_bluetooth_exception.dart';
import 'brilliant_connection_state.dart';
import 'src/halo_sim_link.dart';

final _log = Logger('Bluetooth');

enum BrilliantDeviceType {
  frame,
  halo,
  unknown,
}

/// WebSocket-transport equivalent of the real `BrilliantDevice`.
///
/// The public API matches the real package: `sendString`, `sendData`,
/// `sendMessage`, `uploadScript`, `clearDisplay`, the `stringResponse` /
/// `dataResponse` / `connectionState` streams, break/reset signals, etc. Only
/// the bytes-on-the-wire layer differs (WebSocket frames instead of GATT
/// characteristic writes/notifications).
class BrilliantDevice {
  final HaloSimLink _link = HaloSimLink.instance;

  String id;
  String name;
  BrilliantConnectionState state;
  int? maxStringLength;
  int? maxDataLength;
  BrilliantDeviceType type;

  BrilliantDevice({
    required this.state,
    required this.id,
    this.name = 'Halo Sim',
    this.maxStringLength,
    this.maxDataLength,
    this.type = BrilliantDeviceType.unknown,
  });

  /// For `BrilliantBluetooth.reconnect(uuid)`.
  String get uuid => id;

  Stream<BrilliantDevice> get connectionState {
    return _link.connectionEvents.map((up) {
      if (up) {
        state = BrilliantConnectionState.connected;
      } else {
        state = BrilliantConnectionState.disconnected;
      }
      _log.info('Connection state stream: ${up ? "Connected" : "Disconnected"}');
      return this;
    });
  }

  /// String (stdout) responses: every RX notification whose first byte is not
  /// `0x01`. Lua error strings arrive here too, so this logs at info.
  Stream<String> get stringResponse {
    return _link.rx.where((event) => event.isNotEmpty && event[0] != 0x01).map(
      (event) {
        final s = utf8.decode(event, allowMalformed: true);
        if (event[0] != 0x02) {
          _log.info(() => 'Received string: $s');
        }
        return s;
      },
    );
  }

  /// Data responses: RX notifications with a leading `0x01` marker, stripped.
  Stream<List<int>> get dataResponse {
    return _link.rx.where((event) => event.isNotEmpty && event[0] == 0x01).map(
      (event) {
        _log.finest(() => 'Received data: ${event.sublist(1)}');
        return event.sublist(1);
      },
    );
  }

  Future<void> disconnect() async {
    _log.info('Disconnecting');
    try {
      await _link.closeSession();
    } catch (_) {}
    state = BrilliantConnectionState.disconnected;
  }

  Future<void> clearDisplay() async {
    _log.fine('Sending clearDisplay');
    if (type == BrilliantDeviceType.halo) {
      await sendString('frame.display.clear()print(1)',
          awaitResponse: true, log: false);
    } else {
      await sendString(
          'frame.display.bitmap(1,1,4,2,15,"\\xFF")frame.display.show()print(1)',
          awaitResponse: true,
          log: false);
    }
  }

  /// True when Lua is sitting in the REPL (a bare `print(1)` round-trips fast).
  Future<bool> isLuaInReplState(
      {Duration timeout = const Duration(milliseconds: 200)}) async {
    try {
      final response =
          await sendString('print(1)', awaitResponse: true, log: false);
      return response != null && response == '1';
    } on BrilliantBluetoothException catch (e) {
      if (e.msg == 'Timeout waiting for string response') {
        return false;
      }
      rethrow;
    }
  }

  /// Soak up any unsolicited stdout (e.g. a break/reset banner) until the
  /// channel is quiet, so the next awaited `sendString` gets a clean response.
  Future<void> drainPrintChannel({
    Duration quiet = const Duration(milliseconds: 250),
    Duration maxTotal = const Duration(milliseconds: 1500),
  }) async {
    final done = Completer<void>();
    Timer? quietTimer;
    void restartQuiet() {
      quietTimer?.cancel();
      quietTimer = Timer(quiet, () {
        if (!done.isCompleted) done.complete();
      });
    }

    final sub = stringResponse.listen((_) => restartQuiet());
    restartQuiet();
    final cap = Timer(maxTotal, () {
      if (!done.isCompleted) done.complete();
    });
    try {
      await done.future;
    } finally {
      quietTimer?.cancel();
      cap.cancel();
      await sub.cancel();
    }
  }

  Future<void> sendBreakSignal() async {
    _log.info('Sending break signal');
    await sendString('\x03', awaitResponse: false, log: false);
    await Future.delayed(const Duration(milliseconds: 200));
  }

  Future<void> sendResetSignal() async {
    _log.info('Sending reset signal');
    await sendString('\x04', awaitResponse: false, log: false);
    await Future.delayed(const Duration(milliseconds: 200));
  }

  Future<void> sendRemoveSignal() async {
    if (type == BrilliantDeviceType.halo) {
      _log.info('Sending remove signal');
      await sendString('\x05', awaitResponse: false, log: false);
    } else {
      _log.info('Remove signal is Halo-only');
    }
  }

  Future<String?> sendString(
    String string, {
    bool awaitResponse = true,
    bool log = true,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      if (log) {
        _log.info(() => 'Sending string: $string');
      }

      if (state != BrilliantConnectionState.connected) {
        throw const BrilliantBluetoothException('Device is not connected');
      }

      final data = utf8.encode(string);
      final maxLength = maxStringLength;
      if (maxLength == null || data.length > maxLength) {
        throw BrilliantBluetoothException(
            "Payload exceeds allowed length of ${maxLength ?? 'unknown'}");
      }

      Future<String>? responseFuture;
      if (awaitResponse) {
        responseFuture = _link.rx
            .timeout(timeout, onTimeout: (sink) {
              sink.addError(const BrilliantBluetoothException(
                  'Timeout waiting for string response'));
            })
            .firstWhere((e) => e.isEmpty || e[0] != 0x01)
            .then((e) => utf8.decode(e, allowMalformed: true));
      }

      _link.writeString(data);

      if (awaitResponse && responseFuture != null) {
        return await responseFuture;
      }
      return null;
    } catch (error) {
      _log.warning("Couldn't send string. $error");
      rethrow;
    }
  }

  Future<void> sendData(List<int> data,
      {bool awaitBtResponse = true,
      Duration timeout = const Duration(seconds: 5)}) async {
    final Uint8List byteData = Uint8List.fromList([0x01, ...data]);
    await _sendDataRawInternal(byteData,
        awaitAppResponse: true, validateHeader: true, timeout: timeout);
  }

  Future<void> sendAudio(Uint8List data) async {
    _link.writeAudio(data);
  }

  Future<void> sendDataRaw(Uint8List data,
      {bool awaitBtResponse = true,
      Duration timeout = const Duration(seconds: 5)}) async {
    await _sendDataRawInternal(data,
        awaitAppResponse: true, validateHeader: true, timeout: timeout);
  }

  Future<void> _sendDataRawInternal(
    Uint8List data, {
    bool awaitAppResponse = true,
    bool validateHeader = true,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      _log.finer(() => 'Sending ${data.length - 1} bytes of plain data');

      if (state != BrilliantConnectionState.connected) {
        throw ('Device is not connected');
      }
      if (data.length > maxDataLength! + 1) {
        throw ('Payload exceeds allowed length of ${maxDataLength! + 1}');
      }
      if (validateHeader && data[0] != 0x01) {
        throw ('Data packet missing 0x01 header');
      }

      if (awaitAppResponse) {
        final ack = dataResponse.timeout(timeout, onTimeout: (sink) {
          sink.addError(const BrilliantBluetoothException(
              'Timeout waiting for data response'));
        }).first;
        _link.writeData(data);
        await ack;
      } else {
        _link.writeData(data);
      }
    } catch (error) {
      _log.warning("Couldn't send data. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  /// Sends a typed message as one or more chunks marked
  /// `[0x01, msgCode & 0xFF, {first: length Uint16}, payload...]`, re-assembled
  /// device-side by `data.lua`. Payload must be <= 65535 bytes.
  Future<void> sendMessage(int msgCode, Uint8List payload,
      {bool awaitBtResponse = true}) async {
    if (payload.length > 65535) {
      return Future.error(const BrilliantBluetoothException(
          'Payload length exceeds 65535 bytes'));
    }

    final int lengthMsb = payload.length >> 8;
    final int lengthLsb = payload.length & 0xFF;
    int sentBytes = 0;
    bool firstPacket = true;
    int bytesRemaining = payload.length;
    final int chunksize = maxDataLength! - 1;

    final Uint8List packetBuffer = Uint8List(maxDataLength! + 1);
    Uint8List packetToSend = packetBuffer;
    _log.fine(() => 'sendMessage: payload size: ${payload.length}');

    while (sentBytes < payload.length) {
      if (firstPacket) {
        firstPacket = false;
        if (bytesRemaining < chunksize - 2) {
          packetBuffer[0] = 0x01;
          packetBuffer[1] = msgCode & 0xFF;
          packetBuffer[2] = lengthMsb;
          packetBuffer[3] = lengthLsb;
          packetBuffer.setAll(
              4, payload.getRange(sentBytes, sentBytes + bytesRemaining));
          sentBytes += bytesRemaining;
          packetToSend =
              Uint8List.sublistView(packetBuffer, 0, bytesRemaining + 4);
        } else if (bytesRemaining == chunksize - 2) {
          packetBuffer[0] = 0x01;
          packetBuffer[1] = msgCode & 0xFF;
          packetBuffer[2] = lengthMsb;
          packetBuffer[3] = lengthLsb;
          packetBuffer.setAll(
              4, payload.getRange(sentBytes, sentBytes + bytesRemaining));
          sentBytes += bytesRemaining;
          packetToSend = packetBuffer;
        } else {
          packetBuffer[0] = 0x01;
          packetBuffer[1] = msgCode & 0xFF;
          packetBuffer[2] = lengthMsb;
          packetBuffer[3] = lengthLsb;
          packetBuffer.setAll(
              4, payload.getRange(sentBytes, sentBytes + chunksize - 2));
          sentBytes += chunksize - 2;
          packetToSend = packetBuffer;
        }
      } else {
        if (bytesRemaining < chunksize) {
          packetBuffer[0] = 0x01;
          packetBuffer[1] = msgCode & 0xFF;
          packetBuffer.setAll(
              2, payload.getRange(sentBytes, sentBytes + bytesRemaining));
          sentBytes += bytesRemaining;
          packetToSend =
              Uint8List.sublistView(packetBuffer, 0, bytesRemaining + 2);
        } else {
          packetBuffer[0] = 0x01;
          packetBuffer[1] = msgCode & 0xFF;
          packetBuffer.setAll(
              2, payload.getRange(sentBytes, sentBytes + chunksize));
          sentBytes += chunksize;
          packetToSend = packetBuffer;
        }
      }

      await sendDataRaw(packetToSend, awaitBtResponse: awaitBtResponse);
      bytesRemaining = payload.length - sentBytes;
      _log.finer(() => 'Bytes remaining: $bytesRemaining');
    }
  }

  Future<void> uploadScript(String fileName, String fileContents) async {
    try {
      _log.info('Uploading script: $fileName');
      String file = fileContents;
      file = file.replaceAll('\\', '\\\\');
      file = file.replaceAll('\r\n', '\\n');
      file = file.replaceAll('\n', '\\n');
      file = file.replaceAll("'", "\\'");
      file = file.replaceAll('"', '\\"');

      var resp = await sendString('f=frame.file.open("$fileName", "w");print(2)',
          awaitResponse: true, log: false);
      if (resp != '2') {
        throw ('Error opening file: $resp');
      }

      for (final chunk
          in chunkLuaString(utf8.encode(file), maxStringLength! - 22)) {
        resp = await sendString("f:write('$chunk');print(2)",
            awaitResponse: true, log: false);
        if (resp != '2') {
          throw ('Error writing file: $resp');
        }
      }

      resp = await sendString('f:close();print(2)',
          awaitResponse: true, log: false);
      if (resp != '2') {
        throw ('Error closing file: $resp');
      }
    } catch (error) {
      _log.warning("Couldn't upload script. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }
}

/// Splits [payload] (UTF-8 bytes of an escaped Lua string literal) into chunks
/// of at most [maxChunkBytes] bytes without splitting a multi-byte UTF-8
/// sequence or a Lua escape sequence.
List<String> chunkLuaString(List<int> payload, int maxChunkBytes) {
  if (maxChunkBytes <= 0) {
    throw ArgumentError.value(maxChunkBytes, 'maxChunkBytes', 'must be positive');
  }

  final chunks = <String>[];
  int index = 0;

  while (index < payload.length) {
    int end = index + maxChunkBytes;
    if (end >= payload.length) {
      end = payload.length;
    } else {
      while (end > index && (payload[end] & 0xC0) == 0x80) {
        end--;
      }
      int trailingBackslashes = 0;
      while (end - 1 - trailingBackslashes >= index &&
          payload[end - 1 - trailingBackslashes] == 0x5C) {
        trailingBackslashes++;
      }
      if (trailingBackslashes.isOdd) {
        end--;
      }
      if (end == index) {
        throw ArgumentError.value(maxChunkBytes, 'maxChunkBytes',
            'too small to hold the next character of the payload');
      }
    }
    chunks.add(utf8.decode(payload.sublist(index, end)));
    index = end;
  }
  return chunks;
}
