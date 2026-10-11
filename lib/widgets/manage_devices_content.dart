import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:binsight/services/api_service.dart';
import 'package:binsight/utils/device_labels.dart';

typedef OpenDeviceQrScanner = void Function(ValueChanged<String> onScan);

class ManageDevicesContent extends StatefulWidget {
  const ManageDevicesContent({super.key, required this.openQrScanner});

  final OpenDeviceQrScanner openQrScanner;

  @override
  State<ManageDevicesContent> createState() => _ManageDevicesContentState();
}

String? detectDeviceTypeFromQr(String rawValue) {
  final trimmed = rawValue.trim();
  if (trimmed.isEmpty) return null;

  final normalized = trimmed.toLowerCase();
  if (normalized == 'bin' || normalized.startsWith('bin:')) return 'bin';
  if (normalized == 'zone' || normalized.startsWith('zone:')) return 'zone';

  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map) {
      final type = (decoded['type'] ?? decoded['device_type'])
          ?.toString()
          .toLowerCase();
      if (type == 'bin' || type == 'zone') {
        return type;
      }
    }
  } catch (_) {
    // Ignore and fall through to the generic invalid QR value message.
  }

  return null;
}

class _ManageDevicesContentState extends State<ManageDevicesContent> {
  late Future<List<Map<String, dynamic>>> _devicesFuture;

  @override
  void initState() {
    super.initState();
    _devicesFuture = ApiService.fetchDevices();
  }

  Future<void> _refreshDevices() async {
    final nextFuture = ApiService.fetchDevices();
    setState(() => _devicesFuture = nextFuture);
    await nextFuture;
  }

  String? _deviceTypeFromQr(String rawValue) =>
      detectDeviceTypeFromQr(rawValue);

