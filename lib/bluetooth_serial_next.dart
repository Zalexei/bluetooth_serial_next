// Copyright 2026 Alexei Zalogin. Use of this source code is governed by the MIT license in the LICENSE file.

/// Bluetooth Classic serial ports (SPP over RFCOMM) on Android: HC-05,
/// HC-06, ESP32's BluetoothSerial, ELM327 adapters, printers.
///
/// The ports implement [SerialPort] from serial_port_core, the same
/// interface as usb_serial_next, so protocol code works over either.
library;

export 'package:serial_port_core/serial_port_core.dart';

export 'src/bluetooth_device.dart';
export 'src/bluetooth_serial.dart'
    show BluetoothSecurity, BluetoothSerial, BluetoothSerialPort;
