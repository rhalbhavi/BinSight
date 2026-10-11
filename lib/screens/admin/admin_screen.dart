import 'dart:async';

import 'package:flutter/material.dart';
import 'package:binsight/utils/device_labels.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart'; // For displaying images from URL
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:binsight/services/api_service.dart';
import 'package:binsight/screens/analytics_screen.dart';
import 'package:binsight/utils/ist_time.dart';
import 'package:binsight/main.dart'; // For QRScannerScreen and capitalize extension
import 'package:binsight/widgets/manage_devices_content.dart';
import 'package:binsight/widgets/registered_bins_zones_section.dart';
import 'dart:typed_data';

// --- Main Admin Screen ---
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AdminDashboard();
  }
}

// Helper to create consistent screen headings
int _fillPercent(dynamic rawValue) {
  final value = rawValue is num
      ? rawValue.toDouble()
      : double.tryParse(rawValue?.toString() ?? '');
  if (value == null || !value.isFinite) return 0;
  return value.round().clamp(0, 100).toInt();
}

String _registeredFillStatus(int fill) {
  if (fill >= 90) return 'Full';
  if (fill >= 70) return 'Almost Full';
  if (fill >= 50) return 'Moderate';
  return 'Normal';
}

String _registeredGasStatus(int gas) {
  if (gas > 700) return 'Severe / Hazardous';
  if (gas > 600) return 'Very Poor';
  if (gas > 500) return 'Poor';
  if (gas > 400) return 'Moderate';
  return 'Normal';
}

Color _registeredStatusColor(String? status) {
  switch (status?.trim().toLowerCase()) {
    case 'critical':
    case 'full':
    case 'almost full':
    case 'very poor':
    case 'severe / hazardous':
    case 'fire detected':
      return Colors.red;
    case 'moderate':
    case 'poor':
      return Colors.orange;
    default:
      return Colors.green;
  }
}

Widget _screenHeading(String text, {Color? color, IconData? icon}) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (icon == null)
        Text(text, style: GoogleFonts.rubikMonoOne(fontSize: 18, color: color))
      else
        Row(
          children: [
            Icon(icon, size: 21, color: color ?? const Color(0xFF263238)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: GoogleFonts.rubikMonoOne(fontSize: 18, color: color),
              ),
            ),
          ],
        ),
      const SizedBox(height: 6),
      const Divider(height: 1, thickness: 1),
    ],
  );
}

AppBar sharedAppBar(
  BuildContext context, {
  String? title,
  List<Widget>? actions,
}) {
  return AppBar(
    backgroundColor: const Color(0xFF03A9F4),
    elevation: 0,
    automaticallyImplyLeading: false,
    actions: actions,
    leading: Builder(
      builder: (context) => IconButton(
        icon: const Icon(Icons.menu, color: Colors.white),
        onPressed: () => Scaffold.of(context).openDrawer(),
      ),
    ),
    title: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.asset(
            'assets/logo.png',
            height: 32,
            width: 32,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            'BinSight',
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.rubikMonoOne(color: Colors.white, fontSize: 18),
          ),
        ),
      ],
    ),
  );
}

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _ZoneGroup {
  _ZoneGroup({required this.name, required this.zoneKey, this.location = ''});

  final String name;
  final String zoneKey;
  final String location;
  final List<Map<String, dynamic>> bins = <Map<String, dynamic>>[];

  static bool isCriticalBin(Map<String, dynamic> device) =>
      device['status']?.toString().toLowerCase() == 'critical';

  int get binCount => bins.length;
  int get criticalCount => bins.where(isCriticalBin).length;
}

class _AdminDashboardState extends State<AdminDashboard> {
  List<Map<String, dynamic>> _devices = [];
  bool _isLoading = true;
  String? _error;
  Timer? _refreshTimer;
  String _sortMode = 'nearest';
  LatLng? _currentUserLocation;
  LatLng? _focusedBinLocation;
  int _mapFocusRequest = 0;

  @override
  void initState() {
    super.initState();
    _fetchCurrentUserLocation();
    _fetchData();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _fetchData(),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchCurrentUserLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
        ),
      ).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      setState(() {
        _currentUserLocation = LatLng(position.latitude, position.longitude);
      });
    } catch (_) {}
  }

  Future<void> _fetchData() async {
    try {
      final devices = await ApiService.fetchDevices();
      if (mounted) {
        setState(() {
          _devices = devices;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  double _distanceToBin(Map<String, dynamic> device) {
    final location = _locationFromDevice(device);
    if (location == null || _currentUserLocation == null)
      return double.infinity;
    return const Distance().as(
      LengthUnit.Meter,
      _currentUserLocation!,
      location,
    );
  }

  LatLng? _locationFromDevice(Map<String, dynamic> device) {
    final location = device['location'];
    if (location is List && location.length >= 2) {
      final lat = double.tryParse('${location[1]}');
      final lng = double.tryParse('${location[0]}');
      if (lat != null && lng != null) return LatLng(lat, lng);
    }
    if (location is Map) {
      final lat = double.tryParse(
        '${location['latitude'] ?? location['lat'] ?? location['y']}',
      );
      final lng = double.tryParse(
        '${location['longitude'] ?? location['lng'] ?? location['lon'] ?? location['x']}',
      );
      if (lat != null && lng != null) return LatLng(lat, lng);
      final coords = location['coordinates'];
      if (coords is List && coords.length >= 2) {
        final lat2 = double.tryParse('${coords[1]}');
        final lng2 = double.tryParse('${coords[0]}');
        if (lat2 != null && lng2 != null) return LatLng(lat2, lng2);
      }
    }
    if (device['latitude'] != null && device['longitude'] != null) {
      final lat = double.tryParse('${device['latitude']}');
      final lng = double.tryParse('${device['longitude']}');
      if (lat != null && lng != null) return LatLng(lat, lng);
    }
    return null;
  }

  List<_ZoneGroup> _zoneGroups() {
    final groups = <String, _ZoneGroup>{};
    for (final zone in _devices.where((device) => device['type'] == 'zone')) {
      final zoneKey = (zone['zone_id'] ?? zone['id'] ?? '').toString();
      if (zoneKey.isEmpty) continue;
      groups[zoneKey] = _ZoneGroup(
        name: buildZoneDisplayName(zone),
        zoneKey: zoneKey,
        location: (zone['location_description'] ?? '').toString().trim(),
      );
    }

    for (final bin in _devices.where((device) => device['type'] == 'bin')) {
      final zoneKey = (bin['zone_id'] ?? '').toString();
      final group = groups[zoneKey];
      if (zoneKey.isNotEmpty && group != null) group.bins.add(bin);
    }

    final ordered = groups.values.toList();
    ordered.sort((a, b) {
      if (_sortMode == 'critical') {
        final criticalDiff = b.criticalCount.compareTo(a.criticalCount);
        if (criticalDiff != 0) return criticalDiff;
      }
      final aDistance = a.bins.fold<double>(double.infinity, (
        minDistance,
        bin,
      ) {
        final distance = _distanceToBin(bin);
        return distance < minDistance ? distance : minDistance;
      });
      final bDistance = b.bins.fold<double>(double.infinity, (
        minDistance,
        bin,
      ) {
        final distance = _distanceToBin(bin);
        return distance < minDistance ? distance : minDistance;
      });
      if (_sortMode == 'nearest') {
        final diff = aDistance.compareTo(bDistance);
        if (diff != 0) return diff;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    for (final group in ordered) {
      group.bins.sort((a, b) {
        {
          final criticalDiff =
              (_ZoneGroup.isCriticalBin(b) ? 1 : 0) -
              (_ZoneGroup.isCriticalBin(a) ? 1 : 0);
          if (criticalDiff != 0) return criticalDiff;
        }
        final aDistance = _distanceToBin(a);
        final bDistance = _distanceToBin(b);
        final distanceDiff = aDistance.compareTo(bDistance);
        if (distanceDiff != 0) return distanceDiff;
        return (a['name'] ?? '').toString().compareTo(
          (b['name'] ?? '').toString(),
        );
      });
    }

    return ordered;
  }

  void _openBinOnMap(Map<String, dynamic> device) {
    final location = _locationFromDevice(device);
    if (location == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This bin does not have a location yet.')),
      );
      return;
    }

    setState(() {
      _focusedBinLocation = location;
      _mapFocusRequest++;
    });
  }

  void _openZoneOnMap(Map<String, dynamic> zone) {
    final location = _locationFromDevice(zone);
    if (location == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This zone does not have a location yet.'),
        ),
      );
      return;
    }
    setState(() {
      _focusedBinLocation = location;
      _mapFocusRequest++;
    });
  }

  String _fillStatus(int fillLevel) {
    if (fillLevel >= 90) return 'Full';
    if (fillLevel >= 70) return 'Almost Full';
    if (fillLevel >= 50) return 'Moderate';
    return 'Normal';
  }

  String _gasStatus(int aqi) {
    if (aqi > 700) return 'Severe / Hazardous';
    if (aqi > 600) return 'Very Poor';
    if (aqi > 500) return 'Poor';
    if (aqi > 400) return 'Moderate';
    return 'Normal';
  }

  Color _getStatusColor(String? status) {
    switch (status?.trim().toLowerCase()) {
      case 'full':
      case 'almost full':
      case 'critical':
      case 'very poor':
      case 'severe / hazardous':
      case 'fire detected':
        return Colors.red;
      case 'moderate':
      case 'poor':
        return Colors.orange;
      case 'normal':
      case 'no fire':
        return Colors.green;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: sharedAppBar(context),
      drawer: const AppDrawer(),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text('Failed to load data: $_error'))
          : RefreshIndicator(
              onRefresh: _fetchData,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: _buildDashboardContent(),
              ),
            ),
    );
  }

  Widget _buildDashboardContent() {
    final registeredBins = _devices
        .where((device) => device['type'] == 'bin')
        .toList();
    registeredBins.sort((a, b) {
      if (_sortMode == 'critical') {
        final aCritical = a['status']?.toString().toLowerCase() == 'critical';
        final bCritical = b['status']?.toString().toLowerCase() == 'critical';
        final criticalOrder = (bCritical ? 1 : 0).compareTo(aCritical ? 1 : 0);
        if (criticalOrder != 0) return criticalOrder;
      }
      return _distanceToBin(a).compareTo(_distanceToBin(b));
    });
    final registeredZones = _devices
        .where((device) => device['type'] == 'zone')
        .toList();
    final criticalDevices = _devices
        .where(
          (d) => d['type'] == 'bin' && d['status']?.toLowerCase() == 'critical',
        )
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _screenHeading('DASHBOARD', icon: Icons.home),
        const SizedBox(height: 16),
        MapSection(
          height: 280,
          focusLocation: _focusedBinLocation,
          focusRequest: _mapFocusRequest,
        ),
        const SizedBox(height: 24),
        if (criticalDevices.isNotEmpty) ...[
          _screenHeading('ALERTS'),
          const SizedBox(height: 12),
          ...criticalDevices.map((device) {
            final isBin = device['type'] == 'bin';
            final fillLevel = _fillPercent(device['fill_level']);
            final aqi = int.tryParse('${device['gas_level'] ?? 0}') ?? 0;
            final fillState = _fillStatus(fillLevel);
            final gasState = _gasStatus(aqi);
            return StatusCard(
              title: buildBinDisplayName(device),
              isOnline: device['is_online'] != false,
              subtitle: '',
              fillLevel: fillLevel,
              aqi: aqi,
              status: 'Critical',
              statusColor: Colors.red,
              fillStatus: fillState,
              gasStatus: gasState,
              fireDetected: device['flame'] == true,
              nextOverflowTime: device['next_overflow_time']?.toString(),
              gasSpike: device['gas_spike'] == true,
              predictedFireRisk: device['fire_risk'] == true,
              backgroundColor: const Color(0xFFFFEBEE),
              fillLabel: isBin ? 'Fill' : 'Average Fill',
              gasLabel: 'Air',
              sensorDetails: null,
              onTap: isBin ? () => _openBinOnMap(device) : null,
            );
          }),
          const SizedBox(height: 24),
        ],
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: _screenHeading('BINS AND ZONES')),
            PopupMenuButton<String>(
              icon: const Icon(Icons.filter_list, color: Colors.black87),
              tooltip: 'Sort bins',
              onSelected: (value) => setState(() => _sortMode = value),
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'nearest',
                  child: Text('SHOW NEAREST FIRST'),
                ),
                PopupMenuItem(
                  value: 'critical',
                  child: Text('SHOW CRITICAL FIRST'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        RegisteredBinsZonesSection(
          bins: registeredBins,
          zones: registeredZones,
          binBuilder: (device) {
            final fill = _fillPercent(device['fill_level']);
            final aqi = int.tryParse('${device['gas_level'] ?? 0}') ?? 0;
            final fillState = _fillStatus(fill);
            final gasState = _gasStatus(aqi);
            final isCritical =
                device['status']?.toString().toLowerCase() == 'critical';
            return StatusCard(
              title: buildBinDisplayName(device),
              isOnline: device['is_online'] != false,
              subtitle: '',
              fillLevel: fill,
              aqi: aqi,
              status: (device['status'] ?? 'normal').toString().capitalize(),
              statusColor: _getStatusColor(
                (device['status'] ?? fillState).toString(),
              ),
              fillStatus: fillState,
              gasStatus: gasState,
              fireDetected: device['flame'] == true,
              nextOverflowTime: device['next_overflow_time']?.toString(),
              gasSpike: device['gas_spike'] == true,
              predictedFireRisk: device['fire_risk'] == true,
              backgroundColor: isCritical
                  ? const Color(0xFFFFEBEE)
                  : Colors.white,
              fillLabel: 'Fill',
              gasLabel: 'Air',
              onTap: () => _openBinOnMap(device),
            );
          },
          zoneBuilder: (zone) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openZoneOnMap(zone),
            child: _registeredZoneCard(zone),
          ),
        ),
        const SizedBox(height: 24),
        _screenHeading('RECENT ALERTS'),
        const SizedBox(height: 12),
        if (criticalDevices.isEmpty) const Text('No recent critical alerts.'),
        ...criticalDevices.map((device) {
          final fillLevel = _fillPercent(device['fill_level']);
          final aqi = int.tryParse('${device['gas_level'] ?? 0}') ?? 0;
          final fillState = _fillStatus(fillLevel);
          final gasState = _gasStatus(aqi);
          return StatusCard(
            title: buildBinDisplayName(device),
            isOnline: device['is_online'] != false,
            subtitle: '',
            fillLevel: fillLevel,
            aqi: aqi,
            status: 'Critical',
            statusColor: Colors.red,
            fillStatus: fillState,
            gasStatus: gasState,
            fireDetected: device['flame'] == true,
            nextOverflowTime: device['next_overflow_time']?.toString(),
            gasSpike: device['gas_spike'] == true,
            predictedFireRisk: device['fire_risk'] == true,
            backgroundColor: const Color(0xFFFFEBEE),
            fillLabel: 'Fill',
            gasLabel: 'Air',
            onTap: () => _openBinOnMap(device),
          );
        }),
        const SizedBox(height: 24),
      ],
    );
  }
}

