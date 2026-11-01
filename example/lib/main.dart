import 'package:bluetooth_serial_next/bluetooth_serial_next.dart';
import 'package:flutter/material.dart';

import 'devices_page.dart';

void main() => runApp(TerminalApp(bt: BluetoothSerial.instance));

class TerminalApp extends StatelessWidget {
  const TerminalApp({super.key, required this.bt});

  final BluetoothSerial bt;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bluetooth serial terminal',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: DevicesPage(bt: bt),
    );
  }
}
