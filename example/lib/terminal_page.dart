import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:bluetooth_serial_next/bluetooth_serial_next.dart';

import 'bytes_format.dart';
import 'speed_test.dart';

enum _Direction { rx, tx, info }

class _Entry {
  _Entry(this.direction, this.time, [List<int> bytes = const [], this.note])
    : bytes = [...bytes];

  final _Direction direction;
  final DateTime time;
  final List<int> bytes;
  final String? note;
}

enum _LineEnding {
  none(''),
  lf('\n'),
  cr('\r'),
  crlf('\r\n');

  const _LineEnding(this.chars);
  final String chars;
}

/// Received and sent data of one open port, as text or hex.
class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, required this.port, this.name});

  final BluetoothSerialPort port;

  /// The device's name, for the title.
  final String? name;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  static const _maxEntries = 2000;

  final _entries = <_Entry>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<Uint8List>? _subscription;
  var _showHex = false;
  var _sendHex = false;
  var _lineEnding = _LineEnding.lf;
  var _received = 0;
  var _sent = 0;
  SerialException? _closedBy;
  SpeedTest? _speedTest;

  BluetoothSerialPort get _port => widget.port;

  @override
  void initState() {
    super.initState();
    _add(
      _Entry(
        _Direction.info,
        DateTime.now(),
        const [],
        'Connected, ${_port.isSecure ? 'secure' : 'insecure'} link',
      ),
    );
    _subscription = _port.input.listen(
      _onData,
      onError: (Object e) => setState(() {
        _closedBy = e is SerialException ? e : null;
        _add(
          _Entry(
            _Direction.info,
            DateTime.now(),
            const [],
            e is SerialException && e.error == SerialError.disconnected
                ? 'Connection lost'
                : 'Error: $e',
          ),
        );
      }),
      onDone: () => setState(() {}),
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onData(Uint8List data) {
    final test = _speedTest;
    if (test != null) {
      // No rebuild per chunk while measuring.
      _received += data.length;
      test.add(data);
      return;
    }
    setState(() {
      _received += data.length;
      final last = _entries.isEmpty ? null : _entries.last;
      // Join chunks of one message: a device's line often arrives in pieces.
      if (last != null &&
          last.direction == _Direction.rx &&
          last.bytes.length < 1024 &&
          !last.bytes.endsWith(0x0a)) {
        last.bytes.addAll(data);
      } else {
        _add(_Entry(_Direction.rx, DateTime.now(), data));
      }
    });
    _scrollToEnd();
  }

  void _add(_Entry entry) {
    _entries.add(entry);
    if (_entries.length > _maxEntries) _entries.removeAt(0);
  }

  Future<void> _send() async {
    final text = _input.text;
    final Uint8List bytes;
    if (_sendHex) {
      final parsed = parseHex(text);
      if (parsed == null) {
        _snack('Not hex: use pairs like "41 42 0D 0A"');
        return;
      }
      bytes = parsed;
    } else {
      bytes = Uint8List.fromList(utf8.encode(text + _lineEnding.chars));
    }
    if (bytes.isEmpty) return;
    try {
      await _port.write(bytes);
      setState(() {
        _sent += bytes.length;
        _add(_Entry(_Direction.tx, DateTime.now(), bytes));
      });
      _input.clear();
      _scrollToEnd();
    } on SerialException catch (e) {
      _snack('Send failed: ${e.error.name} ${e.message ?? ''}');
    }
  }

  Future<void> _runSpeedTest() async {
    final test = _speedTest = SpeedTest(_port);
    void note(String text) => setState(
      () => _add(_Entry(_Direction.info, DateTime.now(), const [], text)),
    );
    note('Speed test with tool/esp32_spp_echo, 256 KB each way');
    try {
      for (final run in [() => test.read(1 << 18), () => test.write(1 << 18)]) {
        final result = await run();
        debugPrint('bluetooth_serial_next speed: $result');
        note(result);
      }
    } catch (e) {
      note('Speed test failed: $e');
    } finally {
      _speedTest = null;
      setState(() {});
      _scrollToEnd();
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final open = _port.isOpen;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.name ?? _port.address),
            Text(
              '${_port.address}  ↓$_received ↑$_sent',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _showHex ? 'Show text' : 'Show hex',
            icon: Icon(_showHex ? Icons.text_fields : Icons.hexagon_outlined),
            onPressed: () => setState(() => _showHex = !_showHex),
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => setState(_entries.clear),
          ),
          PopupMenuButton<String>(
            enabled: open,
            onSelected: (_) => _runSpeedTest(),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'speed',
                enabled: _speedTest == null,
                child: const Text('Speed test (esp32_spp_echo)'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (!open)
            MaterialBanner(
              content: Text(switch (_closedBy?.error) {
                SerialError.disconnected =>
                  'The connection was lost: out of range or switched off.',
                SerialError.adapterOff => 'Bluetooth was turned off.',
                _ => 'The port is closed.',
              }),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Back'),
                ),
              ],
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(8),
              itemCount: _entries.length,
              itemBuilder: (context, i) => _EntryView(_entries[i], _showHex),
            ),
          ),
          const Divider(height: 1),
          _composer(open),
        ],
      ),
    );
  }

  Widget _composer(bool open) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Column(
          children: [
            Row(
              children: [
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('Text')),
                    ButtonSegment(value: true, label: Text('Hex')),
                  ],
                  selected: {_sendHex},
                  onSelectionChanged: (v) =>
                      setState(() => _sendHex = v.single),
                ),
                const Spacer(),
                if (!_sendHex)
                  DropdownButton<_LineEnding>(
                    value: _lineEnding,
                    items: const [
                      DropdownMenuItem(
                        value: _LineEnding.none,
                        child: Text('No ending'),
                      ),
                      DropdownMenuItem(
                        value: _LineEnding.lf,
                        child: Text(r'\n'),
                      ),
                      DropdownMenuItem(
                        value: _LineEnding.cr,
                        child: Text(r'\r'),
                      ),
                      DropdownMenuItem(
                        value: _LineEnding.crlf,
                        child: Text(r'\r\n'),
                      ),
                    ],
                    onChanged: (v) => setState(() => _lineEnding = v!),
                  ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    enabled: open,
                    decoration: InputDecoration(
                      hintText: _sendHex ? '41 42 0D 0A' : 'Message',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                IconButton(
                  tooltip: 'Send',
                  icon: const Icon(Icons.send),
                  onPressed: open ? _send : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryView extends StatelessWidget {
  const _EntryView(this.entry, this.hex);

  final _Entry entry;
  final bool hex;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (prefix, color) = switch (entry.direction) {
      _Direction.rx => ('←', scheme.onSurface),
      _Direction.tx => ('→', scheme.primary),
      _Direction.info => ('•', scheme.outline),
    };
    final t = entry.time;
    final time = '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
    final body =
        entry.note ?? (hex ? toHex(entry.bytes) : toVisibleText(entry.bytes));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: SelectableText(
        '$time $prefix $body',
        style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: color),
      ),
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}

extension on List<int> {
  bool endsWith(int byte) => isNotEmpty && last == byte;
}
