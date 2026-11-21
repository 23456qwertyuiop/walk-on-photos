import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../depth/depth_estimator.dart';
import '../depth/depth_map.dart';
import '../scene/image_utils.dart';
import '../scene/photo_scene.dart';
import '../scene/scene_builder.dart';

/// Photo -> AI depth -> layered 3D scene, with lightweight preview image
/// for the fly-in transition animation.
class SceneLoader extends ChangeNotifier {
  SceneLoader() {
    // Load the model in the background so the first photo is quicker.
    _estimator.warmUp().catchError((Object _) {});
  }

  final DepthEstimator _estimator = DepthEstimator();
  final ImagePicker _picker = ImagePicker();

  PhotoScene? scene;
  ui.Image? _previewPhoto;
  bool _busy = false;
  int _sceneVersion = 0;
  String? error;

  bool get busy => _busy;
  ui.Image? get previewPhoto => _previewPhoto;
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
    notifyListeners();

    ui.Image? photo;
    try {
      photo = await decodePhoto(bytes);

      // Expose a resized preview immediately so the fly-in animation can
      // start assembling pieces on screen while depth & 3D mesh compute.
      final ui.Image preview = await resizeImage(photo, 640);
      final ui.Image? oldPreview = _previewPhoto;
      _previewPhoto = preview;
      _sceneVersion++;
      notifyListeners();
      oldPreview?.dispose();

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
    _previewPhoto?.dispose();
    _estimator.dispose();
    super.dispose();
  }
}
