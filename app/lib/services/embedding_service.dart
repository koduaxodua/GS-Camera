import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show ServicesBinding, rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Singleton wrapper around the on-device TFLite image embedding model.
///
/// We use MobileNetV3-Small (image embedder variant from MediaPipe) which
/// takes a 224×224 RGB image and returns a 1024-d feature vector. Cosine
/// similarity in 1024-d is plenty fast (≈ 5 µs / pair) and we avoid the
/// extra complexity of bolting on a learned projection head.
///
/// Pre-processing happens on a background isolate so we don't stutter the
/// capture HUD while encoding pixels for inference. The interpreter
/// itself runs on the calling thread (it spawns its own native worker).
class EmbeddingService {
  EmbeddingService._();
  static final EmbeddingService instance = EmbeddingService._();

  /// Live ML dedup is opt-in. Running TFLite while Camera2 is previewing
  /// can make mid-range phones stutter, so the default build keeps live
  /// capture spatial-only.
  static const bool liveDedupEnabled = bool.fromEnvironment(
    'GS_ENABLE_LIVE_ML_DEDUP',
    defaultValue: false,
  );

  /// Post-capture ML dedup runs after the camera is stopped, before export.
  /// This still reduces duplicate photos without competing with preview.
  static const bool postCaptureDedupEnabled = bool.fromEnvironment(
    'GS_ENABLE_POST_ML_DEDUP',
    defaultValue: true,
  );

  static const bool enabled = liveDedupEnabled || postCaptureDedupEnabled;

  static const String _modelAsset = 'assets/ml/mobilenet_v3_small_224.tflite';
  static const int _inputSize = 224;
  static const int _outputDim = 1024;

  Interpreter? _interpreter;
  bool _initFailed = false;
  String? _initError;
  Future<void>? _initInFlight;

  /// Discovered at warmup time from the actual model output tensor.
  /// Defaults to MobileNetV3-Small's published 1024 but we don't trust
  /// the asset blindly — see [_initialize].
  int _runtimeOutputDim = _outputDim;

  /// 1024 is the mobilenet v3 small feature vector length.
  int get embeddingDim => _runtimeOutputDim;

  /// True once the model is loaded and ready. Until then, embed() returns
  /// null and dedup falls back to spatial-only logic.
  bool get isReady => _interpreter != null;

  /// Last initialization error if [isReady] is false.
  String? get initError => _initError;

  Future<void> warmup() async {
    if (!enabled) {
      _initFailed = true;
      _initError = 'ML dedup disabled';
      return;
    }
    if (_interpreter != null || _initFailed) return;
    _initInFlight ??= _initialize();
    await _initInFlight;
  }

  Future<void> _initialize() async {
    // Two threads on the CPU is plenty for a 4 MB MobileNet model — adding
    // an NNAPI delegate brings ~3× speed-up on flagship Samsungs but also
    // crashes on a non-trivial fraction of older devices, so we leave that
    // optimization for a follow-up once we have telemetry from real users.
    try {
      final options = InterpreterOptions()..threads = 2;
      final interpreter =
          await Interpreter.fromAsset(_modelAsset, options: options);
      // Validate shapes BEFORE handing the interpreter out so any
      // mismatch surfaces as a clear init failure rather than every
      // subsequent embed() returning null.
      final inputShape = interpreter.getInputTensor(0).shape;
      final outputShape = interpreter.getOutputTensor(0).shape;
      // Expect input [1, 224, 224, 3].
      final inputOk = inputShape.length == 4 &&
          inputShape[0] == 1 &&
          inputShape[1] == _inputSize &&
          inputShape[2] == _inputSize &&
          inputShape[3] == 3;
      // Output is typically [1, N] or [1, 1, 1, N]; flatten to find N.
      final outputDim = outputShape.fold<int>(1, (a, b) => a * b);
      if (!inputOk || outputDim < 64) {
        interpreter.close();
        _initFailed = true;
        _initError = 'Unexpected model shape: in=$inputShape '
            'out=$outputShape';
        return;
      }
      _runtimeOutputDim = outputDim;
      _interpreter = interpreter;
      // Smoke-test with a zero-tensor to flush any lazy init paths and
      // catch shape mismatches that don't show up at metadata read time.
      final zeros = Float32List(_inputSize * _inputSize * 3);
      final probe = List.generate(1, (_) => List<double>.filled(outputDim, 0));
      try {
        _interpreter!.run(zeros.reshape([1, _inputSize, _inputSize, 3]), probe);
        debugPrint('EmbeddingService: ready, '
            'in=$inputShape out=$outputShape (dim=$outputDim)');
      } catch (e) {
        _interpreter!.close();
        _interpreter = null;
        _initFailed = true;
        _initError = 'Probe inference failed: $e';
      }
    } catch (e) {
      _initFailed = true;
      _initError = e.toString();
    }
  }

