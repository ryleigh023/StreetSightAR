import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

/// Decodes a single-plane NV21 [CameraImage] into an upright RGB [img.Image],
/// rotating by [sensorOrientation] so the result matches how the frame looks
/// on screen (portrait-up). Shared by the on-device OCR path (which needs
/// the raw bytes + an [InputImageRotation]) and the Cloud Vision path (which
/// needs a JPEG already right-side up, since Vision has no rotation hint).
img.Image decodeNv21Upright(CameraImage image, int sensorOrientation) {
  final w = image.width, h = image.height;
  final nv21 = image.planes.first.bytes;
  final yRowStride = image.planes.first.bytesPerRow;
  final frame = img.Image(width: w, height: h, numChannels: 3);

  final uvStart = w * h; // NV21: Y plane, then interleaved VU
  for (var y = 0; y < h; y++) {
    final rowOff = y * yRowStride;
    for (var x = 0; x < w; x++) {
      final yVal = nv21[rowOff + x] & 0xFF;
      final uvRow = (y >> 1) * w;
      final uvCol = (x >> 1) * 2;
      final vIdx = uvStart + uvRow + uvCol;
      final v = (vIdx < nv21.length ? nv21[vIdx] : 128) & 0xFF;
      final u = (vIdx + 1 < nv21.length ? nv21[vIdx + 1] : 128) & 0xFF;
      final c = yVal - 16, d = u - 128, e = v - 128;
      final r = (298 * c + 409 * e + 128) >> 8;
      final g = (298 * c - 100 * d - 208 * e + 128) >> 8;
      final b = (298 * c + 516 * d + 128) >> 8;
      frame.setPixelRgb(x, y, r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255));
    }
  }

  return switch (sensorOrientation % 360) {
    90 => img.copyRotate(frame, angle: 90),
    180 => img.copyRotate(frame, angle: 180),
    270 => img.copyRotate(frame, angle: 270),
    _ => frame,
  };
}

/// Squashes [image] to an `n`×`n` square (no letterboxing) — good enough for
/// a classifier that only needs coarse scene content, not geometry.
img.Image resizeSquare(img.Image image, int n) => img.copyResize(image, width: n, height: n);

/// Upright JPEG bytes for Cloud Vision, downscaled for latency/cost.
Uint8List uprightJpeg(CameraImage image, int sensorOrientation, {int maxWidth = 640}) {
  var upright = decodeNv21Upright(image, sensorOrientation);
  if (upright.width > maxWidth) {
    upright = img.copyResize(upright, width: maxWidth);
  }
  return Uint8List.fromList(img.encodeJpg(upright, quality: 70));
}
