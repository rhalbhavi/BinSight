import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:binsight/widgets/web_camera_capture_stub.dart'
    if (dart.library.html) 'package:binsight/widgets/web_camera_capture_web.dart'
    as web_camera;
import 'package:binsight/utils/device_labels.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart'; // For displaying images from URL
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:binsight/services/api_service.dart';
import 'package:binsight/screens/analytics_screen.dart';
import 'package:binsight/utils/ist_time.dart';
import 'package:binsight/widgets/live_map_section.dart';
import 'package:binsight/widgets/registered_bins_zones_section.dart';

// --- Main App Entry ---
class WorkerScreen extends StatelessWidget {
  // This is the root, no changes needed here.
  const WorkerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const WorkerDashboard();
  }
}

// --- AppBar (Shared) ---
AppBar sharedAppBar(
  BuildContext context, {
  String? title,
  List<Widget>? actions,
}) {
  return AppBar(
    backgroundColor: const Color(0xFF03A9F4),
    elevation: 0,
    automaticallyImplyLeading: false,
    actions: actions, // Removes back arrow at top
    leading: Builder(
      builder: (context) => IconButton(
        icon: const Icon(Icons.menu, color: Colors.white),
        onPressed: () => Scaffold.of(context).openDrawer(),
      ),
    ),
    title: Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.asset(
            'assets/logo.png', // Corrected asset path
            height: 32,
            width: 32,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          'BinSight',
          style: GoogleFonts.rubikMonoOne(color: Colors.white, fontSize: 18),
        ),
      ],
    ),
  );
}

int _fillPercent(dynamic rawValue) {
  final value = rawValue is num
      ? rawValue.toDouble()
      : double.tryParse(rawValue?.toString() ?? '');
  if (value == null || !value.isFinite) return 0;
  return value.round().clamp(0, 100).toInt();
}

// Helper for screen headings
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

