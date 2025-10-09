import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// ===============================
/// TTL FILE CACHE
/// ===============================
class FileCacheEntry {
  final String filename;
  final DateTime expiresAt;
  final int bytes;
  final String mime;
  final Map<String, dynamic>? meta;

  FileCacheEntry({
    required this.filename,
    required this.expiresAt,
    required this.bytes,
    required this.mime,
    this.meta,
  });

  Map<String, dynamic> toJson() => {
    'filename': filename,
    'expiresAt': expiresAt.toIso8601String(),
    'bytes': bytes,
    'mime': mime,
    'meta': meta,
  };

  static FileCacheEntry fromJson(Map<String, dynamic> j) => FileCacheEntry(
    filename: j['filename'],
    expiresAt: DateTime.parse(j['expiresAt']),
    bytes: j['bytes'],
    mime: j['mime'],
    meta: (j['meta'] as Map?)?.cast<String, dynamic>(),
  );
}

class TTLFileCache {
  TTLFileCache._();
  static const _folder = 'surveyor_cache';
  static const _indexName = '.index.json';
  static const _sessionCounterName = '.session_counter';
  late final Directory _dir;
  late final File _indexFile;
  late final File _sessionCounterFile;
  final Map<String, FileCacheEntry> _index = {};

  static Future<TTLFileCache> open() async {
    final cache = TTLFileCache._();
    final base = await getApplicationSupportDirectory();
    cache._dir = Directory('${base.path}/$_folder');
    if (!(await cache._dir.exists())) await cache._dir.create(recursive: true);
    cache._indexFile = File('${cache._dir.path}/$_indexName');
    cache._sessionCounterFile = File('${cache._dir.path}/$_sessionCounterName');
    await cache._loadIndex();
    await cache._initSessionCounterIfNeeded();
    await cache.purgeExpired();
    return cache;
  }

  Future<void> _initSessionCounterIfNeeded() async {
    if (!await _sessionCounterFile.exists()) {
      await _sessionCounterFile.writeAsString('0');
    }
  }

  Future<int> nextSessionNumber() async {
    int current = 0;
    if (await _sessionCounterFile.exists()) {
      final raw = (await _sessionCounterFile.readAsString()).trim();
      current = int.tryParse(raw) ?? 0;
    }
    final next = current + 1;
    await _sessionCounterFile.writeAsString(next.toString(), flush: true);
    return next;
  }

  Future<void> _loadIndex() async {
    if (await _indexFile.exists()) {
      try {
        final raw = await _indexFile.readAsString();
        final list =
        (jsonDecode(raw) as List).cast<Map>().cast<Map<String, dynamic>>();
        _index
          ..clear()
          ..addEntries(list.map((m) {
            final e = FileCacheEntry.fromJson(m);
            return MapEntry(e.filename, e);
          }));
      } catch (_) {
        await _rebuildIndexFromDisk();
      }
    } else {
      await _rebuildIndexFromDisk();
    }
  }

  Future<void> _rebuildIndexFromDisk() async {
    _index.clear();
    final files = _dir
        .listSync()
        .whereType<File>()
        .where((f) {
      final name = f.path.split('/').last;
      return name != _indexName && name != _sessionCounterName;
    });
    for (final f in files) {
      final stat = await f.stat();
      final name = f.path.split('/').last;
      _index[name] = FileCacheEntry(
        filename: name,
        expiresAt: DateTime.now().add(const Duration(days: 14)),
        bytes: stat.size,
        mime: 'text/csv',
        meta: {'recovered': true},
      );
    }
    await _saveIndex();
  }

  Future<void> _saveIndex() async {
    final list = _index.values.map((e) => e.toJson()).toList();
    await _indexFile.writeAsString(jsonEncode(list));
  }

  String _safe(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  Future<void> ensureHeader({
    required String basename,
    required String headerLine,
    required Duration ttl,
    String mime = 'text/csv',
    Map<String, dynamic>? meta,
  }) async {
    final name = _safe(basename);
    final path = '${_dir.path}/$name';
    final f = File(path);
    if (!await f.exists() || (await f.length()) == 0) {
      final sink = f.openWrite();
      sink.writeln(headerLine);
      await sink.flush();
      await sink.close();
      final stat = await f.stat();
      _index[name] = FileCacheEntry(
        filename: name,
        expiresAt: DateTime.now().add(ttl),
        bytes: stat.size,
        mime: mime,
        meta: meta,
      );
      await _saveIndex();
    }
  }

  Future<String> appendLine({
    required String basename,
    required String line,
    required Duration ttl,
    String mime = 'text/csv',
    Map<String, dynamic>? meta,
  }) async {
    final name = _safe(basename);
    final f = File('${_dir.path}/$name');
    final sink = f.openWrite(mode: FileMode.append);
    sink.writeln(line);
    await sink.flush();
    await sink.close();
    final stat = await f.stat();
    _index[name] = FileCacheEntry(
      filename: name,
      expiresAt: _index[name]?.expiresAt ?? DateTime.now().add(ttl),
      bytes: stat.size,
      mime: mime,
      meta: meta ?? _index[name]?.meta,
    );
    await _saveIndex();
    return f.path;
  }

  Future<void> purgeExpired() async {
    final now = DateTime.now();
    final expired =
    _index.values.where((e) => e.expiresAt.isBefore(now)).toList();
    for (final e in expired) {
      final f = File('${_dir.path}/${e.filename}');
      if (await f.exists()) await f.delete();
      _index.remove(e.filename);
    }
    await _saveIndex();
  }
}

/// ===============================
/// MAIN APP
/// ===============================
void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'BLE Surveyor',
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
    home: const BLEScanner(),
  );
}

