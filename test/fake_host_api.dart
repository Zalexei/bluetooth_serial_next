import 'dart:async';

import 'package:bluetooth_serial_next/src/messages.g.dart';
import 'package:flutter/services.dart';

/// Stands in for the native side: an adapter the test switches, paired
/// devices, permission and pairing dialogs the test answers, and ports that
/// record writes.
class FakeHostApi extends BluetoothSerialHostApi {
  final List<String> calls = [];
  NativeAdapterState state = NativeAdapterState.on;
  bool permitted = false;
  bool scanPermitted = false;
  bool permissionAnswer = true;
  bool bondAnswer = true;
  final List<NativeBluetoothDevice> bonded = [];

  final Map<int, NativeOpenRequest> openPorts = {};
  final Map<int, List<Uint8List>> written = {};
  final Map<int, int> writeTimeouts = {};
  PlatformException? openError;
  PlatformException? writeError;
  PlatformException? discoveryError;
  bool openSecure = true;
  int _nextId = 1;

  NativeBluetoothDevice pair(String address, {String? name}) {
    final device = NativeBluetoothDevice(
      address: address,
      name: name,
      bondState: NativeBondState.bonded,
      type: NativeDeviceType.classic,
      deviceClass: 0x1f00,
    );
    bonded.add(device);
    return device;
  }

  @override
  Future<void> reset() async => calls.add('reset');

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<NativeAdapterState> adapterState() async => state;

  @override
  Future<bool> requestEnable() async {
    calls.add('requestEnable');
    state = NativeAdapterState.on;
    return true;
  }

  @override
  Future<bool> hasPermissions(bool scan) async =>
      permitted && (!scan || scanPermitted);

  @override
  Future<bool> requestPermissions(bool scan) async {
    calls.add('requestPermissions($scan)');
    if (permissionAnswer) {
      permitted = true;
      if (scan) scanPermitted = true;
    }
    return permissionAnswer;
  }

  @override
  Future<List<NativeBluetoothDevice>> bondedDevices() async => bonded;

  @override
  Future<void> startDiscovery() async {
    calls.add('startDiscovery');
    if (discoveryError != null) throw discoveryError!;
  }

  @override
  Future<void> cancelDiscovery() async => calls.add('cancelDiscovery');

  @override
  Future<bool> bond(String address) async {
    calls.add('bond($address)');
    return bondAnswer;
  }

  @override
  Future<NativeOpenResult> open(NativeOpenRequest request) async {
    calls.add('open(${request.address})');
    if (openError != null) throw openError!;
    final id = _nextId++;
    openPorts[id] = request;
    return NativeOpenResult(portId: id, secure: openSecure);
  }

  @override
  Future<void> write(int portId, Uint8List data, int timeoutMs) async {
    if (writeError != null) throw writeError!;
    written.putIfAbsent(portId, () => []).add(data);
    writeTimeouts[portId] = timeoutMs;
  }

  @override
  Future<void> close(int portId) async {
    calls.add('close($portId)');
    openPorts.remove(portId);
  }
}
