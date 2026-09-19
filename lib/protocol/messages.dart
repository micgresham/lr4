// protocomm endpoint message builders + parsers for the Litter-Robot 4.
// Port of whiskerless `ble/messages.py` (MIT, SisyphusMD).
//
// * whisker-config — set/get the device id (serial), reboot.
// * mqtt-config    — write certs / endpoints, apply config.
// * prov-config    — stock esp-idf WiFi provisioning (SetConfig / ApplyConfig).
// * prov-scan      — stock esp-idf WiFi scan (the ROBOT's radio scans).

import 'dart:convert';
import 'dart:typed_data';

import 'protobuf.dart';

const epProvConfig = 'prov-config';
const epProvScan = 'prov-scan';
const epMqtt = 'mqtt-config';
const epWhisker = 'whisker-config';

const provServiceUuid = 'b7ee1c20-dcfd-4208-8813-14845cac5212';

/// Fallback endpoint map by characteristic UUID, from a decoded Whisker-app
/// capture (the app maps this way instead of reading 0x2901 descriptors).
const endpointsByCharUuid = {
  'b7ee0002-dcfd-4208-8813-14845cac5212': epProvConfig,
  'b7ee0004-dcfd-4208-8813-14845cac5212': epProvScan,
  'b7ee0005-dcfd-4208-8813-14845cac5212': epMqtt,
  'b7ee0006-dcfd-4208-8813-14845cac5212': epWhisker,
};

enum CertificateType {
  awsRootCert(1), // server-trust root CA — your CA goes here
  deviceCert(2),
  deviceKey(3);

  const CertificateType(this.value);
  final int value;
}

enum EndpointType {
  cloud(1), // device SUBSCRIBES (command topic)
  device(2), // device PUBLISHES (state/activity topic)
  host(3); // broker host (TLS SNI / hostname-verify target)

  const EndpointType(this.value);
  final int value;
}

// --- whisker-config ---------------------------------------------------------
Uint8List whiskerDeviceIdRequest() => concat([fieldVarint(1, 1), fieldMessage(10, [])]);

Uint8List whiskerDeviceIdSet(String serial) =>
    concat([fieldVarint(1, 5), fieldMessage(14, fieldString(1, serial))]);

Uint8List whiskerReboot() => concat([fieldVarint(1, 3), fieldMessage(12, [])]);

// --- mqtt-config ------------------------------------------------------------
Uint8List mqttCertWrite(CertificateType type, String chunk, int totalSize, int offset, int size) =>
    concat([
      fieldVarint(1, 0),
      fieldMessage(
          10,
          concat([
            fieldVarint(1, type.value),
            fieldString(2, chunk),
            fieldVarint(3, totalSize),
            fieldVarint(4, offset),
            fieldVarint(5, size),
          ])),
    ]);

Uint8List mqttEndpointWrite(EndpointType type, String value) => concat([
      fieldVarint(1, 2),
      fieldMessage(12, concat([fieldVarint(1, type.value), fieldString(2, value)])),
    ]);

Uint8List mqttApplyConfig() => concat([fieldVarint(1, 4), fieldMessage(14, [])]);

// --- prov-config (stock esp-idf) --------------------------------------------
Uint8List wifiSetConfig(String ssid, String passphrase) => concat([
      fieldVarint(1, 2),
      fieldMessage(12, concat([fieldString(1, ssid), fieldString(2, passphrase)])),
    ]);

Uint8List wifiApplyConfig() => concat([fieldVarint(1, 4)]);

/// CmdGetStatus: msg=0 stays off the wire; the empty arm alone selects it.
Uint8List wifiGetStatus() => concat([fieldMessage(10, [])]);

