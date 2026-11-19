## 0.1.1

* Fixed `discover()` never starting a new scan while the listener of the
  previous scan was paused (for example inside an `await for` body).
* Fixed a scan left running on the phone when the subscription was cancelled
  right after listening while a previous scan was still being replaced.
* More tests: permissions, adapter state, ports after a lost link,
  `BluetoothSerialDevice`.

## 0.1.0

* First release: Bluetooth Classic serial ports (SPP over RFCOMM) on
  Android. Paired devices, scanning, pairing, the Android 12+ and the older
  scan permissions, the "turn Bluetooth on" dialog, adapter and pairing
  events.
* Connecting tries a secure and then an insecure link, or an RFCOMM channel
  for devices without a service record, within one timeout enforced by a
  watchdog.
* Ports implement `SerialPort` from serial_port_core, like usb_serial_next;
  every failure is a `SerialException` with a `SerialError`.
