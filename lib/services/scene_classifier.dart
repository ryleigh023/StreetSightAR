import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'frame_codec.dart';

/// Indoor/outdoor "are you really on a street" proxy classifier.
///
/// This is **not** a model trained for indoor/outdoor classification — no
/// such lightweight pretrained model was supplied, so per the agreed
/// fallback we reuse a general-purpose pretrained scene/object classifier
/// and bucket its output classes into outdoor vs. indoor by keyword. The
/// model itself is Google's official TensorFlow Lite **MobileNetV2 1.0 224
/// (quantized)**, trained on ImageNet-1k, Apache-2.0 licensed, fetched from
/// TensorFlow Hub:
/// https://tfhub.dev/tensorflow/lite-model/mobilenet_v2_1.0_224_quantized/1/default/1
/// Labels: https://storage.googleapis.com/download.tensorflow.org/data/ImageNetLabels.txt
///
/// Treat [outdoorScore] as a weak, cheap signal to combine with GPS/VPS
/// (see `SceneGate`), not as a certified indoor/outdoor detector.
class SceneClassifier {
  static const _inputSize = 224;
  Interpreter? _interpreter;
  List<String> _labels = const [];

  // Keyword buckets over the 1000 ImageNet-1k class names. Deliberately
  // conservative (exact/substring matches on well-known classes only) so a
  // false match is rare, even though that leaves most frames "neutral".
  static const _outdoorKeywords = [
    'traffic light', 'parking meter', 'street sign', 'cab, hack', 'taxicab',
    'minivan', 'moped', 'tow truck', 'trailer truck', 'fire engine', 'garbage truck',
    'school bus', 'police van', 'sports car', 'convertible', 'jeep', 'limousine',
    'pickup', 'ambulance', 'snowplow', 'tractor', 'forklift', 'golfcart',
    'horse cart', 'oxcart', 'unicycle', 'mountain bike', 'bicycle-built-for-two',
    'streetcar', 'trolleybus', 'passenger car', 'freight car', 'bullet train',
    'steam locomotive', 'electric locomotive', 'suspension bridge',
    'steel arch bridge', 'viaduct', 'picket fence', 'chainlink fence',
    'stone wall', 'worm fence', 'alp', 'cliff', 'seashore', 'lakeside', 'valley',
    'volcano', 'geyser', 'promontory', 'sandbar', 'ski',
  ];
  static const _indoorKeywords = [
    'microwave', 'refrigerator', 'toaster', 'dishwasher', 'washer, automatic washer',
    'television', 'desktop computer', 'desk,', 'bookcase', 'wardrobe', 'four-poster',
    'chest', 'china cabinet', 'rocking chair', 'studio couch', 'toilet seat',
    'bathtub', 'shower curtain', 'medicine chest', 'home theater', 'sewing machine',
    'washbasin', 'dining table', 'folding chair', 'crib, cot', 'cradle',
    'rotisserie', 'space heater', 'vacuum, vacuum cleaner', 'ironing', 'frying pan',
    'coffee mug', 'oven',
  ];

  Future<void> load() async {
    _interpreter = await Interpreter.fromAsset('assets/models/mobilenet_v2_1.0_224_quant.tflite');
    final raw = await rootBundle.loadString('assets/models/imagenet_labels.txt');
    _labels = raw.split('\n').map((l) => l.trim()).toList();
  }

  /// Returns a value in [0, 1]: fraction of outdoor-vs-indoor keyword mass
  /// among the matched classes, or `null` if the model found no match in
  /// either bucket for this frame (truly inconclusive — common indoors and
  /// out, since most ImageNet classes are neither).
  /// Raw ranked predictions: (class index, probability), highest first.
  ///
  /// Exposed so other features can reuse the one model already resident in
  /// memory — the food identifier reads the ImageNet food classes straight
  /// out of this rather than loading a second network.
  Future<List<(int, double)>> classify(CameraImage image, int sensorOrientation, {int topK = 5}) async {
    final interpreter = _interpreter;
    if (interpreter == null) return const [];

    final upright = decodeNv21Upright(image, sensorOrientation);
    final square = resizeSquare(upright, _inputSize);
    final input = [
      List.generate(_inputSize, (y) {
        return List.generate(_inputSize, (x) {
          final p = square.getPixel(x, y);
          return [p.r.toInt(), p.g.toInt(), p.b.toInt()];
        });
      })
    ];
    final outputTensor = interpreter.getOutputTensor(0);
    final output = List.filled(1 * outputTensor.shape[1], 0).reshape([1, outputTensor.shape[1]]);
    interpreter.run(input, output);

    final params = outputTensor.params; // quantization (scale, zeroPoint)
    final scored = <(int, double)>[];
    for (var i = 0; i < output[0].length; i++) {
      final q = output[0][i] as int;
      final prob = (q - params.zeroPoint) * params.scale;
      if (prob > 0) scored.add((i, prob));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored.take(topK).toList();
  }

  Future<double?> outdoorScore(CameraImage image, int sensorOrientation) async {
    // Keyword buckets need the whole distribution, not just the top few.
    final ranked = await classify(image, sensorOrientation, topK: 1000);
    if (ranked.isEmpty) return null;

    double outdoor = 0, indoor = 0;
    for (final (i, prob) in ranked) {
      if (i >= _labels.length) continue;
      final label = _labels[i].toLowerCase();
      if (_outdoorKeywords.any(label.contains)) outdoor += prob;
      if (_indoorKeywords.any(label.contains)) indoor += prob;
    }
    final total = outdoor + indoor;
    if (total < 0.02) return null; // neither bucket fired meaningfully
    return outdoor / total;
  }


  void dispose() => _interpreter?.close();
}
