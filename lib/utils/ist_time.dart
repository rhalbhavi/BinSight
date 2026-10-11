/// Converts backend UTC timestamps to India Standard Time for display.
/// MongoDB and API timestamps remain UTC so they represent unambiguous instants.
DateTime? parseIstDateTime(dynamic value) {
  final parsed = DateTime.tryParse(value?.toString() ?? '');
  if (parsed == null) return null;
  return parsed.toUtc().add(const Duration(hours: 5, minutes: 30));
}

String formatIstDateTime(dynamic value) {
  final parsed = parseIstDateTime(value);
  if (parsed == null) return '';
  final hour = parsed.hour % 12 == 0 ? 12 : parsed.hour % 12;
  final period = parsed.hour < 12 ? 'AM' : 'PM';
  final time = '$hour:${parsed.minute.toString().padLeft(2, '0')} $period IST';
  final nowIst = DateTime.now().toUtc().add(
    const Duration(hours: 5, minutes: 30),
  );
  if (parsed.year == nowIst.year &&
      parsed.month == nowIst.month &&
      parsed.day == nowIst.day) {
    return 'Today $time';
  }
  final yesterday = nowIst.subtract(const Duration(days: 1));
  if (parsed.year == yesterday.year &&
      parsed.month == yesterday.month &&
      parsed.day == yesterday.day) {
    return 'Yesterday $time';
  }
  return '${parsed.day.toString().padLeft(2, '0')}-'
      '${parsed.month.toString().padLeft(2, '0')}-'
      '${parsed.year.toString().padLeft(4, '0')} $time';
}

String formatIstDate(dynamic value) {
  final parsed = parseIstDateTime(value);
  if (parsed == null) return '';
  return '${parsed.year.toString().padLeft(4, '0')}-'
      '${parsed.month.toString().padLeft(2, '0')}-'
      '${parsed.day.toString().padLeft(2, '0')}';
}
