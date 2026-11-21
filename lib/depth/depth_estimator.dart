import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../scene/image_utils.dart';
import 'depth_map.dart';

/// Monocular depth estimation with Depth Anything V2 Small (ONNX, int8),
/// running fully on-device.
///
/// Model: https://huggingface.co/onnx-community/depth-anything-v2-small
/// (Apache-2.0). Input `pixel_values` [1,3,H,W] (ImageNet-normalized, H and W
/// multiples of 14), output `predicted_depth` [1,H,W] relative disparity.
class DepthEstimator {
  static const String modelAsset =
      'assets/models/depth_anything_v2_small_q8.onnx';
  static const int inputLongSide = 518;
  static const int patch = 14;

  static const List<double> _mean = <double>[0.485, 0.456, 0.406];
  static const List<double> _std = <double>[0.229, 0.224, 0.225];

  OrtSession? _session;
  Future<OrtSession>? _loading;

  Future<OrtSession> _ensureSession() {
    final OrtSession? s = _session;
    if (s != null) return Future<OrtSession>.value(s);
    final Future<OrtSession>? pending = _loading;
    if (pending != null) return pending;
    final OnnxRuntime ort = OnnxRuntime();
    // On the web, onnxruntime-web fetches the model by URL; Flutter serves
    // bundled assets under "assets/<asset key>".
    final Future<OrtSession> create = kIsWeb
        ? ort.createSession('assets/$modelAsset')
        : ort.createSessionFromAsset(modelAsset);
    return _loading = create.then((
      OrtSession s,
    ) {
      _session = s;
      return s;
    }, onError: (Object e) {
      _loading = null; // allow a retry
      throw e;
    });
  }

  /// Loads the model ahead of time so the first photo is faster.
  Future<void> warmUp() => _ensureSession();

  /// Input size: long side 518, both sides multiples of 14, aspect kept.
  static ({int w, int h}) inputSizeFor(int width, int height) {
    final double s = inputLongSide / math.max(width, height);
    int snap(double v) => math.max(patch, (v / patch).round() * patch);
    return (w: snap(width * s), h: snap(height * s));
  }

  /// RGBA bytes -> normalized NCHW float tensor data.
  static Float32List preprocess(Uint8List rgba, int w, int h) {
    final int plane = w * h;
    final Float32List out = Float32List(3 * plane);
    for (int i = 0; i < plane; i++) {
      final int p = i * 4;
      out[i] = (rgba[p] / 255.0 - _mean[0]) / _std[0];
      out[plane + i] = (rgba[p + 1] / 255.0 - _mean[1]) / _std[1];
      out[2 * plane + i] = (rgba[p + 2] / 255.0 - _mean[2]) / _std[2];
    }
    return out;
  }

  Future<DepthMap> estimate(ui.Image photo) async {
    final OrtSession session = await _ensureSession();
    final ({int w, int h}) size = inputSizeFor(photo.width, photo.height);
    final Uint8List rgba = await imageToRgba(photo, size.w, size.h);
    final Float32List input = preprocess(rgba, size.w, size.h);

    final OrtValue tensor = await OrtValue.fromList(input, <int>[
      1,
      3,
      size.h,
      size.w,
    ]);
    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run(<String, OrtValue>{
        session.inputNames.first: tensor,
      });
      final OrtValue out = outputs[session.outputNames.first]!;
      final List<int> shape = out.shape;
      final int oh = shape[shape.length - 2];
      final int ow = shape[shape.length - 1];
      final List<dynamic> flat = await out.asFlattenedList();
      final Float32List values = Float32List(flat.length);
      for (int i = 0; i < flat.length; i++) {
        values[i] = (flat[i] as num).toDouble();
      }
      return DepthMap(ow, oh, values);
    } finally {
      await tensor.dispose();
      if (outputs != null) {
        for (final OrtValue v in outputs.values) {
          await v.dispose();
        }
      }
    }
  }

  Future<void> dispose() async {
    await _session?.close();
    _session = null;
    _loading = null;
  }
}
