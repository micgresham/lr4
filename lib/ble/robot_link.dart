// BLE protocomm transport + provisioning flow for the Litter-Robot 4.
// Port of whiskerless `ble/transport.py` and `ble/provision.py` (MIT, SisyphusMD).
//
// Each protocomm endpoint is a GATT characteristic named by its 0x2901 user
// description; a request is a write and the response is a read-back on the same
// characteristic. The robot runs protocomm with no security, so no session
// handshake is needed.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../protocol/cloud.dart';
import '../protocol/messages.dart' as m;

typedef Log = void Function(String line);

class ProvisioningError implements Exception {
  ProvisioningError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Bytes per CERT_WRITE chunk — the Whisker app's own number.
const certChunk = 100;
const scanPage = 4;
const scanTimeout = Duration(seconds: 30);
const wifiPollInterval = Duration(milliseconds: 1500);
const wifiSettle = Duration(seconds: 1);
/// How long to keep asking for a DHCP address after the robot associates.
const wifiLeaseWait = Duration(seconds: 45);
/// Ceiling on the WiFi join verify. A confirmed join or a named failure
/// returns early; only a robot that never reaches a verdict runs it out.
const wifiJoinTimeout = Duration(seconds: 90);

final provServiceGuid = Guid(m.provServiceUuid);
final _userDescGuid = Guid('2901');

class ProvisioningConfig {
  ProvisioningConfig({
    required String serial,
    required this.host,
    required this.caPem,
    required this.wifiSsid,
    required this.wifiPass,
    this.clientCert,
    this.clientKey,
    this.wifiWait = wifiJoinTimeout,
  }) : serial = m.checkSerial(serial) {
    if (!caPem.contains('BEGIN CERTIFICATE')) {
      throw ProvisioningError('The CA does not look like a PEM certificate');
    }
    if ((clientCert?.isNotEmpty ?? false) != (clientKey?.isNotEmpty ?? false)) {
      throw ProvisioningError('A client certificate needs its private key, and vice versa');
    }
    for (final pem in [caPem, clientCert, clientKey]) {
      if (pem != null && pem.codeUnits.any((c) => c > 0x7F)) {
        throw ProvisioningError('Certificates/keys must be plain ASCII PEM');
      }
    }
  }

  /// Whisker's own cloud settings: their AWS IoT endpoint and Amazon Root CA 1,
  /// the same pair the Whisker app writes at onboarding.
  ///
  /// This restores the robot to the stock service only if its factory
  /// certificate and key are still in place — nothing can read or rewrite those
  /// except the Whisker app. It does not touch them.
  ProvisioningConfig.whiskerCloud({
    required String serial,
    required String wifiSsid,
    required String wifiPass,
  }) : this(
          serial: serial,
          host: whiskerCloudHost,
          caPem: amazonRootCa1,
          wifiSsid: wifiSsid,
          wifiPass: wifiPass,
        );

  final String serial;
  final String host;
  final String caPem;
  final String wifiSsid;
  final String wifiPass;
  final String? clientCert;
  final String? clientKey;
  final Duration wifiWait;

  /// True when this points the robot back at Whisker's cloud.
  bool get isWhiskerCloud => host == whiskerCloudHost;

  String get commandTopic => 'prod/LR4/$serial/command';
  // The firmware derives the /state sub-topic from the /activity endpoint.
  String get deviceTopic => 'prod/LR4/$serial/activity';
}

class RobotLink {
  RobotLink._(this.device, this.log);

  final BluetoothDevice device;
  /// Where progress lines go; the UI re-points this at whichever page is showing.
  Log log;
  final Map<String, BluetoothCharacteristic> _endpoints = {};
  Future<void> _queue = Future.value();
  String? mac;

  List<String> get endpointNames => _endpoints.keys.toList()..sort();

  static Future<RobotLink> connect(BluetoothDevice device, Log log) async {
    final link = RobotLink._(device, log);
    log('Connecting to ${device.remoteId}…');
    await device.connect(license: License.nonprofit, timeout: const Duration(seconds: 20));
    try {
      log('Connected (MTU ${device.mtuNow})');
      await link._discover();
      await link._readProtoVer();
      final id = await link.request(m.epWhisker, m.whiskerDeviceIdRequest());
      link.mac = m.formatMac(m.parseDeviceId(id));
      log('Device MAC: ${link.mac ?? 'unknown'}');
    } catch (_) {
      await device.disconnect();
      rethrow;
    }
    return link;
  }

  Future<void> disconnect() => device.disconnect();

  /// esp-idf's version endpoint: ignores its input (esp_prov sends "---") and
  /// answers with a JSON version string, which custom firmware may extend.
  Future<void> _readProtoVer() async {
    if (!_endpoints.containsKey('proto-ver')) return;
    try {
      final raw = await request('proto-ver', Uint8List.fromList(utf8.encode('---')));
      log('proto-ver: ${utf8.decode(raw, allowMalformed: true)}');
    } catch (e) {
      log('proto-ver read failed: $e');
    }
  }

