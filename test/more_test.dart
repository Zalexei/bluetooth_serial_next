import 'dart:async';

import 'package:bluetooth_serial_next/bluetooth_serial_next.dart';
import 'package:bluetooth_serial_next/src/messages.g.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_host_api.dart';

Matcher throwsSerialError(SerialError error) => throwsA(
      isA<SerialException>().having((e) => e.error, 'error', error),
    );

const _esp32 = '94:3C:C6:8C:2F:B6';

class _FailingReset extends FakeHostApi {
  int failures = 1;

  @override
  Future<void> reset() async {
    if (failures-- > 0) {
      throw PlatformException(code: 'io_error', message: 'not attached');
    }
    return super.reset();
  }
}

void main() {
  late FakeHostApi host;
  late BluetoothSerial bt;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    host = FakeHostApi();
    bt = BluetoothSerial.withHostApi(host);
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  NativeBluetoothDevice found(String address) => NativeBluetoothDevice(
        address: address,
        bondState: NativeBondState.none,
        type: NativeDeviceType.classic,
      );

  group('adapter and permissions', () {
    test('getAdapterState converts the state', () async {
      host.state = NativeAdapterState.turningOff;
      expect(await bt.getAdapterState(), BluetoothAdapterState.turningOff);
      expect(await bt.isAvailable(), isTrue);
    });

    test('requestEnable passes the answer on', () async {
      host.state = NativeAdapterState.off;
      expect(await bt.requestEnable(), isTrue);
      expect(host.calls, contains('requestEnable'));
    });

    test('the scan permission is asked for separately', () async {
      host.permitted = true;
      expect(await bt.hasPermissions(), isTrue);
      expect(await bt.hasPermissions(scan: true), isFalse);

      expect(await bt.requestPermissions(scan: true), isTrue);

      expect(host.calls, contains('requestPermissions(true)'));
      expect(await bt.hasPermissions(scan: true), isTrue);
    });

    test('a failed reset is reported and tried again by the next call',
        () async {
      final failing = _FailingReset();
      final bt = BluetoothSerial.withHostApi(failing);

      await expectLater(bt.isAvailable(), throwsSerialError(SerialError.io));
      expect(await bt.isAvailable(), isTrue);
      expect(failing.calls, ['reset']);
    });
  });

  group('discover', () {
    test('a new scan starts although the previous listener is paused',
        () async {
      final first = bt.discover().listen((_) {});
      await pumpEventQueue();
      first.pause();

      final second = <BluetoothSerialDevice>[];
      bt.discover().listen(second.add);
      await pumpEventQueue();

      expect(host.calls.where((c) => c == 'startDiscovery'), hasLength(2));
      bt.platformCallbacks.onDeviceFound(found(_esp32));
      await pumpEventQueue();
      expect(second, hasLength(1));
      await first.cancel();
      expect(host.calls, isNot(contains('cancelDiscovery')),
          reason: 'the first scan is over; cancelling it must not stop '
              'the second');
    });

    test('cancelling right after listening leaves no scan running', () async {
      final first = bt.discover().listen((_) {});
      await pumpEventQueue();
      final second = bt.discover().listen((_) {});
      await second.cancel();
      await pumpEventQueue();

      expect(host.calls.last, 'cancelDiscovery');
      await first.cancel();
    });

    test('devices found when nobody scans are dropped', () async {
      bt.platformCallbacks
        ..onDeviceFound(found(_esp32))
        ..onDiscoveryFinished();
      final devices = <BluetoothSerialDevice>[];
      final subscription = bt.discover().listen(devices.add);
      await pumpEventQueue();

      expect(devices, isEmpty);
      await subscription.cancel();
    });
  });

  group('open', () {
    test('does not ask for permission when told not to', () async {
      host.openError = PlatformException(code: 'permission_denied');

      await expectLater(bt.open(_esp32, requestPermission: false),
          throwsSerialError(SerialError.permissionDenied));

      expect(host.calls, isNot(contains('requestPermissions(false)')));
      expect(host.calls, contains('open($_esp32)'));
    });

    test('says whether the link is secure', () async {
      host
        ..permitted = true
        ..openSecure = false;
      final port = await bt.open(_esp32);

      expect(port.isSecure, isFalse);
      expect(port.address, _esp32);
      expect(port.toString(), 'BluetoothSerialPort($_esp32, insecure)');
      await port.close();
      expect(port.toString(), 'BluetoothSerialPort($_esp32, insecure, closed)');
    });

    test('two ports get their own data', () async {
      host.permitted = true;
      final a = await bt.open(_esp32);
      final b = await bt.open('00:11:22:33:44:55');
      final ids = host.openPorts.keys.toList();

      bt.platformCallbacks
        ..onData(ids[1], Uint8List.fromList([2]))
        ..onData(ids[0], Uint8List.fromList([1]));

      expect(await a.input.first, [1]);
      expect(await b.input.first, [2]);
    });
  });

  group('port', () {
    late BluetoothSerialPort port;
    late int id;

    setUp(() async {
      host.permitted = true;
      port = await bt.open(_esp32);
      id = host.openPorts.keys.single;
    });

    test('writing after the link was lost fails with the reason', () async {
      bt.platformCallbacks.onPortClosed(id, 'disconnected', 'gone');

      await expectLater(
          port.write([1]), throwsSerialError(SerialError.disconnected));
      expect(port.isOpen, isFalse);
      port.input.listen((_) {}, onError: (_) {});
    });

    test('writing after close fails with portClosed', () async {
      await port.close();

      await expectLater(
          port.write([1]), throwsSerialError(SerialError.portClosed));
      expect(host.written, isEmpty);
    });

    test('an explicit timeout is passed on, zero waits forever', () async {
      await port.write([1], timeout: const Duration(milliseconds: 250));
      expect(host.writeTimeouts[id], 250);

      await port.write([1], timeout: Duration.zero);
      expect(host.writeTimeouts[id], 0);
    });

    test('a list that is not a Uint8List is sent as bytes', () async {
      await port.write(const [0x41, 0x42]);

      expect(host.written[id]!.single, isA<Uint8List>());
      expect(host.written[id]!.single, [0x41, 0x42]);
    });

    test('data and a second close notice after closing are ignored', () async {
      final received = <Uint8List>[];
      final done = Completer<void>();
      port.input.listen(received.add, onDone: done.complete);
      await port.close();

      bt.platformCallbacks
        ..onData(id, Uint8List.fromList([1]))
        ..onPortClosed(id, 'io_error', 'late')
        ..onData(99, Uint8List.fromList([1]))
        ..onPortClosed(99, null, null);
      await done.future;

      expect(received, isEmpty);
      expect(await port.closed, isNull);
    });

    test('the other side closing without an error ends the input quietly',
        () async {
      final done = Completer<void>();
      port.input.listen((_) {}, onDone: done.complete);

      bt.platformCallbacks.onPortClosed(id, null, null);
      await done.future;

      expect(await port.closed, isNull);
      expect(port.isOpen, isFalse);
    });
  });

  group('BluetoothSerialDevice', () {
    const device = BluetoothSerialDevice(
      address: _esp32,
      name: 'ESP32',
      bondState: BluetoothBondState.bonded,
      type: BluetoothDeviceType.dual,
      deviceClass: 0x1f04,
      rssi: -40,
    );

    test('equal when every field is equal', () {
      const same = BluetoothSerialDevice(
        address: _esp32,
        name: 'ESP32',
        bondState: BluetoothBondState.bonded,
        type: BluetoothDeviceType.dual,
        deviceClass: 0x1f04,
        rssi: -40,
      );
      expect(device, same);
      expect(device.hashCode, same.hashCode);
      expect(device, isNot(const BluetoothSerialDevice(address: _esp32)));
    });

    test('majorClass, isBonded and mayHaveSerialPort', () {
      expect(device.majorClass, 0x1f00);
      expect(device.isBonded, isTrue);
      expect(device.mayHaveSerialPort, isTrue);

      const le =
          BluetoothSerialDevice(address: _esp32, type: BluetoothDeviceType.le);
      expect(le.majorClass, isNull);
      expect(le.isBonded, isFalse);
      expect(le.mayHaveSerialPort, isFalse);
    });

    test('toString names what is known', () {
      expect(device.toString(),
          'BluetoothSerialDevice($_esp32 "ESP32", bonded, dual, -40 dBm)');
      expect(const BluetoothSerialDevice(address: _esp32).toString(),
          'BluetoothSerialDevice($_esp32, none, unknown)');
    });
  });
}
