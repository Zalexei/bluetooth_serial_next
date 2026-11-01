# bluetooth_serial_next example

A serial terminal for Android over Bluetooth Classic:

- paired devices, and nearby ones after a scan;
- the nearby devices permission and the "turn Bluetooth on" dialog;
- connect with a tap (secure, then insecure), or from the menu: pair,
  secure only, insecure only, or channel 1 for ELM327 clones;
- received and sent data as text (control characters shown as `\r`, `\n`)
  or hex, sending text with a line ending or raw hex;
- a speed test against `../tool/esp32_spp_echo`.

```bash
flutter run
```

`../tool/esp32_spp_echo` is a PlatformIO firmware for the original ESP32
(ESP32-WROOM-32 and similar; S2, S3, C3 and C6 have no Bluetooth Classic). It
shows up as "SPP echo" and answers `ping`, `info`, `burst N`, `sink N`,
`forget`, `bye`, and echoes everything else.