  /// DEVICE_ID_SET — the app and whiskerless always send this before WiFi.
  Future<void> setDeviceId(String serial) async {
    await _whisker(m.whiskerDeviceIdSet(serial), 'DEVICE_ID_SET');
    log('DEVICE_ID_SET $serial');
  }

  Future<void> _discover() async {
    final services = await device.discoverServices();
    final svc = services.where((s) => s.uuid == provServiceGuid).firstOrNull;
    if (svc == null) {
      throw ProvisioningError('This device does not expose the LR4 provisioning service — '
          'not a Litter-Robot 4; refusing to provision');
    }
    for (final c in svc.characteristics) {
      String? name;
      final desc = c.descriptors.where((d) => d.uuid == _userDescGuid).firstOrNull;
      if (desc != null) {
        try {
          final raw = await desc.read();
          final end = raw.indexOf(0);
          name = utf8.decode(end < 0 ? raw : raw.sublist(0, end), allowMalformed: true);
        } catch (e) {
          log('descriptor read failed on ${c.uuid}: $e');
        }
      }
      if (name == null || name.isEmpty) name = m.endpointsByCharUuid[c.uuid.str128.toLowerCase()];
      if (name != null && name.isNotEmpty) _endpoints[name] = c;
    }
    log('Endpoints: ${endpointNames.join(', ')}');
    for (final required in [m.epMqtt, m.epWhisker, m.epProvConfig]) {
      if (!_endpoints.containsKey(required)) {
        throw ProvisioningError('Required endpoint "$required" not found on device');
      }
    }
  }

