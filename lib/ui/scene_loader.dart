import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../depth/depth_estimator.dart';
import '../depth/depth_map.dart';
import '../scene/image_utils.dart';
import '../scene/photo_scene.dart';
import '../scene/scene_builder.dart';

/// Photo -> AI depth -> layered 3D scene, with progress for the UI.
class SceneLoader extends ChangeNotifier {
  SceneLoader() {
    // Load the model in the background so the first photo is quicker.
    _estimator.warmUp().catchError((Object _) {});
  }

  final DepthEstimator _estimator = DepthEstimator();
  final ImagePicker _picker = ImagePicker();

  PhotoScene? scene;
  String? stage;
  String? error;
  bool get busy => stage != null;

  /// Opens the gallery / file chooser. Returns true if a new scene was built.
  Future<bool> pickAndBuild() async {
    if (busy) return false;
    final XFile? file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return false;
    return buildFromBytes(await file.readAsBytes());
  }

  Future<bool> buildFromBytes(Uint8List bytes) async {
    error = null;
    ui.Image? photo;
    try {
      _setStage('读取照片…');
      photo = await decodePhoto(bytes);

      _setStage('AI 估算深度（Depth Anything V2）…');
      final DepthMap depth = await _estimator.estimate(photo);

      _setStage('重建 3D 空间、补全遮挡背景…');
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
      stage = null;
      notifyListeners();
    }
  }

  void _setStage(String s) {
    stage = s;
    notifyListeners();
  }

  @override
  void dispose() {
    scene?.dispose();
    _estimator.dispose();
    super.dispose();
  }
}
