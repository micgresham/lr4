import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ble/robot_link.dart';
import 'protocol/messages.dart' as m;

void main() => runApp(const Lr4App());

class Lr4App extends StatelessWidget {
  const Lr4App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'LR4 Provisioner',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark, useMaterial3: true),
        home: const ScanPage(),
      );
}

// ---------------------------------------------------------------------------
// 1. Find the robot
// ---------------------------------------------------------------------------
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  List<ScanResult> _results = [];
  bool _scanning = false;
  bool _connecting = false;
  StreamSubscription? _resultsSub, _scanningSub;

  @override
  void initState() {
    super.initState();
    _resultsSub = FlutterBluePlus.onScanResults.listen((r) => setState(() => _results = r));
    _scanningSub = FlutterBluePlus.isScanning.listen((s) => setState(() => _scanning = s));
  }

  @override
  void dispose() {
    _resultsSub?.cancel();
    _scanningSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _scan() async {
    try {
      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
        await FlutterBluePlus.turnOn();
      }
      setState(() => _results = []);
      // The robot advertises only its service UUID (no name) and only in pairing mode.
      await FlutterBluePlus.startScan(withServices: [provServiceGuid], timeout: const Duration(seconds: 20));
    } catch (e) {
      _snack('Scan failed: $e');
    }
  }

  Future<void> _connect(ScanResult r) async {
    await FlutterBluePlus.stopScan();
    setState(() => _connecting = true);
    final log = <String>[];
    try {
      final link = await RobotLink.connect(r.device, log.add);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => RobotPage(link: link, initialLog: log)));
      await link.disconnect();
    } catch (e) {
      _snack('Connection failed: $e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _snack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('LR4 Provisioner')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Put the robot in pairing mode: HOLD the Connect button ~3 seconds until the light '
                'blinks yellow (a short tap only toggles WiFi).\n\n'
                'Pairing mode forgets the saved WiFi. Once you start, finish with a provision '
                '(here, or in the Whisker app).',
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _scanning || _connecting ? null : _scan,
            icon: _scanning
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.bluetooth_searching),
            label: Text(_scanning ? 'Scanning…' : 'Find robot'),
          ),
          if (_connecting) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
          const SizedBox(height: 8),
          if (!_scanning && _results.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No robot found yet. The LR4 advertises weakly — stand close and retry.',
                  textAlign: TextAlign.center),
            ),
          for (final r in _results)
            Card(
              child: ListTile(
                leading: const Icon(Icons.pets),
                title: Text(r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : 'Litter-Robot 4'),
                subtitle: Text('${r.device.remoteId}  ·  ${r.rssi} dBm'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _connecting ? null : () => _connect(r),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 2. Connected robot: WiFi diagnosis and provisioning
// ---------------------------------------------------------------------------
class RobotPage extends StatefulWidget {
  const RobotPage({super.key, required this.link, required this.initialLog});
  final RobotLink link;
  final List<String> initialLog;
  @override
  State<RobotPage> createState() => _RobotPageState();
}

class _RobotPageState extends State<RobotPage> {
  late final List<String> _log = [...widget.initialLog];
  List<m.WifiNetwork>? _networks;
  final _ssid = TextEditingController();
  final _pass = TextEditingController();
  final _serial = TextEditingController();
  bool _obscure = true;
  String? _busy;
  bool _connected = true;
  StreamSubscription? _connSub;

  @override
  void initState() {
    super.initState();
    link.log = _add;
    _connSub = widget.link.device.connectionState.listen((s) {
      final c = s == BluetoothConnectionState.connected;
      if (c != _connected && mounted) {
        setState(() => _connected = c);
        if (!c) _add('Bluetooth link closed.');
      }
    });
    SharedPreferences.getInstance().then((p) {
      _ssid.text = p.getString('ssid') ?? '';
      _serial.text = p.getString('serial') ?? '';
    });
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _ssid.dispose();
    _pass.dispose();
    _serial.dispose();
    super.dispose();
  }

  RobotLink get link => widget.link;

  void _add(String line) {
    _log.add(line);
    if (mounted) setState(() {});
  }

  Future<void> _run(String label, Future<void> Function() body) async {
    setState(() => _busy = label);
    try {
      await body();
    } catch (e) {
      _add('ERROR: $e');
      if (mounted) {
        await showDialog(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('$label failed'),
            content: Text('$e'),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _scanWifi() => _run('WiFi scan', () async {
        final nets = await link.scanNetworks();
        setState(() => _networks = nets);
      });

  Future<void> _testWifi() => _run('WiFi test', () async {
        final ssid = _ssid.text;
        if (ssid.isEmpty) throw ProvisioningError('Pick or type a network first');
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('ssid', ssid);
        // Same order as the Whisker app: the serial goes in before the WiFi.
        if (_serial.text.trim().isNotEmpty) {
          final serial = m.checkSerial(_serial.text);
          await prefs.setString('serial', serial);
          await link.setDeviceId(serial);
        }
        final ip = await link.joinWifi(ssid, _pass.text);
        _add('✅ The robot joined "$ssid"${ip != null ? ' as $ip' : ''}. Its WiFi radio works.');
        if (mounted) {
          await showDialog(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('WiFi works'),
              content: Text('The robot joined "$ssid"${ip != null ? ' ($ip)' : ''}.\n\n'
                  'This was only a test: the robot is still in pairing mode. Finish with "Provision to my '
                  'broker", or re-run setup in the Whisker app, to leave it in a working state.'),
              actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
            ),
          );
        }
      });

  Future<void> _provision() async {
    if (_ssid.text.isEmpty) {
      _add('Pick a WiFi network first.');
      return;
    }
    final cfg = await Navigator.of(context).push<ProvisioningConfig>(MaterialPageRoute(
      builder: (_) => BrokerPage(ssid: _ssid.text, pass: _pass.text, mac: link.mac),
    ));
    if (cfg == null) return;
    (await SharedPreferences.getInstance()).setString('ssid', cfg.wifiSsid);
    await _run('Provision', () async {
      await link.provision(cfg);
      _add('✅ Provisioned. Watch your broker for prod/LR4/${cfg.serial}/#');
    });
  }

  @override
  Widget build(BuildContext context) {
    final busy = _busy != null || !_connected;
    return Scaffold(
      appBar: AppBar(title: Text(link.mac ?? 'Litter-Robot 4')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!_connected)
            const Card(
              color: Colors.orange,
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text('Disconnected. Go back and reconnect (re-enter pairing mode if needed).'),
              ),
            ),
          if (_busy != null) ...[
            Text('$_busy…'),
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
          ],
          Text('WiFi', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          const Text('The list comes from the ROBOT\'s radio, so it shows what the robot can actually reach. '
              'It only supports 2.4 GHz.'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: busy ? null : _scanWifi,
            icon: const Icon(Icons.wifi_find),
            label: const Text('Scan networks from robot'),
          ),
          if (_networks != null)
            Card(
              child: Column(children: [
                if (_networks!.isEmpty) const ListTile(title: Text('The robot sees no networks.')),
                for (final n in _networks!)
                  ListTile(
                    dense: true,
                    selected: n.ssid == _ssid.text,
                    leading: Icon([Icons.wifi_1_bar, Icons.wifi_1_bar, Icons.wifi_2_bar, Icons.wifi][n.bars - 1]),
                    title: Text(n.ssid),
                    subtitle: Text('${n.rssi} dBm · ch ${n.channel} · ${n.authName}'),
                    trailing: n.secured ? const Icon(Icons.lock, size: 16) : null,
                    onTap: () => setState(() => _ssid.text = n.ssid),
                  ),
              ]),
            ),
          const SizedBox(height: 8),
          TextField(controller: _ssid, decoration: const InputDecoration(labelText: 'SSID')),
          TextField(
            controller: _pass,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'WiFi password',
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          TextField(
            controller: _serial,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Robot serial (optional for test)',
              helperText: 'LR4C + 6 digits from the label. If set, it is written first, as the Whisker app does.',
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton(onPressed: busy ? null : _testWifi, child: const Text('Test WiFi join')),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(onPressed: busy ? null : _provision, child: const Text('Provision to my broker')),
            ),
          ]),
          const SizedBox(height: 24),
          Row(children: [
            Text('Log', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            IconButton(
              tooltip: 'Copy log',
              icon: const Icon(Icons.copy),
              onPressed: () => Clipboard.setData(ClipboardData(text: _log.join('\n'))),
            ),
          ]),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(_log.join('\n'), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. Broker details
// ---------------------------------------------------------------------------
class BrokerPage extends StatefulWidget {
  const BrokerPage({super.key, required this.ssid, required this.pass, this.mac});
  final String ssid, pass;
  final String? mac;
  @override
  State<BrokerPage> createState() => _BrokerPageState();
}

class _BrokerPageState extends State<BrokerPage> {
  final _serial = TextEditingController();
  final _host = TextEditingController();
  final _ca = TextEditingController();
  final _cert = TextEditingController();
  final _key = TextEditingController();
  bool _identity = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      _serial.text = p.getString('serial') ?? '';
      _host.text = p.getString('host') ?? '';
      _ca.text = p.getString('ca') ?? '';
    });
  }

  Future<void> _pick(TextEditingController into) async {
    final r = await FilePicker.pickFiles(withData: true);
    final bytes = r?.files.single.bytes;
    if (bytes != null) setState(() => into.text = '${utf8.decode(bytes, allowMalformed: true).trim()}\n');
  }

  Widget _pem(String label, TextEditingController c) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text(label),
            const Spacer(),
            TextButton.icon(onPressed: () => _pick(c), icon: const Icon(Icons.file_open), label: const Text('Load file')),
          ]),
          TextField(
            controller: c,
            minLines: 3,
            maxLines: 6,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            decoration: const InputDecoration(border: OutlineInputBorder(), hintText: '-----BEGIN …-----'),
          ),
        ]),
      );

  Future<void> _submit() async {
    try {
      final cfg = ProvisioningConfig(
        serial: _serial.text,
        host: _host.text.trim(),
        caPem: _ca.text,
        wifiSsid: widget.ssid,
        wifiPass: widget.pass,
        clientCert: _identity ? _cert.text : null,
        clientKey: _identity ? _key.text : null,
      );
      if (cfg.host.isEmpty) throw ProvisioningError('Broker host is required');
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Write to the robot?'),
          content: Text('Robot: ${widget.mac ?? '?'}\n'
              'Serial: ${cfg.serial}\n'
              'WiFi: ${cfg.wifiSsid}\n'
              'Broker: ${cfg.host}:8883 (TLS)\n'
              'Topics: prod/LR4/${cfg.serial}/…\n'
              'Client identity: ${_identity ? 'yes — replaces the factory certificate' : 'no'}\n\n'
              'Reversible by re-onboarding in the Whisker app.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Provision')),
          ],
        ),
      );
      if (ok != true) return;
      final p = await SharedPreferences.getInstance();
      await p.setString('serial', cfg.serial);
      await p.setString('host', cfg.host);
      await p.setString('ca', cfg.caPem);
      if (mounted) Navigator.pop(context, cfg);
    } catch (e) {
      setState(() => _error = e is ArgumentError ? '${e.message}' : '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Your MQTT broker')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _serial,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Robot serial (label: LR4C + 6 digits)'),
            ),
            TextField(
              controller: _host,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Broker host / IP',
                helperText: 'Must match a name in the broker\'s TLS certificate. Port 8883.',
              ),
            ),
            _pem('CA certificate (PEM) the robot should trust', _ca),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Also give the robot a client certificate'),
              subtitle: const Text('Only if your broker requires client certs. Replaces the factory identity '
                  '(the Whisker app reissues one on re-onboarding).'),
              value: _identity,
              onChanged: (v) => setState(() => _identity = v),
            ),
            if (_identity) ...[
              _pem('Client certificate (PEM)', _cert),
              _pem('Client private key (PEM)', _key),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 20),
            FilledButton(onPressed: _submit, child: const Text('Review & provision')),
          ],
        ),
      );
}
