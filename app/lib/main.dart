import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

// ================= PARKSENSE-S3 BLE & ROI CONSTANTS =================
const String kBleDeviceName = 'ParkSense-S3';
const String kBleServiceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const String kBleSlotUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
const String kBleCtrlUuid = '1c95d5e3-d8f7-413a-bf3d-7a2e5d7be87e';

class SlotRoi {
  final double x, y, w, h;
  const SlotRoi(this.x, this.y, this.w, this.h);
}

const List<SlotRoi> kSlotRois = [
  SlotRoi(20, 75, 55, 65),
  SlotRoi(78, 75, 55, 65),
  SlotRoi(135, 75, 55, 65),
  SlotRoi(192, 75, 58, 65),
  SlotRoi(250, 75, 60, 65),
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ParkSenseApp());
}

class ParkSenseApp extends StatelessWidget {
  const ParkSenseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ParkSense S3',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF3B82F6),
          secondary: Color(0xFF22C55E),
          surface: Color(0xFF1E293B),
          error: Color(0xFFEF4444),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF1E293B),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF334155)),
          ),
        ),
      ),
      home: const ParkSenseHome(),
    );
  }
}

class SlotState {
  bool occupied;
  double? confidence;
  SlotState({this.occupied = false, this.confidence});
}

class ParkSenseHome extends StatefulWidget {
  const ParkSenseHome({super.key});

  @override
  State<ParkSenseHome> createState() => _ParkSenseHomeState();
}

class _ParkSenseHomeState extends State<ParkSenseHome> {
  int _tabIndex = 0;

  // ---- Parking & Telemetry State ----
  final List<SlotState> _slots = List.generate(5, (_) => SlotState());
  int _available = 5;
  int? _latencyMs;
  bool? _camOk;
  bool? _frameOk;
  int _fbFails = 0;
  bool? _modOk;
  int? _bleClientsOnNode;
  String _lastBlePayload = 'Waiting...';
  int? _rssi;
  int? _heapKb;
  int? _psramKb;
  int? _uptimeS;
  int? _cycles;

  // ---- Wi-Fi State ----
  final TextEditingController _ipController =
      TextEditingController(text: '10.67.153.208');
  bool _wifiPolling = false;
  bool _wifiConnected = false;
  bool _wifiBusy = false;
  Timer? _wifiTimer;
  Uint8List? _cameraBytes;
  String _wifiStatusMsg = 'Idle';

  // ---- BLE State ----
  BluetoothDevice? _bleDevice;
  BluetoothCharacteristic? _slotChar;
  BluetoothCharacteristic? _ctrlChar;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  bool _bleScanning = false;
  bool _bleConnected = false;
  String _bleStatusMsg = 'Disconnected';

  // ---- Controls & Logs ----
  double _thresholdPct = 70;
  final TextEditingController _pollMsController =
      TextEditingController(text: '2000');
  String _csvPreview = '';
  final List<String> _eventLogs = [];

  @override
  void dispose() {
    _wifiTimer?.cancel();
    _scanSub?.cancel();
    _connSub?.cancel();
    _notifySub?.cancel();
    _bleDevice?.disconnect();
    _ipController.dispose();
    _pollMsController.dispose();
    super.dispose();
  }

  void _addLog(String tag, String message) {
    final now = DateTime.now();
    final ts =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    if (!mounted) return;
    setState(() {
      _eventLogs.insert(0, '[$ts] [$tag] $message');
      if (_eventLogs.length > 80) {
        _eventLogs.removeLast();
      }
    });
  }