  /// Write a request to an endpoint and read back its response. Requests are
  /// serialized: protocomm is strictly one exchange at a time.
  Future<Uint8List> request(String endpoint, Uint8List payload) {
    final c = _endpoints[endpoint];
    if (c == null) {
      return Future.error(ProvisioningError('Endpoint "$endpoint" not found; have $endpointNames'));
    }
    final result = _queue.then((_) async {
      await c.write(payload, withoutResponse: false);
      return Uint8List.fromList(await c.read());
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Ask the ROBOT which networks it can see, strongest first, SSIDs deduped.
  Future<List<m.WifiNetwork>> scanNetworks() async {
    log('Asking the robot to scan for WiFi…');
    var count = 0;
    await () async {
      // The start is blocking: its response arrives once the sweep is done.
      await request(m.epProvScan, m.wifiScanStart());
      while (true) {
        final status = m.parseScanStatus(await request(m.epProvScan, m.wifiScanStatus()));
        if (status != null && status.$1) {
          count = status.$2;
          return;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }()
        .timeout(scanTimeout, onTimeout: () => throw ProvisioningError("The robot's WiFi scan did not finish in time"));

    final best = <String, m.WifiNetwork>{};
    for (var start = 0; start < count; start += scanPage) {
      // CLAMPED to what remains: an out-of-range page makes the firmware drop
      // the BLE link rather than return a short page.
      final n = count - start < scanPage ? count - start : scanPage;
      for (final net in m.parseScanResults(await request(m.epProvScan, m.wifiScanResult(start, n)))) {
        final seen = best[net.ssid];
        if (seen == null || net.rssi > seen.rssi) best[net.ssid] = net;
      }
    }
    final list = best.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
    log('Robot sees ${list.length} network(s) ($count sightings):');
    for (final n in list) {
      log('  "${n.ssid}"  ${n.rssi} dBm  ch ${n.channel}  ${n.authName}');
    }
    return list;
  }

  /// SetConfig + Apply, then poll GetStatus until the join resolves.
  /// Throws on a named failure (bad password / not found). Returns the IP if known.
  Future<String?> joinWifi(String ssid, String pass, {Duration wait = wifiJoinTimeout}) async {
    await request(m.epProvConfig, m.wifiSetConfig(ssid, pass));
    await request(m.epProvConfig, m.wifiApplyConfig());
    log('WiFi SetConfig+Apply for "$ssid"; verifying join (≤${wait.inSeconds}s)…');

    final deadline = DateTime.now().add(wait);
    m.WifiStatus? last;
    DateTime? associated;
    String? lastIp;
    String? lastRaw;
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(wifiPollInterval);
      final m.WifiStatus? status;
      try {
        final raw = await request(m.epProvConfig, m.wifiGetStatus());
        // The whole response, whenever it changes. GetStatus carries no secrets
        // (state, reason, ssid/bssid, ip), and fields this parser doesn't know
        // — e.g. newer esp-idf's attempt_failed — only show up here.
        final hex = raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        if (hex != lastRaw) {
          log('  raw status: $hex');
          log('    ${m.describeFields(raw)}');
          lastRaw = hex;
        }
        status = m.parseWifiStatus(raw);
      } catch (e) {
        log('GetStatus hiccup: $e');
        continue;
      }
      if (status == null) continue;
      if (last?.state != status.state) log('  station: ${status.state.name}');
      last = status;
      if (status.ip4 != lastIp) {
        // Every raw value, including rejected ones: the firmware has reported
        // 0.0.0.0 before DHCP and 1.0.0.0 while holding a real 192.168 lease.
        log('  reported IP: ${status.ip4 ?? 'none'}');
        lastIp = status.ip4;
      }
      if (status.state == m.WifiStationState.connected) {
        // CONNECTED arrives on association, before DHCP; wait briefly for a lease.
        final ip = _lanAddress(status.ip4);
        if (ip == null) {
          associated ??= DateTime.now();
          if (DateTime.now().difference(associated) < wifiLeaseWait) continue;
        }
        if (ip != null) {
          log('WiFi connected (ip=$ip)');
        } else {
          log('WiFi associated, but no LAN address reported after ${wifiLeaseWait.inSeconds}s. '
              "The firmware's IP report is unreliable — check your router's DHCP client list "
              'for MAC ${mac ?? '(see title bar)'} to see whether it actually got a lease.');
        }
        await Future.delayed(wifiSettle);
        return ip;
      }
      if (status.state == m.WifiStationState.connectionFailed) {
        final why = switch (status.failReason) {
          m.WifiFailReason.authError => 'authentication failed — almost always a wrong WiFi password',
          m.WifiFailReason.networkNotFound => 'network "$ssid" not found (robot is 2.4 GHz only)',
          _ => 'unknown reason',
        };
        throw ProvisioningError('WiFi join failed: $why');
      }
    }
    if (last == null) {
      log('No WiFi status after ${wait.inSeconds}s (firmware may not support GetStatus)');
    } else if (last.state == m.WifiStationState.connected) {
      log('WiFi connected');
      await Future.delayed(wifiSettle);
    } else {
      throw ProvisioningError('WiFi still ${last.state.name} after ${wait.inSeconds}s — '
          'the robot could not join "$ssid"');
    }
    return null;
  }

  /// The full whiskerless sequence:
  /// DEVICE_ID_SET → WiFi SetConfig+Apply → verify join → endpoints → CA
  /// [→ device cert → key] → APPLY_CONFIG → REBOOT.
  Future<void> provision(ProvisioningConfig cfg) async {
    await setDeviceId(cfg.serial);

    // The WiFi finalize is load-bearing: skipping it wedged the robot.
    await joinWifi(cfg.wifiSsid, cfg.wifiPass, wait: cfg.wifiWait);

    await _mqtt(m.mqttEndpointWrite(m.EndpointType.host, cfg.host), 'ENDPOINT_HOST');
    await _mqtt(m.mqttEndpointWrite(m.EndpointType.cloud, cfg.commandTopic), 'ENDPOINT_CLOUD');
    await _mqtt(m.mqttEndpointWrite(m.EndpointType.device, cfg.deviceTopic), 'ENDPOINT_DEVICE');
    log('Endpoints: host=${cfg.host} sub=${cfg.commandTopic} pub=${cfg.deviceTopic}');

    await _writeCert(cfg.caPem, m.CertificateType.awsRootCert);
    log('Root CA written (${cfg.caPem.length} bytes)');
    if ((cfg.clientCert?.isNotEmpty ?? false) && (cfg.clientKey?.isNotEmpty ?? false)) {
      await _writeCert(cfg.clientCert!, m.CertificateType.deviceCert);
      log('Device certificate written (${cfg.clientCert!.length} bytes)');
      await _writeCert(cfg.clientKey!, m.CertificateType.deviceKey);
      log('Device key written (${cfg.clientKey!.length} bytes)');
    }

    await _mqtt(m.mqttApplyConfig(), 'APPLY_CONFIG');
    log('APPLY_CONFIG committed');

    try {
      await request(m.epWhisker, m.whiskerReboot());
    } catch (_) {
      // Link loss on reboot is expected.
    }
    log('DEVICE_REBOOT sent — the robot should now connect to ${cfg.host}:8883');
  }

  Future<void> _writeCert(String pem, m.CertificateType type) async {
    final total = pem.length; // ASCII-checked, so chars == bytes
    for (var offset = 0; offset < total; offset += certChunk) {
      final piece = pem.substring(offset, (offset + certChunk).clamp(0, total));
      await _mqtt(m.mqttCertWrite(type, piece, total, offset, piece.length), 'CERT_WRITE[$offset]');
    }
  }

  Future<void> _mqtt(Uint8List payload, String label) async {
    final status = m.parseStatus(await request(m.epMqtt, payload));
    if (status != 0) throw ProvisioningError('$label failed: status=$status');
  }

  Future<void> _whisker(Uint8List payload, String label) async {
    final status = m.parseStatus(await request(m.epWhisker, payload));
    if (status != 0) log('warning: $label returned status=$status');
  }
}

/// The reported STA address, or null unless it's an RFC 1918 lease. The
/// firmware has reported "1.0.0.0" while the real lease was 192.168.x.
String? _lanAddress(String? ip) {
  if (ip == null) return null;
  final parts = ip.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((p) => p == null || p < 0 || p > 255)) return null;
  final a = parts[0]!, b = parts[1]!;
  if (a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168)) return ip;
  return null;
}
