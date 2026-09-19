// Byte vectors ported from whiskerless tests/test_protobuf.py and
// tests/test_provision.py, which match a captured Whisker-app session.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lr4_provisioner/protocol/messages.dart' as m;
import 'package:lr4_provisioner/protocol/protobuf.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
String hexStr(String s) => hex(utf8.encode(s));

void main() {
  test('wifi set config', () {
    const ssid = 'MyNetwork24GHz', pass = 'hunter2hunte';
    expect(ssid.length, 14);
    expect(pass.length, 12);
    expect(hex(m.wifiSetConfig(ssid, pass)), '0802621e0a0e${hexStr(ssid)}120c${hexStr(pass)}');
  });

  test('fixed frames', () {
    expect(hex(m.wifiApplyConfig()), '0804');
    expect(hex(m.mqttApplyConfig()), '08047200');
    expect(hex(m.whiskerDeviceIdRequest()), '08015200');
    expect(hex(m.whiskerReboot()), '08036200');
    expect(hex(m.wifiGetStatus()), '5200');
    expect(m.mqttCertWrite(m.CertificateType.awsRootCert, 'x', 1, 0, 1)[0], 0x52);
  });

  test('device id set', () {
    const serial = 'LR4C123456';
    final len = serial.length.toRadixString(16).padLeft(2, '0');
    final outer = (2 + serial.length).toRadixString(16).padLeft(2, '0');
    expect(hex(m.whiskerDeviceIdSet(serial)), '080572${outer}0a$len${hexStr(serial)}');
  });

  test('varint round trip', () {
    for (final (v, enc) in [(0, '00'), (1, '01'), (127, '7f'), (128, '8001'), (300, 'ac02')]) {
      expect(hex(encodeVarint(v)), enc);
      expect(firstInt(readFields([0x08, ...encodeVarint(v)]), 1), v);
    }
  });

  test('device id parse', () {
    final mac = Uint8List.fromList([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]);
    final resp = concat([fieldVarint(1, 2), fieldMessage(11, fieldMessage(1, mac))]);
    expect(m.formatMac(m.parseDeviceId(resp)), 'aa:bb:cc:dd:ee:ff');
  });

  test('scan result with negative rssi', () {
    // RSSI -51 as a sign-extended int32 varint (10 bytes).
    final rssi = [0xcd, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01];
    final entry = concat([fieldString(1, 'Home'), fieldVarint(2, 6), [0x18, ...rssi], fieldVarint(5, 3)]);
    final resp = concat([fieldVarint(1, 5), fieldMessage(15, fieldMessage(1, entry))]);
    final nets = m.parseScanResults(resp);
    expect(nets.single.ssid, 'Home');
    expect(nets.single.rssi, -51);
    expect(nets.single.channel, 6);
    expect(nets.single.authName, 'WPA2');
  });

  test('wifi status verdicts', () {
    final ok = concat([fieldMessage(11, fieldMessage(11, fieldString(1, '192.168.1.9')))]);
    expect(m.parseWifiStatus(ok)!.state, m.WifiStationState.connected);
    expect(m.parseWifiStatus(ok)!.ip4, '192.168.1.9');
    // AuthError is enum 0 but still present on the wire in the oneof.
    final auth = concat([fieldMessage(11, [0x10, 0x03, 0x50, 0x00])]);
    expect(m.parseWifiStatus(auth)!.failReason, m.WifiFailReason.authError);
    final connecting = concat([fieldMessage(11, fieldVarint(2, 1))]);
    expect(m.parseWifiStatus(connecting)!.state, m.WifiStationState.connecting);
  });

  test('serial check', () {
    expect(m.checkSerial(' lr4c123456 '), 'LR4C123456');
    expect(() => m.checkSerial('LR4-0301-00-US'), throwsArgumentError);
    expect(() => m.checkSerial('ABC123456'), throwsArgumentError);
  });

  test('describeFields', () {
    final resp = concat([fieldVarint(1, 1), fieldMessage(11, concat([fieldVarint(2, 1), fieldMessage(12, fieldVarint(1, 3))]))]);
    expect(m.describeFields(resp), '1=1 11={2=1 12={1=3}}');
  });
}
