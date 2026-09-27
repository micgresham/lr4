// Guards the stock-cloud values: a typo here would point a robot at the wrong
// host or hand it a CA that can't verify Whisker's broker.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lr4_provisioner/ble/robot_link.dart';
import 'package:lr4_provisioner/protocol/cloud.dart';

void main() {
  test('embedded CA is Amazon Root CA 1', () {
    // The certificate's own SHA-256, as openssl reports it for the PEM
    // published at amazontrust.com.
    final der = base64.decode(amazonRootCa1
        .replaceAll('-----BEGIN CERTIFICATE-----', '')
        .replaceAll('-----END CERTIFICATE-----', '')
        .replaceAll('\n', ''));
    expect(sha256.convert(der).toString(),
        '8ecde6884f3d87b1125ba31ac3fcb13d7016de7f57cc904fe1cb97c6ae98196e');
    // The Whisker app was captured writing exactly this many bytes.
    expect(amazonRootCa1.length, 1188);
  });

  test('cloud host matches the captured onboarding', () {
    expect(whiskerCloudHost, 'a2wz9c6y6mikoy-ats.iot.us-east-1.amazonaws.com');
  });

  test('whiskerCloud config carries stock host, CA and topics', () {
    final cfg = ProvisioningConfig.whiskerCloud(
      serial: 'lr4c123456',
      wifiSsid: 'net',
      wifiPass: 'pass',
    );
    expect(cfg.serial, 'LR4C123456');
    expect(cfg.host, whiskerCloudHost);
    expect(cfg.caPem, amazonRootCa1);
    expect(cfg.commandTopic, 'prod/LR4/LR4C123456/command');
    expect(cfg.deviceTopic, 'prod/LR4/LR4C123456/activity');
    expect(cfg.isWhiskerCloud, isTrue);
    // The factory identity must be left alone, or the robot can't authenticate.
    expect(cfg.clientCert, isNull);
    expect(cfg.clientKey, isNull);
  });
}
