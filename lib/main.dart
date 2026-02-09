import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
import 'package:share_plus/share_plus.dart';

/// ===============================
/// TTL FILE CACHE (CSV with TTL)
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
    final base = await getApplicationSupportDirectory(); // private per-app dir
    cache._dir = Directory('${base.path}/$_folder');
    if (!(await cache._dir.exists())) {
      await cache._dir.create(recursive: true);
    }
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
    try {
      int current = 0;
      if (await _sessionCounterFile.exists()) {
        final raw = (await _sessionCounterFile.readAsString()).trim();
        current = int.tryParse(raw) ?? 0;
      }
      final next = current + 1;
      await _sessionCounterFile.writeAsString(next.toString(), flush: true);
      return next;
    } catch (_) {
      await _sessionCounterFile.writeAsString('1', flush: true);
      return 1;
    }
  }

  Future<void> _loadIndex() async {
    if (await _indexFile.exists()) {
      try {
        final raw = await _indexFile.readAsString();
        final list = (jsonDecode(raw) as List).cast<Map>().cast<Map<String, dynamic>>();
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
        expiresAt: DateTime.now().add(const Duration(days: 14)), // default TTL
        bytes: stat.size,
        mime: 'text/csv',
        meta: {'recovered': true},
      );
    }
    await _saveIndex();
  }

  Future<void> _saveIndex() async {
    final list = _index.values.map((e) => e.toJson()).toList(growable: false);
    await _indexFile.writeAsString(jsonEncode(list));
  }

  String _safe(String name) => name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

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
    final exists = await f.exists();
    if (!exists || (await f.length()) == 0) {
      final sink = f.openWrite(mode: FileMode.write);
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
    final path = '${_dir.path}/$name';
    final f = File(path);
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
    return path;
  }

  Future<List<File>> listActive() async {
    final now = DateTime.now();
    final actives = _index.values.where((e) => e.expiresAt.isAfter(now));
    return actives.map((e) => File('${_dir.path}/${e.filename}')).toList();
  }

  Future<void> markUploaded(String filename) async {
    final name = _safe(filename);
    final f = File('${_dir.path}/$name');
    if (await f.exists()) {
      await f.delete();
    }
    _index.remove(name);
    await _saveIndex();
  }

  Future<int> purgeExpired() async {
    int removed = 0;
    final now = DateTime.now();
    final expired = _index.values.where((e) => e.expiresAt.isBefore(now)).toList();
    for (final e in expired) {
      final f = File('${_dir.path}/${e.filename}');
      if (await f.exists()) await f.delete();
      _index.remove(e.filename);
      removed++;
    }
    if (removed > 0) await _saveIndex();
    return removed;
  }

  Future<void> enforceMaxBytes(int maxBytes) async {
    int total = _index.values.fold(0, (s, e) => s + e.bytes);
    if (total <= maxBytes) return;
    final sorted = _index.values.toList()
      ..sort((a, b) {
        final c = a.expiresAt.compareTo(b.expiresAt);
        return c != 0 ? c : a.filename.compareTo(b.filename);
      });
    for (final e in sorted) {
      if (total <= maxBytes) break;
      final f = File('${_dir.path}/${e.filename}');
      if (await f.exists()) await f.delete();
      _index.remove(e.filename);
      total -= e.bytes;
    }
    await _saveIndex();
  }
}

