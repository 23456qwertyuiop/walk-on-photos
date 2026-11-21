import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../depth/depth_estimator.dart';
import '../depth/depth_map.dart';
import '../scene/image_utils.dart';
import '../scene/photo_scene.dart';
import '../scene/scene_builder.dart';

/// Photo -> AI depth -> layered 3D scene.
class SceneLoader extends ChangeNotifier {
  SceneLoader() {
    // Load the model in the background so the first photo is quicker.
    _estimator.warmUp().catchError((Object _) {});
  }

  final DepthEstimator _estimator = DepthEstimator();
  final ImagePicker _picker = ImagePicker();

  PhotoScene? scene;
  bool _busy = false;
  int _sceneVersion = 0;
  String? error;

  bool get busy => _busy;
  int get sceneVersion => _sceneVersion;

  /// Opens the gallery / file chooser. Returns true if a new scene was built.
  Future<bool> pickAndBuild() async {
    if (_busy) return false;
    final XFile? file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return false;
    return buildFromBytes(await file.readAsBytes());
  }

  Future<bool> buildFromBytes(Uint8List bytes) async {
    error = null;
    _busy = true;
    _sceneVersion++;
    notifyListeners();

    ui.Image? photo;
    try {
      // Let the black-screen fade finish painting before running heavy
      // depth inference / 3D mesh generation (especially on Web).
      await Future<void>.delayed(const Duration(milliseconds: 240));

      photo = await decodePhoto(bytes);
      final DepthMap depth = await _estimator.estimate(photo);
      final PhotoScene built = await SceneBuilder.build(photo, depth);

      final PhotoScene? old = scene;
      scene = built;
      old?.dispose();
      return true;
    } catch (e, st) {
      debugPrint('Scene build failed: $e\n$st');
      error = '生成失败：$e';
      return false;
    } finally {
      photo?.dispose();
      _busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    scene?.dispose();
    _estimator.dispose();
    super.dispose();
  }
}