// --- prov-scan (stock esp-idf) ----------------------------------------------
/// The app's own scan parameters: groups of 5 channels, 120 ms each.
Uint8List wifiScanStart({bool blocking = true, bool passive = false, int groupChannels = 5, int periodMs = 120}) =>
    concat([
      fieldMessage(
          10,
          concat([
            fieldVarint(1, blocking ? 1 : 0),
            fieldVarint(2, passive ? 1 : 0),
            fieldVarint(3, groupChannels),
            fieldVarint(4, periodMs),
          ])),
    ]);

Uint8List wifiScanStatus() => concat([fieldVarint(1, 2), fieldMessage(12, [])]);

Uint8List wifiScanResult(int startIndex, int count) => concat([
      fieldVarint(1, 4),
      fieldMessage(14, concat([fieldVarint(1, startIndex), fieldVarint(2, count)])),
    ]);

// --- parsed types -----------------------------------------------------------
const _authModes = {
  0: 'Open',
  1: 'WEP',
  2: 'WPA',
  3: 'WPA2',
  4: 'WPA/WPA2',
  5: 'WPA2-Enterprise',
  6: 'WPA3',
  7: 'WPA2/WPA3',
};

class WifiNetwork {
  WifiNetwork({required this.ssid, required this.channel, required this.rssi, required this.authMode});

  final String ssid;
  final int channel;
  final int rssi;
  final int authMode;

  bool get secured => authMode != 0;
  String get authName => _authModes[authMode] ?? 'auth $authMode';
  int get bars => rssi >= -60 ? 4 : rssi >= -70 ? 3 : rssi >= -80 ? 2 : 1;
}

enum WifiStationState { connected, connecting, disconnected, connectionFailed }

enum WifiFailReason { authError, networkNotFound, unknown }

class WifiStatus {
  WifiStatus(this.state, {this.failReason, this.ip4});

  final WifiStationState state;
  final WifiFailReason? failReason;
  final String? ip4;
}

// --- response parsers -------------------------------------------------------
/// Top-level protocomm `status` (field 2); absent → Success (0).
int parseStatus(List<int> response) =>
    response.isEmpty ? 0 : (firstInt(readFields(response), 2) ?? 0);

/// Decode a prov-config RespGetStatus (arm 11); null if there's no verdict yet.
///
/// `sta_state` alone cannot prove success: its zero value IS Connected, which
/// proto3 omits. The verdict lives in the oneof: `connected` (field 11) or
/// `fail_reason` (field 10, emitted even for its zero value AuthError).
WifiStatus? parseWifiStatus(List<int> response) {
  if (response.isEmpty) return null;
  final arm = firstBytes(readFields(response), 11);
  if (arm == null) return null;
  final f = readFields(arm);
  final connected = firstBytes(f, 11);
  if (connected != null) {
    final ip = firstBytes(readFields(connected), 1);
    final ip4 = ip == null ? null : utf8.decode(ip, allowMalformed: true);
    return WifiStatus(WifiStationState.connected, ip4: (ip4 == null || ip4.isEmpty) ? null : ip4);
  }
  final fail = firstInt(f, 10);
  if (fail != null) {
    final reason = switch (fail) {
      0 => WifiFailReason.authError,
      1 => WifiFailReason.networkNotFound,
      _ => WifiFailReason.unknown,
    };
    return WifiStatus(WifiStationState.connectionFailed, failReason: reason);
  }
  final sta = firstInt(f, 2);
  if (sta != null && sta >= 1 && sta <= 3) return WifiStatus(WifiStationState.values[sta]);
  return null;
}

/// Decode RespScanStatus (arm 13) into (finished, resultCount).
(bool, int)? parseScanStatus(List<int> response) {
  if (response.isEmpty) return null;
  final arm = firstBytes(readFields(response), 13);
  if (arm == null) return null;
  final f = readFields(arm);
  return ((firstInt(f, 1) ?? 0) != 0, firstInt(f, 2) ?? 0);
}