/// ===============================
/// APP
/// ===============================
void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Scanner - Aryan',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const BLEScanner(),
    );
  }
}

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
    await _requestPermissions();
    BluetoothAdapterState state = await FlutterBluePlus.adapterState.first;
    if (state != BluetoothAdapterState.on) {
      await for (final newState in FlutterBluePlus.adapterState) {
        if (newState == BluetoothAdapterState.on) break;
      }
    }
    foundDevices.clear();
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        if (!foundDevices.any((d) => d.device.id == r.device.id)) {
          setState(() => foundDevices.add(r));
        }
      }
    });
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  void _connectAndShowData(BluetoothDevice device) {
    if (!_cacheReady) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SerialDataPage(device: device, cache: _cache!),
      ),
    );
  }

  void _openPendingFiles() {
    if (!_cacheReady) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PendingFilesPage(cache: _cache!),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset('assets/logo.png', height: 60),
            const SizedBox(width: 10),
            Expanded(child: Text('BLE Scanner', style: const TextStyle(fontSize: 16))),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder),
            tooltip: 'Pending files',
            onPressed: _openPendingFiles,
          ),
        ],
      ),
      body: foundDevices.isEmpty
          ? const Center(child: Text('🔍 Scanning for BLE devices...'))
          : ListView.builder(
        itemCount: foundDevices.length,
        itemBuilder: (context, index) {
          final device = foundDevices[index].device;
          return ListTile(
            title: Text(device.name.isNotEmpty ? device.name : '(Unknown Device)'),
            subtitle: Text(device.id.id),
            trailing: Text('${foundDevices[index].rssi} dBm'),
            onTap: () => _connectAndShowData(device),
          );
        },
      ),
    );
  }
}

class SerialDataPage extends StatefulWidget {
  final BluetoothDevice device;
  final TTLFileCache cache;

  const SerialDataPage({super.key, required this.device, required this.cache});

  @override
  State<SerialDataPage> createState() => _SerialDataPageState();
}

class _SerialDataPageState extends State<SerialDataPage> {
  final List<Map<String, String>> dataLog = [];
  final List<LatLng> customMarkers = [];
  BluetoothCharacteristic? notifyChar;
  bool isPaused = false;
  bool alarmEnabled = true;
  double threshold = 20.0;
  bool compactView = false;
  String latestMethane = '--';
  String latestEthane = '--';

  String? phoneLatitude;
  String? phoneLongitude;
  String? gpsUtcIso; // GPS UTC ISO

  // Service/Char UUIDs (Adjust to your device)
  final serviceUUID = Guid("4fafc201-1fb5-459e-8fcc-c5c9c331914b");
  final charUUID = Guid("beb5483e-36e1-4688-b7f5-ea07361b26a8");

  final MapController _mapController = MapController();
  StreamSubscription<Position>? _positionStream;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  final AudioPlayer _player = AudioPlayer();
  DateTime? _lastAlarmTime;
  final Duration _alarmCooldown = const Duration(seconds: 10);

  // Cache/session
  static const _ttl = Duration(days: 14);
  static const _maxCacheBytes = 200 * 1024 * 1024; // 200 MB
  String? _sessionFile; // new CSV per connection
  int? _sessionNumber;  // persisted incremental counter

  @override
  void initState() {
    super.initState();
    _getPhoneLocation();
    _startLiveLocationTracking();
    _connectAndListen();
    _watchConnectionState();
  }

  String _slug(String s) {
    final cleaned = s.trim().replaceAll(' ', '_');
    return cleaned.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
  }

  String _fmtUtc(DateTime dt) {
    final z = dt.toUtc();
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${z.year}-${p2(z.month)}-${p2(z.day)}_${p2(z.hour)}-${p2(z.minute)}-${p2(z.second)}Z';
  }

  Future<void> _startSessionFile() async {
    final sess = await widget.cache.nextSessionNumber();
    _sessionNumber = sess;

    final devId = widget.device.id.id.replaceAll(':', '').toLowerCase();
    final last6 = devId.length >= 6 ? devId.substring(devId.length - 6) : devId;
    final devName = widget.device.name.isNotEmpty ? widget.device.name : 'device';
    final niceName = _slug(devName);
    final stamp = _fmtUtc(DateTime.now());

    final name = 'survey_${niceName}_${last6}_session_${sess.toString().padLeft(3, '0')}_$stamp.csv';
    _sessionFile = name;

    // GPS UTC first; no device timestamp
    const header = 'GPS UTC,Error Code,Methane (ppm),Ethane (ppm),Phone Latitude,Phone Longitude';
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
    setState(() {});
  }

