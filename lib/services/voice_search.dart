import 'package:speech_to_text/speech_to_text.dart';

/// Speaking a destination instead of typing it.
///
/// Typing is the worst possible input while walking: it needs both hands and
/// your eyes. The rest of the app is built so you can keep looking at the
/// street — spoken directions, haptic cues, a tactile compass — and then it
/// made you stop and type to start. This closes that gap.
class VoiceSearch {
  final SpeechToText _speech = SpeechToText();
  bool _available = false;

  bool get isListening => _speech.isListening;

  /// True once the platform has a usable recogniser and permission.
  Future<bool> init() async {
    if (_available) return true;
    try {
      _available = await _speech.initialize(
        // Errors and status are surfaced through the callbacks on listen()
        // rather than thrown, so a device with no recogniser degrades to a
        // disabled mic button instead of an exception.
        onError: (_) {},
        onStatus: (_) {},
      );
    } catch (_) {
      _available = false;
    }
    return _available;
  }

  /// Listens for a single phrase.
  ///
  /// [onPartial] fires as the user speaks so the field can fill live, which
  /// is what makes dictation feel responsive rather than laggy. [onFinal]
  /// fires once with the settled result.
  Future<void> listen({
    required void Function(String text) onPartial,
    required void Function(String text) onFinal,
  }) async {
    if (!await init()) return;
    await _speech.listen(
      onResult: (r) {
        final text = r.recognizedWords.trim();
        if (text.isEmpty) return;
        if (r.finalResult) {
          onFinal(text);
        } else {
          onPartial(text);
        }
      },
      listenOptions: SpeechListenOptions(
        // A place name, not a conversation. Stopping on the first pause
        // keeps it snappy and avoids trailing silence in the result.
        listenMode: ListenMode.search,
        partialResults: true,
        cancelOnError: true,
        // Generous enough for "the big Shell garage on Rajiv Gandhi Salai",
        // short enough that a mis-tap does not hold the mic open.
        listenFor: const Duration(seconds: 8),
        pauseFor: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> stop() async {
    if (_speech.isListening) await _speech.stop();
  }

  Future<void> cancel() async {
    if (_speech.isListening) await _speech.cancel();
  }
}
