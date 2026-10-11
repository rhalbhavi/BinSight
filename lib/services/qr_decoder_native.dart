import 'dart:typed_data';

import 'package:mobile_scanner/mobile_scanner.dart';

String? _extractQrValue(BarcodeCapture capture) {
  for (final barcode in capture.barcodes) {
    if (barcode.format != BarcodeFormat.qrCode &&
        barcode.format != BarcodeFormat.unknown) {
      continue;
    }

    final rawValue = barcode.rawValue?.trim();
    if (rawValue != null && rawValue.isNotEmpty) {
      return rawValue;
    }

    final displayValue = barcode.displayValue?.trim();
    if (displayValue != null && displayValue.isNotEmpty) {
      return displayValue;
    }
  }

  return null;
}

Future<String?> decodeQrCodeFromImage({
  required String? imagePath,
  required Uint8List? imageBytes,
}) async {
  if (imagePath == null || imagePath.trim().isEmpty) {
    return null;
  }

  final controller = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.qrCode],
  );
  try {
    final capture = await controller.analyzeImage(imagePath);
    if (capture == null || capture.barcodes.isEmpty) return null;
    return _extractQrValue(capture);
  } finally {
    await controller.dispose();
  }

  return null;
}
