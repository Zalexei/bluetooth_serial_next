// The fake stands in for the native side, which lives in the plugin's src.
// ignore_for_file: implementation_imports
import 'package:bluetooth_serial_next/bluetooth_serial_next.dart';
import 'package:bluetooth_serial_next/src/messages.g.dart';
import 'package:bluetooth_serial_next_example/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeHost extends BluetoothSerialHostApi {
  var state = NativeAdapterState.on;
  var permitted = true;
  final bonded = <NativeBluetoothDevice>[];
  final written = <List<int>>[];
  NativeOpenRequest? opened;

  @override
  Future<void> reset() async {}

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<NativeAdapterState> adapterState() async => state;

  @override
  Future<bool> requestEnable() async {
    state = NativeAdapterState.on;
    return true;
  }

  @override
  Future<bool> hasPermissions(bool scan) async => permitted;

  @override
  Future<bool> requestPermissions(bool scan) async => permitted = true;

  @override
  Future<List<NativeBluetoothDevice>> bondedDevices() async => bonded;

  @override
  Future<void> startDiscovery() async {}

  @override
  Future<void> cancelDiscovery() async {}

  @override
  Future<bool> bond(String address) async => true;

  @override
  Future<NativeOpenResult> open(NativeOpenRequest request) async {
    opened = request;
    return NativeOpenResult(portId: 1, secure: true);
  }

  @override
  Future<void> write(int portId, Uint8List data, int timeoutMs) async =>
      written.add(data);

  @override
  Future<void> close(int portId) async {}
}

NativeBluetoothDevice _esp32() => NativeBluetoothDevice(
  address: '94:3C:C6:8C:2F:B6',
  name: 'SPP echo',
  bondState: NativeBondState.bonded,
  type: NativeDeviceType.dual,
);

void main() {
  late _FakeHost host;
  late BluetoothSerial bt;

  setUp(() {
    host = _FakeHost();
    bt = BluetoothSerial.withHostApi(host);
  });

  testWidgets('asks for the permission first', (tester) async {
    host.permitted = false;
    await tester.pumpWidget(TerminalApp(bt: bt));
    await tester.pumpAndSettle();

    expect(
      find.text('The app needs the nearby devices permission.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();

    expect(find.text('No paired devices'), findsOneWidget);
  });

  testWidgets('offers to turn Bluetooth on', (tester) async {
    host.state = NativeAdapterState.off;
    await tester.pumpWidget(TerminalApp(bt: bt));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();

    expect(find.text('Paired'), findsOneWidget);
  });

  testWidgets('connects to a paired device and shows what comes back', (
    tester,
  ) async {
    host.bonded.add(_esp32());
    await tester.pumpWidget(TerminalApp(bt: bt));
    await tester.pumpAndSettle();

    await tester.tap(find.text('SPP echo'));
    await tester.pumpAndSettle();
    expect(host.opened?.address, '94:3C:C6:8C:2F:B6');
    expect(find.textContaining('Connected, secure link'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ping');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(host.written.single, 'ping\n'.codeUnits);

    bt.platformCallbacks.onData(1, Uint8List.fromList('pong\r\n'.codeUnits));
    await tester.pumpAndSettle();
    expect(find.textContaining(r'pong\r\n'), findsOneWidget);

    bt.platformCallbacks.onPortClosed(1, 'disconnected', 'lost');
    await tester.pumpAndSettle();
    expect(find.textContaining('The connection was lost'), findsOneWidget);
  });
}