  void _watchConnectionState() {
    _connSub = widget.device.connectionState.listen((s) async {
      if (s == BluetoothConnectionState.connected) {
        // nothing
      } else if (s == BluetoothConnectionState.disconnected) {
        setState(() {
          _sessionFile = null;
          _sessionNumber = null;
        });
      }
    });
  }

  void _startLiveLocationTracking() {
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 1,
    );
    _positionStream?.cancel();
    _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position pos) {
      setState(() {
        phoneLatitude = pos.latitude.toString();
        phoneLongitude = pos.longitude.toString();
        gpsUtcIso = (pos.timestamp ?? DateTime.now()).toUtc().toIso8601String();
      });
      _mapController.move(LatLng(pos.latitude, pos.longitude), 16); //this mobes the map on GPS updates
    });
    // add this timer separately (AFTER the above block)
    Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        gpsUtcIso = DateTime.now().toUtc().toIso8601String();
      });
    });
  }

  Future<void> _getPhoneLocation() async {
    await Geolocator.requestPermission();
    final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    setState(() {
      phoneLatitude = pos.latitude.toString();
      phoneLongitude = pos.longitude.toString();
      gpsUtcIso = (pos.timestamp ?? DateTime.now()).toUtc().toIso8601String();
    });
  }
// BLE Listener
  Future<void> _connectAndListen() async {
    try {
      await widget.device.connect(autoConnect: false);
      await _startSessionFile();

      final services = await widget.device.discoverServices();
      for (final service in services) {
        for (final c in service.characteristics) {
          if (service.uuid == serviceUUID && c.uuid == charUUID) {
            notifyChar = c;
            await c.setNotifyValue(true);

            DateTime? lastUiUpdate; // throttle UI updates

            c.onValueReceived.listen((value) async {
              if (isPaused) return;

              // Decode BLE packet
              final received = String.fromCharCodes(value).trim();
              final raw = parseCSV(received);
              if (raw.isEmpty) return;

              // Fresh UTC timestamp for every packet
              final utcNow = DateTime.now().toUtc();
              final gpsUtc = utcNow.toIso8601String();

              // Debug print (optional)
              print('Sensor packet at $gpsUtc  '
                  'Lat:$phoneLatitude  Lon:$phoneLongitude  '
                  'CH₄:${raw['Methane (ppm)']}  C₂H₆:${raw['Ethane (ppm)']}');

              // Assemble row
              final ordered = <String, String>{
                'GPS UTC': gpsUtc,
                'Error Code': raw['Error Code'] ?? '',
                'Methane (ppm)': raw['Methane (ppm)'] ?? '',
                'Ethane (ppm)': raw['Ethane (ppm)'] ?? '',
                'Phone Latitude': phoneLatitude ?? '',
                'Phone Longitude': phoneLongitude ?? '',
              };

              // Save asynchronously
              unawaited(_saveReadingToCache(ordered));

              // Throttle UI refresh to ~1 Hz
              final now = DateTime.now();
              if (lastUiUpdate == null ||
                  now.difference(lastUiUpdate!) > const Duration(seconds: 1)) {
                setState(() {
                  latestMethane = ordered['Methane (ppm)'] ?? '--';
                  latestEthane = ordered['Ethane (ppm)'] ?? '--';
                  if (dataLog.length > 500) dataLog.removeAt(0);
                  dataLog.add(ordered);
                });
                lastUiUpdate = now;
              }

              // Alarm logic
              final methane = double.tryParse(ordered['Methane (ppm)'] ?? '0') ?? 0;
              if (alarmEnabled && methane > threshold) _triggerAlarm(methane);
            });

            return;
          }
        }
      }
    } catch (e, st) {
      debugPrint('BLE connect error: $e\n$st');
    }
  }


  void _togglePause() => setState(() => isPaused = !isPaused);

  void _triggerAlarm(double value) async {
    final now = DateTime.now();
    if (_lastAlarmTime != null && now.difference(_lastAlarmTime!) < _alarmCooldown) return;
    _lastAlarmTime = now;
    if (await Vibration.hasVibrator() ?? false) Vibration.vibrate(duration: 500);
    await _player.play(AssetSource('alert.mp3'));
  }

  Map<String, String> parseCSV(String line) {
    // Incoming CSV: device_timestamp,err,methane_ppm,ethane_ppm
    final parts = line.split(',');
    if (parts.length != 4) return {};
    return {
      // We intentionally ignore the device timestamp downstream
      'Error Code': parts[1],
      'Methane (ppm)': parts[2],
      'Ethane (ppm)': parts[3],
    };
  }



  Future<void> _saveReadingToCache(Map<String, String> row) async {
    try {
      _sessionFile ??= 'survey_fallback_session_${DateTime.now().millisecondsSinceEpoch}.csv';

      // Header: GPS UTC first; no device timestamp
      const header = 'GPS UTC,Error Code,Methane (ppm),Ethane (ppm),Phone Latitude,Phone Longitude';
      await widget.cache.ensureHeader(
        basename: _sessionFile!,
        headerLine: header,
        ttl: _ttl,
        mime: 'text/csv',
        meta: {'schema': 'sensor_v1'},
      );

      final line = [
        row['GPS UTC'] ?? (gpsUtcIso ?? DateTime.now().toUtc().toIso8601String()),
        row['Error Code'] ?? '',
        row['Methane (ppm)'] ?? '',
        row['Ethane (ppm)'] ?? '',
        row['Phone Latitude'] ?? '',
        row['Phone Longitude'] ?? '',
      ].join(',');

      await widget.cache.appendLine(
        basename: _sessionFile!,
        line: line,
        ttl: _ttl,
        mime: 'text/csv',
      );

      await widget.cache.enforceMaxBytes(_maxCacheBytes);
    } catch (_) {
      // Optionally show a small UI warning if desired
    }
  }


  @override
  void dispose() {
    widget.device.disconnect();
    _positionStream?.cancel();
    _connSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _openPendingFiles() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PendingFilesPage(cache: widget.cache),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset('assets/logo.png', height: 60),
            const SizedBox(width: 10),
            Expanded(child: Text('Connected: ${widget.device.name}', style: const TextStyle(fontSize: 16))),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(compactView ? Icons.list : Icons.view_compact),
            tooltip: compactView ? 'Full View' : 'Compact View',
            onPressed: () => setState(() => compactView = !compactView),
          ),
          IconButton(
            icon: Icon(isPaused ? Icons.play_arrow : Icons.pause),
            tooltip: isPaused ? 'Resume stream' : 'Pause stream',
            onPressed: _togglePause,
          ),
          IconButton(
            icon: const Icon(Icons.folder),
            tooltip: 'Pending files',
            onPressed: _openPendingFiles,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_sessionFile != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  const Icon(Icons.save_alt, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Saving to: $_sessionFile',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            // === Removed map + location UI ===



     if (phoneLatitude != null && phoneLongitude != null)
            SizedBox(
              height: 350,
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: LatLng(double.parse(phoneLatitude!), double.parse(phoneLongitude!)),
                  initialZoom: 16.0,
                  onTap: (tapPos, latlng) => setState(() => customMarkers.add(latlng)),
                ),
                children: [
                  TileLayer(
                    urlTemplate: "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png",
                    subdomains: ['a', 'b', 'c'],
                    userAgentPackageName: 'com.sensorx.xactble', // <-- REQUIRED by OSM
                  ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: LatLng(double.parse(phoneLatitude!), double.parse(phoneLongitude!)),
                        width: 40,
                        height: 40,
                        child: const Icon(Icons.circle, color: Colors.blue, size: 18),
                      ),
                      ...customMarkers.map((pos) => Marker(
                        point: pos,
                        width: 40,
                        height: 40,
                        child: const Icon(Icons.location_on, color: Colors.green),
                      )),
                    ],
                  ),
                ],
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text("📍 Getting phone location..."),
            ),

                       // ===  REMOVE "📍 Get Coordinates" button ===

          /*ElevatedButton(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text("Current Coordinates: $phoneLatitude, $phoneLongitude")),
              );
            },
            child: const Text("📍 Get Coordinates"),
          ),*/

          //Alarm Toggle
          SwitchListTile(
            title: const Text("Enable Alarm"),
            value: alarmEnabled,
            onChanged: (val) => setState(() => alarmEnabled = val),
          ),


          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text("Threshold: "),
              Slider(
                min: 0,
                max: 20,
                divisions: 40,
                value: threshold,
                label: threshold.toStringAsFixed(0),
                onChanged: (val) => setState(() => threshold = val),
              ),
              Text("${threshold.toStringAsFixed(0)} ppm")
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: Center(
              child: Card(
                margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10), // smaller outside space
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), // tighter inside padding
                  child: Text(
                    'Methane: $latestMethane ppm\nEthane: $latestEthane ppm',
                    style: const TextStyle(fontSize: 20),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),

        ],
      ),
    );
  }
}