/// Decode one RespScanResult page (arm 15). Hidden / non-UTF-8 SSIDs are dropped.
List<WifiNetwork> parseScanResults(List<int> response) {
  if (response.isEmpty) return [];
  final arm = firstBytes(readFields(response), 15);
  if (arm == null) return [];
  final found = <WifiNetwork>[];
  for (final entry in readFields(arm)[1] ?? const <Object>[]) {
    if (entry is! Uint8List) continue;
    final f = readFields(entry);
    final raw = firstBytes(f, 1);
    if (raw == null || raw.isEmpty) continue;
    final String ssid;
    try {
      ssid = utf8.decode(raw);
    } on FormatException {
      continue;
    }
    found.add(WifiNetwork(
      ssid: ssid,
      channel: firstInt(f, 2) ?? 0,
      rssi: (firstInt(f, 3) ?? 0).toSigned(32),
      // proto3 omits zero, and auth mode 0 IS open.
      authMode: firstInt(f, 5) ?? 0,
    ));
  }
  return found;
}

/// Extract device_id bytes from a DEVICE_ID_RESPONSE (arm 11, field 1).
Uint8List? parseDeviceId(List<int> response) {
  final arm = firstBytes(readFields(response), 11);
  return arm == null ? null : firstBytes(readFields(arm), 1);
}

String? formatMac(Uint8List? id) {
  if (id == null) return null;
  if (id.length == 6) return id.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
  final s = utf8.decode(id, allowMalformed: true).replaceAll('\x00', '').trim();
  return s.isEmpty ? null : s;
}

/// Normalize a typed serial, or throw explaining why it can't be one.
/// The serial becomes the MQTT client-id and both topic segments, so a wrong
/// value provisions cleanly and then never appears on the broker.
String checkSerial(String value) {
  final serial = value.trim().toUpperCase();
  if (!serial.startsWith('LR4')) {
    throw ArgumentError('"$serial" is not a Litter-Robot 4 serial (expected LR4…, e.g. LR4C123456)');
  }
  final digits = serial.split('').where((c) => '0123456789'.contains(c)).length;
  if (serial.contains('-') || serial.length < 8 || digits < 4) {
    throw ArgumentError('"$serial" looks like the model number, not the serial — '
        'the serial is LR4 followed by a letter and six digits (e.g. LR4C123456)');
  }
  return serial;
}

/// Render a protobuf message as nested `field=value` text for diagnostics.
/// Length-delimited values that parse cleanly as a sub-message are expanded;
/// printable ones are shown as text, anything else as hex.
String describeFields(List<int> data, [int depth = 0]) {
  final Fields f;
  try {
    f = readFields(data);
  } on FormatException {
    return _hexOf(data);
  }
  final parts = <String>[];
  f.forEach((field, values) {
    for (final v in values) {
      if (v is int) {
        parts.add('$field=${v.toSigned(64)}');
        continue;
      }
      final b = v as Uint8List;
      final printable = b.isNotEmpty && b.every((c) => c >= 0x20 && c < 0x7F);
      if (printable) {
        parts.add('$field="${String.fromCharCodes(b)}"');
      } else if (b.isEmpty) {
        parts.add('$field={}');
      } else if (depth < 3 && _parsesCleanly(b)) {
        parts.add('$field={${describeFields(b, depth + 1)}}');
      } else {
        parts.add('$field=0x${_hexOf(b)}');
      }
    }
  });
  return parts.join(' ');
}

String _hexOf(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

bool _parsesCleanly(List<int> b) {
  var pos = 0;
  int? varint() {
    var r = 0, shift = 0;
    while (pos < b.length) {
      final c = b[pos++];
      r |= (c & 0x7F) << shift;
      if (c & 0x80 == 0) return r;
      shift += 7;
      if (shift > 63) return null;
    }
    return null;
  }

  while (pos < b.length) {
    final key = varint();
    if (key == null || key >> 3 == 0) return false;
    switch (key & 7) {
      case 0:
        if (varint() == null) return false;
      case 2:
        final len = varint();
        if (len == null || pos + len > b.length) return false;
        pos += len;
      default:
        return false;
    }
  }
  return true;
}
