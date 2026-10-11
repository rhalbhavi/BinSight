String buildBinDisplayName(Map<String, dynamic> device) {
  final name = (device['name']?.toString() ?? 'Bin').trim();
  final location = (device['location_description']?.toString() ?? '').trim();
  // Admin Setup stores the manually entered detail followed by the picker
  // result in parentheses. Keep the detail and omit the picker place name.
  final pickerSeparator = location.lastIndexOf(' (');
  final manualDetail = location.endsWith(')') && pickerSeparator > 0
      ? location.substring(0, pickerSeparator).trim()
      : location;
  return manualDetail.isEmpty ? name : '$name - $manualDetail';
}

String buildZoneDisplayName(Map<String, dynamic> zone) {
  final name = (zone['name']?.toString() ?? 'Zone').trim();
  final location = (zone['location_description']?.toString() ?? '').trim();
  return location.isEmpty ? name : '$name - $location';
}

String buildZoneNameWithoutPicker(Map<String, dynamic> zone) {
  final name = (zone['name']?.toString() ?? 'Zone').trim();
  final location = (zone['location_description']?.toString() ?? '').trim();
  if (location.isEmpty) return name;

  final pickerSuffix = ' - $location';
  if (name.toLowerCase().endsWith(pickerSuffix.toLowerCase())) {
    return name.substring(0, name.length - pickerSuffix.length).trim();
  }
  return name;
}

String addDeviceNameToMessage(
  dynamic rawMessage,
  dynamic rawDeviceId,
  Map<String, String> deviceNames,
) {
  final message = (rawMessage ?? '').toString().trim();
  final deviceId = rawDeviceId?.toString() ?? '';
  final name = deviceNames[deviceId];
  if (name == null || name.isEmpty || message.contains(name)) return message;
  return '$name: $message';
}
