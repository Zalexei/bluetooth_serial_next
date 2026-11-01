import 'package:bluetooth_serial_next/bluetooth_serial_next.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Apps read the instance in main(), before runApp sets up the bindings.
  test('instance can be read before the bindings exist', () {
    expect(BluetoothSerial.instance, same(BluetoothSerial.instance));
  });
}
