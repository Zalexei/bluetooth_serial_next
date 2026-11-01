import 'dart:async';

import 'package:bluetooth_serial_next/bluetooth_serial_next.dart';
import 'package:flutter/material.dart';

import 'terminal_page.dart';

/// Paired devices and, after a scan, the ones nearby. Tap one to connect.
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key, required this.bt});

  final BluetoothSerial bt;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  BluetoothSerial get _bt => widget.bt;

  var _loading = true;
  var _permitted = false;
  BluetoothAdapterState? _adapter;
  List<BluetoothSerialDevice> _bonded = const [];
  final _found = <String, BluetoothSerialDevice>{};
  StreamSubscription<BluetoothSerialDevice>? _scan;
  final _subscriptions = <StreamSubscription<Object>>[];
  String? _connecting;
  Object? _error;

  @override
  void initState() {
    super.initState();
    if (!BluetoothSerial.isSupported) return;
    _subscriptions
      ..add(_bt.adapterStateChanges.listen((_) => _refresh()))
      ..add(_bt.bondStateChanges.listen((_) => _refresh()));
    _refresh();
  }

  @override
  void dispose() {
    _scan?.cancel();
    for (final s in _subscriptions) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final adapter = await _bt.getAdapterState();
      final permitted = await _bt.hasPermissions();
      final bonded = permitted && adapter == BluetoothAdapterState.on
          ? await _bt.bondedDevices()
          : const <BluetoothSerialDevice>[];
      if (!mounted) return;
      setState(() {
        _adapter = adapter;
        _permitted = permitted;
        _bonded = bonded;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _askPermissions() async {
    await _bt.requestPermissions();
    await _refresh();
  }

  Future<void> _turnOn() async {
    try {
      await _bt.requestEnable();
    } on SerialException catch (e) {
      _snack('Bluetooth: ${e.message}');
    }
    await _refresh();
  }

  Future<void> _toggleScan() async {
    if (_scan != null) {
      await _scan?.cancel();
      setState(() => _scan = null);
      return;
    }
    if (!await _bt.hasPermissions(scan: true) &&
        !await _bt.requestPermissions(scan: true)) {
      _snack('Scanning needs the nearby devices permission');
      return;
    }
    setState(() {
      _found.clear();
      _scan = _bt.discover().listen(
        (d) => setState(() => _found[d.address] = d),
        onError: (Object e) => _snack('Scan: $e'),
        onDone: () => setState(() => _scan = null),
      );
    });
  }

  Future<void> _connect(
    BluetoothSerialDevice device, {
    BluetoothSecurity security = BluetoothSecurity.auto,
    int? channel,
  }) async {
    setState(() => _connecting = device.address);
    try {
      final port = await _bt.open(
        device.address,
        security: security,
        channel: channel,
      );
      if (!mounted) {
        await port.close();
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TerminalPage(port: port, name: device.name),
        ),
      );
      await port.close();
    } on SerialException catch (e) {
      _snack('Could not connect: ${e.error.name}\n${e.message ?? ''}');
    } finally {
      if (mounted) setState(() => _connecting = null);
      await _refresh();
    }
  }

  Future<void> _showOptions(BluetoothSerialDevice device) async {
    final choice = await showModalBottomSheet<_Option>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(device.name ?? device.address),
              subtitle: Text(device.toString()),
            ),
            for (final option in _Option.values)
              if (option != _Option.pair || !device.isBonded)
                ListTile(
                  leading: Icon(option.icon),
                  title: Text(option.label),
                  onTap: () => Navigator.of(context).pop(option),
                ),
          ],
        ),
      ),
    );
    switch (choice) {
      case null:
        return;
      case _Option.pair:
        try {
          final paired = await _bt.bond(device.address);
          _snack(paired ? 'Paired' : 'Not paired');
        } on SerialException catch (e) {
          _snack('Pairing: ${e.message}');
        }
        await _refresh();
      case _Option.secure:
        await _connect(device, security: BluetoothSecurity.secure);
      case _Option.insecure:
        await _connect(device, security: BluetoothSecurity.insecure);
      case _Option.channel1:
        await _connect(device, channel: 1);
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final ready = _permitted && _adapter == BluetoothAdapterState.on;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bluetooth serial'),
        actions: [
          if (ready)
            IconButton(
              tooltip: _scan == null ? 'Scan' : 'Stop scan',
              icon: Icon(_scan == null ? Icons.radar : Icons.stop_circle),
              onPressed: _toggleScan,
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
        bottom: _scan == null
            ? null
            : const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(),
              ),
      ),
      body: _body(ready),
    );
  }

  Widget _body(bool ready) {
    if (!BluetoothSerial.isSupported) {
      return const _Message(
        icon: Icons.phone_android,
        text: 'bluetooth_serial_next works on Android only.',
      );
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _Message(icon: Icons.error_outline, text: 'Error: $_error');
    }
    if (!_permitted) {
      return _Message(
        icon: Icons.bluetooth_disabled,
        text: 'The app needs the nearby devices permission.',
        action: FilledButton(
          onPressed: _askPermissions,
          child: const Text('Allow'),
        ),
      );
    }
    if (_adapter != BluetoothAdapterState.on) {
      return _Message(
        icon: Icons.bluetooth_disabled,
        text: 'Bluetooth is off.',
        action: FilledButton(onPressed: _turnOn, child: const Text('Turn on')),
      );
    }
    final bondedAddresses = {for (final d in _bonded) d.address};
    final found = _found.values.where(
      (d) => !bondedAddresses.contains(d.address),
    );
    return ListView(
      children: [
        const _Header('Paired'),
        if (_bonded.isEmpty)
          const ListTile(
            title: Text('No paired devices'),
            subtitle: Text('Scan, or pair in the Bluetooth settings.'),
          ),
        for (final d in _bonded) _tile(d),
        if (_scan != null || _found.isNotEmpty) ...[
          const _Header('Nearby'),
          if (found.isEmpty)
            ListTile(
              title: Text(_scan == null ? 'Nothing new found' : 'Scanning…'),
            ),
          for (final d in found) _tile(d),
        ],
      ],
    );
  }

  Widget _tile(BluetoothSerialDevice d) {
    final connecting = _connecting == d.address;
    return ListTile(
      leading: Icon(
        d.mayHaveSerialPort ? Icons.settings_input_antenna : Icons.bluetooth,
      ),
      title: Text(d.name ?? 'Unnamed device'),
      subtitle: Text(
        '${d.address}  ${d.type.name}'
        '${d.rssi == null ? '' : '  ${d.rssi} dBm'}',
      ),
      trailing: connecting
          ? const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              tooltip: 'Options',
              icon: const Icon(Icons.more_vert),
              onPressed: _connecting == null ? () => _showOptions(d) : null,
            ),
      onTap: _connecting == null ? () => _connect(d) : null,
    );
  }
}

enum _Option {
  pair('Pair', Icons.link),
  secure('Connect, secure only', Icons.lock),
  insecure('Connect, insecure only', Icons.lock_open),
  channel1('Connect to channel 1 (ELM327)', Icons.numbers);

  const _Option(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48),
          const SizedBox(height: 16),
          Text(text, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    ),
  );
}
