import 'dart:convert';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'connectivity.dart';
import 'env.dart';
import 'settings.dart';
import 'frame_codec.dart';
import 'sign_translator.dart';

/// Primary (deck stack): Cloud Vision (DOCUMENT_TEXT_DETECTION) + Cloud
/// Translation v2, both over REST with the shared `GOOGLE_API_KEY`.
/// Fallback (offline / no key / request failure): on-device ML Kit, via
/// [SignTranslator] — same `TranslatedBlock` shape either way, so the AR
/// screen doesn't need to know which path served a frame.
class TranslationResult {
  final List<TranslatedBlock> blocks;
  final Size imageSize; // upright size the boxes are expressed in
  TranslationResult(this.blocks, this.imageSize);
}

class TranslationService {
  final _onDevice = SignTranslator();
  bool lastFrameWasCloud = false;
  static const _cloudMaxWidth = 640;

  Future<TranslationResult> process(CameraImage image, int sensorOrientation) async {
    final swap = sensorOrientation % 180 == 90;
    final uprightW = (swap ? image.height : image.width).toDouble();
    final uprightH = (swap ? image.width : image.height).toDouble();

    if (Env.hasGoogleApiKey && await hasNetworkLink()) {
      try {
        final blocks = await _cloud(image, sensorOrientation);
        lastFrameWasCloud = true;
        final scale = (uprightW > _cloudMaxWidth ? _cloudMaxWidth / uprightW : 1.0);
        return TranslationResult(blocks, Size(uprightW * scale, uprightH * scale));
      } catch (_) {
        // Fall through to on-device ML Kit below.
      }
    }
    lastFrameWasCloud = false;
    final rot = InputImageRotationValue.fromRawValue(sensorOrientation) ?? InputImageRotation.rotation0deg;
    final input = InputImage.fromBytes(
      bytes: image.planes.first.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rot,
        format: InputImageFormat.nv21,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
    final blocks = await _onDevice.process(input);
    return TranslationResult(blocks, Size(uprightW, uprightH));
  }

  Future<List<TranslatedBlock>> _cloud(CameraImage image, int sensorOrientation) async {
    final jpeg = uprightJpeg(image, sensorOrientation, maxWidth: _cloudMaxWidth);
    final visionRes = await http
        .post(
          Uri.parse('https://vision.googleapis.com/v1/images:annotate'),
          headers: Env.googleHeaders,
          body: jsonEncode({
            'requests': [
              {
                'image': {'content': base64Encode(jpeg)},
                'features': [
                  {'type': 'DOCUMENT_TEXT_DETECTION'}
                ],
              }
            ]
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (visionRes.statusCode != 200) throw Exception('Cloud Vision failed (${visionRes.statusCode})');
    final fullAnnotation = jsonDecode(visionRes.body)['responses']?[0]?['fullTextAnnotation'];
    if (fullAnnotation == null) return [];

    final texts = <String>[];
    final boxes = <Rect>[];
    for (final page in fullAnnotation['pages'] as List) {
      for (final block in page['blocks'] as List) {
        for (final para in block['paragraphs'] as List) {
          final words = <String>[];
          for (final word in para['words'] as List) {
            words.add((word['symbols'] as List).map((s) => s['text']).join());
          }
          final text = words.join(' ').trim();
          if (text.length < 2) continue;
          final verts = (para['boundingBox']['vertices'] as List)
              .map((v) => Offset((v['x'] ?? 0).toDouble(), (v['y'] ?? 0).toDouble()))
              .toList();
          final xs = verts.map((p) => p.dx), ys = verts.map((p) => p.dy);
          texts.add(text);
          boxes.add(Rect.fromLTRB(xs.reduce((a, b) => a < b ? a : b), ys.reduce((a, b) => a < b ? a : b),
              xs.reduce((a, b) => a > b ? a : b), ys.reduce((a, b) => a > b ? a : b)));
        }
      }
    }
    if (texts.isEmpty) return [];

    final translateRes = await http
        .post(
          Uri.parse('https://translation.googleapis.com/language/translate/v2'),
          headers: Env.googleHeaders,
          body: jsonEncode({'q': texts, 'target': settings.translateTo, 'format': 'text'}),
        )
        .timeout(const Duration(seconds: 10));
    if (translateRes.statusCode != 200) throw Exception('Cloud Translate failed (${translateRes.statusCode})');
    final translations = jsonDecode(translateRes.body)['data']['translations'] as List;

    final out = <TranslatedBlock>[];
    for (var i = 0; i < texts.length && i < translations.length; i++) {
      final src = translations[i]['detectedSourceLanguage'];
      if (src == settings.translateTo) continue; // already in the target language
      out.add(TranslatedBlock(boxes[i], texts[i], _unescape(translations[i]['translatedText'])));
    }
    return out;
  }

  String _unescape(String s) =>
      s.replaceAll('&#39;', "'").replaceAll('&quot;', '"').replaceAll('&amp;', '&');

  Future<void> dispose() => _onDevice.dispose();
}