class MapScreen extends StatelessWidget {
  const MapScreen({super.key, this.selectedLocation, this.selectedTitle});

  final LatLng? selectedLocation;
  final String? selectedTitle;

  @override // Changed to use _screenHeading
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: sharedAppBar(context, title: 'LIVE MAP'),
      drawer: const AppDrawer(),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _screenHeading('LIVE MAP', icon: Icons.map),
            if (selectedTitle != null && selectedTitle!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                selectedTitle!,
                style: GoogleFonts.titilliumWeb(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Expanded(
              child: MapSection(height: null, focusLocation: selectedLocation),
            ),
          ],
        ),
      ),
    );
  }
}

class AllTasksScreen extends StatefulWidget {
  const AllTasksScreen({super.key});

  @override
  State<AllTasksScreen> createState() => _AllTasksScreenState();
}

class _AssignmentBundle {
  const _AssignmentBundle({
    required this.assignedBins,
    required this.assignedZones,
  });

  final List<Map<String, dynamic>> assignedBins;
  final List<Map<String, dynamic>> assignedZones;
}

class _AllTasksScreenState extends State<AllTasksScreen> {
  late Future<_AssignmentBundle> _assignmentFuture;

  @override
  void initState() {
    super.initState();
    _assignmentFuture = _loadAssignments();
  }

  Future<_AssignmentBundle> _loadAssignments() async {
    final workers = await ApiService.fetchWorkers();
    final binNameMap = <String, String>{};
    final zoneNameMap = <String, String>{};

    try {
      final devices = await ApiService.fetchDevices();
      for (final device in devices) {
        final rawId = (device['bin_id'] ?? device['id'])?.toString();
        final name = buildBinDisplayName(device);
        if (rawId != null && rawId.isNotEmpty) {
          binNameMap[rawId] = name;
        }
      }

      final zones = await ApiService.fetchZones();
      for (final zone in zones) {
        final rawId = (zone['zone_id'] ?? zone['id'])?.toString();
        final name = buildZoneNameWithoutPicker(zone);
        if (rawId != null && rawId.isNotEmpty) {
          zoneNameMap[rawId] = name;
        }
      }
    } catch (_) {}

    final groupedBins = <String, Map<String, dynamic>>{};
    final groupedZones = <String, Map<String, dynamic>>{};

    for (final worker in workers) {
      final workerName = (worker['name'] ?? worker['email'] ?? 'Unknown')
          .toString();
      final workerPhone = (worker['phone'] ?? '').toString();
      final workerId = (worker['worker_id'] ?? '').toString();

      for (final binId in List<String>.from(
        worker['assigned_bins'] ?? const [],
      )) {
        final label =
            binNameMap[binId] ??
            'Bin ${binId.replaceAll(RegExp(r'[^0-9]'), '')}';
        final entry = groupedBins.putIfAbsent(
          binId,
          () => {
            'binId': binId,
            'binName': label,
            'workers': <Map<String, String>>[],
          },
        );
        final workersList = List<Map<String, String>>.from(
          entry['workers'] as List? ?? const [],
        );
        workersList.add({
          'workerId': workerId,
          'workerName': workerName,
          'workerPhone': workerPhone,
        });
        entry['workers'] = workersList;
      }

      for (final zoneId in List<String>.from(
        worker['assigned_zones'] ?? const [],
      )) {
        final label = zoneNameMap[zoneId] ?? zoneId;
        final entry = groupedZones.putIfAbsent(
          zoneId,
          () => {
            'zoneId': zoneId,
            'zoneName': label,
            'workers': <Map<String, String>>[],
          },
        );
        final workersList = List<Map<String, String>>.from(
          entry['workers'] as List? ?? const [],
        );
        workersList.add({
          'workerId': workerId,
          'workerName': workerName,
          'workerPhone': workerPhone,
        });
        entry['workers'] = workersList;
      }
    }

    return _AssignmentBundle(
      assignedBins: groupedBins.values.toList(),
      assignedZones: groupedZones.values.toList(),
    );
  }

  Future<void> _refresh() async {
    setState(() => _assignmentFuture = _loadAssignments());
  }

  Future<void> _confirmUnassignFromTasks(
    String workerId,
    String itemId,
    String type,
    String label,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Unassign ${type == 'bin' ? 'bin' : 'zone'}'),
        content: Text(
          'Are you sure you want to unassign $label from this worker?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('NO'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('YES'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final worker = await ApiService.fetchWorkerProfile(workerId);
      final assignedBins = List<String>.from(
        worker['assigned_bins'] ?? const <String>[],
      );
      final assignedZones = List<String>.from(
        worker['assigned_zones'] ?? const <String>[],
      );

      if (type == 'bin') {
        assignedBins.remove(itemId);
      } else {
        assignedZones.remove(itemId);
      }

      await ApiService.updateWorkerProfile(
        workerId,
        assignedBins: assignedBins,
        assignedZones: assignedZones,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$label unassigned successfully')),
        );
        _refresh();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to unassign: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: sharedAppBar(context, title: 'WORKER TASKS'),
      drawer: const AppDrawer(),
      body: FutureBuilder<_AssignmentBundle>(
        future: _assignmentFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('Could not load assignments: ${snapshot.error}'),
            );
          }

          final assignedBins =
              snapshot.data?.assignedBins ?? const <Map<String, dynamic>>[];
          final assignedZones =
              snapshot.data?.assignedZones ?? const <Map<String, dynamic>>[];

          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                _screenHeading('WORKER TASKS', icon: Icons.task),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _buildAssignmentColumn(
                        title: "Bins I've Assigned",
                        items: assignedBins,
                        itemBuilder: (item) {
                          final binName =
                              (item['binName'] ?? item['binId'] ?? 'Bin')
                                  .toString();
                          final workers =
                              (item['workers'] as List<Map<String, String>>?) ??
                              const [];
                          final binId = item['binId'] as String;
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    binName,
                                    style: GoogleFonts.titilliumWeb(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 18,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  ...workers.map((worker) {
                                    final workerId = worker['workerId'] ?? '';
                                    final workerName =
                                        worker['workerName'] ?? 'Unknown';
                                    final workerPhone =
                                        worker['workerPhone'] ?? '';
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              '$workerName - No. ${workerPhone.isEmpty ? 'N/A' : workerPhone}',
                                              style: GoogleFonts.titilliumWeb(
                                                fontSize: 16,
                                              ),
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () =>
                                                _confirmUnassignFromTasks(
                                                  workerId,
                                                  binId,
                                                  'bin',
                                                  binName,
                                                ),
                                            child: const Text('UNASSIGN'),
                                          ),
                                        ],
                                      ),
                                    );
                                  }),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      width: 1,
                      height: 260,
                      color: Colors.grey.shade300,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildAssignmentColumn(
                        title: "Zones I've Assigned",
                        items: assignedZones,
                        itemBuilder: (item) {
                          final zoneName =
                              (item['zoneName'] ?? item['zoneId'] ?? 'Zone')
                                  .toString();
                          final workers =
                              (item['workers'] as List<Map<String, String>>?) ??
                              const [];
                          final zoneId = item['zoneId'] as String;
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    zoneName,
                                    style: GoogleFonts.titilliumWeb(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 18,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  ...workers.map((worker) {
                                    final workerId = worker['workerId'] ?? '';
                                    final workerName =
                                        worker['workerName'] ?? 'Unknown';
                                    final workerPhone =
                                        worker['workerPhone'] ?? '';
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              '$workerName - No. ${workerPhone.isEmpty ? 'N/A' : workerPhone}',
                                              style: GoogleFonts.titilliumWeb(
                                                fontSize: 16,
                                              ),
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () =>
                                                _confirmUnassignFromTasks(
                                                  workerId,
                                                  zoneId,
                                                  'zone',
                                                  zoneName,
                                                ),
                                            child: const Text('UNASSIGN'),
                                          ),
                                        ],
                                      ),
                                    );
                                  }),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildAssignmentColumn({
    required String title,
    required List<Map<String, dynamic>> items,
    required Widget Function(Map<String, dynamic>) itemBuilder,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: GoogleFonts.rubikMonoOne(fontSize: 16)),
        const SizedBox(height: 6),
        const Divider(height: 1, thickness: 1),
        const SizedBox(height: 12),
        if (items.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('No items assigned yet.'),
            ),
          )
        else
          ...items.map(itemBuilder),
      ],
    );
  }
}

class ManageWorkersScreen extends StatefulWidget {
  const ManageWorkersScreen({super.key});

  @override
  State<ManageWorkersScreen> createState() => _ManageWorkersScreenState();
}

