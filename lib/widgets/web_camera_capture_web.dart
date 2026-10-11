import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:html' as html;

Future<Uint8List?> captureWebCamera(BuildContext context) async {
  final mediaDevices = html.window.navigator.mediaDevices;
  if (mediaDevices == null) {
    throw StateError('This browser does not provide webcam access.');
  }

  final stream = await mediaDevices.getUserMedia({
    'video': {'facingMode': 'user'},
    'audio': false,
  });
  final viewType = 'binsight-webcam-${DateTime.now().microsecondsSinceEpoch}';
  final video = html.VideoElement()
    ..autoplay = true
    ..muted = true
    ..srcObject = stream
    ..setAttribute('playsinline', 'true');
  video.style
    ..width = '100%'
    ..height = '100%'
    ..objectFit = 'cover';
  ui_web.platformViewRegistry.registerViewFactory(
    viewType,
    (int viewId) => video,
  );

  try {
    return await showDialog<Uint8List>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          'TAKE PHOTO',
          style: GoogleFonts.titilliumWeb(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: SizedBox(
          width: 520,
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: HtmlElementView(viewType: viewType),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('CANCEL'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              final width = video.videoWidth;
              final height = video.videoHeight;
              if (width <= 0 || height <= 0) return;
              final canvas = html.CanvasElement(width: width, height: height);
              canvas.context2D.drawImage(video, 0, 0);
              final dataUrl = canvas.toDataUrl('image/jpeg', 0.85);
              final encoded = dataUrl.split(',').last;
              Navigator.pop(dialogContext, base64Decode(encoded));
            },
            icon: const Icon(Icons.camera_alt_outlined),
            label: const Text('CAPTURE'),
          ),
        ],
      ),
    );
  } finally {
    for (final track in stream.getTracks()) {
      track.stop();
    }
  }
}
