// Copyright 2026 Alexei Zalogin. Use of this source code is governed by the MIT license in the LICENSE file.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:serial_port_core/serial_port_core.dart';

import 'bluetooth_device.dart';
import 'messages.g.dart';

/// How to secure the RFCOMM link.
enum BluetoothSecurity {
  /// Secure first, then insecure: what works with most devices.
  auto,

  /// Encrypted and authenticated; the device must be paired, and Android
  /// pairs on the first connect if it is not.
  secure,

  /// No encryption or pairing; for devices that refuse a secure link.
  insecure,
}

/// Bluetooth Classic serial ports (SPP over RFCOMM) on Android: paired
/// devices, scanning, pairing, and ports that read and write.
///
/// ```dart
/// final bt = BluetoothSerial.instance;
/// await bt.requestPermissions();
/// final device = (await bt.bondedDevices()).firstWhere((d) => d.name == 'HC-05');
/// final port = await bt.open(device.address);
/// port.lines().listen(print);
/// await port.writeText('hello\n');
/// ```
class BluetoothSerial {
  BluetoothSerial._(this._host) : _listensToPlatform = true;

  /// Uses [host] instead of the platform, and does not listen to the
  /// platform: tests deliver its calls through [platformCallbacks].
  @visibleForTesting
  BluetoothSerial.withHostApi(BluetoothSerialHostApi host)
      : _host = host,
        _listensToPlatform = false;

  static BluetoothSerial? _instance;

  /// The one instance for the app.
  static BluetoothSerial get instance =>
      _instance ??= BluetoothSerial._(BluetoothSerialHostApi());

  /// Whether the plugin works here: on Android only.
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// The Serial Port Profile service, what HC-05, ESP32's BluetoothSerial,
  /// ELM327 and printers offer.
  static const sppUuid = '00001101-0000-1000-8000-00805F9B34FB';

  final BluetoothSerialHostApi _host;
  final Map<int, BluetoothSerialPort> _ports = {};
  late final _adapterStates = StreamController<BluetoothAdapterState>.broadcast(
      onListen: _listenToPlatform);
  late final _bondChanges = StreamController<BluetoothSerialDevice>.broadcast(
      onListen: _listenToPlatform);
  StreamController<BluetoothSerialDevice>? _scan;
  Future<void>? _ready;

  // The platform's calls are handled from the first use on, not from
  // construction: `BluetoothSerial.instance` may be read in main() before
  // runApp, when there is no binary messenger yet.
  final bool _listensToPlatform;
  bool _listening = false;

  void _listenToPlatform() {
    if (!_listensToPlatform || _listening) return;
    BluetoothSerialFlutterApi.setUp(platformCallbacks);
    _listening = true;
  }

  /// The receiving end of the platform's calls, for tests.
  @visibleForTesting
  late final BluetoothSerialFlutterApi platformCallbacks = _Callbacks(this);

  /// Whether the phone has Bluetooth Classic at all.
  Future<bool> isAvailable() => _call(_host.isAvailable);

  /// Whether Bluetooth is on now.
  Future<BluetoothAdapterState> getAdapterState() async =>
      _adapterState(await _call(_host.adapterState));

  /// Bluetooth turned on and off while the app runs. When it goes off, the
  /// open ports are closed with [SerialError.adapterOff].
  Stream<BluetoothAdapterState> get adapterStateChanges =>
      _adapterStates.stream;

  /// Asks the user to turn Bluetooth on with the system dialog, unless it is
  /// on, and completes with whether it is on. Needs the permissions of
  /// [requestPermissions] on Android 12+.
  Future<bool> requestEnable() => _call(_host.requestEnable);

  /// Whether the app may use paired devices and connect, and with [scan]
  /// also find new devices.
  Future<bool> hasPermissions({bool scan = false}) =>
      _call(() => _host.hasPermissions(scan));

  /// Asks for what [hasPermissions] checks, with the system dialog, and
  /// completes with the answer.
  ///
  /// Android 12+ asks for "nearby devices". Android 11 and older need
  /// nothing to connect, but finding devices needs the location permission
  /// and location turned on.
  Future<bool> requestPermissions({bool scan = false}) =>
      _call(() => _host.requestPermissions(scan));