class _ManageWorkersScreenState extends State<ManageWorkersScreen> {
  // Corrected `Future` type usage
  late Future<List<Map<String, dynamic>>> _workersFuture;
  final ImagePicker _picker = ImagePicker();
  String _workerFilter = 'all';

  @override
  void initState() {
    super.initState();
    _workersFuture = _fetchWorkers();
  }

  Future<List<Map<String, dynamic>>> _fetchWorkers() async {
    final workers = await ApiService.fetchWorkers();
    // Apply a cache-busting parameter to each worker's profile image URL.
    // This ensures that if a picture was updated, we fetch the new version instead
    // of using the one from the cache.
    for (final worker in workers) {
      final imageUrl = worker['profile_image_url'] as String?;
      if (imageUrl != null && imageUrl.isNotEmpty) {
        worker['profile_image_url'] =
            '$imageUrl?v=${DateTime.now().millisecondsSinceEpoch}';
      }
    }
    return workers;
  }

  void _refreshWorkers() {
    setState(() {
      _workersFuture = _fetchWorkers();
    });
  }

  String _workerName(Map<String, dynamic> worker) =>
      worker['name'] ?? worker['email'] ?? 'Unknown';

  String _workerImage(Map<String, dynamic> worker) =>
      worker['profile_image_url'] ?? '';

  List<dynamic> _assignedZones(Map<String, dynamic> worker) =>
      List<dynamic>.from(worker['assigned_zones'] ?? const []);
  List<dynamic> _assignedBins(Map<String, dynamic> worker) =>
      List<dynamic>.from(worker['assigned_bins'] ?? const []);

  bool _matchesWorkerFilter(Map<String, dynamic> worker) {
    final zones = _assignedZones(worker).isNotEmpty;
    final bins = _assignedBins(worker).isNotEmpty;
    return switch (_workerFilter) {
      'bins' => bins,
      'zones' => zones,
      'both' => bins && zones,
      'unassigned' => !bins && !zones,
      _ => true,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: sharedAppBar(context),
      drawer: const AppDrawer(),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _workersFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final workers = snapshot.data ?? [];

          return RefreshIndicator(
            onRefresh: () async => _refreshWorkers(),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'MANAGE WORKERS',
                        style: GoogleFonts.rubikMonoOne(fontSize: 20),
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Filter workers',
                      icon: const Icon(
                        Icons.filter_list,
                        color: Colors.black87,
                      ),
                      onSelected: (value) =>
                          setState(() => _workerFilter = value),
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'bins',
                          child: Text('SHOW ASSIGNED TO BINS'),
                        ),
                        PopupMenuItem(
                          value: 'zones',
                          child: Text('SHOW ASSIGNED TO ZONES'),
                        ),
                        PopupMenuItem(
                          value: 'both',
                          child: Text('SHOW ASSIGNED TO BOTH'),
                        ),
                        PopupMenuItem(
                          value: 'unassigned',
                          child: Text('SHOW UNASSIGNED'),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (workers.where(_matchesWorkerFilter).isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('No workers match this filter.'),
                  ),
                ...workers.where(_matchesWorkerFilter).map((worker) {
                  final workerId = worker['worker_id'] as String;

                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundImage: _workerImage(worker).isNotEmpty
                            ? CachedNetworkImageProvider(_workerImage(worker))
                            : null,
                        child: _workerImage(worker).isEmpty
                            ? const Icon(Icons.person)
                            : null,
                      ),
                      title: Text(
                        _workerName(worker),
                        style: GoogleFonts.titilliumWeb(
                          fontWeight: FontWeight.bold,
                          fontSize: 20,
                        ),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            worker['email'] ?? '',
                            style: GoogleFonts.titilliumWeb(fontSize: 18),
                          ),
                          if (worker['phone'] != null &&
                              worker['phone'].isNotEmpty)
                            Text(
                              'Phone: ${worker['phone']}',
                              style: GoogleFonts.titilliumWeb(fontSize: 18),
                            ),
                          if (_assignedZones(worker).isNotEmpty ||
                              _assignedBins(worker).isNotEmpty)
                            Text(
                              'Assigned: ${[if (_assignedZones(worker).isNotEmpty) '${_assignedZones(worker).length} zone(s)', if (_assignedBins(worker).isNotEmpty) '${_assignedBins(worker).length} bin(s)'].join(', ')}',
                              style: GoogleFonts.titilliumWeb(fontSize: 18),
                            ),
                        ],
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) async {
                          if (value == 'edit') {
                            _showEditWorkerDialog(context, workerId, worker);
                          } else if (value == 'delete') {
                            _showDeleteConfirmation(context, workerId, worker);
                          } else if (value == 'assign') {
                            _showAssignTasksDialog(context, workerId, worker);
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'edit',
                            child: Text('EDIT PROFILE'),
                          ),
                          const PopupMenuItem(
                            value: 'assign',
                            child: Text('ASSIGN TASKS'),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('DELETE WORKER'),
                          ),
                        ],
                      ),
                      onTap: () =>
                          _showWorkerDetails(context, workerId, worker),
                    ),
                  );
                }),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AddWorkerScreen()),
                  ).then((_) => _refreshWorkers()),
                  icon: const Icon(Icons.add),
                  label: const Text('ADD NEW WORKER'),
                  style: ElevatedButton.styleFrom(
                    // Added textStyle and foregroundColor
                    textStyle: GoogleFonts.titilliumWeb(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    foregroundColor: Colors.white,
                    backgroundColor: const Color(0xFF03A9F4),
                    minimumSize: const Size(double.infinity, 50),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showWorkerDetails(
    BuildContext context,
    String workerId,
    Map<String, dynamic> worker,
  ) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            WorkerProfileScreen(workerId: workerId, workerData: worker),
      ),
    );
    // Refresh the list when returning from the details screen to see any updates.
    _refreshWorkers();
  }

  void _showEditWorkerDialog(
    BuildContext context,
    String workerId,
    Map<String, dynamic> worker,
  ) {
    final nameController = TextEditingController(text: worker['name'] ?? '');
    final phoneController = TextEditingController(text: worker['phone'] ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Worker'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Full Name'),
            ),
            TextField(
              controller: phoneController,
              decoration: const InputDecoration(labelText: 'Phone Number'),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _uploadProfilePicture(workerId),
              icon: const Icon(Icons.camera_alt), // Keep icon
              label: const Text('CHANGE PHOTO'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: () async {
              await ApiService.updateWorkerProfile(
                workerId,
                name: nameController.text.trim(),
                phone: phoneController.text.trim(),
              );
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Worker updated successfully')),
              );
              _refreshWorkers();
            },
            child: const Text('SAVE'),
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirmation(
    BuildContext context,
    String workerId,
    Map<String, dynamic> worker,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('DELETE WORKER'),
        content: Text(
          'Are you sure you want to delete ${worker['name'] ?? worker['email']}? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              try {
                await ApiService.deleteWorker(workerId);

                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Worker deleted successfully')),
                );
                _refreshWorkers();
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Error deleting worker: $e')),
                );
              }
            },
            child: const Text('DELETE'),
          ),
        ],
      ),
    );
  }

  void _showAssignTasksDialog(
    BuildContext context,
    String workerId,
    Map<String, dynamic> worker,
  ) {
    // This would show available bins/zones to assign to this worker
    // For now, just show a placeholder
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Task assignment feature coming soon')),
    );
  }

  Future<void> _uploadProfilePicture(String workerId) async {
    // Corrected `Future` type usage
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
      );
      if (pickedFile == null) return;

      final Uint8List imageBytes = await pickedFile
          .readAsBytes(); // Read image bytes

      // Upload to backend via ApiService (MongoDB storage)
      final String newImageUrl = await ApiService.uploadProfilePicture(
        ownerId: workerId,
        ownerType: 'worker',
        imageBytes: imageBytes,
      );

      // Update worker profile with the new URL via API
      await ApiService.updateWorkerProfile(
        workerId,
        profileImageUrl: newImageUrl,
      );

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile picture updated')));
      _refreshWorkers();
    } on Exception catch (e) {
      // Catch specific Exception from ApiService
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error uploading picture: $e')));
    }
  }
}

class ManageDevicesScreen extends StatefulWidget {
  const ManageDevicesScreen({super.key});

  @override
  State<ManageDevicesScreen> createState() => _ManageDevicesScreenState();
}

class _ManageDevicesScreenState extends State<ManageDevicesScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: sharedAppBar(context),
      drawer: const AppDrawer(),
      body: ManageDevicesContent(
        openQrScanner: (onScan) {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => QRScannerScreen(onScan: onScan)),
          );
        },
      ),
    );
  }
}

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  List<Map<String, dynamic>> _reports = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadReports();
  }

  Future<void> _loadReports() async {
    try {
      final reports = await ApiService.fetchReports();
      if (!mounted) return;
      setState(() {
        _reports = reports;
        _isLoading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: sharedAppBar(
        context,
        title: 'ISSUE REPORTS',
        actions: [
          IconButton(
            onPressed: _loadReports,
            icon: const Icon(Icons.refresh, color: Colors.white),
          ),
        ],
      ),
      drawer: const AppDrawer(),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Could not load issue reports: $_error',
                    style: GoogleFonts.titilliumWeb(fontSize: 18),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: _loadReports,
                    child: Text(
                      'RETRY',
                      style: GoogleFonts.titilliumWeb(fontSize: 18),
                    ),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadReports,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  _screenHeading('ISSUE REPORTS', icon: Icons.assignment),
                  const SizedBox(height: 16),
                  if (_reports.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Text(
                          'No issue reports submitted.',
                          style: GoogleFonts.titilliumWeb(fontSize: 18),
                        ),
                      ),
                    ),
                  ..._reports.map((report) {
                    final reportName = (report['name'] ?? 'Issue Report')
                        .toString();
                    final workerName =
                        (report['reporter_name'] ?? 'Unknown worker')
                            .toString();
                    final relatedDeviceName =
                        (report['related_device_name'] ?? '').toString();
                    final timestamp = formatIstDateTime(
                      report['submitted_at'] ?? report['created_at'],
                    );
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        leading: const Icon(
                          Icons.report_outlined,
                          color: Color(0xFF03A9F4),
                        ),
                        title: Text(
                          reportName,
                          style: GoogleFonts.titilliumWeb(
                            fontWeight: FontWeight.bold,
                            fontSize: 20,
                          ),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            [
                              if (timestamp.isNotEmpty) timestamp,
                              'Submitted by $workerName',
                              if (relatedDeviceName.isNotEmpty)
                                'Related: $relatedDeviceName',
                            ].join(' • '),
                            style: GoogleFonts.titilliumWeb(fontSize: 18),
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          final resolved = await Navigator.push<bool>(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  IssueReportDetailScreen(report: report),
                            ),
                          );
                          if (resolved == true) _loadReports();
                        },
                      ),
                    );
                  }),
                ],
              ),
            ),
    );
  }
}

class IssueReportDetailScreen extends StatefulWidget {
  const IssueReportDetailScreen({super.key, required this.report});

  final Map<String, dynamic> report;

  @override
  State<IssueReportDetailScreen> createState() =>
      _IssueReportDetailScreenState();
}

class _IssueReportDetailScreenState extends State<IssueReportDetailScreen> {
  bool _isResolving = false;

  String _submittedAt() {
    final formatted = formatIstDateTime(
      widget.report['submitted_at'] ?? widget.report['created_at'],
    );
    return formatted.isEmpty ? 'Timestamp unavailable' : formatted;
  }