/// ===============================
/// Pending files UI + CSV preview
/// ===============================
class PendingFilesPage extends StatefulWidget {
  final TTLFileCache cache;
  const PendingFilesPage({super.key, required this.cache});

  @override
  State<PendingFilesPage> createState() => _PendingFilesPageState();
}

class _PendingFilesPageState extends State<PendingFilesPage> {
  late Future<List<_FileMeta>> _futureFiles;
  bool _busy = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _futureFiles = _loadFiles();
      _err = null;
    });
  }

  Future<List<_FileMeta>> _loadFiles() async {
    final files = await widget.cache.listActive();
    files.sort((a, b) => a.path.compareTo(b.path));
    final metas = <_FileMeta>[];
    for (final f in files) {
      try {
        final stat = await f.stat();
        final lines = await _countLinesQuick(f, maxToRead: 1000000);
        metas.add(_FileMeta(
          name: f.uri.pathSegments.last,
          file: f,
          sizeBytes: stat.size,
          modified: stat.modified,
          recordCount: lines > 0 ? lines - 1 : 0, // minus header
        ));
      } catch (e) {
        metas.add(_FileMeta(
          name: f.uri.pathSegments.last,
          file: f,
          sizeBytes: 0,
          modified: DateTime.fromMillisecondsSinceEpoch(0),
          recordCount: 0,
          error: e.toString(),
        ));
      }
    }
    return metas;
  }

  static Future<int> _countLinesQuick(File f, {int maxToRead = 1000000}) async {
    final reader = f.openRead();
    int count = 0;
    await for (final chunk in reader) {
      for (final byte in chunk) {
        if (byte == 10) count++; // '\n'
        if (count >= maxToRead) break;
      }
      if (count >= maxToRead) break;
    }
    return count;
  }

  static Future<List<List<String>>> _readCsvPreview(String path, {int maxLines = 300}) async {
    final lines = await File(path).readAsLines();
    final take = lines.take(maxLines).toList();
    return take.map((l) => l.split(',')).toList();
  }

  Future<void> _deleteLocal(String name) async {
    setState(() => _busy = true);
    try {
      await widget.cache.markUploaded(name);
    } finally {
      setState(() => _busy = false);
      _reload();
    }
  }



  Future<void> _shareFile(File file) async {
    try {
      final xFile = XFile(file.path);
      await Share.shareXFiles(
        [xFile],
        text: 'Exported from Surveyor App',
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Share failed: $e')),
      );
    }
  }


  Future<void> _purgeExpired() async {
    setState(() => _busy = true);
    try {
      await widget.cache.purgeExpired();
    } finally {
      setState(() => _busy = false);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pending Files'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Purge expired',
            onPressed: _busy ? null : _purgeExpired,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _reload,
          ),
        ],
      ),
      body: FutureBuilder<List<_FileMeta>>(
        future: _futureFiles,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          final items = snap.data ?? const [];
          final totalBytes = items.fold<int>(0, (s, m) => s + m.sizeBytes);

          return Column(
            children: [
              if (_err != null)
                Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.red.withOpacity(0.08),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Error: $_err')),
                    ],
                  ),
                ),
              _SummaryBar(count: items.length, bytes: totalBytes),
              const Divider(height: 0),
              Expanded(
                child: items.isEmpty
                    ? const Center(child: Text('No pending files'))
                    : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 0),
                  itemBuilder: (context, i) {
                    final m = items[i];
                    return ListTile(
                      leading: const CircleAvatar(radius: 10, child: Icon(Icons.insert_drive_file, size: 14)),
                      title: Text(m.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        'Records: ${m.recordCount} • ${_fmtBytes(m.sizeBytes)} • Modified: ${m.modified.toLocal()}',
                      ),
                      trailing: Wrap(
                        spacing: 6,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.visibility),
                            tooltip: 'Preview',
                            onPressed: _busy
                                ? null
                                : () async {
                              final rows = await _readCsvPreview(m.file.path, maxLines: 500);
                              if (!context.mounted) return;
                              Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => CsvPreviewPage(filename: m.name, rows: rows),
                              ));
                            },
                          ),
                          /*IconButton(
                            icon: const Icon(Icons.download),
                            tooltip: 'Download file',
                            onPressed: _busy ? null : () => _downloadFile(m.file),
                          ),*/
                          IconButton(
                            icon: const Icon(Icons.share),
                            tooltip: 'Share file',
                            onPressed: _busy ? null : () => _shareFile(m.file),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Delete local',
                            onPressed: _busy ? null : () => _deleteLocal(m.name),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
            ],
          );
        },
      ),
    );
  }

  static String _fmtBytes(int n) {
    const kb = 1024, mb = 1024 * kb, gb = 1024 * mb;
    if (n >= gb) return '${(n / gb).toStringAsFixed(2)} GB';
    if (n >= mb) return '${(n / mb).toStringAsFixed(2)} MB';
    if (n >= kb) return '${(n / kb).toStringAsFixed(2)} KB';
    return '$n B';
  }
}

