// Contract between Dart and the native side. Regenerate after editing:
//   dart run pigeon --input pigeons/messages.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartPackageName: 'bluetooth_serial_next',
    kotlinOut:
        'android/src/main/kotlin/io/github/zalexei/bluetooth_serial_next/Messages.g.kt',
    kotlinOptions:
        KotlinOptions(package: 'io.github.zalexei.bluetooth_serial_next'),
    copyrightHeader: 'pigeons/copyright.txt',
  ),
)
enum NativeAdapterState { off, turningOn, on, turningOff }

enum NativeBondState { none, bonding, bonded }

enum NativeDeviceType { unknown, classic, le, dual }

/// How to secure the RFCOMM link.
enum NativeSecurity { auto, secure, insecure }

/// A device the phone knows: paired, or found by a scan.
class NativeBluetoothDevice {
  NativeBluetoothDevice({
    required this.address,
    required this.bondState,
    required this.type,
  });

  String address;
  String? name;
  NativeBondState bondState;
  NativeDeviceType type;

  /// BluetoothClass.getDeviceClass(): major and minor class bits.
  int? deviceClass;

  /// Only for devices found by a scan.
  int? rssi;
}

class NativeOpenRequest {
  NativeOpenRequest({
    required this.address,
    required this.uuid,
    required this.security,
    required this.timeoutMs,
  });

  String address;
  String uuid;
  NativeSecurity security;

  /// Connect to this RFCOMM channel and skip the service lookup.
  int? channel;
  int timeoutMs;
}

class NativeOpenResult {
  NativeOpenResult({required this.portId, required this.secure});

  int portId;

  /// Whether the link that worked is encrypted and authenticated.
  bool secure;
}

/// Error codes are the ones in serial_port_core's SerialException.fromCode.
@HostApi()
abstract class BluetoothSerialHostApi {
  /// Closes every port; a hot restart leaves them open otherwise.
  void reset();

  /// Whether the device has Bluetooth Classic at all.
  bool isAvailable();

  NativeAdapterState adapterState();

  /// Shows the system dialog that turns Bluetooth on; true if it is on.
  @async
  bool requestEnable();

  /// BLUETOOTH_CONNECT (Android 12+), plus BLUETOOTH_SCAN or the location
  /// permission when [scan].
  bool hasPermissions(bool scan);

  @async
  bool requestPermissions(bool scan);

  List<NativeBluetoothDevice> bondedDevices();

  /// Results arrive through onDeviceFound until onDiscoveryFinished.
  void startDiscovery();

  void cancelDiscovery();

  /// Pairs with the device; true once it is paired.
  @async
  bool bond(String address);

  @async
  NativeOpenResult open(NativeOpenRequest request);

  @async
  void write(int portId, Uint8List data, int timeoutMs);

  @async
  void close(int portId);
}

@FlutterApi()
abstract class BluetoothSerialFlutterApi {
  void onData(int portId, Uint8List data);

  /// After the last onData. Without an error code for a requested close.
  void onPortClosed(int portId, String? errorCode, String? errorMessage);

  void onAdapterStateChanged(NativeAdapterState state);

  void onDeviceFound(NativeBluetoothDevice device);

  void onDiscoveryFinished();

  void onBondStateChanged(NativeBluetoothDevice device);
}