  String get _baseUrl {
    final raw = _ipController.text.trim();
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
    }
    return 'http://$raw';
  }

  // ================= BLE WORKFLOW =================
  Future<bool> _ensureBlePermissions() async {
    if (!Platform.isAndroid) return true;
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connOk = statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    final locOk = statuses[Permission.locationWhenInUse]?.isGranted ?? false;

    if (scanOk && connOk) return true;
    if (locOk) return true; // Android 11 and below
    _addLog('BLE', 'Bluetooth permissions denied');
    return false;
  }

  Future<void> _scanAndConnectBle() async {
    if (_bleScanning) return;

    final granted = await _ensureBlePermissions();
    if (!granted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please allow Nearby Devices / Bluetooth permission.'),
          ),
        );
      }
      return;
    }

    if (await FlutterBluePlus.isSupported == false) {
      _addLog('BLE', 'BLE not supported on this device');
      return;
    }

    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {}
    }

    setState(() {
      _bleScanning = true;
      _bleStatusMsg = 'Scanning for $kBleDeviceName...';
    });
    _addLog('BLE', 'Scanning for $kBleDeviceName');

    bool found = false;
    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen((results) async {
      if (found) return;
      for (final r in results) {
        final advName = r.advertisementData.advName;
        final platName = r.device.platformName;
        final hasService = r.advertisementData.serviceUuids.any(
          (u) => u.str.toLowerCase() == kBleServiceUuid,
        );
        if (advName == kBleDeviceName ||
            platName == kBleDeviceName ||
            hasService) {
          found = true;
          await FlutterBluePlus.stopScan();
          _addLog('BLE', 'Found ${r.device.remoteId} (RSSI ${r.rssi} dBm)');
          await _connectBleDevice(r.device);
          break;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    } catch (e) {
      _addLog('BLE', 'Scan error: $e');
    }

    await Future.delayed(const Duration(seconds: 10));
    if (!found && mounted) {
      setState(() {
        _bleScanning = false;
        if (!_bleConnected) _bleStatusMsg = 'Not found — tap Retry';
      });
      if (!_bleConnected) {
        _addLog('BLE', '$kBleDeviceName not found in scan window');
      }
    }
  }

  Future<void> _connectBleDevice(BluetoothDevice device) async {
    setState(() {
      _bleDevice = device;
      _bleScanning = false;
      _bleStatusMsg = 'Connecting...';
    });

    await _connSub?.cancel();
    _connSub = device.connectionState.listen((state) {
      if (!mounted) return;
      if (state == BluetoothConnectionState.disconnected) {
        setState(() {
          _bleConnected = false;
          _slotChar = null;
          _ctrlChar = null;
          _bleStatusMsg = 'Disconnected';
        });
        _addLog('BLE', 'Disconnected from $kBleDeviceName');
      }
    });

    try {
      await device.connect(timeout: const Duration(seconds: 12));
      if (Platform.isAndroid) {
        try {
          await device.requestMtu(128);
        } catch (_) {}
      }

      final services = await device.discoverServices();
      BluetoothCharacteristic? slotC;
      BluetoothCharacteristic? ctrlC;

      for (final s in services) {
        if (s.uuid.str.toLowerCase() == kBleServiceUuid) {
          for (final c in s.characteristics) {
            final id = c.uuid.str.toLowerCase();
            if (id == kBleSlotUuid) slotC = c;
            if (id == kBleCtrlUuid) ctrlC = c;
          }
        }
      }

      if (slotC == null) {
        throw Exception('ParkSense GATT service ($kBleServiceUuid) not found');
      }

      await _notifySub?.cancel();
      await slotC.setNotifyValue(true);
      _notifySub = slotC.onValueReceived.listen((bytes) {
        final payload = utf8.decode(bytes, allowMalformed: true).trim();
        _parseBlePayload(payload);
      });

      // Perform an initial READ so UI populates immediately
      try {
        final initBytes = await slotC.read();
        final initPayload = utf8.decode(initBytes, allowMalformed: true).trim();
        if (initPayload.isNotEmpty) _parseBlePayload(initPayload);
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _bleConnected = true;
        _slotChar = slotC;
        _ctrlChar = ctrlC;
        _bleStatusMsg = 'Connected (${device.remoteId})';
      });
      _addLog('BLE', 'Connected & subscribed to slot notifications');
    } catch (e) {
      _addLog('BLE', 'Connection failed: $e');
      try {
        await device.disconnect();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _bleConnected = false;
          _bleStatusMsg = 'Error — tap Retry';
        });
      }
    }
  }

  Future<void> _disconnectBle() async {
    await _notifySub?.cancel();
    await _bleDevice?.disconnect();
    if (!mounted) return;
    setState(() {
      _bleConnected = false;
      _slotChar = null;
      _ctrlChar = null;
      _bleStatusMsg = 'Disconnected';
    });
  }

  // Parses: AVAIL:3/5|S1:1,S2:0,S3:1,S4:0,S5:0
  void _parseBlePayload(String payload) {
    if (payload.isEmpty) return;
    _addLog('BLE-RX', payload);

    int? parsedAvail;
    final availMatch = RegExp(r'AVAIL:(\d+)/5').firstMatch(payload);
    if (availMatch != null) {
      parsedAvail = int.tryParse(availMatch.group(1)!);
    }

    final slotMatches = RegExp(r'S([1-5]):([01])').allMatches(payload);
    if (!mounted) return;
    setState(() {
      _lastBlePayload = payload;
      for (final m in slotMatches) {
        final idx = int.parse(m.group(1)!) - 1;
        final occ = m.group(2) == '1';
        _slots[idx].occupied = occ;
      }
      if (parsedAvail != null) {
        _available = parsedAvail;
      } else {
        _available = _slots.where((s) => !s.occupied).length;
      }
    });
  }

  Future<void> _writeBleThreshold() async {
    if (!_bleConnected || _ctrlChar == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect to ParkSense-S3 via BLE first.')),
      );
      return;
    }
    final cmd = 'THR:${_thresholdPct.round()}';
    try {
      await _ctrlChar!.write(utf8.encode(cmd), withoutResponse: false);
      _addLog('BLE-TX', 'Sent $cmd');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('BLE command sent: $cmd')),
        );
      }
    } catch (e) {
      _addLog('BLE-TX', 'Write failed: $e');
    }
  }

  // ================= WI-FI HTTP WORKFLOW =================
  void _toggleWifiPolling() {
    if (_wifiPolling) {
      _wifiTimer?.cancel();
      setState(() {
        _wifiPolling = false;
        _wifiConnected = false;
        _wifiStatusMsg = 'Stopped';
      });
      _addLog('WIFI', 'Polling stopped');
    } else {
      setState(() {
        _wifiPolling = true;
        _wifiStatusMsg = 'Connecting to $_baseUrl...';
      });
      _addLog('WIFI', 'Started polling $_baseUrl');
      _pollWifiOnce();
      _wifiTimer = Timer.periodic(
        const Duration(milliseconds: 2000),
        (_) => _pollWifiOnce(),
      );
    }
  }

  Future<void> _pollWifiOnce() async {
    if (_wifiBusy) return;
    _wifiBusy = true;
    try {
      final statusRes = await http
          .get(Uri.parse('$_baseUrl/api/status'))
          .timeout(const Duration(seconds: 3));

      if (statusRes.statusCode == 200) {
        final Map<String, dynamic> d = jsonDecode(statusRes.body);
        final List<dynamic> slotList = (d['slots'] as List<dynamic>? ?? []);

        Uint8List? jpegBytes;
        if (_tabIndex == 0 && (d['frame_ok'] == true)) {
          try {
            final imgRes = await http
                .get(Uri.parse(
                    '$_baseUrl/capture?t=${DateTime.now().millisecondsSinceEpoch}'))
                .timeout(const Duration(seconds: 3));
            if (imgRes.statusCode == 200 && imgRes.bodyBytes.isNotEmpty) {
              jpegBytes = imgRes.bodyBytes;
            }
          } catch (_) {}
        }

        if (!mounted) return;
        setState(() {
          _wifiConnected = true;
          _wifiStatusMsg = 'Live (${_ipController.text.trim()})';
          _available = (d['available'] as num?)?.toInt() ?? _available;
          _latencyMs = (d['latency_ms'] as num?)?.toInt();
          _camOk = d['cam_ok'] as bool?;
          _frameOk = d['frame_ok'] as bool?;
          _fbFails = (d['fb_fails'] as num?)?.toInt() ?? 0;
          _modOk = d['mod_ok'] as bool?;
          _bleClientsOnNode = (d['ble_clients'] as num?)?.toInt();
          if (d['ble_payload'] is String) {
            _lastBlePayload = d['ble_payload'] as String;
          }
          _rssi = (d['rssi'] as num?)?.toInt();
          _heapKb = (d['heap_kb'] as num?)?.toInt();
          _psramKb = (d['psram_kb'] as num?)?.toInt();
          _uptimeS = (d['uptime_s'] as num?)?.toInt();
          _cycles = (d['cycles'] as num?)?.toInt();

          for (int i = 0; i < slotList.length && i < 5; i++) {
            final item = slotList[i] as Map<String, dynamic>;
            _slots[i].occupied = item['occ'] == true;
            _slots[i].confidence = (item['conf'] as num?)?.toDouble();
          }
          if (jpegBytes != null) {
            _cameraBytes = jpegBytes;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _wifiConnected = false;
          _wifiStatusMsg = 'Unreachable (retrying...)';
        });
      }
    } finally {
      _wifiBusy = false;
    }
  }

  Future<void> _sendWifiSettings() async {
    final thr = (_thresholdPct / 100.0).toStringAsFixed(2);
    final intv = int.tryParse(_pollMsController.text.trim()) ?? 2000;
    try {
      final res = await http
          .get(Uri.parse('$_baseUrl/api/settings?thr=$thr&intv=$intv'))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        _addLog('WIFI-TX', 'Updated thr=$thr, intv=${intv}ms');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Wi-Fi settings saved (THR=${_thresholdPct.round()}%)')),
          );
        }
      }
    } catch (e) {
      _addLog('WIFI-TX', 'Settings update failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not reach ESP32 over Wi-Fi.')),
        );
      }
    }
  }

  Future<void> _fetchCsvLog() async {
    try {
      final res = await http
          .get(Uri.parse('$_baseUrl/export.csv'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200 && mounted) {
        setState(() => _csvPreview = res.body);
        _addLog('WIFI', 'Downloaded CSV (${res.body.length} bytes)');
      }
    } catch (e) {
      _addLog('WIFI', 'CSV fetch failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Wi-Fi unreachable for CSV download.')),
        );
      }
    }
  }

  // ================= UI BUILDERS =================
  String get _activeSourceLabel {
    if (_wifiConnected && _bleConnected) return 'Wi-Fi + BLE';
    if (_wifiConnected) return 'Wi-Fi HTTP';
    if (_bleConnected) return 'BLE GATT';
    return 'Offline';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ParkSense S3', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            Text('TinyML + NimBLE 2.x + OV2640', style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              visualDensity: VisualDensity.compact,
              backgroundColor: (_wifiConnected || _bleConnected)
                  ? const Color(0xFF14532D)
                  : const Color(0xFF334155),
              side: BorderSide(
                color: (_wifiConnected || _bleConnected)
                    ? const Color(0xFF22C55E)
                    : const Color(0xFF64748B),
              ),
              label: Text(
                _activeSourceLabel,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _tabIndex,
        children: [
          _buildMonitorTab(),
          _buildDiagnosticsTab(),
          _buildControlTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF1E293B),
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.local_parking), label: 'Monitor'),
          NavigationDestination(icon: Icon(Icons.analytics_outlined), label: 'Diagnostics'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Control'),
        ],
      ),
    );
  }

  Widget _buildMonitorTab() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        // Connection Control Bar
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.bluetooth,
                      color: _bleConnected ? const Color(0xFF38BDF8) : const Color(0xFF94A3B8),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('BLE GATT (ParkSense-S3)', style: TextStyle(fontWeight: FontWeight.w600)),
                          Text(_bleStatusMsg, style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
                        ],
                      ),
                    ),
                    FilledButton.tonal(
                      onPressed: _bleScanning
                          ? null
                          : (_bleConnected ? _disconnectBle : _scanAndConnectBle),
                      child: Text(_bleScanning
                          ? 'Scanning...'
                          : (_bleConnected ? 'Disconnect' : 'Connect BLE')),
                    ),
                  ],
                ),
                const Divider(height: 20, color: Color(0xFF334155)),
                Row(
                  children: [
                    Icon(
                      Icons.wifi,
                      color: _wifiConnected ? const Color(0xFF22C55E) : const Color(0xFF94A3B8),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _ipController,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: 'ESP32-S3 IP ($_wifiStatusMsg)',
                          border: const OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.url,
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _toggleWifiPolling,
                      style: FilledButton.styleFrom(
                        backgroundColor: _wifiPolling
                            ? const Color(0xFFDC2626)
                            : const Color(0xFF2563EB),
                      ),
                      child: Text(_wifiPolling ? 'Stop' : 'Connect'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Summary KPI Row
        Row(
          children: [
            Expanded(
              child: _kpiCard(
                'Available Slots',
                '$_available / 5',
                _available > 0 ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _kpiCard(
                'TinyML Latency',
                _latencyMs != null ? '$_latencyMs ms' : '-- ms',
                const Color(0xFF38BDF8),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // 5-Slot Status Grid
        const Text('Parking Bays', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 5,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.15,
          ),
          itemBuilder: (_, idx) {
            final s = _slots[idx];
            final bg = s.occupied ? const Color(0xFF7F1D1D) : const Color(0xFF14532D);
            final border = s.occupied ? const Color(0xFFEF4444) : const Color(0xFF22C55E);
            return Container(
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: border, width: 1.8),
              ),
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Slot ${idx + 1}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 4),
                  Text(
                    s.occupied ? 'OCCUPIED' : 'EMPTY',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: border),
                  ),
                  if (s.confidence != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      '${(s.confidence! * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(fontSize: 11, color: Color(0xFFE2E8F0)),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 14),

        // Live OV2640 Camera Feed with ROI Overlay
        const Text('OV2640 Live Feed (QVGA 320x240 + ROI Overlay)',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Card(
          clipBehavior: Clip.antiAlias,
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_cameraBytes != null)
                  Image.memory(
                    _cameraBytes!,
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                  )
                else
                  Container(
                    color: const Color(0xFF020617),
                    alignment: Alignment.center,
                    child: Text(
                      _wifiConnected
                          ? 'Waiting for camera frame...'
                          : 'Connect Wi-Fi above to view live OV2640 stream\n(BLE continues updating slots offline)',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                    ),
                  ),
                CustomPaint(
                  painter: _RoiOverlayPainter(_slots),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _kpiCard(String title, String value, Color accent) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: accent)),
          ],
        ),
      ),
    );
  }

  Widget _buildDiagnosticsTab() {
    final rows = <MapEntry<String, String>>[
      MapEntry('Data Source', _activeSourceLabel),
      MapEntry('OV2640 Camera',
          _camOk == null ? '--' : '${_camOk! ? "Init PASS" : "FAIL"} | ${_frameOk == true ? "Frame OK" : "NULL ($_fbFails fails)"}'),
      MapEntry('TinyML Model', _modOk == null ? '--' : (_modOk! ? 'PASS (10.12 KB INT8)' : 'FAIL')),
      MapEntry('BLE Clients on Node', _bleClientsOnNode?.toString() ?? (_bleConnected ? '1 (this phone)' : '--')),
      MapEntry('Last BLE Payload', _lastBlePayload),
      MapEntry('Wi-Fi RSSI', _rssi != null ? '$_rssi dBm' : '--'),
      MapEntry('Free Heap / PSRAM',
          (_heapKb != null && _psramKb != null) ? '$_heapKb KB / $_psramKb KB' : '--'),
      MapEntry('Uptime / Cycles',
          (_uptimeS != null && _cycles != null) ? '${_uptimeS}s ($_cycles cycles)' : '--'),
    ];

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Card(
          child: Column(
            children: rows
                .map((e) => ListTile(
                      dense: true,
                      title: Text(e.key, style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8))),
                      trailing: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 200),
                        child: Text(
                          e.value,
                          textAlign: TextAlign.right,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ))
                .toList(),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Live BLE & Wi-Fi Event Log',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            TextButton(
              onPressed: () => setState(() => _eventLogs.clear()),
              child: const Text('Clear'),
            ),
          ],
        ),
        Card(
          child: Container(
            height: 260,
            padding: const EdgeInsets.all(10),
            child: _eventLogs.isEmpty
                ? const Center(
                    child: Text('No events logged yet.', style: TextStyle(color: Color(0xFF94A3B8))),
                  )
                : ListView.builder(
                    itemCount: _eventLogs.length,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        _eventLogs[i],
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildControlTab() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Occupancy Confidence Threshold: ${_thresholdPct.round()}%',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                Slider(
                  value: _thresholdPct,
                  min: 50,
                  max: 99,
                  divisions: 49,
                  label: '${_thresholdPct.round()}%',
                  onChanged: (v) => setState(() => _thresholdPct = v),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _pollMsController,
                  decoration: const InputDecoration(
                    labelText: 'Node Inference Interval (ms, Wi-Fi only)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _writeBleThreshold,
                        icon: const Icon(Icons.bluetooth_connected, size: 18),
                        label: Text('Send BLE (THR:${_thresholdPct.round()})'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: _sendWifiSettings,
                        icon: const Icon(Icons.wifi, size: 18),
                        label: const Text('Send Wi-Fi'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('CSV Telemetry Export (/export.csv)',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: _fetchCsvLog,
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Fetch CSV Log'),
                    ),
                    const SizedBox(width: 8),
                    if (_csvPreview.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _csvPreview));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('CSV copied to clipboard')),
                          );
                        },
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('Copy'),
                      ),
                  ],
                ),
                if (_csvPreview.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    height: 180,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF020617),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        _csvPreview,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RoiOverlayPainter extends CustomPainter {
  final List<SlotState> slots;
  _RoiOverlayPainter(this.slots);

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 320.0;
    final sy = size.height / 240.0;

    for (int i = 0; i < kSlotRois.length; i++) {
      final roi = kSlotRois[i];
      final occ = slots[i].occupied;
      final color = occ ? const Color(0xFFEF4444) : const Color(0xFF22C55E);

      final rect = Rect.fromLTWH(roi.x * sx, roi.y * sy, roi.w * sx, roi.h * sy);
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawRect(rect, paint);

      final tp = TextPainter(
        text: TextSpan(
          text: 'S${i + 1}',
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            backgroundColor: Colors.black54,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(rect.left + 2, (rect.top - 14).clamp(0.0, size.height - 14)));
    }
  }

  @override
  bool shouldRepaint(covariant _RoiOverlayPainter oldDelegate) => true;
}