Widget screenHeading(
  String text, {
  Color? color,
  double fontSize = 18,
  IconData? icon,
  bool showDivider = true,
}) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (icon == null)
        Text(
          text,
          style: GoogleFonts.rubikMonoOne(fontSize: fontSize, color: color),
        )
      else
        Row(
          children: [
            Icon(icon, size: 21, color: color ?? const Color(0xFF263238)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: GoogleFonts.rubikMonoOne(
                  fontSize: fontSize,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      const SizedBox(height: 6),
      if (showDivider) const Divider(height: 1, thickness: 1),
    ],
  );
}

class WorkerNotificationOverlay extends StatefulWidget {
  const WorkerNotificationOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<WorkerNotificationOverlay> createState() =>
      _WorkerNotificationOverlayState();
}

class _WorkerNotificationOverlayState extends State<WorkerNotificationOverlay> {
  StreamSubscription<User?>? _authSubscription;
  Timer? _pollTimer;
  Timer? _hideTimer;
  String? _accountId;
  String? _role;
  String? _bannerMessage;
  String? _bannerNotificationId;
  final Map<String, String> _deviceNames = <String, String>{};
  bool _deviceNamesLoaded = false;

  @override
  void initState() {
    super.initState();
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen(
      _handleAuthChange,
    );
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _pollTimer?.cancel();
    _hideTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleAuthChange(User? user) async {
    _pollTimer?.cancel();
    _accountId = null;
    _role = null;
    if (user == null) return;

    try {
      final role = await ApiService.fetchUserRole(user.uid, email: user.email);
      if (!mounted || (role != 'worker' && role != 'admin')) return;
      _role = role;
      _accountId = user.uid;
      await _pollNotifications();
      _pollTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _pollNotifications(),
      );
    } catch (_) {}
  }

  Future<void> _pollNotifications() async {
    final accountId = _accountId;
    final role = _role;
    if (accountId == null || role == null) return;
    try {
      final notifications = role == 'admin'
          ? await ApiService.fetchAdminNotifications(accountId)
          : await ApiService.fetchWorkerNotifications(accountId);
      final bannerId = _bannerNotificationId;
      if (bannerId != null &&
          !notifications.any(
            (item) => item['notification_id']?.toString() == bannerId,
          )) {
        _hideTimer?.cancel();
        if (mounted)
          setState(() {
            _bannerMessage = null;
            _bannerNotificationId = null;
          });
      }
      // Do not replace an active banner or consume a transient event until
      // the current banner has had its full display time.
      if (_bannerMessage != null) return;
      if (!_deviceNamesLoaded) {
        try {
          final devices = await ApiService.fetchDevices();
          for (final device in devices) {
            final id = (device['bin_id'] ?? device['zone_id'] ?? device['id'])
                ?.toString();
            if (id != null && id.isNotEmpty) {
              _deviceNames[id] = device['type'] == 'zone'
                  ? buildZoneDisplayName(device)
                  : buildBinDisplayName(device);
            }
          }
          _deviceNamesLoaded = true;
        } catch (_) {}
      }
      if (role == 'admin') {
        try {
          final events = await ApiService.fetchAdminConnectivityEvents(
            accountId,
          );
          if (events.isNotEmpty && mounted) {
            _hideTimer?.cancel();
            setState(() {
              _bannerNotificationId = null;
              _bannerMessage = (events.first['message'] ?? '').toString();
            });
            _hideTimer = Timer(const Duration(seconds: 5), () {
              if (mounted) {
                setState(() {
                  _bannerMessage = null;
                  _bannerNotificationId = null;
                });
              }
            });
            return;
          }
        } catch (_) {}
      }
      final preferences = await SharedPreferences.getInstance();
      final key = 'seen_${role}_notifications_$accountId';
      final seen = (preferences.getStringList(key) ?? const <String>[]).toSet();
      Map<String, dynamic>? newestUnseen;
      for (final notification in notifications) {
        final id = notification['notification_id']?.toString() ?? '';
        if (id.isEmpty || seen.contains(id)) continue;
        try {
          final shouldShow = await ApiService.claimNotificationBanner(id);
          seen.add(id);
          if (shouldShow) {
            newestUnseen = notification;
            break;
          }
        } catch (_) {
          break;
        }
      }
      if (seen.length > 500) {
        seen.removeAll(seen.take(seen.length - 500).toList());
      }
      await preferences.setStringList(key, seen.toList());
      if (!mounted || newestUnseen == null) return;
      _hideTimer?.cancel();
      setState(() {
        _bannerNotificationId = newestUnseen!['notification_id']?.toString();
        final message =
            (newestUnseen!['message'] ??
                    "Your report '${newestUnseen['report_name'] ?? 'Issue Report'}' has been resolved by the admin.")
                .toString();
        _bannerMessage = addDeviceNameToMessage(
          message,
          newestUnseen!['device_id'] ??
              newestUnseen['bin_id'] ??
              newestUnseen['zone_id'],
          _deviceNames,
        );
      });
      _hideTimer = Timer(const Duration(seconds: 5), () {
        if (mounted)
          setState(() {
            _bannerMessage = null;
            _bannerNotificationId = null;
          });
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_bannerMessage != null)
          Positioned(
            top: 0,
            left: 12,
            right: 12,
            child: SafeArea(
              child: IgnorePointer(
                child: Material(
                  elevation: 8,
                  color: const Color(0xFFF3F3F3),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.report_outlined,
                          color: Color(0xFF424242),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _bannerMessage!,
                            style: GoogleFonts.titilliumWeb(
                              color: Color(0xFF303030),
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// --- Main Dashboard ---
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

class WorkerDashboard extends StatefulWidget {
  const WorkerDashboard({super.key});

  @override
  State<WorkerDashboard> createState() => _WorkerDashboardState();
}

class _WorkerDashboardState extends State<WorkerDashboard> {
  List<Map<String, dynamic>> _devices = [];
  List<Map<String, dynamic>> _workers = [];
  Map<String, dynamic> _workerProfile = {};
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
      final user = FirebaseAuth.instance.currentUser;
      final results = await Future.wait<dynamic>([
        ApiService.fetchDevices(),
        user == null
            ? Future.value(<String, dynamic>{})
            : ApiService.fetchWorkerProfile(user.uid),
        ApiService.fetchWorkers(),
      ]);
      if (mounted) {
        final devices = results[0] as List<Map<String, dynamic>>;
        setState(() {
          _devices = devices;
          _workerProfile = results[1] as Map<String, dynamic>;
          _workers = results[2] as List<Map<String, dynamic>>;
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

  List<String> get _assignedBinIds =>
      List<String>.from(_workerProfile['assigned_bins'] ?? const []);
  List<String> get _assignedZoneIds =>
      List<String>.from(_workerProfile['assigned_zones'] ?? const []);

  Set<String> get _allWorkerAssignedBinIds => {
    for (final worker in _workers)
      for (final id in List<String>.from(worker['assigned_bins'] ?? const []))
        id,
  };

  Set<String> get _allWorkerAssignedZoneIds => {
    for (final worker in _workers)
      for (final id in List<String>.from(worker['assigned_zones'] ?? const []))
        id,
  };

  List<Map<String, dynamic>> get _assignedBinDevices =>
      _devices.where((device) {
        final id = (device['bin_id'] ?? device['id']).toString();
        return device['type'] == 'bin' && _assignedBinIds.contains(id);
      }).toList();

  List<Map<String, dynamic>> get _allAssignedBinDevices {
    final assigned = <String, Map<String, dynamic>>{};
    for (final bin in [
      ..._assignedBinDevices,
      ..._assignedZoneGroups.expand((group) => group.bins),
    ]) {
      final id = (bin['bin_id'] ?? bin['id']).toString();
      assigned.putIfAbsent(id, () => bin);
    }
    return assigned.values.toList();
  }

  List<Map<String, dynamic>> get _criticalAssignedBinDevices =>
      _allAssignedBinDevices
          .where((bin) => bin['status']?.toString().toLowerCase() == 'critical')
          .toList();

  String _pickerLocationForZone(String zoneId) {
    for (final device in _devices) {
      if (device['type'] != 'zone') continue;
      if ((device['zone_id'] ?? device['id']).toString() == zoneId) {
        return (device['location_description'] ?? '').toString().trim();
      }
    }
    return '';
  }

  List<_ZoneGroup> get _assignedZoneGroups {
    final groups = <String, _ZoneGroup>{};
    for (final bin in _devices.where(
      (device) =>
          device['type'] == 'bin' &&
          _assignedZoneIds.contains((device['zone_id'] ?? '').toString()),
    )) {
      final zoneKey = (bin['zone_id'] ?? '').toString();
      final group = groups.putIfAbsent(
        zoneKey,
        () => _ZoneGroup(
          name: (bin['zone_name'] ?? zoneKey).toString(),
          zoneKey: zoneKey,
          location: _pickerLocationForZone(zoneKey),
        ),
      );
      group.bins.add(bin);
    }
    return groups.values.toList();
  }

  Widget _buildMyTasks() {
    final assignedZoneIds = _assignedZoneIds.toSet();
    return RegisteredBinsZonesSection(
      bins: _assignedBinDevices,
      zones: _devices.where((device) {
        if (device['type'] != 'zone') return false;
        final id = (device['zone_id'] ?? device['id'] ?? '').toString();
        return assignedZoneIds.contains(id);
      }).toList(),
      binTitle: 'ASSIGNED BINS',
      zoneTitle: 'ASSIGNED ZONES',
      binBuilder: (device) {
        final fill = _fillPercent(device['fill_level']);
        final aqi = int.tryParse('${device['gas_level'] ?? 0}') ?? 0;
        final fillState = _fillStatus(fill);
        return StatusCard(
          title: buildBinDisplayName(device),
          isOnline: device['is_online'] != false,
          subtitle: '',
          fillLevel: fill,
          aqi: aqi,
          status: (device['status'] ?? 'normal').toString().titleCaseStatus,
          statusColor: _getStatusColor(
            (device['status'] ?? fillState).toString(),
          ),
          fillStatus: fillState,
          gasStatus: _gasStatus(aqi),
          fireDetected: device['flame'] == true,
          nextOverflowTime: device['next_overflow_time']?.toString(),
          gasSpike: device['gas_spike'] == true,
          predictedFireRisk: device['fire_risk'] == true,
          backgroundColor: Colors.white,
          fillLabel: 'Fill',
          gasLabel: 'Air',
          onTap: () => _openBinOnMap(device),
        );
      },
      zoneBuilder: (zone) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openZoneOnMap(zone),
        child: _workerRegisteredZoneCard(zone),
      ),
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

  List<_ZoneGroup> _zoneGroups() {
    final groups = <String, _ZoneGroup>{};
    final assignedBinIds = _allWorkerAssignedBinIds;
    final bins = _devices.where((device) {
      if (device['type'] != 'bin') return false;
      final binId = (device['bin_id'] ?? device['id']).toString();
      return !assignedBinIds.contains(binId);
    }).toList();

    for (final bin in bins) {
      final zoneKey = (bin['zone_id'] ?? bin['zone_name'] ?? 'unassigned')
          .toString();
      final zoneName = (bin['zone_name'] ?? 'Unassigned').toString();
      final group = groups.putIfAbsent(
        zoneKey,
        () => _ZoneGroup(
          name: zoneName,
          zoneKey: zoneKey,
          location: _pickerLocationForZone(zoneKey),
        ),
      );
      group.bins.add(bin);
    }

    final ordered = groups.values
        .where((group) => group.bins.isNotEmpty)
        .toList();
    ordered.sort((a, b) {
      if (_sortMode == 'critical') {
        final diff = b.criticalCount.compareTo(a.criticalCount);
        if (diff != 0) return diff;
      }
      final aDistance = a.bins.fold<double>(
        double.infinity,
        (minDistance, bin) => _distanceToBin(bin) < minDistance
            ? _distanceToBin(bin)
            : minDistance,
      );
      final bDistance = b.bins.fold<double>(
        double.infinity,
        (minDistance, bin) => _distanceToBin(bin) < minDistance
            ? _distanceToBin(bin)
            : minDistance,
      );
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
        final diff = aDistance.compareTo(bDistance);
        if (diff != 0) return diff;
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
    final zoneGroups = _zoneGroups();
    final nearbyBins = zoneGroups.expand((group) => group.bins).toList();
    final assignedZoneIds = _allWorkerAssignedZoneIds;
    final nearbyZones = _devices
        .where(
          (device) =>
              device['type'] == 'zone' &&
              !assignedZoneIds.contains(
                (device['zone_id'] ?? device['id']).toString(),
              ),
        )
        .toList();
    final criticalDevices = _devices
        .where(
          (d) => d['type'] == 'bin' && d['status']?.toLowerCase() == 'critical',
        )
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        screenHeading('DASHBOARD', icon: Icons.home),
        const SizedBox(height: 16),
        LiveMapSection(
          height: 280,
          // LiveMapSection centers on current GPS unless a dashboard card
          // has explicitly focused a bin or zone.
          focusLocation: _focusedBinLocation,
          focusRequest: _mapFocusRequest,
        ),
        const SizedBox(height: 24),
        if (criticalDevices.isNotEmpty) ...[
          screenHeading('ALERTS', color: Colors.red[900]),
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
        const SizedBox(height: 24),
        screenHeading('MY TASKS'),
        const SizedBox(height: 12),
        _buildMyTasks(),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(child: screenHeading('NEARBY BINS & ZONES')),
            PopupMenuButton<String>(
              icon: const Icon(Icons.filter_list, color: Colors.black87),
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
          bins: nearbyBins,
          zones: nearbyZones,
          binBuilder: (device) {
            final fill = _fillPercent(device['fill_level']);
            final aqi = int.tryParse('${device['gas_level'] ?? 0}') ?? 0;
            final fillState = _fillStatus(fill);
            final gasState = _gasStatus(aqi);
            final status = (device['status'] ?? 'normal').toString();
            final critical = status.toLowerCase() == 'critical';
            return StatusCard(
              title: buildBinDisplayName(device),
              isOnline: device['is_online'] != false,
              subtitle: '',
              fillLevel: fill,
              aqi: aqi,
              status: status.titleCaseStatus,
              statusColor: critical ? Colors.red : _getStatusColor(fillState),
              fillStatus: fillState,
              gasStatus: gasState,
              fireDetected: device['flame'] == true,
              nextOverflowTime: device['next_overflow_time']?.toString(),
              gasSpike: device['gas_spike'] == true,
              predictedFireRisk: device['fire_risk'] == true,
              backgroundColor: critical
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
            child: _workerRegisteredZoneCard(zone),
          ),
        ),
        screenHeading('REPORT ISSUE'),
        const SizedBox(height: 12),
        const ReportIssueCard(),
        const SizedBox(height: 40),
      ],
    );
  }
}

Widget _workerRegisteredZoneCard(
  Map<String, dynamic> zone, {
  bool hidePickerLocation = false,
}) {
  final status = (zone['status'] ?? 'normal').toString();
  final fill = _fillPercent(zone['fill_level']);
  final gas = int.tryParse('${zone['gas_level'] ?? 0}') ?? 0;
  final location = (zone['location_description'] ?? '').toString().trim();
  final count = int.tryParse('${zone['bin_count'] ?? 0}') ?? 0;
  return Card(
    margin: const EdgeInsets.only(bottom: 10),
    color: status.toLowerCase() == 'critical'
        ? const Color(0xFFFFEBEE)
        : Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(
        color: status.toLowerCase() == 'critical'
            ? Colors.red.shade200
            : Colors.black12,
      ),
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
                  buildZoneNameWithoutPicker(zone),
                  style: GoogleFonts.titilliumWeb(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                status.titleCaseStatus,
                style: GoogleFonts.titilliumWeb(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: _registeredStatusColor(status),
                ),
              ),
            ],
          ),
          if (location.isNotEmpty && !hidePickerLocation)
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

// --- Screens ---

// Map Screen
class MapScreen extends StatelessWidget {
  const MapScreen({super.key, this.selectedLocation, this.selectedTitle});

  final LatLng? selectedLocation;
  final String? selectedTitle;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: sharedAppBar(context, title: 'LIVE MAP'),
    drawer: const AppDrawer(),
    body: Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          screenHeading('LIVE MAP', icon: Icons.map),
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
            child: LiveMapSection(
              height: null,
              focusLocation: selectedLocation,
            ),
          ),
        ],
      ),
    ),
  );
}

// Tasks Screen
class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  List<Map<String, dynamic>> _devices = [];
  Map<String, dynamic> _profile = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTasks();
  }

  Future<void> _loadTasks() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      final results = await Future.wait<dynamic>([
        ApiService.fetchDevices(),
        user == null
            ? Future.value(<String, dynamic>{})
            : ApiService.fetchWorkerProfile(user.uid),
      ]);
      if (!mounted) return;
      setState(() {
        _devices = results[0] as List<Map<String, dynamic>>;
        _profile = results[1] as Map<String, dynamic>;
        _loading = false;
      });
    } catch (error) {
      if (mounted)
        setState(() {
          _error = error.toString();
          _loading = false;
        });
    }
  }

  Future<void> _updateTaskStatus(String taskId, String status) async {
    try {
      await ApiService.updateTaskStatus(taskId: taskId, status: status);
      await _loadTasks();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update task: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final binIds = List<String>.from(_profile['assigned_bins'] ?? const []);
    final zoneIds = List<String>.from(_profile['assigned_zones'] ?? const []);
    final assignedBins = _devices
        .where(
          (device) =>
              device['type'] == 'bin' &&
              binIds.contains((device['bin_id'] ?? device['id']).toString()),
        )
        .toList();
    final assignedZones = _devices.where((device) {
      if (device['type'] != 'zone') return false;
      final id = (device['zone_id'] ?? device['id'] ?? '').toString();
      return zoneIds.contains(id);
    }).toList();

    Widget binCard(Map<String, dynamic> device) {
      final fill = _fillPercent(device['fill_level']);
      final aqi = int.tryParse('${device['gas_level'] ?? 0}') ?? 0;
      final status = (device['status'] ?? 'normal').toString().titleCaseStatus;
      final color = status.toLowerCase() == 'critical'
          ? Colors.red
          : status.toLowerCase() == 'moderate'
          ? Colors.orange
          : Colors.green;
      return StatusCard(
        title: buildBinDisplayName(device),
        isOnline: device['is_online'] != false,
        subtitle: '',
        fillLevel: fill,
        aqi: aqi,
        status: status,
        statusColor: color,
        fillStatus: status,
        gasStatus: aqi > 700
            ? 'Severe / Hazardous'
            : aqi > 600
            ? 'Very Poor'
            : aqi > 500
            ? 'Poor'
            : aqi > 400
            ? 'Moderate'
            : 'Normal',
        fireDetected: device['flame'] == true,
        nextOverflowTime: device['next_overflow_time']?.toString(),
        gasSpike: device['gas_spike'] == true,
        predictedFireRisk: device['fire_risk'] == true,
        backgroundColor: Colors.white,
        fillLabel: 'Fill',
        gasLabel: 'Air',
      );
    }

    return Scaffold(
      appBar: sharedAppBar(context, title: 'MY TASKS'),
      drawer: const AppDrawer(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text('Could not load tasks: $_error'))
          : RefreshIndicator(
              onRefresh: _loadTasks,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  screenHeading('MY TASKS', icon: Icons.task),
                  const SizedBox(height: 16),
                  ...((_profile['tasks'] as List<dynamic>? ?? const [])
                      .whereType<Map>()
                      .map((rawTask) {
                        final task = Map<String, dynamic>.from(rawTask);
                        final taskId = (task['task_id'] ?? '').toString();
                        final status = (task['status'] ?? 'pending').toString();
                        final description =
                            (task['description'] ?? 'Assigned task').toString();
                        final nextStatus = status.toLowerCase() == 'pending'
                            ? 'acknowledged'
                            : status.toLowerCase() == 'acknowledged'
                            ? 'completed'
                            : null;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: ListTile(
                            leading: const Icon(Icons.assignment_outlined),
                            title: Text(description),
                            subtitle: Text('Status: ${status.titleCaseStatus}'),
                            trailing: nextStatus == null
                                ? const Icon(
                                    Icons.check_circle_outline,
                                    color: Colors.green,
                                  )
                                : TextButton(
                                    onPressed: taskId.isEmpty
                                        ? null
                                        : () => _updateTaskStatus(
                                            taskId,
                                            nextStatus,
                                          ),
                                    child: Text(
                                      nextStatus == 'acknowledged'
                                          ? 'Acknowledge'
                                          : 'Complete',
                                    ),
                                  ),
                          ),
                        );
                      })),
                  if (assignedBins.isEmpty && assignedZones.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('No assigned bins or zones.'),
                    )
                  else ...[
                    const SizedBox(height: 16),
                    RegisteredBinsZonesSection(
                      bins: assignedBins,
                      zones: assignedZones,
                      binTitle: 'ASSIGNED BINS',
                      zoneTitle: 'ASSIGNED ZONES',
                      binBuilder: binCard,
                      zoneBuilder: (zone) => _workerRegisteredZoneCard(
                        zone,
                        hidePickerLocation: true,
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

class WorkerBinsZonesScreen extends StatefulWidget {
  const WorkerBinsZonesScreen({super.key});

  @override
  State<WorkerBinsZonesScreen> createState() => _WorkerBinsZonesScreenState();
}

class _WorkerBinsZonesScreenState extends State<WorkerBinsZonesScreen> {
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

  Widget _binCard(Map<String, dynamic> device) {
    final fill = _fillPercent(device['fill_level']);
    final aqi = int.tryParse('${device['gas_level'] ?? 0}') ?? 0;
    final status = (device['status'] ?? 'normal').toString();
    final critical = status.toLowerCase() == 'critical';
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
      status: status.titleCaseStatus,
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
          screenHeading('BINS & ZONES', icon: Icons.delete_outline),
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
              binBuilder: _binCard,
              zoneBuilder: _workerRegisteredZoneCard,
            ),
        ],
      ),
    );
  }
}

// Alerts Screen
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _WorkerAlertsScreenState();
}

class _WorkerAlertsScreenState extends State<AlertsScreen> {
  Timer? _refreshTimer;
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

  List<Map<String, dynamic>> _criticalBins = [];
  bool _loading = true;
  String? _error;

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
    try {
      final results = await Future.wait<dynamic>([
        ApiService.fetchDevices(),
        ApiService.fetchAlerts(),
      ]);
      final devices = results[0] as List<Map<String, dynamic>>;
      final alerts = results[1] as List<Map<String, dynamic>>;
      final activeBinIds = alerts
          .map((alert) => alert['device_id'].toString())
          .toSet();
      if (!mounted) return;
      setState(() {
        _criticalBins = devices
            .where(
              (device) =>
                  device['type'] == 'bin' &&
                  device['status']?.toString().toLowerCase() == 'critical' &&
                  activeBinIds.contains(
                    (device['bin_id'] ?? device['id']).toString(),
                  ),
            )
            .toList();
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
  Widget build(BuildContext context) => Scaffold(
    appBar: sharedAppBar(context, title: 'ALERTS'),
    drawer: const AppDrawer(),
    body: RefreshIndicator(
      onRefresh: _loadAlerts,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          screenHeading('ALERTS', color: Colors.red, icon: Icons.warning),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_error != null)
            Text('Could not load alerts: $_error')
          else if (_criticalBins.isEmpty)
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
        ],
      ),
    ),
  );
}

// Report Issue Screen
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
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
      final notifications = await ApiService.fetchWorkerNotifications(user.uid);
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
        _error = error.toString();
        _isLoading = false;
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
    if (type.contains('alert') || type.contains('critical') || type.contains('escalation')) {
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
                  screenHeading(
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
                    final remarks = (notification['remarks'] ?? '')
                        .toString()
                        .trim();
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
                            fontWeight: FontWeight.bold,
                            fontSize: 20,
                          ),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_timestamp(
                              notification['created_at'],
                            ).isNotEmpty)
                              Text(
                                _timestamp(notification['created_at']),
                                style: GoogleFonts.titilliumWeb(fontSize: 18),
                              ),
                            if (remarks.isNotEmpty)
                              Text(
                                'Admin remarks: $remarks',
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

class ReportIssueScreen extends StatefulWidget {
  const ReportIssueScreen({super.key});

  @override
  State<ReportIssueScreen> createState() => _ReportIssueScreenState();
}

class _ReportIssueScreenState extends State<ReportIssueScreen> {
  static const int _maxPhotos = 6;
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final List<Uint8List> _photos = [];
  final List<String> _photoExtensions = [];
  late Future<List<Map<String, dynamic>>> _devicesFuture;
  String? _relatedDeviceKey;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _devicesFuture = ApiService.fetchDevices();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _takePhoto() async {
    if (_photos.length >= _maxPhotos) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You can attach up to 6 photos.')),
      );
      return;
    }
    try {
      Uint8List? bytes;
      if (kIsWeb) {
        bytes = await web_camera.captureWebCamera(context);
      } else {
        final photo = await _picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 80,
          maxWidth: 1800,
        );
        if (photo == null) return;
        bytes = await photo.readAsBytes();
      }
      if (bytes == null) return;
      final capturedBytes = bytes;
      if (!mounted) return;
      setState(() {
        _photos.add(capturedBytes);
        _photoExtensions.add('jpg');
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open camera: $error')));
    }
  }

  Future<void> _uploadPhotos() async {
    final availableSlots = _maxPhotos - _photos.length;
    if (availableSlots <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You can attach up to 6 photos.')),
      );
      return;
    }

    try {
      final files = await _picker.pickMultiImage(
        imageQuality: 80,
        maxWidth: 1800,
      );
      if (files.isEmpty) return;
      const allowedExtensions = {'jpg', 'jpeg', 'png', 'webp'};
      final validFiles = files.where((file) {
        final extension = file.name.split('.').last.toLowerCase();
        return allowedExtensions.contains(extension);
      }).toList();
      if (validFiles.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Upload JPG, JPEG, PNG, or WEBP photos only.'),
          ),
        );
        return;
      }

      final selected = validFiles.take(availableSlots);
      final chosenFiles = selected.toList();
      final bytes = await Future.wait(
        chosenFiles.map((file) => file.readAsBytes()),
      );
      final extensions = chosenFiles
          .map((file) => file.name.split('.').last.toLowerCase())
          .toList();
      if (!mounted) return;
      setState(() {
        _photos.addAll(bytes);
        _photoExtensions.addAll(extensions);
      });
      if (validFiles.length > availableSlots) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Only 6 photos can be attached.')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not upload photos: $error')),
      );
    }
  }

  Future<void> _submitReport() async {
    final name = _nameController.text.trim();
    final description = _descriptionController.text.trim();
    if (name.isEmpty || description.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter an issue name and description.')),
      );
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _isSubmitting = true);
    try {
      await ApiService.submitReport(
        name: name,
        description: description,
        reporterId: user.uid,
        photos: List<Uint8List>.from(_photos),
        photoExtensions: List<String>.from(_photoExtensions),
        relatedDeviceId: _relatedDeviceKey?.split('|').last,
        relatedDeviceType: _relatedDeviceKey?.split('|').first,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Issue report submitted.')));
      Navigator.maybePop(context);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to submit report: $error')),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Widget _reportFieldLabel(String label) => Text(
    label,
    style: GoogleFonts.titilliumWeb(fontSize: 18, fontWeight: FontWeight.bold),
  );

  InputDecoration _fieldDecoration() => InputDecoration(
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: sharedAppBar(context, title: 'REPORT ISSUE'),
      drawer: const AppDrawer(),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            screenHeading('REPORT ISSUE', icon: Icons.report_problem_outlined),
            const SizedBox(height: 20),
            _reportFieldLabel('Issue Name'),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              textCapitalization: TextCapitalization.sentences,
              decoration: _fieldDecoration(),
            ),
            const SizedBox(height: 16),
            _reportFieldLabel('Select Related Bin/Zone'),
            const SizedBox(height: 8),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _devicesFuture,
              builder: (context, snapshot) {
                final devices = snapshot.data ?? const <Map<String, dynamic>>[];
                final bins = devices.where((device) => device['type'] == 'bin');
                final zones = devices.where(
                  (device) => device['type'] == 'zone',
                );
                final zoneNames = <String, String>{
                  for (final zone in zones)
                    (zone['zone_id'] ?? zone['id']).toString():
                        buildZoneDisplayName(zone),
                };
                return DropdownButtonFormField<String?>(
                  initialValue: _relatedDeviceKey,
                  isExpanded: true,
                  decoration: _fieldDecoration(),
                  hint: Text(
                    snapshot.hasError
                        ? 'Could not load bins and zones'
                        : 'Choose a bin or zone (optional)',
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('None selected'),
                    ),
                    ...bins.map((bin) {
                      final id = (bin['bin_id'] ?? bin['id']).toString();
                      final zoneId = (bin['zone_id'] ?? '').toString();
                      final zoneName = zoneNames[zoneId] ?? '';
                      final name = buildBinDisplayName(bin);
                      return DropdownMenuItem<String?>(
                        value: 'bin|$id',
                        child: Text(
                          zoneName.isEmpty ? name : '$name • $zoneName',
                        ),
                      );
                    }),
                    ...zones.map((zone) {
                      final id = (zone['zone_id'] ?? zone['id']).toString();
                      return DropdownMenuItem<String?>(
                        value: 'zone|$id',
                        child: Text(buildZoneDisplayName(zone)),
                      );
                    }),
                  ],
                  onChanged: snapshot.hasError
                      ? null
                      : (value) => setState(() => _relatedDeviceKey = value),
                );
              },
            ),
            const SizedBox(height: 16),
            _reportFieldLabel('Enter Description'),
            const SizedBox(height: 8),
            TextField(
              controller: _descriptionController,
              minLines: 4,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
              decoration: _fieldDecoration(),
            ),
            const SizedBox(height: 20),
            _reportFieldLabel('Attach Photos'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _takePhoto,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('TAKE PHOTO'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _uploadPhotos,
                    icon: const Icon(Icons.upload_file_outlined),
                    label: const Text('UPLOAD'),
                  ),
                ),
              ],
            ),
            if (_photos.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: List.generate(_photos.length, (index) {
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.memory(
                          _photos[index],
                          width: 112,
                          height: 112,
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        top: -6,
                        left: -6,
                        child: Material(
                          color: Colors.white,
                          shape: const CircleBorder(),
                          elevation: 3,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => setState(() {
                              _photos.removeAt(index);
                              _photoExtensions.removeAt(index);
                            }),
                            child: const Padding(
                              padding: EdgeInsets.all(3),
                              child: Icon(
                                Icons.cancel,
                                color: Colors.red,
                                size: 24,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                }),
              ),
            ],
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSubmitting ? null : _submitReport,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                  backgroundColor: const Color(0xFF03A9F4),
                  foregroundColor: Colors.white,
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        'SUBMIT REPORT',
                        style: GoogleFonts.titilliumWeb(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
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
  Map<String, dynamic>? _workerData;
  Map<String, dynamic>? _contactAdminData;
  String? _profileImageUrl;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchWorkerData();
    _fetchContactAdminData();
  }

  Future<void> _fetchWorkerData() async {
    setState(() => _isLoading = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final data = await ApiService.fetchWorkerProfile(user.uid);
        setState(() {
          _workerData = data;
          _profileImageUrl = data['profile_image_url'];
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading worker profile: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchContactAdminData() async {
    try {
      // This assumes a new method in ApiService that hits the new /contact-admin endpoint
      final data = await ApiService.fetchContactAdmin();
      if (mounted) {
        setState(() {
          _contactAdminData = data;
        });
      }
    } catch (e) {
      debugPrint('Failed to load contact admin info: $e');
    }
  }

  Widget _infoRow(String label, Widget valueWidget) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
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

  Widget _contactInfoRow(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: Colors.grey[700]),
        const SizedBox(width: 12),
        Flexible(
          child: Text(text, style: GoogleFonts.titilliumWeb(fontSize: 18)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: sharedAppBar(
        context,
        title: 'PROFILE',
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
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  screenHeading('PROFILE', icon: Icons.person),
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
                            Text(
                              _workerData?['name'] ?? 'Not set',
                              style: GoogleFonts.titilliumWeb(fontSize: 18),
                            ),
                          ),
                          _infoRow(
                            'Email',
                            Text(
                              _workerData?['email'] ?? 'Not set',
                              style: GoogleFonts.titilliumWeb(fontSize: 18),
                            ),
                          ),
                          _infoRow(
                            'Phone',
                            Text(
                              _workerData?['phone'] ?? 'Not set',
                              style: GoogleFonts.titilliumWeb(fontSize: 18),
                            ),
                          ),
                          _infoRow(
                            'Date of Birth',
                            Text(
                              _workerData?['date_of_birth'] ?? 'Not set',
                              style: GoogleFonts.titilliumWeb(fontSize: 18),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_contactAdminData != null)
                    Card(
                      elevation: 2,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              'CONTACT ADMIN',
                              style: GoogleFonts.rubikMonoOne(fontSize: 16),
                            ),
                            const Divider(height: 24, thickness: 1),
                            _contactInfoRow(
                              Icons.person_outline,
                              _contactAdminData!['name'] ?? 'Not available',
                            ),
                            const SizedBox(height: 10),
                            _contactInfoRow(
                              Icons.email_outlined,
                              _contactAdminData!['email'] ?? 'Not available',
                            ),
                            const SizedBox(height: 10),
                            InkWell(
                              onTap: () async {
                                final phone =
                                    (_contactAdminData!['phone'] ?? '')
                                        .toString()
                                        .trim();
                                if (phone.isEmpty) return;
                                final uri = Uri(scheme: 'tel', path: phone);
                                if (await canLaunchUrl(uri))
                                  await launchUrl(uri);
                              },
                              child: _contactInfoRow(
                                Icons.phone_outlined,
                                (_contactAdminData!['phone'] ?? 'Not available')
                                    .toString(),
                              ),
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
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const Map<String, bool> _defaults = {
    'task_updates': true,
    'critical_reminders': true,
    'bin_alerts': true,
    'report_updates': true,
  };
  static const Map<String, String> _labels = {
    'task_updates': 'Task assignments and updates',
    'critical_reminders': 'Critical alert reminders',
    'bin_alerts': 'Bin fill alerts',
    'report_updates': 'Issue report updates',
  };
  final Map<String, bool> _preferences = Map<String, bool>.from(_defaults);
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _workerId;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() {
        _loading = false;
        _error = 'Sign in to manage settings.';
      });
      return;
    }
    try {
      final worker = await ApiService.fetchWorkerProfile(user.uid);
      final saved = worker['notification_preferences'];
      if (!mounted) return;
      setState(() {
        _workerId = user.uid;
        if (saved is Map) {
          for (final key in _defaults.keys) {
            _preferences[key] = saved[key] is bool ? saved[key] as bool : true;
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

  void _setPreference(String key, bool value) {
    setState(() => _preferences[key] = value);
  }

  Future<void> _savePreferences() async {
    final workerId = _workerId;
    if (workerId == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ApiService.saveWorkerNotificationPreferences(
        workerId: workerId,
        preferences: Map<String, bool>.from(_preferences),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification settings saved.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save settings: $error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: sharedAppBar(context, title: 'SETTINGS'),
    drawer: const AppDrawer(),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          screenHeading('SETTINGS', icon: Icons.settings, showDivider: false),
          const SizedBox(height: 20),
          Text('NOTIFICATIONS', style: GoogleFonts.rubikMonoOne(fontSize: 16)),
          const SizedBox(height: 8),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else
            Expanded(
              child: ListView(
                children: [
                  for (final entry in _labels.entries)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(entry.value),
                      value: _preferences[entry.key]!,
                      onChanged: _saving
                          ? null
                          : (value) => _setPreference(entry.key, value),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                ],
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Center(
                child: ElevatedButton(
                  onPressed: _saving || _loading ? null : _savePreferences,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

// --- Dashboard Screen Sections --- //

// Map Section
class MapSection extends StatefulWidget {
  final double? height;
  const MapSection({super.key, this.height});

  @override
  State<MapSection> createState() => _MapSectionState();
}

class _MapSectionState extends State<MapSection> {
  bool _isLoading = true;
  String? _error;
  List<Marker> _markers = [];

  // Default to a central local building view matching the old 146% visual zoom
  static const LatLng _defaultCenter = LatLng(12.9716, 77.5946);
  static const double _baseZoom = 13.0;
  static const double _defaultZoomFactor = 1.46;
  static const double _defaultZoomForDisplay = _baseZoom * _defaultZoomFactor;
  final MapController _mapController = MapController();
  LatLng _center = _defaultCenter;
  double _zoom = _defaultZoomForDisplay;

  @override
  void initState() {
    super.initState();
    _fetchLocations();
  }

  Future<void> _fetchLocations() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Fetch app config for initial location
      LatLng? orgCenter;
      try {
        final config = await ApiService.fetchAppConfig();
        final organization = config['organization_location'];
        final nested = organization is Map
            ? organization
            : const <String, dynamic>{};
        final orgLat = _coordinate(
          config['latitude'] ??
              config['location_lat'] ??
              nested['latitude'] ??
              nested['lat'],
        );
        final orgLng = _coordinate(
          config['longitude'] ??
              config['location_lon'] ??
              nested['longitude'] ??
              nested['lng'],
        );

        if (orgLat != null &&
            orgLng != null &&
            orgLat.abs() <= 90 &&
            orgLng.abs() <= 180 &&
            (orgLat != 0.0 || orgLng != 0.0)) {
          orgCenter = LatLng(orgLat, orgLng);
        }
      } catch (e) {
        debugPrint("Could not fetch app config for map center: $e");
      }

      final results = await Future.wait([
        ApiService.fetchWorkers(),
        ApiService.fetchDevices(),
      ]);

      final workers = results[0];
      final devices = results[1];
      if (!mounted) return;
      final Set<Marker> newMarkers = {};
      LatLng? firstValidLocation;

      // Process workers
      for (final worker in workers) {
        final location = worker['current_location'];
        if (location != null &&
            location['lat'] is num &&
            location['lng'] is num) {
          final lat = (location['lat'] as num).toDouble();
          final lng = (location['lng'] as num).toDouble();

          // Skip default/invalid locations (e.g., 0,0)
          if (lat == 0.0 && lng == 0.0) continue;

          final position = LatLng(lat, lng);
          firstValidLocation ??= position;

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
          firstValidLocation ??= position;

          final isBin = device['type'] == 'bin';
          newMarkers.add(
            Marker(
              width: 80.0,
              height: 80.0,
              point: position,
              child: Tooltip(
                message: '${device['name'] ?? 'Device'} (${device['type']})',
                child: Icon(
                  isBin ? Icons.delete_sweep : Icons.business_center,
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
          if (orgCenter != null) {
            _center = orgCenter;
            _zoom = _defaultZoomForDisplay;
          } else if (firstValidLocation != null) {
            _center = firstValidLocation;
            _zoom = _defaultZoomForDisplay;
          }
        });
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

  double? _coordinate(dynamic value) =>
      value is num ? value.toDouble() : double.tryParse('$value');

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
        options: MapOptions(
          initialCenter: _center,
          initialZoom: _zoom,
          minZoom: 4,
          maxZoom: 22,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all,
          ),
          onMapReady: () {
            _zoom = _defaultZoomForDisplay;
            _mapController.move(_center, _defaultZoomForDisplay);
          },
          onMapEvent: (_) {
            if (!mounted) return;
            _zoom = _mapController.camera.zoom;
            setState(() {});
          },
        ),
        mapController: _mapController,
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

    return Container(
      height: widget.height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(16),
        border: _error != null ? Border.all(color: Colors.red[300]!) : null,
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(16), child: content),
    );
  }
}

// Status Card
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

// My Tasks Section
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
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: ListTile(
      title: Text(name),
      subtitle: Text(
        "$priority • $distance",
        style: TextStyle(color: priorityColor),
      ),
    ),
  );
}

class ReportIssueCard extends StatelessWidget {
  const ReportIssueCard({super.key});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      border: Border.all(color: Colors.grey[300]!),
      borderRadius: BorderRadius.circular(12),
    ),
    child: SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => Navigator.push(
          context,
          createInstantRoute(const ReportIssueScreen()),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.red,
          foregroundColor: Colors.white,
        ),
        icon: const Icon(Icons.report_outlined),
        label: const Text('REPORT ISSUE'),
      ),
    ),
  );
}

// --- NAVIGATION HELPER & APP DRAWER (BOTTOM) ---

Route createInstantRoute(Widget page) {
  return PageRouteBuilder(
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        child,
  );
}

// --- Logout Function ---
Future<void> logout(BuildContext context) async {
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
            "Dashboard",
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const WorkerDashboard()),
            ),
          ),
          _drawerItem(
            context,
            Icons.map,
            "Live Map",
            onSelect: () =>
                Navigator.push(context, createInstantRoute(const MapScreen())),
          ),
          _drawerItem(
            context,
            Icons.delete_outline,
            'Bins / Zones',
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const WorkerBinsZonesScreen()),
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
            "My Tasks",
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const TasksScreen()),
            ),
          ),
          _drawerItem(
            context,
            Icons.warning,
            "Alerts",
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const AlertsScreen()),
            ),
          ),
          _drawerItem(
            context,
            Icons.notifications_outlined,
            "Notifications",
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const NotificationsScreen()),
            ),
          ),
          _drawerItem(
            context,
            Icons.report_problem_outlined,
            "Report Issue",
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const ReportIssueScreen()),
            ),
          ),
          const Divider(),
          _drawerItem(
            context,
            Icons.settings,
            "Settings",
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const SettingsScreen()),
            ),
          ),
          _drawerItem(
            context,
            Icons.person,
            "Profile",
            onSelect: () => Navigator.push(
              context,
              createInstantRoute(const ProfilePage()),
            ),
          ),
          const Spacer(),
          _drawerItem(
            context,
            Icons.logout,
            "Logout",
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
        Navigator.pop(context); // Closes the drawer
        onSelect(); // Navigates instantly
      },
    );
  }
}

extension WorkerStatusCapitalization on String {
  String get titleCaseStatus =>
      isEmpty ? this : '${this[0].toUpperCase()}${substring(1)}';
}