  /// The devices paired with the phone, in Android's settings or with
  /// [bond]. Not all of them have a serial port.
  Future<List<BluetoothSerialDevice>> bondedDevices() async {
    final devices = await _call(_host.bondedDevices);
    return devices.map(_toDevice).toList();
  }

  /// Scans for devices nearby: the scan starts when you listen and stops
  /// when you cancel, or after about 12 seconds, when the stream ends.
  ///
  /// A device can come more than once, as its name or signal strength
  /// becomes known. Needs [requestPermissions] with `scan: true`. A new
  /// scan ends the stream of the previous one.
  Stream<BluetoothSerialDevice> discover() {
    late final StreamController<BluetoothSerialDevice> controller;
    controller = StreamController<BluetoothSerialDevice>(
      onListen: () async {
        final previous = _scan;
        _scan = controller;
        if (previous != null && !previous.isClosed) await previous.close();
        try {
          await _call(_host.startDiscovery);
        } on SerialException catch (e) {
          if (_scan == controller) _scan = null;
          controller
            ..addError(e)
            ..close();
        }
      },
      onCancel: () async {
        if (_scan != controller) return;
        _scan = null;
        try {
          await _call(_host.cancelDiscovery);
        } on SerialException {
          // The scan ends anyway.
        }
      },
    );
    return controller.stream;
  }

  /// Pairs with the device at [address]; the system shows its dialog (with
  /// a PIN field for devices that have one, 1234 or 0000 for HC-05).
  /// Completes with whether the device is paired.
  Future<bool> bond(String address) => _call(() => _host.bond(address));

  /// Pairing started, finished or was removed, here or in the settings.
  Stream<BluetoothSerialDevice> get bondStateChanges => _bondChanges.stream;

  /// Connects to the serial port of the device at [address].
  ///
  /// [uuid] picks the service; the default is the serial port profile.
  /// [security] picks the kind of link; [BluetoothSecurity.auto] tries a
  /// secure one and then an insecure one. [channel] connects to that RFCOMM
  /// channel and skips the service lookup, for devices that do not
  /// advertise the service (many ELM327 clones listen on channel 1).
  /// [timeout] covers all the tries.
  ///
  /// Asks for permission first if the app has none, unless
  /// [requestPermission] is false.
  ///
  /// Throws [SerialException]: [SerialError.permissionDenied],
  /// [SerialError.adapterOff], [SerialError.invalidArgument],
  /// [SerialError.busy] (already connected), [SerialError.notPaired],
  /// [SerialError.connectionFailed] (off, out of range, no such service, or
  /// connected to someone else), [SerialError.timeout].
  Future<BluetoothSerialPort> open(
    String address, {
    String uuid = sppUuid,
    BluetoothSecurity security = BluetoothSecurity.auto,
    int? channel,
    Duration timeout = const Duration(seconds: 15),
    bool requestPermission = true,
  }) async {
    if (timeout <= Duration.zero) {
      throw SerialException(
          SerialError.invalidArgument, 'The timeout must be positive');
    }
    if (requestPermission && !await hasPermissions()) {
      if (!await requestPermissions()) {
        throw const SerialException(SerialError.permissionDenied,
            'No permission to connect to Bluetooth devices');
      }
    }
    final request = NativeOpenRequest(
      address: address,
      uuid: uuid,
      security: NativeSecurity.values[security.index],
      channel: channel,
      timeoutMs: timeout.inMilliseconds,
    );
    final result = await _call(() => _host.open(request));
    final port =
        BluetoothSerialPort._(this, result.portId, address, result.secure);
    _ports[result.portId] = port;
    return port;
  }

  /// Calls the platform and turns its errors into [SerialException].
  ///
  /// The first call closes ports left open by an earlier run of the Dart
  /// code (a hot restart keeps the native side running).
  Future<T> _call<T>(Future<T> Function() call) async {
    if (!isSupported) {
      throw const SerialException(SerialError.unsupportedOperation,
          'bluetooth_serial_next works on Android only');
    }
    _listenToPlatform();
    try {
      final ready = _ready ??= _host.reset();
      try {
        await ready;
      } catch (_) {
        _ready = null;
        rethrow;
      }
      return await call();
    } on PlatformException catch (e) {
      throw SerialException.fromCode(e.code, e.message, e.details);
    }
  }