  void _handleQrScan(String qrValue) {
    final deviceType = detectDeviceTypeFromQr(qrValue);
    if (deviceType == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('QR code must identify a bin or zone.')),
      );
      return;
    }

    final nameController = TextEditingController();
    final locationController = TextEditingController();
    final zonesFuture = deviceType == 'bin'
        ? ApiService.fetchZones()
        : Future.value(<Map<String, dynamic>>[]);
    final screenContext = context;
    String? selectedZoneId;

    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('Register ${deviceType == 'bin' ? 'Bin' : 'Zone'}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                TextField(
                  controller: locationController,
                  decoration: const InputDecoration(
                    labelText: 'Location description',
                  ),
                ),
                if (deviceType == 'bin')
                  FutureBuilder<List<Map<String, dynamic>>>(
                    future: zonesFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Padding(
                          padding: EdgeInsets.all(12),
                          child: LinearProgressIndicator(),
                        );
                      }
                      if (snapshot.hasError) {
                        return const Text('Could not load zones.');
                      }
                      final zones = snapshot.data ?? const [];
                      return DropdownButtonFormField<String?>(
                        initialValue: selectedZoneId,
                        decoration: const InputDecoration(
                          labelText: 'Zone (optional)',
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Unassigned'),
                          ),
                          ...zones.map(
                            (zone) => DropdownMenuItem<String?>(
                              value: zone['zone_id']?.toString(),
                              child: Text(zone['name']?.toString() ?? 'Zone'),
                            ),
                          ),
                        ],
                        onChanged: (zoneId) =>
                            setDialogState(() => selectedZoneId = zoneId),
                      );
                    },
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameController.text.trim();
                final location = locationController.text.trim();
                if (name.isEmpty || location.isEmpty) {
                  if (!screenContext.mounted || !dialogContext.mounted) return;
                  ScaffoldMessenger.of(screenContext).showSnackBar(
                    const SnackBar(
                      content: Text('Name and location are required.'),
                    ),
                  );
                  return;
                }
                try {
                  // Match Admin Setup: validate the scanned QR, then submit its
                  // canonical device type to the registration API.
                  final registered = await ApiService.createDeviceFromQr(
                    qrValue: deviceType,
                    name: name,
                    locationDescription: location,
                    zoneId: selectedZoneId,
                  );
                  if (!screenContext.mounted || !dialogContext.mounted) return;
                  Navigator.pop(dialogContext);
                  ScaffoldMessenger.of(screenContext).showSnackBar(
                    SnackBar(
                      content: Text(
                        '${deviceType == 'bin' ? 'Bin' : 'Zone'} registered${registered['name'] != null ? ' (${registered['name']})' : ''}.',
                      ),
                    ),
                  );
                  await _refreshDevices();
                } catch (error) {
                  if (!screenContext.mounted || !dialogContext.mounted) return;
                  ScaffoldMessenger.of(screenContext).showSnackBar(
                    SnackBar(
                      content: Text('Could not register device: $error'),
                    ),
                  );
                }
              },
              child: const Text('Register'),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      nameController.dispose();
      locationController.dispose();
    });
  }

  Future<void> _confirmDeleteDevice(Map<String, dynamic> device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete device'),
        content: const Text('Are you sure you want to delete this device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final deviceId =
        (device['bin_id'] ??
                device['zone_id'] ??
                device['device_id'] ??
                device['id'])
            ?.toString() ??
        '';
    if (deviceId.isEmpty) return;

    try {
      await ApiService.deleteDevice(deviceId, type: device['type']?.toString());
      if (!mounted) return;
      await _refreshDevices();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${device['name'] ?? 'Device'} deleted.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete device: $error')),
      );
    }
  }

  Future<void> _editBin(Map<String, dynamic> device) async {
    final nameController = TextEditingController(
      text: device['name']?.toString() ?? '',
    );
    final locationController = TextEditingController(
      text: device['location_description']?.toString() ?? '',
    );
    final zonesFuture = ApiService.fetchZones();
    final screenContext = context;
    String? selectedZoneId = device['zone_id']?.toString();
    String? locationError;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('Edit ${device['name'] ?? 'Bin'}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  enabled: false,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    helperText:
                        'Automatically assigned and fixed by the system',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: locationController,
                  decoration: const InputDecoration(
                    labelText: 'Location description',
                  ),
                ),
                const SizedBox(height: 12),
                FutureBuilder<List<Map<String, dynamic>>>(
                  future: zonesFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const LinearProgressIndicator();
                    }
                    if (snapshot.hasError) {
                      return const Text('Could not load zones.');
                    }
                    final zones = snapshot.data ?? const [];
                    return DropdownButtonFormField<String?>(
                      initialValue: selectedZoneId,
                      decoration: const InputDecoration(labelText: 'Zone'),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('Unassigned'),
                        ),
                        ...zones.map(
                          (zone) => DropdownMenuItem<String?>(
                            value: zone['zone_id']?.toString(),
                            child: Text(zone['name']?.toString() ?? 'Zone'),
                          ),
                        ),
                      ],
                      onChanged: (zoneId) =>
                          setDialogState(() => selectedZoneId = zoneId),
                    );
                  },
                ),
                if (locationError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    locationError!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final updatedLocation = locationController.text.trim();
                if (updatedLocation.isEmpty) {
                  setDialogState(() => locationError = 'Location is required.');
                  return;
                }

                try {
                  final binId =
                      device['bin_id']?.toString() ??
                      device['device_id']?.toString() ??
                      device['id']?.toString() ??
                      '';
                  if (binId.isEmpty) {
                    throw Exception('Bin ID is missing.');
                  }
                  await ApiService.updateBinDetails(
                    binId: binId,
                    locationDescription: updatedLocation,
                    zoneId: selectedZoneId,
                  );
                  if (!screenContext.mounted || !dialogContext.mounted) return;
                  Navigator.pop(dialogContext);
                  await _refreshDevices();
                } catch (error) {
                  if (!screenContext.mounted || !dialogContext.mounted) return;
                  ScaffoldMessenger.of(screenContext).showSnackBar(
                    SnackBar(content: Text('Could not update bin: $error')),
                  );
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      nameController.dispose();
      locationController.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _devicesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError && !snapshot.hasData) {
          return Center(
            child: Text('Could not load devices: ${snapshot.error}'),
          );
        }

        final devices = snapshot.data ?? const [];
        return RefreshIndicator(
          onRefresh: _refreshDevices,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'MANAGE DEVICES',
                style: GoogleFonts.rubikMonoOne(fontSize: 20),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => widget.openQrScanner(_handleQrScan),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('REGISTER DEVICE'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF03A9F4),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 50),
                ),
              ),
              const SizedBox(height: 16),
              if (devices.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 20),
                  child: Center(child: Text('No devices registered yet.')),
                )
              else
                ...devices.where((device) => device['type'] == 'bin').map((
                  device,
                ) {
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: const Icon(Icons.delete_outline),
                      title: Text(
                        buildBinDisplayName(device),
                        style: GoogleFonts.titilliumWeb(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: Text(
                        'Fill ${device['fill_level'] ?? 0}% • Air ${device['gas_level'] ?? 0} PPM • Flame ${device['flame'] == true ? 'detected' : 'clear'} • Zone ${device['zone_name'] ?? 'unassigned'}',
                        style: GoogleFonts.titilliumWeb(fontSize: 18),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Edit bin',
                            onPressed: () => _editBin(device),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          const SizedBox(width: 4),
                          SizedBox(
                            width: 96,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                              ),
                              onPressed: () => _confirmDeleteDevice(device),
                              child: const Text(
                                'Delete',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
            ],
          ),
        );
      },
    );
  }
}