  /// Run inference on a JPEG byte array. Returns null if the model isn't
  /// available — callers should treat that as "skip dedup, keep the frame".
  Future<Float32List?> embedJpeg(Uint8List jpegBytes) async {
    if (!enabled) return null;
    if (_interpreter == null) {
      await warmup();
      if (_interpreter == null) return null;
    }
    final input = await _preprocessOnIsolate(jpegBytes);
    if (input == null) return null;

    // Output buffer must match the interpreter's output tensor shape.
    final dim = _runtimeOutputDim;
    final output = List.generate(1, (_) => List<double>.filled(dim, 0));
    try {
      _interpreter!.run(input.reshape([1, _inputSize, _inputSize, 3]), output);
    } catch (_) {
      return null;
    }
    final embedding = Float32List(dim);
    for (var i = 0; i < dim; i++) {
      embedding[i] = output[0][i].toDouble();
    }
    return embedding;
  }

  /// Cosine similarity in [-1, 1]. ≥ 0.92 ≈ "essentially the same view"
  /// for natural indoor scenes; tune empirically.
  static double cosineSimilarity(Float32List a, Float32List b) {
    if (a.length != b.length || a.isEmpty) return 0;
    var dot = 0.0;
    var na = 0.0;
    var nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    final denom = math.sqrt(na) * math.sqrt(nb);
    if (denom == 0) return 0;
    return dot / denom;
  }

  /// Decode + resize + normalise the JPEG on a background isolate so the
  /// UI thread stays smooth during capture.
  Future<Float32List?> _preprocessOnIsolate(Uint8List jpegBytes) async {
    try {
      final token = ServicesBinding.rootIsolateToken;
      if (token == null) {
        return _preprocessSync(jpegBytes);
      }
      return await Isolate.run(() => _preprocessSync(jpegBytes));
    } catch (_) {
      return _preprocessSync(jpegBytes);
    }
  }

  static Float32List? _preprocessSync(Uint8List jpegBytes) {
    final decoded = img.decodeJpg(jpegBytes);
    if (decoded == null) return null;
    final resized = img.copyResize(
      decoded,
      width: _inputSize,
      height: _inputSize,
      interpolation: img.Interpolation.linear,
    );
    final out = Float32List(_inputSize * _inputSize * 3);
    var i = 0;
    for (var y = 0; y < _inputSize; y++) {
      for (var x = 0; x < _inputSize; x++) {
        final px = resized.getPixel(x, y);
        out[i++] = px.r / 255.0;
        out[i++] = px.g / 255.0;
        out[i++] = px.b / 255.0;
      }
    }
    return out;
  }

  /// Verify the asset exists at compile time so misconfigurations show up
  /// as a clear startup error rather than the first capture mysteriously
  /// failing.
  static Future<bool> assetIsBundled() async {
    try {
      final data = await rootBundle.load(_modelAsset);
      return data.lengthInBytes > 1024;
    } catch (_) {
      return false;
    }
  }
}