class _FileMeta {
  final String name;
  final File file;
  final int sizeBytes;
  final DateTime modified;
  final int recordCount;
  final String? error;

  _FileMeta({
    required this.name,
    required this.file,
    required this.sizeBytes,
    required this.modified,
    required this.recordCount,
    this.error,
  });
}

class _SummaryBar extends StatelessWidget {
  final int count;
  final int bytes;
  const _SummaryBar({required this.count, required this.bytes});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.folder, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text('Pending: $count • ${_fmtBytes(bytes)}'),
        ],
      ),
    );
  }

  static String _fmtBytes(int n) {
    const kb = 1024, mb = 1024 * kb, gb = 1024 * mb;
    if (n >= gb) return '${(n / gb).toStringAsFixed(2)} GB';
    if (n >= mb) return '${(n / mb).toStringAsFixed(2)} MB';
    if (n >= kb) return '${(n / kb).toStringAsFixed(2)} KB';
    return '$n B';
  }
}

class CsvPreviewPage extends StatelessWidget {
  final String filename;
  final List<List<String>> rows;
  const CsvPreviewPage({super.key, required this.filename, required this.rows});

  @override
  Widget build(BuildContext context) {
    final headers = rows.isNotEmpty ? rows.first : <String>[];
    final dataRows = rows.length > 1 ? rows.sublist(1) : const <List<String>>[];
    return Scaffold(
      appBar: AppBar(title: Text('Preview: $filename')),
      body: rows.isEmpty
          ? const Center(child: Text('No data'))
          : SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 600),
          child: SingleChildScrollView(
            child: DataTable(
              columns: headers.map((h) => DataColumn(label: Text(h))).toList(),
              rows: dataRows
                  .map(
                    (r) => DataRow(
                  cells: r.map((c) => DataCell(Text(c))).toList(),
                ),
              )
                  .toList(),
            ),
          ),
        ),
      ),
    );
  }
}