  static BluetoothSerialDevice _toDevice(NativeBluetoothDevice d) =>
      BluetoothSerialDevice(
        address: d.address,
        name: d.name,
        bondState: BluetoothBondState.values[d.bondState.index],
        type: BluetoothDeviceType.values[d.type.index],
        deviceClass: d.deviceClass,
        rssi: d.rssi,
      );

  static BluetoothAdapterState _adapterState(NativeAdapterState s) =>
      BluetoothAdapterState.values[s.index];
}

/// A connection to a device's serial port. Get one from
/// [BluetoothSerial.open].
class BluetoothSerialPort implements SerialPort {
  BluetoothSerialPort._(this._owner, this._id, this.address, this.isSecure);

  final BluetoothSerial _owner;
  final int _id;

  /// The device's address, as passed to [BluetoothSerial.open].
  final String address;

  /// Whether the link is encrypted and authenticated, which
  /// [BluetoothSecurity.auto] does not tell in advance.
  final bool isSecure;

  SerialException? _closeReason;
  final _input = StreamController<Uint8List>();
  final _closed = Completer<SerialException?>();

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  bool get isOpen => !_closed.isCompleted;

  @override
  Future<SerialException?> get closed => _closed.future;

  /// Sends [data]. Fails with [SerialError.timeout] if it takes longer than
  /// [timeout]; the default allows 10 KB/s plus two seconds.
  /// [Duration.zero] waits forever.
  @override
  Future<void> write(List<int> data, {Duration? timeout}) async {
    _checkOpen();
    if (data.isEmpty) return;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final limit = timeout ??
        Duration(milliseconds: 2000 + bytes.length ~/ _defaultBytesPerMs);
    await _owner
        ._call(() => _owner._host.write(_id, bytes, limit.inMilliseconds));
  }

  static const _defaultBytesPerMs = 10;

  @override
  Future<void> close() async {
    if (!isOpen) return;
    _markClosed(null);
    await _owner._call(() => _owner._host.close(_id));
  }

  void _checkOpen() {
    if (!isOpen) {
      throw _closeReason ??
          const SerialException(SerialError.portClosed, 'The port is closed');
    }
  }

  void _onData(Uint8List data) {
    if (isOpen) _input.add(data);
  }

  void _markClosed(SerialException? reason) {
    if (!isOpen) return;
    _closeReason = reason;
    _owner._ports.remove(_id);
    if (reason != null) _input.addError(reason);
    _input.close();
    _closed.complete(reason);
  }

  @override
  String toString() => 'BluetoothSerialPort($address, '
      '${isSecure ? 'secure' : 'insecure'}${isOpen ? '' : ', closed'})';
}

class _Callbacks implements BluetoothSerialFlutterApi {
  _Callbacks(this._owner);

  final BluetoothSerial _owner;

  @override
  void onData(int portId, Uint8List data) =>
      _owner._ports[portId]?._onData(data);

  @override
  void onPortClosed(int portId, String? errorCode, String? errorMessage) =>
      _owner._ports[portId]?._markClosed(errorCode == null
          ? null
          : SerialException.fromCode(errorCode, errorMessage));

  @override
  void onAdapterStateChanged(NativeAdapterState state) =>
      _owner._adapterStates.add(BluetoothSerial._adapterState(state));

  @override
  void onDeviceFound(NativeBluetoothDevice device) {
    final scan = _owner._scan;
    if (scan != null && !scan.isClosed) {
      scan.add(BluetoothSerial._toDevice(device));
    }
  }

  @override
  void onDiscoveryFinished() {
    final scan = _owner._scan;
    _owner._scan = null;
    scan?.close();
  }

  @override
  void onBondStateChanged(NativeBluetoothDevice device) =>
      _owner._bondChanges.add(BluetoothSerial._toDevice(device));
}
