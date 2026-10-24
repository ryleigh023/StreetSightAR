import 'dart:ui';
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import 'settings.dart';

class TranslatedBlock {
  final Rect box; // in image coordinates
  final String original, translated;
  TranslatedBlock(this.box, this.original, this.translated);
}

/// On-device OCR (ML Kit) + on-device translation into the chosen language.
///
/// Note the recogniser is the Latin-script model, so scripts such as Tamil,
/// Arabic or Thai are not read at all. ML Kit ships separate recognisers for
/// Chinese, Devanagari, Japanese and Korean only; there is no Tamil model,
/// so that limitation is the vendor's, not a configuration mistake.
class SignTranslator {
  // Latin recogniser covers Latin scripts; swap script per target region if needed.
  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final _langId = LanguageIdentifier(confidenceThreshold: 0.5);
  final _modelManager = OnDeviceTranslatorModelManager();
  final _translators = <String, OnDeviceTranslator>{};

  Future<List<TranslatedBlock>> process(InputImage image) async {
    final target = BCP47Code.fromRawValue(settings.translateTo) ?? TranslateLanguage.english;
    final targetCode = target.bcpCode;

    final text = await _recognizer.processImage(image);
    final out = <TranslatedBlock>[];
    for (final b in text.blocks) {
      final src = b.text.replaceAll('\n', ' ').trim();
      if (src.length < 2) continue;
      final code = await _langId.identifyLanguage(src);
      // Already in the target language — nothing to show.
      if (code == 'und' || code == targetCode) continue;
      final lang = BCP47Code.fromRawValue(code);
      if (lang == null) continue;
      try {
        // Keyed by the pair: the target can change between frames.
        final t = _translators.putIfAbsent('\$code>\$targetCode',
            () => OnDeviceTranslator(sourceLanguage: lang, targetLanguage: target));
        // Both halves of the pair need their model present. Downloading only
        // the source silently fails whenever the target is not English.
        for (final c in [code, targetCode]) {
          if (!await _modelManager.isModelDownloaded(c)) {
            await _modelManager.downloadModel(c); // needs network once per language
          }
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