/// ===============================
/// BLE SCANNER
/// ===============================
class BLEScanner extends StatefulWidget {
  const BLEScanner({super.key});
  @override
  State<BLEScanner> createState() => _BLEScannerState();
}

class _BLEScannerState extends State<BLEScanner> {
  final List<ScanResult> foundDevices = [];
  TTLFileCache? _cache;
  bool _cacheReady = false;

  @override
  void initState() {
    super.initState();
    _initCache();
    _startBLEScan();
  }

  Future<void> _initCache() async {
    _cache = await TTLFileCache.open();
    await _cache!.purgeExpired();
    setState(() => _cacheReady = true);
  }

  Future<void> _startBLEScan() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (!foundDevices.any((d) => d.device.id == r.device.id)) {
          setState(() => foundDevices.add(r));
        }
      }
    });
  }

  void _connect(BluetoothDevice d) {
    if (_cacheReady) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SerialDataPage(device: d, cache: _cache!),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('BLE Scanner')),
    body: foundDevices.isEmpty
        ? const Center(child: Text('🔍 Scanning for BLE devices...'))
        : ListView.builder(
      itemCount: foundDevices.length,
      itemBuilder: (c, i) {
        final r = foundDevices[i];
        return ListTile(
          title:
          Text(r.device.name.isEmpty ? 'Unknown Device' : r.device.name),
          subtitle: Text(r.device.id.id),
          trailing: Text('${r.rssi} dBm'),
          onTap: () => _connect(r.device),
        );
      },
    ),
  );
}

/// ===============================
/// SERIAL DATA PAGE (MAP + SESSION FILE CREATION)
/// ===============================
class SerialDataPage extends StatefulWidget {
  final BluetoothDevice device;
  final TTLFileCache cache;
  const SerialDataPage({super.key, required this.device, required this.cache});

  @override
  State<SerialDataPage> createState() => _SerialDataPageState();
}

class _SerialDataPageState extends State<SerialDataPage> {
  String latestMethane = '--';
  String latestEthane = '--';
  String? phoneLatitude, phoneLongitude;

  final MapController _mapController = MapController();

  String? _sessionFile;
  int? _sessionNumber;
  final Duration _ttl = const Duration(days: 14);

  @override
  void initState() {
    super.initState();
    _initLocation();
  }

  Future<void> _initLocation() async {
    await Geolocator.requestPermission();
    final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);
    setState(() {
      phoneLatitude = pos.latitude.toString();
      phoneLongitude = pos.longitude.toString();
    });
  }

  String _slug(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_|_$'), '');

  String _fmtUtc(DateTime dt) {
    return dt.toUtc().toIso8601String().replaceAll(RegExp(r'[:\-T]'), '').split('.').first;
  }

  Future<void> _startSessionFile() async {
    final sess = await widget.cache.nextSessionNumber();
    _sessionNumber = sess;

    final devId = widget.device.id.id.replaceAll(':', '').toLowerCase();
    final last6 = devId.length >= 6 ? devId.substring(devId.length - 6) : devId;
    final devName = widget.device.name.isNotEmpty ? widget.device.name : 'device';
    final niceName = _slug(devName);
    final stamp = _fmtUtc(DateTime.now());

    final name =
        'survey_${niceName}_${last6}_session_${sess.toString().padLeft(3, '0')}_$stamp.csv';
    _sessionFile = name;

    const header =
        'GPS UTC,Error Code,Methane (ppm),Ethane (ppm),Phone Latitude,Phone Longitude';

    await widget.cache.ensureHeader(
      basename: name,
      headerLine: header,
      ttl: _ttl,
      mime: 'text/csv',
      meta: {
        'schema': 'sensor_v1',
        'device_name': widget.device.name,
        'device_id': widget.device.id.id,
        'session_number': sess,
        'session_started_utc': DateTime.now().toUtc().toIso8601String(),
      },
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('📄 Session $sess started: $_sessionFile')),
    );

    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Row(
        children: [
          Image.asset('assets/logo.png', height: 40),
          const SizedBox(width: 10),
          Expanded(child: Text('Connected: ${widget.device.name}')),
        ],
      ),
    ),
    body: Column(
      children: [
        if (phoneLatitude != null && phoneLongitude != null)
          AspectRatio(
            aspectRatio: 3 / 4,
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: LatLng(
                    double.parse(phoneLatitude!), double.parse(phoneLongitude!)),
                initialZoom: 15.5,
              ),
              children: [
                TileLayer(
                  urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                ),
                MarkerLayer(markers: [
                  Marker(
                    point: LatLng(double.parse(phoneLatitude!),
                        double.parse(phoneLongitude!)),
                    width: 40,
                    height: 40,
                    child: const Icon(Icons.circle, color: Colors.blue),
                  ),
                ]),
              ],
            ),
          )
        else
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text("📍 Fetching location..."),
          ),
        const SizedBox(height: 10),
        Card(
          margin: const EdgeInsets.all(16),
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text('Methane: $latestMethane ppm',
                    style: const TextStyle(fontSize: 20)),
                const SizedBox(height: 8),
                Text('Ethane: $latestEthane ppm',
                    style: const TextStyle(fontSize: 20)),
              ],
            ),
          ),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.play_circle),
          label: const Text('Start New Session'),
          onPressed: _startSessionFile,
        ),
      ],
    ),
  );
}
