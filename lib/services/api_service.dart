import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

class SetupWorkerPayload {
  final String localId;
  final String workerId;
  final String firstName;
  final String lastName;
  final String dateOfBirth;
  final String name;
  final String phone;
  final String email;
  final String profileImageUrl;
  final Uint8List? photoBytes;

  SetupWorkerPayload({
    required this.localId,
    required this.workerId,
    required this.firstName,
    required this.lastName,
    required this.dateOfBirth,
    required this.name,
    required this.phone,
    required this.email,
    required this.profileImageUrl,
    this.photoBytes,
  });

  Map<String, dynamic> toJson() {
    return {
      'local_id': localId,
      'worker_id': workerId,
      'first_name': firstName,
      'last_name': lastName,
      'date_of_birth': dateOfBirth,
      'name': name,
      'phone': phone,
      'email': email,
      'profile_image_url': profileImageUrl,
    };
  }
}

class ApiService {
  static const String _configuredBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
  );
  static final String _baseUrl = _configuredBaseUrl.isNotEmpty
      ? _configuredBaseUrl
      : kIsWeb || defaultTargetPlatform != TargetPlatform.android
      ? 'http://localhost:5000'
      : 'http://10.0.2.2:5000';

  static Uri _uri(String path, {Map<String, String>? queryParameters}) {
    return Uri.parse('$_baseUrl$path').replace(
      queryParameters: queryParameters == null || queryParameters.isEmpty
          ? null
          : queryParameters,
    );
  }

  static dynamic _decodeBody(http.Response response) {
    if (response.body.isEmpty) {
      return null;
    }
    return json.decode(response.body);
  }

  static String _normalizeUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }

    final repaired = trimmed
        .replaceFirst('http://localhost:50005000', 'http://localhost:5000')
        .replaceFirst('http://127.0.0.1:50005000', 'http://127.0.0.1:5000');

    if (kIsWeb) {
      return repaired;
    }

    return repaired
        .replaceFirst('http://localhost:5000', 'http://10.0.2.2:5000')
        .replaceFirst('http://127.0.0.1:5000', 'http://10.0.2.2:5000');
  }

  static Map<String, dynamic> _normalizeProfileMap(Map<String, dynamic> data) {
    final next = Map<String, dynamic>.from(data);
    final imageUrl = next['profile_image_url'];
    if (imageUrl is String) {
      next['profile_image_url'] = _normalizeUrl(imageUrl);
    }
    final reportImageUrl = next['image_url'];
    if (reportImageUrl is String) {
      next['image_url'] = _normalizeUrl(reportImageUrl);
    }
    final photos = next['photos'];
    if (photos is List) {
      next['photos'] = photos
          .map((photo) => photo is String ? _normalizeUrl(photo) : photo)
          .toList();
    }
    return next;
  }

  static Exception _requestException(String message, http.Response response) {
    final body = _decodeBody(response);
    final errorMessage = body is Map<String, dynamic> && body['error'] != null
        ? body['error'].toString()
        : response.body;
    return Exception(
      '$message (${response.statusCode})${errorMessage.isEmpty ? '' : ': $errorMessage'}',
    );
  }

  static Future<bool> fetchSetupStatus() async {
    final response = await http.get(_uri('/setup/status'));
    if (response.statusCode != 200) {
      throw _requestException('Failed to fetch setup status', response);
    }

    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    return data['is_setup_complete'] == true;
  }

  static Future<String?> fetchUserRole(String uid, {String? email}) async {
    final queryParameters = <String, String>{};
    if (email != null && email.trim().isNotEmpty) {
      queryParameters['email'] = email.trim();
    }

    final response = await http.get(
      _uri('/users/$uid/role', queryParameters: queryParameters),
    );

    if (response.statusCode == 404) {
      return null;
    }

    if (response.statusCode != 200) {
      throw _requestException('Failed to fetch user role', response);
    }

    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    return data['role']?.toString();
  }

  static Future<void> completeSetup({
    required Map<String, dynamic> admin,
    required List<SetupWorkerPayload> workers,
    required List<Map<String, dynamic>> bins,
    required List<Map<String, dynamic>> zones,
    Uint8List? adminPhotoBytes,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/setup/complete'));

    request.fields['payload'] = json.encode({
      'admin': admin,
      'workers': workers.map((worker) => worker.toJson()).toList(),
      'bins': bins,
      'zones': zones,
      'organization_name':
          admin['organization_name'] ??
          admin['organization_location'] ??
          'BinSight Deployment',
      'organization_location': admin['organization_location'],
      'location_lat': admin['location_lat'] ?? 0.0,
      'location_lon': admin['location_lon'] ?? 0.0,
    });

    if (adminPhotoBytes != null && adminPhotoBytes.isNotEmpty) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'adminPhoto',
          adminPhotoBytes,
          filename: 'admin.jpg',
        ),
      );
    }

    for (final worker in workers) {
      final photoBytes = worker.photoBytes;
      if (photoBytes == null || photoBytes.isEmpty) {
        continue;
      }

      request.files.add(
        http.MultipartFile.fromBytes(
          'workerPhoto_${worker.localId}',
          photoBytes,
          filename: '${worker.workerId}.jpg',
        ),
      );
    }

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw _requestException('Failed to complete setup', response);
    }
  }

  static Future<List<Map<String, dynamic>>> fetchWorkers() async {
    final response = await http.get(_uri('/workers'));
    if (response.statusCode != 200) {
      throw _requestException('Failed to fetch workers', response);
    }

    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    final workers = data['workers'] as List<dynamic>? ?? const [];
    return workers
        .map(
          (worker) =>
              _normalizeProfileMap(Map<String, dynamic>.from(worker as Map)),
        )
        .toList();
  }

  static Future<Map<String, dynamic>> fetchWorkerProfile(
    String workerId,
  ) async {
    final response = await http.get(_uri('/workers/$workerId'));
    if (response.statusCode != 200) {
      throw _requestException('Failed to fetch worker profile', response);
    }

    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    return _normalizeProfileMap(
      Map<String, dynamic>.from(
        data['worker'] as Map? ?? const <String, dynamic>{},
      ),
    );
  }

  static Future<Map<String, dynamic>> fetchAdminProfile(String adminId) async {
    final response = await http.get(_uri('/admins/$adminId'));
    if (response.statusCode != 200) {
      throw _requestException('Failed to fetch admin profile', response);
    }

    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    return _normalizeProfileMap(
      Map<String, dynamic>.from(
        data['admin'] as Map? ?? const <String, dynamic>{},
      ),
    );
  }

  static Future<Map<String, dynamic>> fetchContactAdmin() async {
    final response = await http.get(_uri('/contact-admin'));
    if (response.statusCode != 200) {
      throw _requestException('Failed to fetch contact admin info', response);
    }

    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    return _normalizeProfileMap(data);
  }

  static Future<Map<String, dynamic>> fetchAppConfig() async {
    final response = await http.get(_uri('/config'));
    if (response.statusCode != 200) {
      throw _requestException('Failed to fetch app config', response);
    }
    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    return data;
  }

  static Future<void> saveWorkerNotificationPreferences({
    required String workerId,
    required Map<String, bool> preferences,
  }) async {
    final response = await http.patch(
      _uri('/workers/${Uri.encodeComponent(workerId)}'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'notification_preferences': preferences}),
    );
    if (response.statusCode != 200) {
      throw _requestException(
        'Failed to save notification preferences',
        response,
      );
    }
  }

  static Future<bool> claimNotificationBanner(String notificationId) async {
    final response = await http.post(
      _uri(
        '/notifications/${Uri.encodeComponent(notificationId)}/claim-banner',
      ),
    );
    if (response.statusCode != 200) {
      throw _requestException('Failed to claim notification banner', response);
    }
    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    return data['show'] == true;
  }

  static Future<void> saveAdminNotificationPreferences({
    required String adminId,
    required Map<String, bool> preferences,
  }) async {
    final response = await http.patch(
      _uri('/admins/${Uri.encodeComponent(adminId)}'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'notification_preferences': preferences}),
    );
    if (response.statusCode != 200) {
      throw _requestException(
        'Failed to save notification preferences',
        response,
      );
    }
  }

  static Future<void> updateAdminProfile(
    String adminId, {
    String? name,
    String? email,
    String? phone,
    String? dateOfBirth,
    String? profileImageUrl,
  }) async {
    final payload = <String, dynamic>{};
    if (name != null) {
      payload['name'] = name;
    }
    if (email != null) {
      payload['email'] = email;
    }
    if (phone != null) {
      payload['phone'] = phone;
    }
    if (dateOfBirth != null) {
      payload['date_of_birth'] = dateOfBirth;
    }
    if (profileImageUrl != null) {
      payload['profile_image_url'] = profileImageUrl;
    }

    final response = await http.patch(
      _uri('/admins/$adminId'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(payload),
    );

    if (response.statusCode != 200) {
      throw _requestException('Failed to update admin profile', response);
    }
  }

  static Future<void> upsertWorkerProfile({
    required String workerId,
    required String email,
    String name = '',
    String firstName = '',
    String lastName = '',
    String dateOfBirth = '',
    String phone = '',
    String profileImageUrl = '',
    List<String> assignedZones = const [],
    List<String> assignedBins = const [],
  }) async {
    final response = await http.post(
      _uri('/workers'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'worker_id': workerId,
        'name': name,
        'first_name': firstName,
        'last_name': lastName,
        'date_of_birth': dateOfBirth,
        'email': email,
        'phone': phone,
        'profile_image_url': profileImageUrl,
        'assigned_zones': assignedZones,
        'assigned_bins': assignedBins,
      }),
    );

    if (response.statusCode != 200) {
      throw _requestException('Failed to save worker profile', response);
    }
  }

  static Future<void> updateWorkerProfile(
    String workerId, {
    String? name,
    String? email,
    String? phone,
    String? dateOfBirth,
    String? profileImageUrl,
    List<String>? assignedZones,
    List<String>? assignedBins,
  }) async {
    final payload = <String, dynamic>{};
    if (name != null) {
      payload['name'] = name;
    }
    if (email != null) {
      payload['email'] = email;
    }
    if (phone != null) {
      payload['phone'] = phone;
    }
    if (dateOfBirth != null) {
      payload['date_of_birth'] = dateOfBirth;
    }
    if (profileImageUrl != null) {
      payload['profile_image_url'] = profileImageUrl;
    }
    if (assignedZones != null) {
      payload['assigned_zones'] = assignedZones;
    }
    if (assignedBins != null) {
      payload['assigned_bins'] = assignedBins;
    }

    final response = await http.patch(
      _uri('/workers/$workerId'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(payload),
    );

    if (response.statusCode != 200) {
      throw _requestException('Failed to update worker profile', response);
    }
  }

  static Future<void> updateWorkerLocation({
    required String workerId,
    required double lat,
    required double lng,
  }) async {
    final payload = <String, dynamic>{
      'current_location': {'lat': lat, 'lng': lng},
    };

    final response = await http.patch(
      _uri('/workers/$workerId'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(payload),
    );

    if (response.statusCode != 200) {
      throw _requestException('Failed to update worker location', response);
    }
  }

  static Future<void> deleteWorker(String workerId) async {
    final response = await http.delete(_uri('/workers/$workerId'));
    if (response.statusCode != 200) {
      throw _requestException('Failed to delete worker', response);
    }
  }

  static Future<String> uploadProfilePicture({
    required String ownerId,
    required String ownerType,
    required Uint8List imageBytes,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      _uri('/upload/profile_picture'),
    );

    request.fields['ownerId'] = ownerId;
    request.fields['ownerType'] = ownerType;
    request.files.add(
      http.MultipartFile.fromBytes(
        'profilePicture',
        imageBytes,
        filename: '$ownerType-$ownerId.jpg',
      ),
    );

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw _requestException('Failed to upload profile picture', response);
    }

    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    final imageUrl = data['profile_image_url']?.toString() ?? '';
    if (imageUrl.isEmpty) {
      throw Exception(
        'Profile picture upload succeeded but no URL was returned.',
      );
    }
    return _normalizeUrl(imageUrl);
  }

  static Future<Map<String, dynamic>> fetchAnalyticsFillHistory() async {
    final response = await http.get(_uri('/analytics/fill-history'));
    if (response.statusCode != 200) {
      throw _requestException('Failed to fetch predictive analytics', response);
    }
    return _decodeBody(response) as Map<String, dynamic>? ?? const {};
  }

  static Future<List<Map<String, dynamic>>> fetchDevices() async {
    final response = await http.get(_uri('/devices'));
    if (response.statusCode != 200) {
      throw _requestException('Failed to fetch devices', response);
    }

    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    final devices = data['devices'] as List<dynamic>? ?? const [];
    return devices
        .map((device) => Map<String, dynamic>.from(device as Map))
        .toList();
  }

  static Future<List<Map<String, dynamic>>> fetchAlerts({
    String status = 'open',
  }) async {
    final response = await http.get(
      _uri('/alerts', queryParameters: {'status': status}),
    );
    if (response.statusCode != 200) {
      throw _requestException('Failed to fetch alerts', response);
    }

    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    final alerts = data['alerts'] as List<dynamic>? ?? const [];
    return alerts
        .map((alert) => Map<String, dynamic>.from(alert as Map))
        .toList();
  }

  static Future<void> resolveAlert(
    String alertId, {
    required String resolvedBy,
  }) async {
    final response = await http.patch(
      _uri('/alerts/${Uri.encodeComponent(alertId)}/resolve'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'resolved_by': resolvedBy}),
    );
    if (response.statusCode != 200) {
      throw _requestException('Failed to resolve alert', response);
    }
  }

  static Future<void> resolveDeviceAlerts(String deviceId) async {
    final response = await http.delete(
      _uri('/alerts/device/${Uri.encodeComponent(deviceId)}/resolve'),
    );
    if (response.statusCode != 200) {
      throw _requestException('Failed to resolve bin alerts', response);
    }
  }

  static Future<void> deleteNotification(String notificationId) async {
    final response = await http.delete(
      _uri('/notifications/${Uri.encodeComponent(notificationId)}'),
    );
    if (response.statusCode != 200) {
      throw _requestException('Failed to resolve notification', response);
    }
  }

  static Future<List<Map<String, dynamic>>> fetchZones() async {
    final response = await http.get(_uri('/zones'));
    if (response.statusCode != 200) {
      throw _requestException('Failed to fetch zones', response);
    }

    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    final zones = data['zones'] as List<dynamic>? ?? const [];
    return zones.map((zone) => Map<String, dynamic>.from(zone as Map)).toList();
  }

  static Future<Map<String, dynamic>> createDeviceFromQr({
    required String qrValue,
    required String name,
    required String locationDescription,
    double? latitude,
    double? longitude,
    String? zoneId,
  }) async {
    final payload = <String, dynamic>{
      'qr_value': qrValue,
      'name': name,
      'location_description': locationDescription,
    };
    if (latitude != null && longitude != null) {
      payload['latitude'] = latitude;
      payload['longitude'] = longitude;
    }
    if (zoneId != null) payload['zone_id'] = zoneId;

    final response = await http.post(
      _uri('/devices'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(payload),
    );

    if (response.statusCode != 200) {
      throw _requestException('Failed to create device', response);
    }

    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    return Map<String, dynamic>.from(
      data['device'] as Map? ?? const <String, dynamic>{},
    );
  }

  static Future<void> registerDevice({
    required String qrValue,
    required String name,
    required String locationDescription,
    double? latitude,
    double? longitude,
    String? zoneId,
  }) async {
    final payload = <String, dynamic>{
      'qr_value': qrValue,
      'name': name,
      'location_description': locationDescription,
    };
    if (latitude != null && longitude != null) {
      payload['latitude'] = latitude;
      payload['longitude'] = longitude;
    }
    if (zoneId != null) payload['zone_id'] = zoneId;

    final response = await http.post(
      _uri('/devices'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(payload),
    );

    if (response.statusCode != 200) {
      throw _requestException('Failed to register device', response);
    }
  }

  static Future<void> assignBinToZone({
    required String binId,
    String? zoneId,
  }) async {
    final response = await http.patch(
      _uri('/bins/$binId/zone'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'zone_id': zoneId}),
    );

    if (response.statusCode != 200) {
      throw _requestException('Failed to update bin zone', response);
    }
  }

  static Future<Map<String, dynamic>> updateBinDetails({
    required String binId,
    String? name,
    String? locationDescription,
    double? latitude,
    double? longitude,
    String? zoneId,
  }) async {
    final payload = <String, dynamic>{};
    if (name != null) payload['name'] = name;
    if (locationDescription != null)
      payload['location_description'] = locationDescription;
    if (latitude != null) payload['latitude'] = latitude;
    if (longitude != null) payload['longitude'] = longitude;
    if (zoneId != null) payload['zone_id'] = zoneId;

    final response = await http.patch(
      _uri('/bins/${Uri.encodeComponent(binId)}'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(payload),
    );

    if (response.statusCode != 200) {
      throw _requestException('Failed to update bin details', response);
    }

    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    return Map<String, dynamic>.from(
      data['updated'] as Map? ?? const <String, dynamic>{},
    );
  }

  static Future<void> deleteBin(String binId) async {
    final response = await http.delete(_uri('/bins/$binId'));
    if (response.statusCode != 200) {
      throw _requestException('Failed to delete bin', response);
    }
  }

  static Future<void> deleteDevice(String deviceId, {String? type}) async {
    final normalizedType = (type ?? '').toLowerCase();
    final response = await http.delete(
      _uri('/devices/${Uri.encodeComponent(deviceId)}'),
    );
    if (response.statusCode != 200) {
      throw _requestException(
        normalizedType == 'zone'
            ? 'Failed to delete zone'
            : 'Failed to delete device',
        response,
      );
    }
  }

  static Future<List<Map<String, dynamic>>> fetchReports() async {
    final response = await http.get(_uri('/reports'));
    if (response.statusCode != 200) {
      throw _requestException('Failed to fetch reports', response);
    }

    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    final reports = data['reports'] as List<dynamic>? ?? const [];
    return reports
        .map(
          (report) =>
              _normalizeProfileMap(Map<String, dynamic>.from(report as Map)),
        )
        .toList();
  }

  static Future<Map<String, dynamic>> submitReport({
    required String name,
    required String description,
    required String reporterId,
    required List<Uint8List> photos,
    List<String>? photoExtensions,
    String? relatedDeviceId,
    String? relatedDeviceType,
  }) async {
    final reportId =
        'report_'
        '${DateTime.now().millisecondsSinceEpoch}_'
        '${Uri.encodeComponent(reporterId)}';
    final request = http.MultipartRequest('POST', _uri('/reports'));
    request.fields['report_id'] = reportId;
    request.fields['name'] = name.trim();
    request.fields['description'] = description.trim();
    request.fields['reporter_id'] = reporterId;
    if (relatedDeviceId != null && relatedDeviceType != null) {
      request.fields['related_device_id'] = relatedDeviceId;
      request.fields['related_device_type'] = relatedDeviceType;
    }

    for (var i = 0; i < photos.length; i++) {
      final bytes = photos[i];
      if (bytes.isEmpty) continue;
      final extension = i < (photoExtensions?.length ?? 0)
          ? photoExtensions![i].toLowerCase()
          : 'jpg';
      final mimeSubtype = extension == 'jpg' ? 'jpeg' : extension;
      request.files.add(
        http.MultipartFile.fromBytes(
          'reportPictures',
          bytes,
          filename: '$reportId-${i + 1}.$extension',
          contentType: MediaType('image', mimeSubtype),
        ),
      );
    }

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    if (response.statusCode != 200) {
      throw _requestException('Failed to submit report', response);
    }

    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    return _normalizeProfileMap(
      Map<String, dynamic>.from(
        data['report'] as Map? ?? const <String, dynamic>{},
      ),
    );
  }

  static Future<void> resolveIssueReport({
    required String reportId,
    required String remarks,
    required String adminId,
  }) async {
    final response = await http.post(
      _uri('/reports/${Uri.encodeComponent(reportId)}/resolve'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'remarks': remarks, 'admin_id': adminId}),
    );
    if (response.statusCode != 200) {
      throw _requestException('Failed to resolve issue report', response);
    }
  }

  static Future<void> updateTaskStatus({
    required String taskId,
    required String status,
  }) async {
    final response = await http.patch(
      _uri('/tasks/${Uri.encodeComponent(taskId)}/status'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'status': status}),
    );
    if (response.statusCode != 200) {
      throw _requestException('Failed to update task status', response);
    }
  }

  static Future<List<Map<String, dynamic>>> fetchAdminConnectivityEvents(
    String adminId,
  ) async {
    final response = await http.get(
      _uri('/admins/${Uri.encodeComponent(adminId)}/connectivity-events'),
    );
    if (response.statusCode != 200) {
      throw _requestException('Failed to fetch connectivity events', response);
    }
    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    final events = data['events'] as List<dynamic>? ?? const [];
    return events
        .map((event) => Map<String, dynamic>.from(event as Map))
        .toList();
  }

  static Future<List<Map<String, dynamic>>> fetchAdminNotifications(
    String adminId,
  ) async {
    final response = await http.get(
      _uri('/admins/${Uri.encodeComponent(adminId)}/notifications'),
    );
    if (response.statusCode != 200) {
      throw _requestException('Failed to fetch admin notifications', response);
    }

    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    final notifications = data['notifications'] as List<dynamic>? ?? const [];
    return notifications
        .map((notification) => Map<String, dynamic>.from(notification as Map))
        .toList();
  }

  static Future<List<Map<String, dynamic>>> fetchWorkerNotifications(
    String workerId,
  ) async {
    final response = await http.get(
      _uri('/workers/${Uri.encodeComponent(workerId)}/notifications'),
    );
    if (response.statusCode != 200) {
      throw _requestException('Failed to fetch notifications', response);
    }

    final data = _decodeBody(response) as Map<String, dynamic>? ?? const {};
    final notifications = data['notifications'] as List<dynamic>? ?? const [];
    return notifications
        .map((notification) => Map<String, dynamic>.from(notification as Map))
        .toList();
  }
}
