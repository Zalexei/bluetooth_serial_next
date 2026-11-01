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

void main() {
  late FakeHostApi host;
  late BluetoothSerial bt;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    host = FakeHostApi();
    bt = BluetoothSerial.withHostApi(host);
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  NativeBluetoothDevice found(String address, {String? name, int? rssi}) =>
      NativeBluetoothDevice(
        address: address,
        name: name,
        bondState: NativeBondState.none,
        type: NativeDeviceType.classic,
        rssi: rssi,
      );

  group('devices', () {
    test('the first call resets the native side once', () async {
      await bt.isAvailable();
      await bt.getAdapterState();

      expect(host.calls.where((c) => c == 'reset'), hasLength(1));
    });

    test('bondedDevices converts every field', () async {
      host.pair(_esp32, name: 'SPP echo');

      final device = (await bt.bondedDevices()).single;

      expect(device.address, _esp32);
      expect(device.name, 'SPP echo');
      expect(device.isBonded, isTrue);
      expect(device.type, BluetoothDeviceType.classic);
      expect(device.majorClass, 0x1f00);
      expect(device.mayHaveSerialPort, isTrue);
      expect(
        device,
        const BluetoothSerialDevice(
          address: _esp32,
          name: 'SPP echo',
          bondState: BluetoothBondState.bonded,
          type: BluetoothDeviceType.classic,
          deviceClass: 0x1f00,
        ),
      );
    });

    test('adapter and bond changes arrive as streams', () async {
      final states = <BluetoothAdapterState>[];
      final bonds = <BluetoothSerialDevice>[];
      bt.adapterStateChanges.listen(states.add);
      bt.bondStateChanges.listen(bonds.add);

      bt.platformCallbacks
        ..onAdapterStateChanged(NativeAdapterState.turningOff)
        ..onAdapterStateChanged(NativeAdapterState.off)
        ..onBondStateChanged(found(_esp32));
      await pumpEventQueue();

      expect(states,
          [BluetoothAdapterState.turningOff, BluetoothAdapterState.off]);
      expect(bonds.single.address, _esp32);
    });

    test('bond passes the answer on', () async {
      expect(await bt.bond(_esp32), isTrue);
      host.bondAnswer = false;
      expect(await bt.bond(_esp32), isFalse);
    });
  });

  group('discover', () {
    test('starts on listen and ends when the scan finishes', () async {
      final devices = <BluetoothSerialDevice>[];
      final done = Completer<void>();
      bt.discover().listen(devices.add, onDone: done.complete);
      await pumpEventQueue();

      expect(host.calls, contains('startDiscovery'));
      bt.platformCallbacks
        ..onDeviceFound(found('00:11:22:33:44:55', rssi: -60))
        ..onDeviceFound(found('00:11:22:33:44:55', name: 'HC-05', rssi: -58))
        ..onDiscoveryFinished();
      await done.future;

      expect(devices.map((d) => d.name), [null, 'HC-05']);
      expect(devices.last.rssi, -58);
      expect(host.calls, isNot(contains('cancelDiscovery')));
    });

    test('cancelling stops the scan', () async {
      final subscription = bt.discover().listen((_) {});
      await pumpEventQueue();

      await subscription.cancel();

      expect(host.calls, contains('cancelDiscovery'));
    });

    test('a new scan ends the previous one', () async {
      final firstDone = Completer<void>();
      bt.discover().listen((_) {}, onDone: firstDone.complete);
      await pumpEventQueue();
      final second = <BluetoothSerialDevice>[];
      bt.discover().listen(second.add);
      await firstDone.future;

      bt.platformCallbacks.onDeviceFound(found(_esp32));
      await pumpEventQueue();

      expect(second, hasLength(1));
    });

    test('a scan that cannot start ends with the error', () async {
      host.discoveryError = PlatformException(
          code: 'permission_denied', message: 'needs BLUETOOTH_SCAN');

      await expectLater(bt.discover(), emitsError(isA<SerialException>()));
    });
  });

  group('open', () {
    test('asks for permission, then connects', () async {
      host.pair(_esp32);

      final port = await bt.open(_esp32, timeout: const Duration(seconds: 5));

      expect(host.calls,
          containsAllInOrder(['requestPermissions(false)', 'open($_esp32)']));
      final request = host.openPorts.values.single;
      expect(request.uuid, BluetoothSerial.sppUuid);
      expect(request.security, NativeSecurity.auto);
      expect(request.channel, isNull);
      expect(request.timeoutMs, 5000);
      expect(port.address, _esp32);
      expect(port.isSecure, isTrue);
      expect(port.isOpen, isTrue);
    });

    test('passes security and channel', () async {
      host.permitted = true;
      host.openSecure = false;

      final port = await bt.open(_esp32,
          security: BluetoothSecurity.insecure, channel: 1);

      final request = host.openPorts.values.single;
      expect(request.security, NativeSecurity.insecure);
      expect(request.channel, 1);
      expect(port.isSecure, isFalse);
      expect(port.toString(), contains('insecure'));
    });

    test('fails when the user says no', () async {
      host.permissionAnswer = false;

      await expectLater(
          bt.open(_esp32), throwsSerialError(SerialError.permissionDenied));
      expect(host.calls, isNot(contains('open($_esp32)')));
    });

    test('turns platform errors into SerialException', () async {
      host.permitted = true;
      for (final (code, error) in [
        ('adapter_off', SerialError.adapterOff),
        ('not_paired', SerialError.notPaired),
        ('connection_failed', SerialError.connectionFailed),
        ('timeout', SerialError.timeout),
        ('busy', SerialError.busy),
      ]) {
        host.openError = PlatformException(code: code, message: 'm');
        await expectLater(bt.open(_esp32), throwsSerialError(error));
      }
    });

    test('rejects a timeout that is not positive', () async {
      await expectLater(bt.open(_esp32, timeout: Duration.zero),
          throwsSerialError(SerialError.invalidArgument));
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

    test('delivers data, also what came before listening', () async {
      bt.platformCallbacks.onData(id, Uint8List.fromList([1, 2]));
      final received = <int>[];
      port.input.listen(received.addAll);
      bt.platformCallbacks.onData(id, Uint8List.fromList([3]));
      await pumpEventQueue();

      expect(received, [1, 2, 3]);
    });

    test('lines() works over Bluetooth too', () async {
      final lines = port.lines().toList();
      bt.platformCallbacks
        ..onData(id, Uint8List.fromList('po'.codeUnits))
        ..onData(id, Uint8List.fromList('ng\r\n'.codeUnits));
      await port.close();

      expect(await lines, ['pong']);
    });

    test('write sends bytes with a timeout that grows with the size', () async {
      await port.write([1, 2, 3]);
      expect(host.writeTimeouts[id], 2000);

      await port.write(Uint8List(100000));
      expect(host.writeTimeouts[id], 12000);

      await port.write([1], timeout: const Duration(milliseconds: 300));
      expect(host.writeTimeouts[id], 300);
      expect(host.written[id]!.first, [1, 2, 3]);
    });

    test('an empty write does not reach the platform', () async {
      await port.write(const []);
      expect(host.written[id], isNull);
    });

    test('a write timeout says how much went out', () async {
      host.writeError =
          PlatformException(code: 'timeout', message: 'slow', details: 8192);

      await expectLater(
        port.write(Uint8List(20000)),
        throwsA(isA<SerialException>()
            .having((e) => e.bytesWritten, 'bytesWritten', 8192)),
      );
    });

    test('a lost link ends the input with an error and completes closed',
        () async {
      final errors = <Object>[];
      final done = Completer<void>();
      port.input.listen((_) {}, onError: errors.add, onDone: done.complete);

      bt.platformCallbacks.onPortClosed(id, 'disconnected', 'lost');
      await done.future;

      expect(
          (errors.single as SerialException).error, SerialError.disconnected);
      expect((await port.closed)?.error, SerialError.disconnected);
      expect(port.isOpen, isFalse);
      await expectLater(
          port.write([1]), throwsSerialError(SerialError.disconnected));
    });

    test('close is quiet, once, and completes closed with null', () async {
      await port.close();
      await port.close();

      expect(host.calls.where((c) => c == 'close($id)'), hasLength(1));
      expect(await port.closed, isNull);
      await expectLater(
          port.write([1]), throwsSerialError(SerialError.portClosed));
    });
  });

  test('throws on platforms other than Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    expect(BluetoothSerial.isSupported, isFalse);
    await expectLater(bt.bondedDevices(),
        throwsSerialError(SerialError.unsupportedOperation));
  });
}
