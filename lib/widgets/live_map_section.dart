import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:binsight/services/api_service.dart';

class LiveMapSection extends StatefulWidget {
  const LiveMapSection({
    super.key,
    this.height = 230,
    this.focusLocation,
    this.focusZoom,
    this.focusRequest = 0,
  });

  final double? height;
  final LatLng? focusLocation;
  final double? focusZoom;
  final int focusRequest;

  @override
  State<LiveMapSection> createState() => _LiveMapSectionState();
}

class _LiveMapSectionState extends State<LiveMapSection> {
  static const LatLng _fallbackCenter = LatLng(12.9716, 77.5946);
  static const double _baseZoom = 13.0;
  static const double _defaultZoomFactor = 1.46;
  static const double _defaultZoomForDisplay = _baseZoom * _defaultZoomFactor;

  final MapController _mapController = MapController();
  double _zoomLevel = _defaultZoomForDisplay;
  StreamSubscription<Position>? _positionSubscription;

  LatLng? _currentLatLng;
  Marker? _currentMarker;
  List<Marker> _markers = [];
  bool _isLoading = true;
  bool _mapReady = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initializeLocation();
  }

  @override
  void didUpdateWidget(covariant LiveMapSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.focusLocation != oldWidget.focusLocation ||
            widget.focusRequest != oldWidget.focusRequest) &&
        widget.focusLocation != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_mapReady) return;
        _mapController.move(
          widget.focusLocation!,
          widget.focusZoom ?? _defaultZoomForDisplay,
        );
      });
    }
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initializeLocation() async {
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
        debugPrint('Could not fetch map configuration: $error');
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
      final organizationLatLng = _configLocation(config);
      final markers = <Marker>[];
      if (organizationLatLng != null) {
        markers.add(
          Marker(
            point: organizationLatLng,
            width: 64,
            height: 64,
            child: const Icon(Icons.business, color: Colors.red, size: 40),
          ),
        );
      }

      for (final worker in workers) {
        final position = _locationFromValue(worker['current_location']);
        if (position == null) continue;
        markers.add(
          Marker(
            point: position,
            width: 64,
            height: 64,
            child: Tooltip(
              message: worker['name']?.toString() ?? 'Worker',
              child: const Icon(
                Icons.person_pin_circle,
                color: Colors.blue,
                size: 40,
              ),
            ),
          ),
        );
      }

      final devicePointCounts = <String, int>{};
      for (final device in devices) {
        LatLng? position = _locationFromValue(device['location']);
        if (position == null) {
          final lat = _number(device['latitude']);
          final lng = _number(device['longitude']);
          if (lat != null && lng != null) {
            position = LatLng(lat, lng);
          }
        }
        if (position == null) continue;

        final isBin = device['type'] == 'bin';
        final pointKey =
            '${position.latitude.toStringAsFixed(7)},${position.longitude.toStringAsFixed(7)}';
        final samePointMarkerCount = devicePointCounts.update(
          pointKey,
          (count) => count + 1,
          ifAbsent: () => 0,
        );
        final spreadPoint = samePointMarkerCount == 0
            ? position
            : const Distance().offset(
                position,
                12.0 + samePointMarkerCount * 8.0,
                45.0 + samePointMarkerCount * 60.0,
              );

        markers.add(
          Marker(
            point: spreadPoint,
            width: 68,
            height: 68,
            child: Tooltip(
              message: device['name']?.toString() ?? 'Device',
              child: Icon(
                isBin ? Icons.delete_outline : Icons.business_center,
                color: isBin ? Colors.brown.shade700 : Colors.deepPurple,
                size: 36,
              ),
            ),
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _markers = markers;
        _isLoading = false;
        _errorMessage = null;
      });
      // GPS is optional for rendering the map. Do not keep the map covered
      // while a browser permission prompt or location fix is pending.
      bool serviceEnabled = false;
      try {
        serviceEnabled = await Geolocator.isLocationServiceEnabled().timeout(
          const Duration(seconds: 3),
        );
      } catch (_) {}
      if (!serviceEnabled) return;

      LocationPermission permission;
      try {
        permission = await Geolocator.checkPermission().timeout(
          const Duration(seconds: 3),
        );
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission().timeout(
            const Duration(seconds: 3),
          );
        }
      } catch (_) {
        return;
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever)
        return;

      Position? currentPosition;
      try {
        currentPosition = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.best,
            distanceFilter: 5,
          ),
        ).timeout(const Duration(seconds: 5));
      } catch (_) {
        currentPosition = null;
      }
      if (currentPosition == null) return;
      final initialLatLng = LatLng(
        currentPosition.latitude,
        currentPosition.longitude,
      );

      if (!mounted) return;
      final currentMarker = _buildCurrentMarker(initialLatLng);
      setState(() {
        _currentLatLng = initialLatLng;
        _currentMarker = currentMarker;
        _markers = [..._markers, currentMarker];
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_mapReady) return;
        if (widget.focusLocation != null) {
          _mapController.move(
            widget.focusLocation!,
            widget.focusZoom ?? _defaultZoomForDisplay,
          );
          return;
        }
        _moveToCurrentLocation();
      });

      _positionSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.best,
              distanceFilter: 5,
            ),
          ).listen(
            (position) {
              final nextLatLng = LatLng(position.latitude, position.longitude);
              if (!mounted) return;
              final currentMarker = _buildCurrentMarker(nextLatLng);
              setState(() {
                _currentLatLng = nextLatLng;
                _markers = [
                  ..._markers.where((marker) => marker != _currentMarker),
                  currentMarker,
                ];
                _currentMarker = currentMarker;
              });
              if (widget.focusLocation == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted || !_mapReady) return;
                  _moveToCurrentLocation();
                });
              }
            },
            onError: (Object error) {
              debugPrint('Live location updates stopped: $error');
            },
          );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Unable to load live location: $error';
      });
    }
  }

  LatLng? _configLocation(Map<String, dynamic> config) {
    final apiLocation = _latLngFromPair(
      config['latitude'],
      config['longitude'],
    );
    return apiLocation ?? _locationFromValue(config['organization_location']);
  }

  LatLng? _locationFromValue(dynamic value) {
    if (value is List && value.length >= 2) {
      // GeoJSON coordinates are ordered longitude, latitude.
      return _latLngFromPair(value[1], value[0]);
    }

    if (value is! Map) return null;

    final latitude = value['latitude'] ?? value['lat'];
    final longitude = value['longitude'] ?? value['lng'] ?? value['lon'];
    final directLocation = _latLngFromPair(latitude, longitude);
    if (directLocation != null) return directLocation;

    final coordinates = value['coordinates'];
    final coordinateLocation = _locationFromValue(coordinates);
    if (coordinateLocation != null) return coordinateLocation;

    for (final key in const ['location', 'organization_location', 'geometry']) {
      final nestedLocation = _locationFromValue(value[key]);
      if (nestedLocation != null) return nestedLocation;
    }
    return null;
  }

  double? _number(dynamic value) =>
      value is num ? value.toDouble() : double.tryParse('$value');

  LatLng? _latLngFromPair(dynamic latitudeValue, dynamic longitudeValue) {
    final latitude = _number(latitudeValue);
    final longitude = _number(longitudeValue);
    if (latitude == null ||
        longitude == null ||
        latitude.abs() > 90 ||
        longitude.abs() > 180 ||
        (latitude == 0 && longitude == 0)) {
      return null;
    }
    return LatLng(latitude, longitude);
  }

  Marker _buildCurrentMarker(LatLng position) {
    return Marker(
      point: position,
      width: 58,
      height: 58,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFE53935).withValues(alpha: 0.25),
              blurRadius: 14,
              spreadRadius: 3,
            ),
          ],
        ),
        padding: const EdgeInsets.all(4),
        child: const Icon(
          Icons.location_pin,
          color: Color(0xFFE53935),
          size: 30,
        ),
      ),
    );
  }

  void _moveToCurrentLocation() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_mapReady) return;
      final target = _currentLatLng ?? widget.focusLocation ?? _fallbackCenter;
      final nextZoom = _mapController.camera.zoom > 0
          ? _mapController.camera.zoom
          : _defaultZoomForDisplay;
      _zoomLevel = nextZoom;
      _mapController.move(target, nextZoom);
    });
  }

  void _focusOnCurrentLocation() {
    if (!mounted || !_mapReady) return;
    final target = _currentLatLng ?? widget.focusLocation ?? _fallbackCenter;
    const zoom = _defaultZoomForDisplay;
    _zoomLevel = zoom;
    _mapController.move(target, zoom);
  }

  int _displayPercent() {
    if (_baseZoom <= 0 || _zoomLevel <= 0) return 100;
    return ((_zoomLevel / _defaultZoomForDisplay) * 100).round();
  }

  void _zoomBy(double delta) {
    final nextZoom = (_zoomLevel + delta).clamp(4.0, 22.0);
    _zoomLevel = nextZoom;
    _mapController.move(_mapController.camera.center, nextZoom);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final center = _currentLatLng ?? widget.focusLocation ?? _fallbackCenter;

    return Container(
      height: widget.height,
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: _defaultZoomForDisplay,
              maxZoom: 22,
              minZoom: 4,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
              onMapReady: () {
                _mapReady = true;
                _zoomLevel = _defaultZoomForDisplay;
                if (widget.focusLocation != null) {
                  _mapController.move(
                    widget.focusLocation!,
                    widget.focusZoom ?? _defaultZoomForDisplay,
                  );
                  return;
                }
                if (_currentLatLng != null) _moveToCurrentLocation();
              },
              onMapEvent: (_) {
                if (!mounted) return;
                _zoomLevel = _mapController.camera.zoom;
                setState(() {});
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                maxNativeZoom: 19,
                userAgentPackageName: 'com.example.binsight',
              ),
              MarkerLayer(markers: _markers),
            ],
          ),
          if (_isLoading)
            const Center(child: CircularProgressIndicator())
          else if (_errorMessage != null)
            Positioned(
              left: 12,
              right: 12,
              top: 12,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.black87,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            )
          else
            Positioned(
              right: 14,
              top: 14,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Material(
                    color: const Color(0xFFE53935),
                    shape: const CircleBorder(),
                    elevation: 4,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _mapReady ? _focusOnCurrentLocation : null,
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
                          onPressed: () => _zoomBy(1),
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
                          onPressed: () => _zoomBy(-1),
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
      ),
    );
  }
}