  Future<void> _markResolved() async {
    final remarksController = TextEditingController();
    final shouldResolve = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          'Mark as Resolved',
          style: GoogleFonts.titilliumWeb(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to mark this report as resolved? '
              'This will remove the report and all its details from the list.',
              style: GoogleFonts.titilliumWeb(fontSize: 18),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: remarksController,
              minLines: 2,
              maxLines: 4,
              style: GoogleFonts.titilliumWeb(fontSize: 18),
              decoration: InputDecoration(
                labelText: 'Enter additional remarks:',
                labelStyle: GoogleFonts.titilliumWeb(fontSize: 18),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('NO', style: GoogleFonts.titilliumWeb(fontSize: 18)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('YES', style: GoogleFonts.titilliumWeb(fontSize: 18)),
          ),
        ],
      ),
    );
    final remarks = remarksController.text.trim();
    remarksController.dispose();
    if (shouldResolve != true) return;

    final reportId = (widget.report['report_id'] ?? '').toString();
    final adminId = FirebaseAuth.instance.currentUser?.uid;
    if (reportId.isEmpty || adminId == null) return;
    setState(() => _isResolving = true);
    try {
      await ApiService.resolveIssueReport(
        reportId: reportId,
        remarks: remarks,
        adminId: adminId,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isResolving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not resolve report: $error',
            style: GoogleFonts.titilliumWeb(fontSize: 18),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final reportName = (widget.report['name'] ?? 'Issue Report').toString();
    final reporterName = (widget.report['reporter_name'] ?? 'Unknown worker')
        .toString();
    final description = (widget.report['description'] ?? '').toString();
    final relatedDeviceName = (widget.report['related_device_name'] ?? '')
        .toString();
    final photos = (widget.report['photos'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList();

    return Scaffold(
      appBar: sharedAppBar(context, title: reportName),
      drawer: const AppDrawer(),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    reportName,
                    style: GoogleFonts.titilliumWeb(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${_submittedAt()}  •  Submitted by $reporterName',
                    style: GoogleFonts.titilliumWeb(
                      fontSize: 18,
                      color: Colors.black54,
                    ),
                  ),
                  if (relatedDeviceName.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      'Related device: $relatedDeviceName',
                      style: GoogleFonts.titilliumWeb(fontSize: 18),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Text(
                    'Description',
                    style: GoogleFonts.titilliumWeb(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    description,
                    style: GoogleFonts.titilliumWeb(fontSize: 18),
                  ),
                  if (photos.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      'Photos',
                      style: GoogleFonts.titilliumWeb(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: photos.length,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                      itemBuilder: (context, index) {
                        final url = photos[index];
                        return GestureDetector(
                          onTap: () => showDialog<void>(
                            context: context,
                            barrierColor: Colors.black87,
                            builder: (dialogContext) => Dialog(
                              backgroundColor: Colors.transparent,
                              insetPadding: const EdgeInsets.all(16),
                              child: Stack(
                                alignment: Alignment.topRight,
                                children: [
                                  Center(
                                    child: InteractiveViewer(
                                      minScale: 0.8,
                                      maxScale: 4,
                                      child: Image.network(
                                        url,
                                        fit: BoxFit.contain,
                                        errorBuilder: (context, error, stack) =>
                                            const Icon(
                                              Icons.broken_image_outlined,
                                              color: Colors.white,
                                              size: 64,
                                            ),
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () =>
                                        Navigator.pop(dialogContext),
                                    icon: const Icon(
                                      Icons.close,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.network(
                              url,
                              fit: BoxFit.cover,
                              loadingBuilder: (context, child, progress) =>
                                  progress == null
                                  ? child
                                  : const Center(
                                      child: CircularProgressIndicator(),
                                    ),
                              errorBuilder: (context, error, stack) =>
                                  Container(
                                    alignment: Alignment.center,
                                    color: Colors.black12,
                                    child: const Icon(
                                      Icons.broken_image_outlined,
                                    ),
                                  ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ElevatedButton.icon(
                  onPressed: _isResolving ? null : _markResolved,
                  icon: _isResolving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_circle_outline),
                  label: Text(
                    'MARK AS RESOLVED',
                    style: GoogleFonts.titilliumWeb(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: const Color(0xFF03A9F4),
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

class AdminNotificationsScreen extends StatefulWidget {
  const AdminNotificationsScreen({super.key});

  @override
  State<AdminNotificationsScreen> createState() =>
      _AdminNotificationsScreenState();
}

class _AdminNotificationsScreenState extends State<AdminNotificationsScreen> {
  List<Map<String, dynamic>> _notifications = [];
  Map<String, String> _notificationDeviceNames = {};
  bool _isLoading = true;
  String? _error;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadNotifications();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _loadNotifications(),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadNotifications() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() {
        _isLoading = false;
        _error = 'Sign in to view notifications.';
      });
      return;
    }
    try {
      final notifications = await ApiService.fetchAdminNotifications(user.uid);
      final deviceNames = <String, String>{};
      try {
        final devices = await ApiService.fetchDevices();
        for (final device in devices) {
          final id = (device['bin_id'] ?? device['zone_id'] ?? device['id'])
              ?.toString();
          if (id != null && id.isNotEmpty) {
            deviceNames[id] = device['type'] == 'zone'
                ? buildZoneDisplayName(device)
                : buildBinDisplayName(device);
          }
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _notifications = notifications;
        _notificationDeviceNames = deviceNames;
        _isLoading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = error.toString();
      });
    }
  }

  String? _resolvingNotificationId;

  Future<void> _resolveNotification(String notificationId) async {
    setState(() => _resolvingNotificationId = notificationId);
    try {
      await ApiService.deleteNotification(notificationId);
      await _loadNotifications();
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not resolve notification: $error')),
        );
    } finally {
      if (mounted) setState(() => _resolvingNotificationId = null);
    }
  }

  IconData _notificationIcon(dynamic rawType) {
    final type = rawType?.toString() ?? '';
    if (type.contains('task')) return Icons.assignment_outlined;
    if (type.contains('reminder')) return Icons.alarm_outlined;
    if (type.contains('critical') || type.contains('escalation')) {
      return Icons.warning_amber_rounded;
    }
    return Icons.report_outlined;
  }

  String _timestamp(dynamic value) => formatIstDateTime(value);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: sharedAppBar(context, title: 'NOTIFICATIONS'),
      drawer: const AppDrawer(),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : RefreshIndicator(
              onRefresh: _loadNotifications,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _screenHeading(
                    'NOTIFICATIONS',
                    icon: Icons.notifications_outlined,
                  ),
                  const SizedBox(height: 16),
                  if (_notifications.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Center(child: Text('No notifications yet.')),
                    ),
                  ..._notifications.map((notification) {
                    final timestamp = _timestamp(notification['created_at']);
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        leading: Icon(
                          _notificationIcon(notification['notification_type']),
                          color: const Color(0xFF03A9F4),
                        ),
                        title: Text(
                          addDeviceNameToMessage(
                            notification['message'] ?? 'Report update',
                            notification['device_id'] ??
                                notification['bin_id'] ??
                                notification['zone_id'],
                            _notificationDeviceNames,
                          ),
                          style: GoogleFonts.titilliumWeb(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (timestamp.isNotEmpty)
                              Text(
                                timestamp,
                                style: GoogleFonts.titilliumWeb(fontSize: 18),
                              ),
                          ],
                        ),
                        trailing:
                            _resolvingNotificationId ==
                                notification['notification_id']?.toString()
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : TextButton.icon(
                                onPressed:
                                    (notification['notification_id'] ?? '')
                                        .toString()
                                        .isEmpty
                                    ? null
                                    : () => _resolveNotification(
                                        notification['notification_id']
                                            .toString(),
                                      ),
                                icon: const Icon(Icons.check, size: 18),
                                label: Text(
                                  'Resolve',
                                  style: GoogleFonts.titilliumWeb(fontSize: 18),
                                ),
                              ),
                      ),
                    );
                  }),
                ],
              ),
            ),
    );
  }
}

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  Future<void> _resolveBinAlerts(Map<String, dynamic> device) async {
    final binId = (device['bin_id'] ?? device['id'] ?? '').toString();
    if (binId.isEmpty) return;
    try {
      await ApiService.resolveDeviceAlerts(binId);
      await _loadAlerts();
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not resolve alert: $error')),
        );
    }
  }

  Timer? _refreshTimer;
  List<Map<String, dynamic>> _alerts = [];
  List<Map<String, dynamic>> _criticalBins = [];
  Map<String, String> _alertDeviceNames = {};
  bool _isLoading = true;
  String? _error;
  String? _resolvingAlertId;

  @override
  void initState() {
    super.initState();
    _loadAlerts();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _loadAlerts(),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadAlerts() async {
    List<Map<String, dynamic>> criticalBins = [];
    List<Map<String, dynamic>> alerts = [];
    final alertDeviceNames = <String, String>{};
    try {
      final results = await Future.wait<dynamic>([
        ApiService.fetchDevices(),
        ApiService.fetchAlerts(),
      ]);
      final devices = results[0] as List<Map<String, dynamic>>;
      alerts = results[1] as List<Map<String, dynamic>>;
      for (final device in devices) {
        final id = (device['bin_id'] ?? device['zone_id'] ?? device['id'])
            ?.toString();
        if (id != null && id.isNotEmpty) {
          alertDeviceNames[id] = device['type'] == 'zone'
              ? buildZoneDisplayName(device)
              : buildBinDisplayName(device);
        }
      }
      final activeBinIds = alerts
          .map((alert) => alert['device_id'].toString())
          .toSet();
      criticalBins = devices
          .where(
            (device) =>
                device['type'] == 'bin' &&
                device['status']?.toString().toLowerCase() == 'critical' &&
                activeBinIds.contains(
                  (device['bin_id'] ?? device['id']).toString(),
                ),
          )
          .toList();
    } catch (_) {}
    try {
      if (alerts.isEmpty) alerts = await ApiService.fetchAlerts();
      if (!mounted) return;
      setState(() {
        _criticalBins = criticalBins;
        _alerts = alerts;
        _alertDeviceNames = alertDeviceNames;
        _isLoading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _resolveAlert(String alertId) async {
    setState(() => _resolvingAlertId = alertId);
    try {
      await ApiService.resolveAlert(
        alertId,
        resolvedBy: FirebaseAuth.instance.currentUser?.uid ?? 'unknown',
      );
      await _loadAlerts();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not resolve alert: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _resolvingAlertId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: sharedAppBar(context, title: 'ALERTS'),
      drawer: const AppDrawer(),
      body: RefreshIndicator(
        onRefresh: _loadAlerts,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _screenHeading('ALERTS', color: Colors.red, icon: Icons.warning),
            const SizedBox(height: 16),
            if (_isLoading)
              const Center(child: CircularProgressIndicator())
            else if (_error != null)
              Text(_error!)
            else ...[
              _screenHeading('CRITICAL BINS'),
              const SizedBox(height: 8),
              if (_criticalBins.isEmpty)
                const Text('No critical bins right now.')
              else
                ..._criticalBins.map((device) {
                  final fill = _fillPercent(device['fill_level']);
                  final aqi = int.tryParse('${device['gas_level'] ?? 0}') ?? 0;
                  final fillState = fill >= 90
                      ? 'Full'
                      : fill >= 70
                      ? 'Almost Full'
                      : fill >= 50
                      ? 'Moderate'
                      : 'Normal';
                  final gasState = aqi > 700
                      ? 'Severe / Hazardous'
                      : aqi > 600
                      ? 'Very Poor'
                      : aqi > 500
                      ? 'Poor'
                      : aqi > 400
                      ? 'Moderate'
                      : 'Normal';
                  return StatusCard(
                    title: buildBinDisplayName(device),
                    isOnline: device['is_online'] != false,
                    subtitle: '',
                    fillLevel: fill,
                    aqi: aqi,
                    status: 'Critical',
                    statusColor: Colors.red,
                    fillStatus: fillState,
                    gasStatus: gasState,
                    fireDetected: device['flame'] == true,
                    nextOverflowTime: device['next_overflow_time']?.toString(),
                    gasSpike: device['gas_spike'] == true,
                    predictedFireRisk: device['fire_risk'] == true,
                    backgroundColor: const Color(0xFFFFEBEE),
                    fillLabel: 'Fill',
                    gasLabel: 'Air',
                    onResolve: () => _resolveBinAlerts(device),
                  );
                }),
              const SizedBox(height: 12),
              _screenHeading('OPEN ALERTS'),
              const SizedBox(height: 8),
              if (_alerts.isEmpty)
                const Text('No open alerts.')
              else
                ..._alerts.map((alert) {
                  final alertId = alert['alert_id']?.toString() ?? '';
                  final isResolving = alertId == _resolvingAlertId;
                  return Card(
                    child: ListTile(
                      leading: const Icon(
                        Icons.warning_amber,
                        color: Colors.red,
                      ),
                      title: Text(
                        addDeviceNameToMessage(
                          alert['message'] ?? 'Bin alert',
                          alert['device_id'],
                          _alertDeviceNames,
                        ),
                        style: GoogleFonts.titilliumWeb(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      trailing: isResolving
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : IconButton(
                              tooltip: 'Resolve alert',
                              onPressed: alertId.isEmpty
                                  ? null
                                  : () => _resolveAlert(alertId),
                              icon: const Icon(Icons.check_circle_outline),
                            ),
                    ),
                  );
                }),
            ],
          ],
        ),
      ),
    );
  }
}

class BinsZonesScreen extends StatefulWidget {
  const BinsZonesScreen({super.key});

  @override
  State<BinsZonesScreen> createState() => _BinsZonesScreenState();
}

class _BinsZonesScreenState extends State<BinsZonesScreen> {
  List<Map<String, dynamic>> _devices = [];
  Timer? _refreshTimer;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDevices();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _loadDevices(),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    try {
      final devices = await ApiService.fetchDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bins = _devices.where((device) => device['type'] == 'bin').toList();
    final zones = _devices.where((device) => device['type'] == 'zone').toList();
    return Scaffold(
      appBar: sharedAppBar(context, title: 'BINS & ZONES'),
      drawer: const AppDrawer(),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _screenHeading('BINS & ZONES', icon: Icons.delete_outline),
          const SizedBox(height: 16),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_error != null)
            Center(
              child: Column(
                children: [
                  Text('Unable to load registered devices: $_error'),
                  TextButton(
                    onPressed: _loadDevices,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          else
            RegisteredBinsZonesSection(
              bins: bins,
              zones: zones,
              binBuilder: _registeredBinCard,
              zoneBuilder: (zone) => _registeredZoneCard(zone),
            ),
        ],
      ),
    );
  }
}

Widget _registeredBinCard(Map<String, dynamic> device) {
  final fill = _fillPercent(device['fill_level']);
  final aqi = int.tryParse('${device['gas_level'] ?? 0}') ?? 0;
  final fillState = _registeredFillStatus(fill);
  final gasState = _registeredGasStatus(aqi);
  final status = (device['status'] ?? 'normal').toString();
  final critical = status.toLowerCase() == 'critical';
  return StatusCard(
    title: buildBinDisplayName(device),
    isOnline: device['is_online'] != false,
    subtitle: '',
    fillLevel: fill,
    aqi: aqi,
    status: status.capitalize(),
    statusColor: _registeredStatusColor(status),
    fillStatus: fillState,
    gasStatus: gasState,
    fireDetected: device['flame'] == true,
    nextOverflowTime: device['next_overflow_time']?.toString(),
    gasSpike: device['gas_spike'] == true,
    predictedFireRisk: device['fire_risk'] == true,
    backgroundColor: critical ? const Color(0xFFFFEBEE) : Colors.white,
    fillLabel: 'Fill',
    gasLabel: 'Air',
  );
}

Widget _registeredZoneCard(Map<String, dynamic> zone) {
  final status = (zone['status'] ?? 'normal').toString();
  final critical = status.toLowerCase() == 'critical';
  final fill = _fillPercent(zone['fill_level']);
  final gas = int.tryParse('${zone['gas_level'] ?? 0}') ?? 0;
  final location = (zone['location_description'] ?? '').toString().trim();
  final count = int.tryParse('${zone['bin_count'] ?? 0}') ?? 0;
  return Card(
    margin: const EdgeInsets.only(bottom: 10),
    color: critical ? const Color(0xFFFFEBEE) : Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: critical ? Colors.red.shade200 : Colors.black12),
    ),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.map_outlined, color: Color(0xFF0288D1)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  (zone['name'] ?? 'Zone').toString(),
                  style: GoogleFonts.titilliumWeb(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                status.capitalize(),
                style: GoogleFonts.titilliumWeb(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: _registeredStatusColor(status),
                ),
              ),
            ],
          ),
          if (location.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                location,
                style: GoogleFonts.titilliumWeb(
                  fontSize: 16,
                  color: Colors.black54,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            '$count bins  •  Average fill $fill%  •  Air $gas',
            style: GoogleFonts.titilliumWeb(fontSize: 16),
          ),
        ],
      ),
    ),
  );
}

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: sharedAppBar(context, title: 'HISTORY'),
      drawer: const AppDrawer(),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _screenHeading('HISTORY'),
            const SizedBox(height: 20),
            const Center(child: Text('No history available')),
          ],
        ),
      ),
    );
  }
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final ImagePicker _picker = ImagePicker();
  String? _profileImageUrl;
  bool _isLoading = true;

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _dobController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchAdminData();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _dobController.dispose();
    super.dispose();
  }

  Future<void> _fetchAdminData() async {
    setState(() {
      _isLoading = true;
    });
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final data = await ApiService.fetchAdminProfile(user.uid);
        setState(() {
          _profileImageUrl = data['profile_image_url'];
          _nameController.text = data['name'] ?? '';
          _emailController.text = data['email'] ?? '';
          _phoneController.text = data['phone'] ?? '';
          _dobController.text = data['date_of_birth'] ?? '';
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading admin profile: $e')),
        );
      }
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _uploadProfilePicture() async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
      );
      if (pickedFile == null) return;

      final Uint8List imageBytes = await pickedFile.readAsBytes();
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final String newImageUrl = await ApiService.uploadProfilePicture(
        ownerId: user.uid,
        ownerType: 'admin',
        imageBytes: imageBytes,
      );

      await ApiService.updateAdminProfile(
        user.uid,
        profileImageUrl: newImageUrl,
      );

      final cacheBustedUrl =
          '$newImageUrl?v=${DateTime.now().millisecondsSinceEpoch}';
      setState(() {
        _profileImageUrl = cacheBustedUrl;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile picture updated')),
        );
      }
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error uploading picture: $e')));
      }
    }
  }

  Future<void> _pickDate(TextEditingController controller) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 20),
      firstDate: DateTime(1950),
      lastDate: now,
    );
    if (picked == null) return;
    controller.text =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
  }

  Future<void> _saveChanges() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      await ApiService.updateAdminProfile(
        user.uid,
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
        phone: _phoneController.text.trim(),
        dateOfBirth: _dobController.text.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile updated successfully')),
        );
        _fetchAdminData(); // Refresh data after saving
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error saving profile: $e')));
      }
    }
  }

  Widget _infoRow(String label, Widget valueWidget) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 105,
            child: Text(
              '$label:',
              style: GoogleFonts.titilliumWeb(
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Colors.black12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: DefaultTextStyle.merge(
                style: GoogleFonts.titilliumWeb(fontSize: 18),
                child: valueWidget,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: sharedAppBar(context, title: 'PROFILE'),
      drawer: const AppDrawer(),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _screenHeading('PROFILE', icon: Icons.person),
                  const SizedBox(height: 20),
                  Center(
                    child: Stack(
                      children: [
                        CircleAvatar(
                          radius: 60,
                          backgroundImage:
                              _profileImageUrl != null &&
                                  _profileImageUrl!.isNotEmpty
                              ? CachedNetworkImageProvider(_profileImageUrl!)
                              : null,
                          child:
                              (_profileImageUrl == null ||
                                  _profileImageUrl!.isEmpty)
                              ? const Icon(Icons.person, size: 60)
                              : null,
                        ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: CircleAvatar(
                            backgroundColor: const Color(0xFF03A9F4),
                            child: IconButton(
                              icon: const Icon(
                                Icons.camera_alt,
                                color: Colors.white,
                              ),
                              onPressed: _uploadProfilePicture,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'PERSONAL INFORMATION',
                            style: GoogleFonts.rubikMonoOne(fontSize: 16),
                          ),
                          const Divider(),
                          const SizedBox(height: 12),
                          _infoRow(
                            'Full Name',
                            TextField(
                              controller: _nameController,
                              style: GoogleFonts.titilliumWeb(fontSize: 18),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                          _infoRow(
                            'Email',
                            TextField(
                              controller: _emailController,
                              style: GoogleFonts.titilliumWeb(fontSize: 18),
                              keyboardType: TextInputType.emailAddress,
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                          _infoRow(
                            'Phone',
                            TextField(
                              controller: _phoneController,
                              style: GoogleFonts.titilliumWeb(fontSize: 18),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                              keyboardType: TextInputType.phone,
                            ),
                          ),
                          _infoRow(
                            'Date of Birth',
                            TextField(
                              style: GoogleFonts.titilliumWeb(fontSize: 18),
                              controller: _dobController,
                              readOnly: true,
                              onTap: () => _pickDate(_dobController),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                                suffixIcon: Icon(
                                  Icons.calendar_month,
                                  size: 20,
                                ),
                                suffixIconConstraints: BoxConstraints(
                                  minWidth: 20,
                                  minHeight: 20,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: _saveChanges,
                    icon: const Icon(Icons.save),
                    label: const Text('SAVE CHANGES'),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 50),
                      backgroundColor: const Color(0xFF03A9F4),
                      foregroundColor: Colors.white,
                      textStyle: GoogleFonts.titilliumWeb(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const Map<String, bool> _defaults = {
    'report_submitted': true,
    'unresolved_critical_alert': true,
    'task_acknowledged': true,
    'task_completed': true,
    'device_offline': true,
    'device_online': true,
    'sensor_issue': true,
  };
  static const Map<String, String> _labels = {
    'report_submitted': 'Issue reports submitted',
    'unresolved_critical_alert': 'Unresolved critical alerts',
    'task_acknowledged': 'Task acknowledged',
    'task_completed': 'Task completed',
    'device_offline': 'Bin device offline',
    'device_online': 'Bin device back online',
    'sensor_issue': 'Sensor reading issues',
  };

  final Map<String, bool> _preferences = Map<String, bool>.from(_defaults);
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _adminId;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = 'Sign in to manage settings.';
        });
      return;
    }
    try {
      final admin = await ApiService.fetchAdminProfile(user.uid);
      final saved = admin['notification_preferences'];
      if (!mounted) return;
      setState(() {
        _adminId = user.uid;
        if (saved is Map) {
          for (final key in _defaults.keys) {
            _preferences[key] = saved[key] is bool
                ? saved[key] as bool
                : _defaults[key]!;
          }
        }
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _savePreferences() async {
    final adminId = _adminId;
    if (adminId == null) return;
    setState(() => _saving = true);
    try {
      await ApiService.saveAdminNotificationPreferences(
        adminId: adminId,
        preferences: Map<String, bool>.from(_preferences),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification settings saved.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save settings: $error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: sharedAppBar(context, title: 'SETTINGS'),
      drawer: const AppDrawer(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _screenHeading('SETTINGS', icon: Icons.settings),
                const Divider(height: 28, thickness: 1),
                Text(
                  'Choose what notifications to receive',
                  style: GoogleFonts.titilliumWeb(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                ..._labels.entries.map(
                  (entry) => SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      entry.value,
                      style: GoogleFonts.titilliumWeb(fontSize: 16),
                    ),
                    value: _preferences[entry.key] ?? true,
                    onChanged: (value) =>
                        setState(() => _preferences[entry.key] = value),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton(
                    onPressed: _saving ? null : _savePreferences,
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Save'),
                  ),
                ),
              ],
            ),
    );
  }
}

class MapSection extends StatefulWidget {
  final double? height;
  final LatLng? focusLocation;
  final double? focusZoom;
  final int focusRequest;

  const MapSection({
    super.key,
    this.height,
    this.focusLocation,
    this.focusZoom,
    this.focusRequest = 0,
  });

  @override
  State<MapSection> createState() => _MapSectionState();
}

class _MapSectionState extends State<MapSection> {
  bool _isLoading = true;
  String? _error;
  List<Marker> _markers = [];

  static const LatLng _defaultCenter = LatLng(12.9716, 77.5946);
  static const double _baseZoom = 13.0;
  static const double _defaultZoomFactor = 1.46;
  static const double _defaultZoomForDisplay = _baseZoom * _defaultZoomFactor;
  final MapController _mapController = MapController();
  LatLng _center = _defaultCenter;
  double _zoom = _defaultZoomForDisplay;
  double _zoomLevel = _defaultZoomForDisplay;
  LatLng? _currentUserLocation;
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    _fetchLocations();
  }

  @override
  void didUpdateWidget(covariant MapSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusLocation != null &&
        (widget.focusLocation != oldWidget.focusLocation ||
            widget.focusRequest != oldWidget.focusRequest)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_mapReady) return;
        _mapController.move(
          widget.focusLocation!,
          widget.focusZoom ?? _defaultZoomForDisplay,
        );
      });
    }
  }

  Future<void> _fetchLocations() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final configFuture = ApiService.fetchAppConfig().timeout(
        const Duration(seconds: 6),
      );
      final markerDataFuture = Future.wait([
        ApiService.fetchWorkers().timeout(const Duration(seconds: 6)),
        ApiService.fetchDevices().timeout(const Duration(seconds: 6)),
      ]).timeout(const Duration(seconds: 6));

      Map<String, dynamic> config = const {};
      try {
        config = await configFuture;
      } catch (error) {
        debugPrint('Could not fetch app config for map center: $error');
      }
      LatLng? orgCenter;
      try {
        final organization = config['organization_location'];
        final nested = organization is Map
            ? organization
            : const <String, dynamic>{};
        final latitude = _coordinate(
          config['latitude'] ??
              config['location_lat'] ??
              nested['latitude'] ??
              nested['lat'],
        );
        final longitude = _coordinate(
          config['longitude'] ??
              config['location_lon'] ??
              nested['longitude'] ??
              nested['lng'],
        );
        if (latitude != null &&
            longitude != null &&
            latitude.abs() <= 90 &&
            longitude.abs() <= 180 &&
            (latitude != 0 || longitude != 0)) {
          orgCenter = LatLng(latitude, longitude);
        }
      } catch (error) {
        debugPrint('Could not fetch app config for map center: $error');
      }

      List<Map<String, dynamic>> workers = [];
      List<Map<String, dynamic>> devices = [];
      try {
        final results = await markerDataFuture;
        workers = results[0];
        devices = results[1];
      } catch (error) {
        debugPrint('Could not fetch map markers: $error');
      }
      if (!mounted) return;
      final Set<Marker> newMarkers = {};

      if (orgCenter != null) {
        newMarkers.add(
          Marker(
            point: orgCenter,
            width: 64,
            height: 64,
            child: const Icon(Icons.business, color: Colors.red, size: 40),
          ),
        );
      }

      // Process workers
      for (final worker in workers) {
        final location = worker['current_location'];
        if (location != null &&
            location['lat'] is num &&
            location['lng'] is num) {
          final lat = (location['lat'] as num).toDouble();
          final lng = (location['lng'] as num).toDouble();

          if (lat == 0.0 && lng == 0.0) continue;

          final position = LatLng(lat, lng);

          newMarkers.add(
            Marker(
              width: 80.0,
              height: 80.0,
              point: position,
              child: Tooltip(
                message: worker['name'] ?? 'Worker',
                child: const Icon(
                  Icons.person_pin_circle,
                  color: Colors.blueAccent,
                  size: 40,
                ),
              ),
            ),
          );
        }
      }
      // Process devices (bins and zones)
      final devicePointCounts = <String, int>{};
      for (final device in devices) {
        final location = device['location'];
        if (location != null &&
            location['coordinates'] is List &&
            (location['coordinates'] as List).length == 2) {
          final coords = location['coordinates'] as List;
          final lng = (coords[0] as num).toDouble();
          final lat = (coords[1] as num).toDouble();

          if (lat == 0.0 && lng == 0.0) continue;

          final position = LatLng(lat, lng);

          final isBin = device['type'] == 'bin';
          final pointKey =
              '${position.latitude.toStringAsFixed(7)},${position.longitude.toStringAsFixed(7)}';
          final overlapIndex = devicePointCounts.update(
            pointKey,
            (count) => count + 1,
            ifAbsent: () => 0,
          );
          final markerPosition = overlapIndex == 0
              ? position
              : const Distance().offset(
                  position,
                  12 + overlapIndex * 8,
                  45 + overlapIndex * 60,
                );
          newMarkers.add(
            Marker(
              width: 80.0,
              height: 80.0,
              point: markerPosition,
              child: Tooltip(
                message: '${device['name'] ?? 'Device'} (${device['type']})',
                child: Icon(
                  isBin ? Icons.delete_outline : Icons.business_center,
                  color: isBin ? Colors.brown[600] : Colors.purple[600],
                  size: 35,
                ),
              ),
            ),
          );
        }
      }

      if (mounted) {
        setState(() {
          _isLoading = false;
          _markers = newMarkers.toList();
          _center =
              orgCenter ??
              (newMarkers.isEmpty ? _defaultCenter : newMarkers.first.point);
          _zoom = _defaultZoomForDisplay;
          _zoomLevel = _defaultZoomForDisplay;
        });
        unawaited(_loadCurrentLocation());
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = "Failed to load map data: $e";
        });
      }
    }
  }

  Future<void> _loadCurrentLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled().timeout(
        const Duration(seconds: 3),
      )) {
        return;
      }
      var permission = await Geolocator.checkPermission().timeout(
        const Duration(seconds: 3),
      );
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission().timeout(
          const Duration(seconds: 10),
        );
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
        ),
      ).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      final location = LatLng(position.latitude, position.longitude);
      final marker = Marker(
        point: location,
        width: 64,
        height: 64,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFFE53935), width: 2),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFE53935).withValues(alpha: 0.2),
                blurRadius: 12,
                spreadRadius: 2,
              ),
            ],
          ),
          padding: const EdgeInsets.all(4),
          child: const Icon(
            Icons.location_pin,
            color: Color(0xFFE53935),
            size: 28,
          ),
        ),
      );
      setState(() {
        _currentUserLocation = location;
        _markers = [..._markers, marker];
      });
      if (_mapReady && widget.focusLocation == null) {
        _mapController.move(location, _zoom);
      }
    } catch (error) {
      debugPrint('Could not get current location for map: $error');
    }
  }

  double? _coordinate(dynamic value) =>
      value is num ? value.toDouble() : double.tryParse('$value');

  int _displayPercent() {
    if (_baseZoom <= 0 || _zoomLevel <= 0) return 100;
    return ((_zoomLevel / _defaultZoomForDisplay) * 100).round();
  }

  void _zoomBy(double delta) {
    final nextZoom = (_zoomLevel + delta).clamp(4.0, 22.0);
    _zoomLevel = nextZoom;
    _zoom = nextZoom;
    _mapController.move(_mapController.camera.center, nextZoom);
    if (mounted) setState(() {});
  }

  void _resetView() {
    final target = _currentUserLocation ?? _center;
    _zoomLevel = _defaultZoomForDisplay;
    _zoom = _defaultZoomForDisplay;
    _mapController.move(target, _defaultZoomForDisplay);
  }

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (_isLoading) {
      content = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      content = Center(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Text(
            _error!,
            style: TextStyle(color: Colors.red[700]),
            textAlign: TextAlign.center,
          ),
        ),
      );
    } else {
      content = FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: widget.focusLocation ?? _center,
          initialZoom: widget.focusZoom ?? _zoom,
          minZoom: 4,
          maxZoom: 22,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all,
          ),
          onMapReady: () {
            _mapReady = true;
            _zoom = widget.focusZoom ?? _defaultZoomForDisplay;
            _zoomLevel = widget.focusZoom ?? _defaultZoomForDisplay;
            final target =
                widget.focusLocation ?? _currentUserLocation ?? _center;
            _mapController.move(target, _zoom);
          },
          onMapEvent: (_) {
            if (!mounted) return;
            _zoom = _mapController.camera.zoom;
            _zoomLevel = _mapController.camera.zoom;
            setState(() {});
          },
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            maxNativeZoom: 19,
            userAgentPackageName: 'com.binsight.app',
          ),
          MarkerLayer(markers: _markers),
        ],
      );
    }

    return Stack(
      children: [
        Container(
          height: widget.height,
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(16),
            border: _error != null ? Border.all(color: Colors.red[300]!) : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: content,
          ),
        ),
        if (_error == null)
          Positioned(
            right: 14,
            top: 14,
            child: Column(
              children: [
                Material(
                  color: const Color(0xFFE53935),
                  shape: const CircleBorder(),
                  elevation: 4,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: !_mapReady ? null : _resetView,
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(
                        Icons.my_location,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.08),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: _mapReady && !_isLoading
                            ? () => _zoomBy(1)
                            : null,
                        icon: const Icon(Icons.add, size: 18),
                        tooltip: 'Zoom in',
                      ),
                      Text(
                        '${_displayPercent()}%',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                          color: Colors.black87,
                        ),
                      ),
                      IconButton(
                        onPressed: _mapReady && !_isLoading
                            ? () => _zoomBy(-1)
                            : null,
                        icon: const Icon(Icons.remove, size: 18),
                        tooltip: 'Zoom out',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class StatusCard extends StatelessWidget {
  final String title, status;
  final String? subtitle;
  final int fillLevel, aqi;
  final Color statusColor;
  final Color? backgroundColor;
  final String fillLabel;
  final String gasLabel;
  final String fillStatus;
  final String gasStatus;
  final bool fireDetected;
  final bool isOnline;
  final String? nextOverflowTime;
  final bool gasSpike;
  final bool predictedFireRisk;
  final String? sensorDetails;
  final VoidCallback? onTap;
  final VoidCallback? onResolve;

  const StatusCard({
    super.key,
    required this.title,
    this.subtitle,
    required this.fillLevel,
    required this.aqi,
    required this.status,
    required this.statusColor,
    this.backgroundColor,
    this.fillLabel = 'Fill',
    this.gasLabel = 'Air',
    this.fillStatus = 'Normal',
    this.gasStatus = 'Normal',
    this.fireDetected = false,
    this.isOnline = true,
    this.nextOverflowTime,
    this.gasSpike = false,
    this.predictedFireRisk = false,
    this.sensorDetails,
    this.onTap,
    this.onResolve,
  });

  @override
  Widget build(BuildContext context) {
    final fillColor = _statusColorFromValue(fillStatus);
    final gasColor = _statusColorFromValue(gasStatus);
    final fireColor = fireDetected ? Colors.red : Colors.green;
    final fireText = fireDetected ? 'Present' : 'Not Present';

    final card = Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: backgroundColor ?? Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.titilliumWeb(
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
          if (subtitle != null && subtitle!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                subtitle!,
                style: GoogleFonts.titilliumWeb(
                  fontSize: 16,
                  color: Colors.black54,
                ),
              ),
            ),
          const Divider(),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Wrap(
                  alignment: WrapAlignment.start,
                  spacing: 18,
                  runSpacing: 10,
                  children: [
                    _metricInfo(
                      '$fillLabel: ',
                      '$fillLevel% ($fillStatus)',
                      fillColor,
                      Icons.bar_chart,
                    ),
                    _metricInfo(
                      '$gasLabel: ',
                      '${aqi} PPM ($gasStatus)',
                      gasColor,
                      Icons.cloud_outlined,
                    ),
                    _metricInfo(
                      'Fire: ',
                      fireText,
                      fireColor,
                      Icons.local_fire_department,
                    ),
                    if (nextOverflowTime != null)
                      _metricInfo(
                        'Next Overflow Time: ',
                        nextOverflowTime!,
                        Colors.blueGrey,
                        Icons.timer_outlined,
                      ),
                    if (gasSpike || predictedFireRisk)
                      _metricInfo(
                        'Predicted anomaly: ',
                        [
                          if (gasSpike) 'gas spike',
                          if (predictedFireRisk) 'fire risk',
                        ].join(' and '),
                        Colors.deepOrange,
                        Icons.warning_amber_rounded,
                      ),
                  ],
                ),
              ),
              Row(
                children: [
                  Text(
                    'Status: ',
                    style: GoogleFonts.titilliumWeb(
                      fontSize: 16,
                      color: Colors.grey[700],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      status,
                      style: GoogleFonts.titilliumWeb(
                        color: statusColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
              if (onResolve != null) ...[
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: onResolve,
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Resolve'),
                ),
              ],
            ],
          ),
          if (!isOnline) ...[
            const SizedBox(height: 8),
            Text(
              'Bin is offline. Showing last logged data.',
              style: GoogleFonts.titilliumWeb(
                fontSize: 15,
                fontStyle: FontStyle.italic,
                color: Colors.red.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (sensorDetails != null && sensorDetails!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              sensorDetails!,
              style: GoogleFonts.titilliumWeb(
                fontSize: 16,
                color: Colors.black54,
              ),
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return card;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: card,
    );
  }

  Color _statusColorFromValue(String value) {
    switch (value.trim().toLowerCase()) {
      case 'full':
      case 'almost full':
      case 'very poor':
      case 'severe / hazardous':
        return Colors.red;
      case 'moderate':
      case 'poor':
        return const Color(0xFFB26A00);
      case 'normal':
      case 'no fire':
        return Colors.green;
      default:
        return Colors.grey;
    }
  }

  Widget _metricInfo(String label, String value, Color color, IconData icon) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text.rich(
            TextSpan(
              style: GoogleFonts.titilliumWeb(
                fontSize: 16,
                color: Colors.black,
              ),
              children: [
                TextSpan(
                  text: label,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                TextSpan(
                  text: value,
                  style: TextStyle(color: color, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class TaskCard extends StatelessWidget {
  final String name, priority, distance;
  final Color priorityColor;

  const TaskCard({
    super.key,
    required this.name,
    required this.priority,
    required this.priorityColor,
    required this.distance,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        title: Text(name),
        subtitle: Text(
          '$priority • $distance',
          style: TextStyle(color: priorityColor),
        ),
      ),
    );
  }
}

class AddWorkerScreen extends StatefulWidget {
  const AddWorkerScreen({super.key});

  @override
  State<AddWorkerScreen> createState() => _AddWorkerScreenState();
}

class _AddWorkerScreenState extends State<AddWorkerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _dob = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _picker = ImagePicker();
  Uint8List? _photoBytes;
  bool _loading = false;

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _dob.dispose();
    _phone.dispose();
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final value = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 20),
      firstDate: DateTime(1950),
      lastDate: now,
    );
    if (value != null) {
      _dob.text =
          '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
    }
  }

  Future<void> _pickPhoto() async {
    final image = await _picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;
    setState(() => _photoBytes = null);
    final bytes = await image.readAsBytes();
    if (mounted) setState(() => _photoBytes = bytes);
  }

  Future<void> _addWorker() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    FirebaseApp? workerApp;
    User? createdUser;
    try {
      workerApp = await Firebase.initializeApp(
        name: 'binsight-worker-${DateTime.now().microsecondsSinceEpoch}',
        options: Firebase.app().options,
      );
      final workerAuth = FirebaseAuth.instanceFor(app: workerApp);
      final email = _email.text.trim();
      final credential = await workerAuth.createUserWithEmailAndPassword(
        email: email,
        password: _password.text,
      );
      createdUser = credential.user;
      if (createdUser == null)
        throw Exception('Firebase did not create the worker account.');

      var photoUrl = '';
      if (_photoBytes != null) {
        photoUrl = await ApiService.uploadProfilePicture(
          ownerId: createdUser.uid,
          ownerType: 'worker',
          imageBytes: _photoBytes!,
        );
      }
      final first = _firstName.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      final last = _lastName.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      await ApiService.upsertWorkerProfile(
        workerId: createdUser.uid,
        email: email,
        name: '$first $last',
        firstName: first,
        lastName: last,
        dateOfBirth: _dob.text.trim(),
        phone: _phone.text.trim(),
        profileImageUrl: photoUrl,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Worker added successfully')),
      );
      Navigator.pop(context);
    } catch (error) {
      if (createdUser != null && workerApp != null) {
        try {
          await FirebaseAuth.instanceFor(app: workerApp).currentUser?.delete();
        } catch (_) {}
      }
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not add worker: $error')));
    } finally {
      if (workerApp != null) {
        try {
          await workerApp.delete();
        } catch (_) {}
      }
      if (mounted) setState(() => _loading = false);
    }
  }

  InputDecoration _decoration(String label, {Widget? suffix}) =>
      InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        suffixIcon: suffix,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: sharedAppBar(
        context,
        title: 'ADD WORKER',
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.maybePop(context),
            icon: const Icon(Icons.arrow_back, color: Colors.white, size: 18),
            label: Text(
              'BACK',
              style: GoogleFonts.titilliumWeb(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      drawer: const AppDrawer(),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _screenHeading('ADD WORKER', icon: Icons.people),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _firstName,
                    decoration: _decoration('First Name'),
                    validator: _required,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _lastName,
                    decoration: _decoration('Last Name'),
                    validator: _required,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _dob,
              readOnly: true,
              onTap: _pickDate,
              decoration: _decoration(
                'Date of Birth',
                suffix: const Icon(Icons.calendar_month),
              ),
              validator: _required,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: _decoration('Worker Phone Number'),
              validator: _required,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: _decoration('Worker Email'),
              validator: (v) =>
                  (v == null ||
                      !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim()))
                  ? 'Enter a valid email'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _password,
              obscureText: true,
              decoration: _decoration('Worker Password'),
              validator: (v) => (v == null || v.trim().length < 6)
                  ? 'Password must be at least 6 characters'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _confirmPassword,
              obscureText: true,
              decoration: _decoration('Confirm Worker Password'),
              validator: (v) =>
                  v != _password.text ? "Passwords don't match" : null,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundImage: _photoBytes == null
                      ? null
                      : MemoryImage(_photoBytes!),
                  child: _photoBytes == null ? const Icon(Icons.person) : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _loading ? null : _pickPhoto,
                    icon: const Icon(Icons.upload),
                    label: const Text('UPLOAD WORKER PHOTO'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _loading ? null : _addWorker,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF03A9F4),
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 52),
              ),
              child: _loading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : Text(
                      'ADD WORKER',
                      style: GoogleFonts.titilliumWeb(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Required' : null;
}

// ---------------- WORKER PROFILE SCREEN ---------------- //

class WorkerProfileScreen extends StatefulWidget {
  final String workerId;
  final Map<String, dynamic> workerData;

  const WorkerProfileScreen({
    super.key,
    required this.workerId,
    required this.workerData,
  });

  @override
  State<WorkerProfileScreen> createState() => _WorkerProfileScreenState();
}

class _WorkerProfileScreenState extends State<WorkerProfileScreen> {
  final ImagePicker _picker = ImagePicker();
  late Map<String, dynamic> _workerData;
  bool _isLoading = false;

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _dobController = TextEditingController();

  String? _profileImageUrl;
  final Map<String, String> _zoneNameCache = <String, String>{};
  final Map<String, String> _binNameCache = <String, String>{};

  List<String> get _assignedZones =>
      List<String>.from(_workerData['assigned_zones'] ?? const []);
  List<String> get _assignedBins =>
      List<String>.from(_workerData['assigned_bins'] ?? const []);

  bool get _hasChanges =>
      _nameController.text.trim() !=
          (_workerData['name'] ?? '').toString().trim() ||
      _emailController.text.trim() !=
          (_workerData['email'] ?? '').toString().trim() ||
      _phoneController.text.trim() !=
          (_workerData['phone'] ?? '').toString().trim() ||
      _dobController.text.trim() !=
          (_workerData['date_of_birth'] ?? '').toString().trim();

  @override
  void initState() {
    super.initState();
    _workerData = widget.workerData;
    _profileImageUrl = _workerData['profile_image_url'];
    _nameController.text = (_workerData['name'] ?? '').toString();
    _emailController.text = (_workerData['email'] ?? '').toString();
    _phoneController.text = (_workerData['phone'] ?? '').toString();
    _dobController.text = (_workerData['date_of_birth'] ?? '').toString();
    _populateAssignmentNameCache();
  }

  Future<void> _populateAssignmentNameCache() async {
    try {
      final zones = await ApiService.fetchZones();
      for (final zone in zones) {
        final zoneId = (zone['zone_id'] ?? zone['id'])?.toString();
        final zoneName = buildZoneNameWithoutPicker(zone);
        if (zoneId != null && zoneId.isNotEmpty) {
          _zoneNameCache[zoneId] = zoneName;
        }
      }
    } catch (_) {}

    try {
      final devices = await ApiService.fetchDevices();
      for (final device in devices) {
        final binId = (device['bin_id'] ?? device['id'])?.toString();
        final binName = buildBinDisplayName(device);
        if (binId != null && binId.isNotEmpty) {
          _binNameCache[binId] = binName;
        }
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _dobController.dispose();
    super.dispose();
  }

  Widget _infoRow(String label, Widget valueWidget) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 105,
            child: Text(
              '$label:',
              style: GoogleFonts.titilliumWeb(
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Colors.black12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: DefaultTextStyle.merge(
                style: GoogleFonts.titilliumWeb(fontSize: 18),
                child: valueWidget,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveWorkerProfile() async {
    try {
      await ApiService.updateWorkerProfile(
        widget.workerId,
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
        phone: _phoneController.text.trim(),
        dateOfBirth: _dobController.text.trim(),
        assignedZones: _assignedZones,
        assignedBins: _assignedBins,
      );

      setState(() {
        _workerData['name'] = _nameController.text.trim();
        _workerData['email'] = _emailController.text.trim();
        _workerData['phone'] = _phoneController.text.trim();
        _workerData['date_of_birth'] = _dobController.text.trim();
        _workerData['assigned_zones'] = _assignedZones;
        _workerData['assigned_bins'] = _assignedBins;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Worker profile updated successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error saving profile: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: sharedAppBar(
        context,
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.maybePop(context),
            icon: const Icon(Icons.arrow_back, color: Colors.white, size: 18),
            label: Text(
              'BACK',
              style: GoogleFonts.titilliumWeb(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      drawer: const AppDrawer(),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _screenHeading('WORKER PROFILE', icon: Icons.person),
                  const SizedBox(height: 24),
                  Center(
                    child: Stack(
                      children: [
                        CircleAvatar(
                          radius: 60,
                          backgroundImage:
                              _profileImageUrl != null &&
                                  _profileImageUrl!.isNotEmpty
                              ? CachedNetworkImageProvider(_profileImageUrl!)
                              : null,
                          child:
                              (_profileImageUrl == null ||
                                  _profileImageUrl!.isEmpty)
                              ? const Icon(Icons.person, size: 60)
                              : null,
                        ),
                        Positioned(
                          bottom: 0,
                          right: 4,
                          child: CircleAvatar(
                            backgroundColor: const Color(0xFF03A9F4),
                            child: IconButton(
                              icon: const Icon(
                                Icons.camera_alt,
                                color: Colors.white,
                              ),
                              onPressed: _uploadProfilePicture,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'PERSONAL INFORMATION',
                            style: GoogleFonts.rubikMonoOne(fontSize: 16),
                          ),
                          const Divider(),
                          const SizedBox(height: 12),
                          _infoRow(
                            'Full Name',
                            TextField(
                              controller: _nameController,
                              style: GoogleFonts.titilliumWeb(fontSize: 18),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                          _infoRow(
                            'Email',
                            TextField(
                              controller: _emailController,
                              style: GoogleFonts.titilliumWeb(fontSize: 18),
                              keyboardType: TextInputType.emailAddress,
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                          _infoRow(
                            'Phone',
                            TextField(
                              controller: _phoneController,
                              style: GoogleFonts.titilliumWeb(fontSize: 18),
                              keyboardType: TextInputType.phone,
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                          _infoRow(
                            'Date of Birth',
                            TextField(
                              controller: _dobController,
                              style: GoogleFonts.titilliumWeb(fontSize: 18),
                              readOnly: true,
                              onTap: () async {
                                final now = DateTime.now();
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: DateTime(now.year - 20),
                                  firstDate: DateTime(1950),
                                  lastDate: now,
                                );
                                if (picked == null) return;
                                _dobController.text =
                                    '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                              },
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                                suffixIcon: Icon(
                                  Icons.calendar_month,
                                  size: 18,
                                ),
                              ),
                            ),
                          ),
                          _infoRow(
                            'Join Date',
                            Text(
                              _workerData['created_at'] != null
                                  ? formatIstDate(_workerData['created_at'])
                                  : 'Not set',
                            ),
                          ),
                          const SizedBox(height: 16),
                          if (_hasChanges)
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _saveWorkerProfile,
                                icon: const Icon(Icons.save),
                                label: const Text('SAVE CHANGES'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF03A9F4),
                                  foregroundColor: Colors.white,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ASSIGNED TASKS',
                            style: GoogleFonts.rubikMonoOne(fontSize: 16),
                          ),
                          const Divider(),
                          const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Assigned Zones',
                                      style: GoogleFonts.rubikMonoOne(
                                        fontSize: 16,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    if (_assignedZones.isEmpty)
                                      const Text('No zones assigned yet')
                                    else
                                      ..._assignedZones.map<Widget>((zoneId) {
                                        final zoneName = _zoneName(zoneId);
                                        return ListTile(
                                          dense: true,
                                          contentPadding: EdgeInsets.zero,
                                          leading: const Icon(
                                            Icons.home_outlined,
                                          ),
                                          title: Text(zoneName),
                                          trailing: TextButton(
                                            onPressed: () =>
                                                _confirmUnassignZone(zoneId),
                                            child: const Text('UNASSIGN'),
                                          ),
                                        );
                                      }),
                                    const SizedBox(height: 12),
                                    ElevatedButton.icon(
                                      onPressed: () => _showAssignZoneDialog(),
                                      icon: const Icon(Icons.add),
                                      label: const Text('ASSIGN ZONE'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFF03A9F4,
                                        ),
                                        foregroundColor: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Assigned Bins',
                                      style: GoogleFonts.rubikMonoOne(
                                        fontSize: 16,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    if (_assignedBins.isEmpty)
                                      const Text('No bins assigned yet')
                                    else
                                      ..._assignedBins.map<Widget>((binId) {
                                        final binName = _binName(binId);
                                        return ListTile(
                                          dense: true,
                                          contentPadding: EdgeInsets.zero,
                                          leading: const Icon(
                                            Icons.delete_outline,
                                          ),
                                          title: Text(binName),
                                          trailing: TextButton(
                                            onPressed: () =>
                                                _confirmUnassignBin(binId),
                                            child: const Text('UNASSIGN'),
                                          ),
                                        );
                                      }),
                                    const SizedBox(height: 12),
                                    ElevatedButton.icon(
                                      onPressed: () => _showAssignBinDialog(),
                                      icon: const Icon(Icons.add),
                                      label: const Text('ASSIGN BIN'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFF03A9F4,
                                        ),
                                        foregroundColor: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  String _zoneName(String zoneId) => _zoneNameCache[zoneId] ?? zoneId;

  String _binName(String binId) => _binNameCache[binId] ?? binId;

  void _showAssignZoneDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => FutureBuilder<List<Map<String, dynamic>>>(
        future: ApiService.fetchZones(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const AlertDialog(
              content: Center(child: CircularProgressIndicator()),
            );
          }

          final zones = snapshot.data ?? const <Map<String, dynamic>>[];
          final availableZones = zones
              .where(
                (zone) => !_assignedZones.contains(zone['zone_id']?.toString()),
              )
              .toList();

          if (availableZones.isEmpty) {
            return AlertDialog(
              title: const Text('ASSIGN ZONE'),
              content: const Text('No available zones to assign'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
              ],
            );
          }

          return AlertDialog(
            title: const Text('ASSIGN ZONE'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: availableZones.length,
                itemBuilder: (context, index) {
                  final zone = availableZones[index];
                  final zoneId = zone['zone_id']?.toString() ?? '';
                  return ListTile(
                    title: Text(buildZoneDisplayName(zone)),
                    onTap: () => _assignZone(zoneId),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('CANCEL'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showAssignBinDialog() async {
    final devices = await ApiService.fetchDevices();
    final bins = devices.where((d) => d['type'] == 'bin').toList();
    final availableBins = bins
        .where(
          (bin) => !_assignedBins.contains(
            bin['bin_id']?.toString() ?? bin['id']?.toString(),
          ),
        )
        .toList();

    if (!mounted) return;
    if (availableBins.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No available bins to assign')),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ASSIGN BIN'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: availableBins.length,
            itemBuilder: (context, index) {
              final bin = availableBins[index];
              final binId =
                  (bin['bin_id'] ?? bin['id'])?.toString() ?? 'Unknown';
              final binName = buildBinDisplayName(bin);
              return ListTile(
                title: Text(binName),
                onTap: () => _assignBin(binId),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('CANCEL'),
          ),
        ],
      ),
    );
  }

  Future<void> _assignZone(String zoneId) async {
    final assignedZones = List<String>.from(_assignedZones);
    if (zoneId.isEmpty || assignedZones.contains(zoneId)) {
      if (mounted) Navigator.pop(context);
      return;
    }
    assignedZones.add(zoneId);

    await ApiService.updateWorkerProfile(
      widget.workerId,
      assignedZones: assignedZones,
      assignedBins: _assignedBins,
    );

    setState(() {
      _workerData['assigned_zones'] = assignedZones;
    });

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Zone assigned successfully')),
      );
    }
  }

  Future<void> _assignBin(String binId) async {
    final assignedBins = List<String>.from(_assignedBins);
    if (binId.isEmpty || assignedBins.contains(binId)) {
      if (mounted) Navigator.pop(context);
      return;
    }
    assignedBins.add(binId);

    await ApiService.updateWorkerProfile(
      widget.workerId,
      assignedZones: _assignedZones,
      assignedBins: assignedBins,
    );

    setState(() {
      _workerData['assigned_bins'] = assignedBins;
    });

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bin assigned successfully')),
      );
    }
  }

  Future<void> _confirmUnassignZone(String zoneId) async {
    final zoneName = _zoneName(zoneId);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unassign zone'),
        content: Text(
          'Are you sure you want to unassign $zoneName from this worker?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('NO'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('YES'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final assignedZones = List<String>.from(_assignedZones)..remove(zoneId);
    await ApiService.updateWorkerProfile(
      widget.workerId,
      assignedZones: assignedZones,
      assignedBins: _assignedBins,
    );
    setState(() => _workerData['assigned_zones'] = assignedZones);
  }

  Future<void> _confirmUnassignBin(String binId) async {
    final binName = _binName(binId);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unassign bin'),
        content: Text(
          'Are you sure you want to unassign $binName from this worker?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('NO'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('YES'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final assignedBins = List<String>.from(_assignedBins)..remove(binId);
    await ApiService.updateWorkerProfile(
      widget.workerId,
      assignedZones: _assignedZones,
      assignedBins: assignedBins,
    );
    setState(() => _workerData['assigned_bins'] = assignedBins);
  }

  Future<void> _uploadProfilePicture() async {
    // Corrected `Future` type usage
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
      );
      if (pickedFile == null) return;

      final Uint8List imageBytes = await pickedFile.readAsBytes();

      // Upload to backend via ApiService (MongoDB storage)
      final String newImageUrl = await ApiService.uploadProfilePicture(
        ownerId: widget.workerId,
        ownerType: 'worker',
        imageBytes: imageBytes,
      );

      // Update worker profile with the new URL via API
      await ApiService.updateWorkerProfile(
        widget.workerId,
        profileImageUrl: newImageUrl,
      );

      // Add a cache-busting query parameter to force a reload of the image.
      final cacheBustedUrl =
          '$newImageUrl?v=${DateTime.now().millisecondsSinceEpoch}';
      setState(() {
        _workerData['profile_image_url'] = newImageUrl; // Store the clean URL
        _profileImageUrl =
            cacheBustedUrl; // Use the cache-busted one for display
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile picture updated')));
    } on Exception catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error uploading picture: $e')));
    }
  }
}

Route createInstantRoute(Widget page) {
  return PageRouteBuilder(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        child,
  );
}

Future<void> logout(BuildContext context) async {
  // Corrected `Future` type usage
  try {
    await FirebaseAuth.instance.signOut();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('lastRole');
    await prefs.remove('lastUid');

    if (!context.mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
  } catch (e) {
    debugPrint('Logout error: $e');
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Error logging out: $e')));
  }
}

class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Column(
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(color: Color(0xFF03A9F4)),
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset(
                  'assets/logo.png',
                  height: 80,
                  width: 80,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
          _drawerItem(
            context,
            Icons.home,
            'Dashboard',
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const AdminDashboard()),
            ),
          ),
          _drawerItem(
            context,
            Icons.map,
            'Live Map',
            onSelect: () =>
                Navigator.push(context, createInstantRoute(const MapScreen())),
          ),
          _drawerItem(
            context,
            Icons.delete_outline,
            'Bins / Zones',
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const BinsZonesScreen()),
            ),
          ),
          _drawerItem(
            context,
            Icons.insights,
            'Analytics',
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const AnalyticsScreen(drawer: AppDrawer())),
            ),
          ),
          _drawerItem(
            context,
            Icons.task,
            'Worker Tasks',
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const AllTasksScreen()),
            ),
          ),
          _drawerItem(
            context,
            Icons.warning,
            'Alerts',
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const AlertsScreen()),
            ),
          ),
          _drawerItem(
            context,
            Icons.notifications_outlined,
            'Notifications',
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const AdminNotificationsScreen()),
            ),
          ),
          _drawerItem(
            context,
            Icons.assignment,
            'Issue Reports',
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const ReportsScreen()),
            ),
          ),
          _drawerItem(
            context,
            Icons.people,
            'Manage Workers',
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const ManageWorkersScreen()),
            ),
          ),
          _drawerItem(
            context,
            Icons.devices,
            'Manage Devices',
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const ManageDevicesScreen()),
            ),
          ),
          const Divider(),
          _drawerItem(
            context,
            Icons.settings,
            'Settings',
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const SettingsScreen()),
            ),
          ),
          _drawerItem(
            context,
            Icons.person,
            'Profile',
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const ProfilePage()),
            ),
          ),
          const Spacer(),
          _drawerItem(
            context,
            Icons.logout,
            'Logout',
            onSelect: () => logout(context),
          ),
        ],
      ),
    );
  }

  Widget _drawerItem(
    BuildContext context,
    IconData icon,
    String title, {
    required VoidCallback onSelect,
  }) {
    return ListTile(
      leading: Icon(icon, color: Colors.black),
      title: Text(title, style: GoogleFonts.titilliumWeb(fontSize: 18)),
      onTap: () {
        Navigator.pop(context);
        onSelect();
      },
    );
  }
}
