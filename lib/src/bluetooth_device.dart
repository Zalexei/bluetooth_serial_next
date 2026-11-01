// Copyright 2026 Alexei Zalogin. Use of this source code is governed by the MIT license in the LICENSE file.
import 'package:meta/meta.dart';

/// Whether the phone's Bluetooth is on.
enum BluetoothAdapterState { off, turningOn, on, turningOff }

/// Whether the phone is paired with a device.
enum BluetoothBondState { none, bonding, bonded }

/// Which Bluetooth a device speaks, as far as the phone knows. Devices it
/// has not seen yet are [unknown].
enum BluetoothDeviceType {
  unknown,

  /// Bluetooth Classic only (HC-05, ELM327, most printers).
  classic,

  /// Bluetooth Low Energy only; it has no serial port profile.
  le,

  /// Both (the original ESP32, phones, laptops).
  dual,
}

/// A Bluetooth device the phone knows: paired, or found by a scan.
@immutable
class BluetoothSerialDevice {
  const BluetoothSerialDevice({
    required this.address,
    this.name,
    this.bondState = BluetoothBondState.none,
    this.type = BluetoothDeviceType.unknown,
    this.deviceClass,
    this.rssi,
  });

  /// The MAC address, for example "94:3C:C6:8C:2F:B6". Pass it to
  /// `BluetoothSerial.open`.
  final String address;

  /// The name the device gives itself; null until the phone has heard it.
  final String? name;

  final BluetoothBondState bondState;
  final BluetoothDeviceType type;

  /// The Bluetooth device class (major and minor bits); see [majorClass].
  final int? deviceClass;

  /// Signal strength in dBm, for devices found by a scan.
  final int? rssi;

  bool get isBonded => bondState == BluetoothBondState.bonded;

  /// The major device class: 0x100 computer, 0x200 phone, 0x400 audio,
  /// 0x600 imaging (printers), 0x1f00 uncategorized (most serial modules).
  int? get majorClass => deviceClass == null ? null : deviceClass! & 0x1f00;

  /// Whether it could have a serial port: not a Low Energy only device.
  bool get mayHaveSerialPort => type != BluetoothDeviceType.le;

  @override
  bool operator ==(Object other) =>
      other is BluetoothSerialDevice &&
      other.address == address &&
      other.name == name &&
      other.bondState == bondState &&
      other.type == type &&
      other.deviceClass == deviceClass &&
      other.rssi == rssi;

  @override
  int get hashCode =>
      Object.hash(address, name, bondState, type, deviceClass, rssi);

  @override
  String toString() =>
      'BluetoothSerialDevice($address${name == null ? '' : ' "$name"'}, '
      '${bondState.name}, ${type.name}${rssi == null ? '' : ', $rssi dBm'})';
}
