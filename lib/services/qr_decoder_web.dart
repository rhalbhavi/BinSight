// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

Future<String?> decodeQrCodeFromImage({
  required String? imagePath,
  required Uint8List? imageBytes,
}) async {
  if (imageBytes == null || imageBytes.isEmpty) {
    return null;
  }
  final blob = html.Blob([imageBytes]);
  final objectUrl = html.Url.createObjectUrlFromBlob(blob);
  final image = html.ImageElement(src: objectUrl);

  try {
    await image.onLoad.first.timeout(const Duration(seconds: 10));

    final detector = html.BarcodeDetector();
    final results = await detector.detect(image);
    if (results.isEmpty) {
      return null;
    }

    final first = results.first;
    if (first is Map && first['rawValue'] is String) {
      return first['rawValue'] as String;
    }
  } catch (_) {
    return null;
  } finally {
    html.Url.revokeObjectUrl(objectUrl);
  }

  return null;
}
