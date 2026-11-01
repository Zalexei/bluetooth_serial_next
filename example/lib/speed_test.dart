import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_serial_next/bluetooth_serial_next.dart';

/// Measures throughput against tool/esp32_spp_echo: "burst N" for reading,
/// "sink N" for writing. While a test runs, the terminal hands it every
/// received chunk through [add].
class SpeedTest {
  SpeedTest(this.port);

  final SerialPort port;

  _Phase? _phase;

  void add(Uint8List data) => _phase?.add(data);

  /// Asks the device for [bytes] letters A..Z and checks every one arrived
  /// in order.
  Future<String> read(int bytes) async {
    final phase = _phase = _Phase('burst done', checkPattern: true);
    await port.writeText('burst $bytes\n');
    await phase.done.future.timeout(const Duration(seconds: 60));
    _phase = null;
    final seconds =
        phase.lastData!.difference(phase.firstData!).inMicroseconds / 1e6;
    final lost = bytes - phase.payload;
    return 'Read ${_kb(phase.payload)} in ${seconds.toStringAsFixed(2)} s: '
        '${_rate(phase.payload, seconds)}, '
        '${lost == 0 && phase.wrong == 0 ? 'no bytes lost' : '$lost lost, ${phase.wrong} out of order'}';
  }

  /// Sends [bytes] in writes of [chunk] bytes; the device counts them.
  Future<String> write(int bytes, {int chunk = 4096}) async {
    final phase = _phase = _Phase('sink done', checkPattern: false);
    await port.writeText('sink $bytes\n');
    final data = Uint8List.fromList(List.generate(chunk, (i) => 0x41 + i % 26));
    final watch = Stopwatch()..start();
    for (var sent = 0; sent < bytes; sent += chunk) {
      final n = bytes - sent < chunk ? bytes - sent : chunk;
      await port.write(n == chunk ? data : Uint8List.sublistView(data, 0, n));
    }
    final seconds = watch.elapsedMicroseconds / 1e6;
    await phase.done.future.timeout(const Duration(seconds: 60));
    _phase = null;
    // "sink done <got> in <ms> ms"
    final match = RegExp(r'sink done (\d+)').firstMatch(phase.tail);
    final got = int.tryParse(match?.group(1) ?? '') ?? -1;
    return 'Wrote ${_kb(bytes)} in ${seconds.toStringAsFixed(2)} s: '
        '${_rate(bytes, seconds)}, device got $got';
  }

  static String _kb(int bytes) => '${(bytes / 1024).round()} KB';

  static String _rate(int bytes, double seconds) =>
      '${(bytes / 1024 / seconds).round()} KB/s';
}

class _Phase {
  _Phase(this.marker, {required this.checkPattern});

  final String marker;
  final bool checkPattern;
  final done = Completer<void>();
  DateTime? firstData;
  DateTime? lastData;

  /// Letters before the closing line, and how many were not the expected one.
  int payload = 0;
  int wrong = 0;
  bool _payloadEnded = false;
  String tail = '';

  void add(Uint8List data) {
    final now = DateTime.now();
    firstData ??= now;
    for (final byte in data) {
      if (checkPattern && !_payloadEnded) {
        if (byte == 0x0a) {
          _payloadEnded = true;
          lastData = now;
        } else {
          if (byte != 0x41 + payload % 26) wrong++;
          payload++;
        }
      }
    }
    final text = String.fromCharCodes(
      data.length > 64 ? data.sublist(data.length - 64) : data,
    );
    tail = (tail + text);
    if (tail.length > 128) tail = tail.substring(tail.length - 128);
    if (tail.contains(marker) && tail.endsWith('\n') && !done.isCompleted) {
      lastData ??= now;
      done.complete();
    }
  }
}
