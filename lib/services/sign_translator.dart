import 'dart:ui';
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

class TranslatedBlock {
  final Rect box; // in image coordinates
  final String original, translated;
  TranslatedBlock(this.box, this.original, this.translated);
}

/// On-device OCR (ML Kit) + on-device translation to English.
class SignTranslator {
  // Latin recogniser covers Latin scripts; swap script per target region if needed.
  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final _langId = LanguageIdentifier(confidenceThreshold: 0.5);
  final _modelManager = OnDeviceTranslatorModelManager();
  final _translators = <String, OnDeviceTranslator>{};

  Future<List<TranslatedBlock>> process(InputImage image) async {
    final text = await _recognizer.processImage(image);
    final out = <TranslatedBlock>[];
    for (final b in text.blocks) {
      final src = b.text.replaceAll('\n', ' ').trim();
      if (src.length < 2) continue;
      final code = await _langId.identifyLanguage(src);
      if (code == 'und' || code == 'en') continue;
      final lang = BCP47Code.fromRawValue(code);
      if (lang == null) continue;
      try {
        final t = _translators.putIfAbsent(code,
            () => OnDeviceTranslator(sourceLanguage: lang, targetLanguage: TranslateLanguage.english));
        if (!await _modelManager.isModelDownloaded(code)) {
          await _modelManager.downloadModel(code); // needs network once per language
        }
        out.add(TranslatedBlock(b.boundingBox, src, await t.translateText(src)));
      } catch (_) {}
    }
    return out;
  }

  Future<void> dispose() async {
    await _recognizer.close();
    await _langId.close();
    for (final t in _translators.values) {
      await t.close();
    }
  }
}
